import Foundation

struct CodexTaskSession: Identifiable, Equatable {
    enum Status: String, Equatable {
        case running
        case ended

        var title: String {
            switch self {
            case .running:
                return "进行中"
            case .ended:
                return "已结束"
            }
        }
    }

    let id: String
    let threadID: String
    let turnID: String
    let projectName: String
    let taskName: String
    let status: Status
    let startedAt: Date
    let endedAt: Date?

    var sortDate: Date {
        endedAt ?? startedAt
    }

    func shouldDisplay(referenceDate: Date = Date()) -> Bool {
        switch status {
        case .running:
            return true
        case .ended:
            guard let endedAt else { return false }
            return endedAt.addingTimeInterval(5 * 60) > referenceDate
        }
    }
}

enum CodexTaskDisplaySettings {
    static let showSessionsKey = "showCodexTaskSessions"

    static func isEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: showSessionsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: showSessionsKey)
    }
}

enum CodexTaskSessionReader {
    private static let tailReadSizes: [Int] = [
        128 * 1024,
        512 * 1024,
        2 * 1024 * 1024,
        8 * 1024 * 1024
    ]
    private static let headReadSize = 64 * 1024

    private static let codexRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }()

    private static let sessionIndexURL = codexRoot.appendingPathComponent("session_index.jsonl", isDirectory: false)

    static var sessionIndexWatchPath: String {
        sessionIndexURL.path
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func loadRecentTasks(limit: Int = 24) -> [CodexTaskSession] {
        let threadNames = loadThreadNames()
        let files = QuotaReader.findSessionFiles(limit: limit)

        var newestByThreadID: [String: CodexTaskSession] = [:]
        for file in files {
            let sessionHeader = loadSessionHeader(from: file)
            guard let threadID = sessionHeader?.sessionID ?? threadID(from: file),
                  let task = extractLatestTask(
                    from: file,
                    threadID: threadID,
                    preferredTitle: threadNames[threadID],
                    initialCwd: sessionHeader?.cwd
                  ) else {
                continue
            }

            if let existing = newestByThreadID[threadID] {
                if task.sortDate > existing.sortDate {
                    newestByThreadID[threadID] = task
                }
            } else {
                newestByThreadID[threadID] = task
            }
        }

        return newestByThreadID.values.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .running
            }
            return lhs.sortDate > rhs.sortDate
        }
    }

    private static func extractLatestTask(
        from url: URL,
        threadID: String,
        preferredTitle: String?,
        initialCwd: String?
    ) -> CodexTaskSession? {
        guard let fileSize = fileSize(of: url) else { return nil }

        var latestScan: TailScanResult?
        for maxBytes in tailReadSizes {
            let bytesToRead = min(maxBytes, fileSize)
            let isPartialRead = bytesToRead < fileSize
            guard let text = readTailText(from: url, bytesToRead: bytesToRead),
                  let scan = scanLatestTask(from: text, dropFirstLine: isPartialRead) else {
                continue
            }

            latestScan = scan
            if scan.cwd != nil || !isPartialRead {
                break
            }
        }

        // 超长会话里，task_started 可能已经被后续的大量工具输出“挤”到尾部 8MB 之外。
        // 这种情况只对当前文件做一次整文件兜底，避免长时间运行的会话直接消失。
        if latestScan == nil {
            latestScan = scanLatestTaskInWholeFile(from: url)
        }

        guard var latestScan else { return nil }
        if latestScan.cwd == nil {
            latestScan.cwd = initialCwd
        }

        if latestScan.cwd == nil || (preferredTitle == nil && latestScan.fallbackTitle == nil) {
            enrichFromHead(of: url, scan: &latestScan)
        }

        let title = preferredTitle ?? latestScan.fallbackTitle ?? "未命名会话"
        let projectName = projectName(from: latestScan.cwd)
        let taskID = "\(threadID):\(latestScan.task.turnID)"

        return CodexTaskSession(
            id: taskID,
            threadID: threadID,
            turnID: latestScan.task.turnID,
            projectName: projectName,
            taskName: title,
            status: latestScan.task.status,
            startedAt: latestScan.task.startedAt,
            endedAt: latestScan.task.endedAt
        )
    }

    // 只从日志尾部反向找最后一轮任务，避免每次刷新都扫完整个 jsonl。
    private static func scanLatestTask(
        from text: String,
        dropFirstLine: Bool
    ) -> TailScanResult? {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        let iterable = dropFirstLine ? lines.dropFirst() : ArraySlice(lines)

        var latestTaskInfo: LatestTask?
        var cwd: String?

        for line in iterable.reversed() {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data) else {
                continue
            }

            if latestTaskInfo == nil {
                latestTaskInfo = latestTask(from: envelope)
                continue
            }

            if cwd == nil,
               envelope.type == "turn_context",
               envelope.payload?.turnID == latestTaskInfo?.turnID,
               let lineCwd = trimmed(envelope.payload?.cwd) {
                cwd = lineCwd
            }

            if cwd != nil {
                break
            }
        }

        guard let latestTaskInfo else { return nil }
        return TailScanResult(task: latestTaskInfo, cwd: cwd, fallbackTitle: nil)
    }

    private static func scanLatestTaskInWholeFile(from url: URL) -> TailScanResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        var latestTaskInfo: LatestTask?
        var cwdByTurnID: [String: String] = [:]

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data) else {
                continue
            }

            if envelope.type == "turn_context",
               let turnID = trimmed(envelope.payload?.turnID),
               let lineCwd = trimmed(envelope.payload?.cwd) {
                cwdByTurnID[turnID] = lineCwd
            }

            if let task = latestTask(from: envelope) {
                latestTaskInfo = task
            }
        }

        guard let latestTaskInfo else { return nil }
        return TailScanResult(
            task: latestTaskInfo,
            cwd: cwdByTurnID[latestTaskInfo.turnID],
            fallbackTitle: nil
        )
    }

    private static func enrichFromHead(of url: URL, scan: inout TailScanResult) {
        guard let text = readHeadText(from: url, bytesToRead: headReadSize) else { return }

        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data) else {
                continue
            }

            if scan.cwd == nil,
               envelope.type == "session_meta",
               let lineCwd = trimmed(envelope.payload?.cwd) {
                scan.cwd = lineCwd
            }

            if scan.fallbackTitle == nil,
               let title = fallbackTitle(from: envelope) {
                scan.fallbackTitle = title
            }

            if scan.cwd != nil && scan.fallbackTitle != nil {
                break
            }
        }
    }

    private static func fallbackTitle(from envelope: SessionEnvelope) -> String? {
        if envelope.type == "event_msg",
           envelope.payload?.type == "user_message" {
            return cleanedTaskTitle(from: envelope.payload?.message)
        }

        guard envelope.type == "response_item",
              envelope.payload?.type == "message",
              envelope.payload?.role == "user" else {
            return nil
        }

        let raw = envelope.payload?.content?
            .compactMap(\.text)
            .joined(separator: "\n")

        return cleanedResponseItemUserTitle(from: raw)
    }

    private static func latestTask(from envelope: SessionEnvelope) -> LatestTask? {
        guard envelope.type == "event_msg",
              let payload = envelope.payload,
              let turnID = trimmed(payload.turnID) else {
            return nil
        }

        switch payload.type {
        case "task_started":
            guard let startedAt = payload.startedAt.map({ Date(timeIntervalSince1970: $0) }) ?? parsedDate(from: envelope.timestamp) else {
                return nil
            }
            return LatestTask(
                turnID: turnID,
                status: .running,
                startedAt: startedAt,
                endedAt: nil
            )
        case "task_complete", "turn_aborted":
            guard let endedAt = payload.completedAt.map({ Date(timeIntervalSince1970: $0) }) ?? parsedDate(from: envelope.timestamp) else {
                return nil
            }
            let startedAt: Date
            if let started = payload.startedAt.map({ Date(timeIntervalSince1970: $0) }) {
                startedAt = started
            } else if let durationMS = payload.durationMS {
                startedAt = endedAt.addingTimeInterval(-(durationMS / 1000))
            } else {
                startedAt = endedAt
            }
            return LatestTask(
                turnID: turnID,
                status: .ended,
                startedAt: startedAt,
                endedAt: endedAt
            )
        default:
            return nil
        }
    }

    private static func loadThreadNames() -> [String: String] {
        guard let text = try? String(contentsOf: sessionIndexURL, encoding: .utf8) else { return [:] }

        var names: [String: IndexedThreadName] = [:]
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(SessionIndexRecord.self, from: data),
                  let title = trimmed(record.threadName) else {
                continue
            }

            let updatedAt = parsedDate(from: record.updatedAt)
            if let existing = names[record.id] {
                if (updatedAt ?? .distantPast) >= (existing.updatedAt ?? .distantPast) {
                    names[record.id] = IndexedThreadName(title: title, updatedAt: updatedAt)
                }
            } else {
                names[record.id] = IndexedThreadName(title: title, updatedAt: updatedAt)
            }
        }

        return names.mapValues(\.title)
    }

    private static func loadSessionHeader(from url: URL) -> SessionHeader? {
        guard let text = readHeadText(from: url, bytesToRead: headReadSize),
              let firstLine = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first,
              let data = firstLine.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data),
              envelope.type == "session_meta" else {
            return nil
        }

        let sessionID = trimmed(envelope.payload?.sessionID) ?? trimmed(envelope.payload?.id)
        let cwd = trimmed(envelope.payload?.cwd)
        return SessionHeader(sessionID: sessionID, cwd: cwd)
    }

    private static func threadID(from url: URL) -> String? {
        let fileName = url.lastPathComponent
        guard let range = fileName.range(
            of: #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        return fileName[range]
            .replacingOccurrences(of: ".jsonl", with: "")
            .lowercased()
    }

    private static func projectName(from cwd: String?) -> String {
        guard let cwd = trimmed(cwd) else { return "未知项目" }
        let lastPath = URL(fileURLWithPath: cwd).lastPathComponent
        return trimmed(lastPath) ?? cwd
    }

    private static func cleanedTaskTitle(from raw: String?) -> String? {
        guard var text = trimmed(raw) else { return nil }

        if let start = text.range(of: "<in-app-browser-context"),
           let end = text.range(of: "</in-app-browser-context>") {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }

        if let requestRange = text.range(of: "## My request for Codex:") {
            text = String(text[requestRange.upperBound...])
        }

        let lines = text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }

        guard let firstLine = lines.first else { return nil }
        return trimmed(firstLine)
    }

    private static func cleanedResponseItemUserTitle(from raw: String?) -> String? {
        guard let raw = trimmed(raw) else { return nil }

        if raw.contains("<recommended_plugins>") || raw.contains("# AGENTS.md instructions") {
            return nil
        }

        if raw.contains("# Files mentioned by the user:"),
           !raw.contains("## My request for Codex:") {
            return nil
        }

        return cleanedTaskTitle(from: raw)
    }

    private static func parsedDate(from raw: String?) -> Date? {
        guard let raw = trimmed(raw) else { return nil }
        return isoFormatterWithFractionalSeconds.date(from: raw) ?? isoFormatter.date(from: raw)
    }

    private static func readTailText(from url: URL, bytesToRead: Int) -> String? {
        guard bytesToRead > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(),
              fileSize > 0 else { return nil }
        let readCount = min(UInt64(bytesToRead), fileSize)
        let offset = fileSize - readCount
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: Int(readCount))
        return String(decoding: data, as: UTF8.self)
    }

    private static func readHeadText(from url: URL, bytesToRead: Int) -> String? {
        guard bytesToRead > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: bytesToRead)
        return String(decoding: data, as: UTF8.self)
    }

    private static func fileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0 else { return nil }
        return size
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private extension CodexTaskSessionReader {
    struct TailScanResult {
        let task: LatestTask
        var cwd: String?
        var fallbackTitle: String?
    }

    struct LatestTask {
        let turnID: String
        let status: CodexTaskSession.Status
        let startedAt: Date
        let endedAt: Date?
    }

    struct IndexedThreadName {
        let title: String
        let updatedAt: Date?
    }

    struct SessionHeader {
        let sessionID: String?
        let cwd: String?
    }

    struct SessionIndexRecord: Decodable {
        let id: String
        let threadName: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
            case updatedAt = "updated_at"
        }
    }

    struct SessionEnvelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?
    }

    struct Payload: Decodable {
        let type: String?
        let sessionID: String?
        let id: String?
        let turnID: String?
        let startedAt: TimeInterval?
        let completedAt: TimeInterval?
        let durationMS: Double?
        let cwd: String?
        let message: String?
        let role: String?
        let content: [MessageContent]?

        enum CodingKeys: String, CodingKey {
            case type
            case sessionID = "session_id"
            case id
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case durationMS = "duration_ms"
            case cwd
            case message
            case role
            case content
        }
    }

    struct MessageContent: Decodable {
        let type: String?
        let text: String?
    }
}

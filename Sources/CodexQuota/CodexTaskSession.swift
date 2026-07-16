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

enum CodexTaskCompactDisplayStyle: String, CaseIterable, Identifiable {
    // 前四个存储值已经上线，不能改名或复用为其他样式。
    case stacked
    case capsule
    case badge
    case carousel
    case layered
    case taskRail
    case statusCards
    case timeline

    static let storageKey = "codexTaskCompactDisplayStyle"
    static let defaultValue: CodexTaskCompactDisplayStyle = .badge
    static let legacyCases: [CodexTaskCompactDisplayStyle] = [.stacked, .capsule, .badge, .carousel]
    static let fullListCases: [CodexTaskCompactDisplayStyle] = [.layered, .taskRail, .statusCards, .timeline]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "双层"
        case .capsule: return "胶囊"
        case .badge: return "角标"
        case .carousel: return "轮播"
        case .layered: return "分层"
        case .taskRail: return "任务轨"
        case .statusCards: return "状态卡"
        case .timeline: return "时间线"
        }
    }

    var detail: String {
        switch self {
        case .stacked: return "额度和当前会话分成两行显示。"
        case .capsule: return "当前会话显示为紧凑胶囊。"
        case .badge: return "只显示运行和结束数量，最节省空间。"
        case .carousel: return "额度与当前会话定时切换显示。"
        case .layered: return "逐行显示全部会话，信息最清楚。"
        case .taskRail: return "按运行状态分组显示全部会话。"
        case .statusCards: return "全部会话使用独立色块，状态最醒目。"
        case .timeline: return "用状态点和连线显示全部会话。"
        }
    }

    var showsAllSessions: Bool {
        Self.fullListCases.contains(self)
    }
}

enum CodexTaskSessionReader {
    private static let maximumTailReadSize = 8 * 1024 * 1024
    private static let maximumHeadReadSize = 64 * 1024
    private static let sessionIndexReadSize = 2 * 1024 * 1024
    private static let tailReadSizes: [Int] = [
        128 * 1024,
        512 * 1024,
        2 * 1024 * 1024,
        maximumTailReadSize
    ]
    private static let cacheLock = NSLock()
    private static var sessionFileCache: [String: CachedSessionFile] = [:]
    private static var threadNameCache: CachedThreadNames?

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
        // 除了上层合并刷新，这里也强制串行，防止未来其他调用方并发扫描日志。
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let threadNames = loadThreadNames()
        let files = QuotaReader.findSessionFiles(limit: limit)
        let recentPaths = Set(files.map(\.path))
        sessionFileCache = sessionFileCache.filter { recentPaths.contains($0.key) }

        var newestByThreadID: [String: CodexTaskSession] = [:]
        for file in files {
            guard let task = extractLatestTask(from: file, threadNames: threadNames) else {
                continue
            }
            let threadID = task.threadID

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
        threadNames: [String: String]
    ) -> CodexTaskSession? {
        guard let fingerprint = fileFingerprint(of: url) else { return nil }
        let cacheKey = url.path

        if let cached = sessionFileCache[cacheKey],
           cached.fingerprint == fingerprint {
            return makeTask(from: cached, preferredTitle: threadNames[cached.threadID])
        }

        let sessionHeader = loadSessionHeader(from: url)
        guard let threadID = sessionHeader?.sessionID ?? threadID(from: url) else { return nil }

        var latestScan: TailScanResult?
        for maxBytes in tailReadSizes {
            let bytesToRead = min(maxBytes, fingerprint.fileSize)
            let isPartialRead = bytesToRead < fingerprint.fileSize
            guard let text = readTailText(from: url, bytesToRead: bytesToRead),
                  let scan = scanLatestTask(from: text, dropFirstLine: isPartialRead) else {
                continue
            }

            latestScan = scan
            if scan.cwd != nil || !isPartialRead {
                break
            }
        }

        // 文件继续增长但任务标记已离开尾部窗口时，沿用本次进程之前的有界扫描结果。
        if latestScan == nil,
           let cached = sessionFileCache[cacheKey],
           cached.threadID == threadID,
           fingerprint.fileSize > cached.fingerprint.fileSize {
            latestScan = cached.scan
        }

        guard var latestScan else {
            sessionFileCache[cacheKey] = CachedSessionFile(
                fingerprint: fingerprint,
                threadID: threadID,
                scan: nil
            )
            return nil
        }
        if latestScan.cwd == nil {
            latestScan.cwd = sessionHeader?.cwd
        }

        let preferredTitle = threadNames[threadID]
        if latestScan.cwd == nil || (preferredTitle == nil && latestScan.fallbackTitle == nil) {
            enrichFromHead(of: url, scan: &latestScan)
        }

        let cached = CachedSessionFile(
            fingerprint: fingerprint,
            threadID: threadID,
            scan: latestScan
        )
        sessionFileCache[cacheKey] = cached
        return makeTask(from: cached, preferredTitle: preferredTitle)
    }

    private static func makeTask(
        from cached: CachedSessionFile,
        preferredTitle: String?
    ) -> CodexTaskSession? {
        guard let latestScan = cached.scan else { return nil }
        let title = preferredTitle ?? latestScan.fallbackTitle ?? "未命名会话"
        let projectName = projectName(from: latestScan.cwd)
        let taskID = "\(cached.threadID):\(latestScan.task.turnID)"

        return CodexTaskSession(
            id: taskID,
            threadID: cached.threadID,
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

    private static func enrichFromHead(of url: URL, scan: inout TailScanResult) {
        guard let text = readHeadText(from: url, bytesToRead: maximumHeadReadSize) else { return }

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
        guard let fingerprint = fileFingerprint(of: sessionIndexURL) else {
            threadNameCache = nil
            return [:]
        }
        if let cached = threadNameCache,
           cached.fingerprint == fingerprint {
            return cached.names
        }

        let bytesToRead = min(sessionIndexReadSize, fingerprint.fileSize)
        let isPartialRead = bytesToRead < fingerprint.fileSize
        guard let text = readTailText(from: sessionIndexURL, bytesToRead: bytesToRead) else {
            return [:]
        }
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        let iterable = isPartialRead ? lines.dropFirst() : ArraySlice(lines)

        var names: [String: IndexedThreadName] = [:]
        for line in iterable {
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

        let result = names.mapValues(\.title)
        threadNameCache = CachedThreadNames(fingerprint: fingerprint, names: result)
        return result
    }

    private static func loadSessionHeader(from url: URL) -> SessionHeader? {
        guard let text = readHeadText(from: url, bytesToRead: maximumHeadReadSize),
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
        // 双重限制读取量，调用方即使传错参数也不能把整个超大会话载入内存。
        let boundedBytes = min(bytesToRead, maximumTailReadSize)
        let readCount = min(UInt64(boundedBytes), fileSize)
        let offset = fileSize - readCount
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: Int(readCount))
        return String(decoding: data, as: UTF8.self)
    }

    private static func readHeadText(from url: URL, bytesToRead: Int) -> String? {
        guard bytesToRead > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: min(bytesToRead, maximumHeadReadSize))
        return String(decoding: data, as: UTF8.self)
    }

#if DEBUG
    static func readTailTextForTesting(from url: URL, bytesToRead: Int) -> String? {
        readTailText(from: url, bytesToRead: bytesToRead)
    }

    static func readHeadTextForTesting(from url: URL, bytesToRead: Int) -> String? {
        readHeadText(from: url, bytesToRead: bytesToRead)
    }
#endif

    private static func fileFingerprint(of url: URL) -> FileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              size > 0 else { return nil }
        return FileFingerprint(fileSize: size, modificationDate: values.contentModificationDate)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private extension CodexTaskSessionReader {
    struct FileFingerprint: Equatable {
        let fileSize: Int
        let modificationDate: Date?
    }

    struct CachedSessionFile {
        let fingerprint: FileFingerprint
        let threadID: String
        let scan: TailScanResult?
    }

    struct CachedThreadNames {
        let fingerprint: FileFingerprint
        let names: [String: String]
    }

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

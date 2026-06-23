import Foundation

/// 从 ~/.codex/sessions/**/*.jsonl 中读取最新的 rate_limits
enum QuotaReader {
    private static let tailReadSizes: [Int] = [
        256 * 1024,
        1024 * 1024,
        4 * 1024 * 1024,
        16 * 1024 * 1024
    ]

    static let sessionsRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }()

    /// 找到所有 .jsonl 文件，按 mtime 倒序（正在使用的 session 会持续更新 mtime）
    static func findSessionFiles(limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate else { continue }
            files.append((url, mtime))
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).map { $0.0 }
    }

    /// 反向扫描文件，优先取“更像主额度”的 rate_limits，避免误拿到某个模型自己的额度桶
    static func extractLatestLimits(from url: URL) -> (RateLimits, Date)? {
        guard let fileSize = fileSize(of: url) else { return nil }

        var fallback: (RateLimits, Date)?
        var fallbackPriority = Int.min

        for maxBytes in tailReadSizes {
            let bytesToRead = min(maxBytes, fileSize)
            let isPartialRead = bytesToRead < fileSize
            guard let text = readTailText(from: url, bytesToRead: bytesToRead) else { continue }
            guard let candidate = extractBestLimits(from: text, dropFirstLine: isPartialRead) else { continue }

            let priority = candidate.0.displayPriority
            if priority > fallbackPriority {
                fallback = candidate
                fallbackPriority = priority
            }
            if priority >= RateLimits.maxDisplayPriority || !isPartialRead {
                return candidate
            }
        }
        return fallback
    }

    private struct Envelope: Decodable {
        let timestamp: String?
        let payload: Payload
        struct Payload: Decodable {
            let type: String?
            let info: Info?
            let rateLimits: RateLimits?
            enum CodingKeys: String, CodingKey {
                case type, info
                case rateLimits = "rate_limits"
            }
        }
        struct Info: Decodable {
            let rateLimits: RateLimits?
            enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseLine(_ data: Data) -> (RateLimits, Date)? {
        let decoder = JSONDecoder()
        guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }

        // rate_limits 既可能在 payload 顶层，也可能在 payload.info 内（不同版本不同）
        let limits = env.payload.rateLimits ?? env.payload.info?.rateLimits
        guard let limits else { return nil }

        let date: Date
        if let ts = env.timestamp, let parsed = isoFormatter.date(from: ts) {
            date = parsed
        } else {
            date = Date()
        }
        return (limits, date)
    }

    /// 主入口：在最新若干个会话文件中寻找最新的快照
    static func loadLatest() -> QuotaSnapshot? {
        var best: (RateLimits, Date)?
        var bestPriority = Int.min

        for file in findSessionFiles(limit: 12) {
            if let best,
               bestPriority >= RateLimits.maxDisplayPriority,
               let mtime = modificationDate(of: file),
               mtime < best.1 {
                break
            }

            guard let (limits, date) = extractLatestLimits(from: file) else { continue }
            let priority = limits.displayPriority

            if best == nil || priority > bestPriority || (priority == bestPriority && date > best!.1) {
                best = (limits, date)
                bestPriority = priority
            }
        }

        guard let best else { return nil }
        return QuotaSnapshot(limits: best.0, capturedAt: best.1)
    }

    private static func extractBestLimits(from text: String, dropFirstLine: Bool) -> (RateLimits, Date)? {
        var best: (RateLimits, Date)?
        var bestPriority = Int.min
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
        let iterable = dropFirstLine ? lines.dropFirst() : ArraySlice(lines)

        for line in iterable.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let parsed = parseLine(lineData) else { continue }

            let priority = parsed.0.displayPriority
            guard priority >= 0 else { continue }
            if priority > bestPriority {
                best = parsed
                bestPriority = priority
            }
        }
        return best
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

    private static func fileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0 else { return nil }
        return size
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

import Foundation

/// 从 ~/.codex/sessions/**/*.jsonl 中读取最新的 rate_limits
enum QuotaReader {
    private static let maximumScanSize = 16 * 1024 * 1024
    private static let readChunkSize = 256 * 1024
    private static let maximumCandidateLineSize = 1024 * 1024
    private static let rateLimitsMarker = Data("\"rate_limits\"".utf8)

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

    /// 分块反向扫描，优先取“更像主额度”的 rate_limits。
    /// 最多检查 16 MB，但不会把整段会话日志一次性载入内存。
    static func extractLatestLimits(from url: URL) -> (RateLimits, Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        let scanStart = fileSize > UInt64(maximumScanSize)
            ? fileSize - UInt64(maximumScanSize)
            : 0
        var cursor = fileSize
        var trailingFragment = Data()
        var discardingOversizedLine = false
        var best: (RateLimits, Date)?
        var bestPriority = Int.min

        func consider(_ line: Data) -> Bool {
            guard !line.isEmpty,
                  line.count <= maximumCandidateLineSize,
                  line.range(of: rateLimitsMarker) != nil,
                  let parsed = parseLine(line) else {
                return false
            }

            let priority = parsed.0.displayPriority
            guard priority >= 0 else { return false }
            if parsed.0.isMainQuota {
                best = parsed
                bestPriority = priority
                return true
            }
            if priority > bestPriority {
                best = parsed
                bestPriority = priority
            }
            return false
        }

        while cursor > scanStart {
            // 先限制本次读取长度，再做减法，避免小文件触发 UInt64 下溢。
            let availableLength = cursor - scanStart
            let chunkLength = min(UInt64(readChunkSize), availableLength)
            let chunkStart = cursor - chunkLength
            guard (try? handle.seek(toOffset: chunkStart)) != nil else { break }
            let chunk = handle.readData(ofLength: Int(chunkLength))
            guard !chunk.isEmpty else { break }

            var prefixEnd = chunk.endIndex
            if discardingOversizedLine {
                guard let newline = chunk.lastIndex(of: 0x0A) else {
                    cursor = chunkStart
                    continue
                }
                // 这个换行之后的内容属于已超限的同一行，直接丢弃。
                prefixEnd = newline
                discardingOversizedLine = false
            } else if let newline = chunk.lastIndex(of: 0x0A) {
                var completedLine = Data(chunk[chunk.index(after: newline)...])
                completedLine.append(trailingFragment)
                trailingFragment.removeAll(keepingCapacity: true)
                if consider(completedLine) { return best }
                prefixEnd = newline
            } else {
                if chunk.count > maximumCandidateLineSize - trailingFragment.count {
                    trailingFragment.removeAll(keepingCapacity: false)
                    discardingOversizedLine = true
                } else {
                    var combined = chunk
                    combined.append(trailingFragment)
                    trailingFragment = combined
                }
                cursor = chunkStart
                continue
            }

            let fragments = chunk[..<prefixEnd].split(
                separator: 0x0A,
                omittingEmptySubsequences: false
            )
            if let first = fragments.first {
                for fragment in fragments.dropFirst().reversed() {
                    if consider(Data(fragment)) { return best }
                }

                if chunkStart == 0 {
                    if consider(Data(first)) { return best }
                    trailingFragment.removeAll(keepingCapacity: false)
                } else {
                    trailingFragment = Data(first)
                }
            }
            cursor = chunkStart
        }

        if scanStart == 0, !discardingOversizedLine, !trailingFragment.isEmpty {
            _ = consider(trailingFragment)
        }
        return best
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
        var latestMain: (RateLimits, Date)?
        var fallback: (RateLimits, Date)?
        var fallbackPriority = Int.min

        for file in findSessionFiles(limit: 12) {
            if let latestMain,
               let mtime = modificationDate(of: file),
               mtime < latestMain.1 {
                break
            }

            guard let (limits, date) = extractLatestLimits(from: file) else { continue }
            if limits.isMainQuota {
                if latestMain == nil || date > latestMain!.1 {
                    latestMain = (limits, date)
                }
                continue
            }

            let priority = limits.displayPriority
            if fallback == nil || priority > fallbackPriority || (priority == fallbackPriority && date > fallback!.1) {
                fallback = (limits, date)
                fallbackPriority = priority
            }
        }

        guard let best = latestMain ?? fallback else { return nil }
        return QuotaSnapshot(limits: best.0, capturedAt: best.1)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

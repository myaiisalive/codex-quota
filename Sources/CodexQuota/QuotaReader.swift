import Foundation

/// 从 ~/.codex/sessions/**/*.jsonl 中读取最新的 rate_limits
enum QuotaReader {
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

    /// 反向扫描文件，找到第一条带 rate_limits 的事件
    static func extractLatestLimits(from url: URL) -> (RateLimits, Date)? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // 反向遍历每一行，命中含 rate_limits 的就解析
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            if let parsed = parseLine(lineData) {
                return parsed
            }
        }
        return nil
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
        for file in findSessionFiles(limit: 12) {
            guard let (limits, date) = extractLatestLimits(from: file) else { continue }
            if best == nil || date > best!.1 {
                best = (limits, date)
            }
        }
        guard let best else { return nil }
        return QuotaSnapshot(limits: best.0, capturedAt: best.1)
    }
}

import Foundation

@main
struct QuotaReaderRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let quotaLine = """
        {"timestamp":"2026-07-16T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":2000000000},"secondary":{"used_percent":18,"window_minutes":10080,"resets_at":2000000000}}}}
        """

        // 小于单次读取块的文件曾因 UInt64 减法下溢导致应用直接崩溃。
        let smallFile = directory.appendingPathComponent("small-quota-session.jsonl")
        try Data((quotaLine + "\n").utf8).write(to: smallFile)
        guard let smallResult = QuotaReader.extractLatestLimits(from: smallFile) else {
            throw RegressionError("小会话文件没有找到额度")
        }
        try require(smallResult.0.primary?.usedPercent == 42, "小会话文件额度读取错误")

        let changingWindowFile = directory.appendingPathComponent("changing-window-session.jsonl")
        let oldDoubleWindow = """
        {"timestamp":"2026-07-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":62,"window_minutes":300,"resets_at":2000000000},"secondary":{"used_percent":27,"window_minutes":10080,"resets_at":2000000000}}}}
        """
        let latestSingleWindow = """
        {"timestamp":"2026-07-17T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":45,"window_minutes":10080,"resets_at":2000000000}}}}
        """
        let latestNamedModelWindow = """
        {"timestamp":"2026-07-17T08:01:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":1,"window_minutes":300,"resets_at":2000000000}}}}
        """
        try Data((oldDoubleWindow + "\n" + latestSingleWindow + "\n" + latestNamedModelWindow + "\n").utf8)
            .write(to: changingWindowFile)
        guard let changingWindowResult = QuotaReader.extractLatestLimits(from: changingWindowFile) else {
            throw RegressionError("窗口变化后的主额度没有找到")
        }
        try require(changingWindowResult.0.primary?.usedPercent == 45, "旧的双窗口额度覆盖了最新主额度")
        try require(changingWindowResult.0.secondary == nil, "错误保留了旧账号的第二个额度窗口")

        let file = directory.appendingPathComponent("large-quota-session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<17 {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("\n".utf8))

        try handle.write(contentsOf: Data((quotaLine + "\n").utf8))

        // 超大无关行用于验证扫描器会丢弃单行，而不是把整段日志拼进内存。
        try handle.write(contentsOf: chunk)
        try handle.write(contentsOf: chunk)
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let startedAt = Date()
        guard let result = QuotaReader.extractLatestLimits(from: file) else {
            throw RegressionError("没有找到额度")
        }
        try require(result.0.primary?.usedPercent == 42, "5 小时额度读取错误")
        try require(result.0.secondary?.usedPercent == 18, "周额度读取错误")
        try require(Date().timeIntervalSince(startedAt) < 3, "分块扫描耗时异常")
        print("bounded quota reader regression passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw RegressionError(message)
        }
    }
}

private struct RegressionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

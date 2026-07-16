import Foundation

@main
struct CodexTaskSessionReaderRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("large-session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("HEAD_MARKER".utf8))

        let chunk = Data(repeating: 0x41, count: 256 * 1024)
        for _ in 0..<36 {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("TAIL_MARKER".utf8))
        try handle.close()

        guard let tail = CodexTaskSessionReader.readTailTextForTesting(
            from: file,
            bytesToRead: .max
        ) else {
            throw RegressionError("尾部读取失败")
        }
        try require(tail.utf8.count <= 8 * 1024 * 1024, "尾部读取超过 8 MB")
        try require(tail.hasSuffix("TAIL_MARKER"), "尾部内容不正确")
        try require(!tail.contains("HEAD_MARKER"), "尾部读取覆盖了整个文件")

        guard let head = CodexTaskSessionReader.readHeadTextForTesting(
            from: file,
            bytesToRead: .max
        ) else {
            throw RegressionError("头部读取失败")
        }
        try require(head.utf8.count <= 64 * 1024, "头部读取超过 64 KB")
        try require(head.hasPrefix("HEAD_MARKER"), "头部内容不正确")
        try require(!head.contains("TAIL_MARKER"), "头部读取覆盖了整个文件")

        print("bounded session reader regression passed")
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

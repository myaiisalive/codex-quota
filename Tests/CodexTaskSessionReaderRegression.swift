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

        let sessionID = "019f17b5-ff8e-7b92-8bd7-a57819815d53"
        let turnID = "019f6eee-27ce-7bc1-a7f6-910eabe1685b"
        let sessionFile = directory.appendingPathComponent("rollout-\(sessionID).jsonl")
        FileManager.default.createFile(atPath: sessionFile.path, contents: nil)
        let sessionHandle = try FileHandle(forWritingTo: sessionFile)
        let header = """
        {"timestamp":"2026-06-30T08:47:11.000Z","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/svc-center-order"}}
        """
        let oldTask = """
        {"timestamp":"2026-07-17T06:48:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn","started_at":1784270880}}
        """
        try sessionHandle.write(contentsOf: Data((header + "\n" + oldTask + "\n").utf8))
        for _ in 0..<36 {
            try sessionHandle.write(contentsOf: chunk)
            try sessionHandle.write(contentsOf: Data("\n".utf8))
        }
        let turnContext = """
        {"timestamp":"2026-07-17T07:19:47.333Z","type":"turn_context","payload":{"turn_id":"\(turnID)","cwd":"/tmp/svc-center-order"}}
        """
        try sessionHandle.write(contentsOf: Data((turnContext + "\n").utf8))
        try sessionHandle.close()

        let expectedTitle = "生成迁移计划文档-订单接口"
        guard let task = CodexTaskSessionReader.extractLatestTaskForTesting(
            from: sessionFile,
            threadNames: [sessionID: expectedTitle]
        ) else {
            throw RegressionError("大日志中的当前轮次未被识别")
        }
        try require(task.turnID == turnID, "识别成了旧轮次")
        try require(task.taskName == expectedTitle, "会话名称没有使用 Codex 标题")
        try require(task.projectName == "svc-center-order", "项目名称识别错误")
        try require(
            abs(task.startedAt.timeIntervalSince1970 - 1_784_272_787.333) < 0.01,
            "当前轮次开始时间识别错误"
        )

        let activityJSON = """
        [
          {"conversationId":"money-thread","turnId":"current-turn","startedAtMs":1784269701777,"updatedAtMs":1784270335138,"cwd":"/tmp/money-more"},
          {"conversationId":"money-thread","turnId":"current-turn","startedAtMs":1784273458025,"updatedAtMs":1784273458026,"cwd":"/tmp/money-more"},
          {"conversationId":"money-thread","turnId":"old-turn","startedAtMs":1784138103668,"updatedAtMs":1784138103669,"cwd":"/tmp/money-more"}
        ]
        """
        guard let activity = CodexTaskSessionReader.processActivityForTesting(
            from: Data(activityJSON.utf8),
            threadID: "money-thread"
        ) else {
            throw RegressionError("活动任务索引解析失败")
        }
        try require(activity.turnID == "current-turn", "没有选择最新活动轮次")
        try require(
            abs(activity.startedAt.timeIntervalSince1970 - 1_784_269_701.777) < 0.01,
            "活动轮次开始时间没有取最早记录"
        )
        try require(activity.cwd == "/tmp/money-more", "活动轮次项目路径错误")

        let endedTask = CodexTaskSession(
            id: "money-thread:current-turn",
            threadID: "money-thread",
            turnID: "current-turn",
            projectName: "money-more",
            taskName: "iQuant (3)",
            status: .ended,
            startedAt: activity.startedAt,
            endedAt: activity.updatedAt.addingTimeInterval(1)
        )
        let resolvedEndedTask = CodexTaskSessionReader.resolvedTaskForTesting(
            logTask: endedTask,
            activityData: Data(activityJSON.utf8),
            threadID: "money-thread",
            preferredTitle: "iQuant (3)"
        )
        try require(resolvedEndedTask?.status == .ended, "活动索引覆盖了日志中的结束状态")

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

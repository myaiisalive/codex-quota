import Foundation

@main
struct BoundedIORegression {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let smallURL = URL(string: CommandLine.arguments[1]),
              let largeURL = URL(string: CommandLine.arguments[2]) else {
            throw RegressionError("测试地址缺失")
        }

        var smallRequest = URLRequest(url: smallURL)
        smallRequest.timeoutInterval = 2
        let (smallData, _) = try await BoundedURLLoader.data(
            for: smallRequest,
            maxBytes: 64 * 1024,
            resourceTimeout: 3
        )
        try require(smallData.count == 1024, "正常小响应读取失败")

        var largeRequest = URLRequest(url: largeURL)
        largeRequest.timeoutInterval = 2
        do {
            _ = try await BoundedURLLoader.data(
                for: largeRequest,
                maxBytes: 64 * 1024,
                resourceTimeout: 3
            )
            throw RegressionError("超限响应没有被拒绝")
        } catch BoundedURLLoader.LoadError.responseTooLarge {
            // 符合预期。
        }

        print("bounded IO regression passed")
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

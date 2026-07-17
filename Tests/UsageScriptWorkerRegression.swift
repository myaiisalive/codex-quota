import Foundation

// 这个测试只需要 UsageScriptRunner 的字段契约，不访问 CC Switch 数据库。
struct CCSwitchProvider {
    let rowID: Int64
    let name: String
    let usageScriptCode: String
    let apiKey: String?
    let baseUrl: String
    let accessToken: String?
    let userId: String?
    let timeoutSeconds: Double?
    let isCurrent: Bool
}

@main
struct UsageScriptWorkerRegression {
    static func main() async throws {
        if UsageScriptRunner.runWorkerIfRequested() {
            return
        }

        let script = """
        ({
          request: {
            url: "https://example.com/usage",
            method: "POST",
            headers: { "X-Test": "yes" },
            body: { "scope": "all" }
          },
          extractor: function(response) {
            return { remaining: response.balance, unit: "USD", isValid: true };
          }
        })
        """

        let request = try await UsageScriptRunner.evaluateRequestForTesting(script: script)
        try require(request.url == "https://example.com/usage", "请求地址不兼容")
        try require(request.method == "POST", "请求方法不兼容")

        let result = try await UsageScriptRunner.evaluateSessionForTesting(
            script: script,
            responseJSON: "{\"balance\":12.5}"
        )
        try require((result.result["remaining"] as? NSNumber)?.doubleValue == 12.5, "余额提取不兼容")

        let statefulScript = """
        (function() {
          var marker = String(Math.random());
          return {
            request: { url: "https://example.com/usage", headers: { "X-Marker": marker } },
            extractor: function(response) { return { planName: marker, isValid: true }; }
          };
        })()
        """
        let statefulResult = try await UsageScriptRunner.evaluateSessionForTesting(
            script: statefulScript,
            responseJSON: "{}"
        )
        try require(
            statefulResult.headers["X-Marker"] == statefulResult.result["planName"] as? String,
            "请求和提取阶段没有保留同一个脚本上下文"
        )

        let startedAt = Date()
        do {
            _ = try await UsageScriptRunner.evaluateRequestForTesting(
                script: "(function(){ while (true) {} })()",
                timeoutSeconds: 0.25
            )
            throw RegressionError("死循环脚本没有被终止")
        } catch {
            try require(Date().timeIntervalSince(startedAt) < 2, "死循环脚本终止过慢")
        }

        let memoryStartedAt = Date()
        do {
            _ = try await UsageScriptRunner.evaluateRequestForTesting(
                script: """
                (function(){
                  var blocks = [];
                  while (true) {
                    var block = new Uint8Array(4 * 1024 * 1024);
                    for (var i = 0; i < block.length; i += 4096) { block[i] = 1; }
                    blocks.push(block);
                  }
                })()
                """,
                timeoutSeconds: 5
            )
            throw RegressionError("超内存脚本没有被终止")
        } catch {
            try require(Date().timeIntervalSince(memoryStartedAt) < 3, "超内存脚本终止过慢")
        }

        print("isolated usage script regression passed")
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

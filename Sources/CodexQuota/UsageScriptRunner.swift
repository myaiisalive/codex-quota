import Foundation
import JavaScriptCore

/// 调用 CC Switch 的 usage_script 拿到余额
/// 流程：模板替换 → JS eval 拿 request 配置 → URLSession 发请求 → JS eval extractor(response)
enum UsageScriptRunner {

    struct Balance: Equatable {
        var providerName: String
        var remaining: Double?
        var used: Double?
        var total: Double?
        var unit: String?
        var planName: String?
        var isValid: Bool
        var invalidMessage: String?
    }

    enum RunError: Error {
        case jsEvalFailed(String)
        case badRequestSpec
        case http(Int)
        case network(Error)
        case invalidJSON
    }

    static func run(provider: CCSwitchProvider) async throws -> Balance {
        // 1. 模板替换（baseUrl 末尾保留，extractor 里要用）
        let baseUrl = provider.baseUrl.hasSuffix("/")
            ? String(provider.baseUrl.dropLast())
            : provider.baseUrl
        let filled = provider.usageScriptCode
            .replacingOccurrences(of: "{{baseUrl}}", with: baseUrl)
            .replacingOccurrences(of: "{{apiKey}}", with: provider.apiKey ?? "")
            .replacingOccurrences(of: "{{accessToken}}", with: provider.accessToken ?? "")
            .replacingOccurrences(of: "{{userId}}", with: provider.userId ?? "")

        // 2. JS eval 拿出 request spec（同时把 script 自身留在全局，下一步还要 extractor）
        guard let ctx = JSContext() else {
            throw RunError.jsEvalFailed("无法创建 JSContext")
        }
        ctx.exceptionHandler = { _, exc in
            print("[usage_script] JS exception:", exc?.toString() ?? "?")
        }

        // 把 script 求值结果存到全局 __spec
        let bootstrap = "var __spec = \(filled);"
        ctx.evaluateScript(bootstrap)
        if let exc = ctx.exception {
            throw RunError.jsEvalFailed(exc.toString() ?? "eval failed")
        }
        guard let spec = ctx.objectForKeyedSubscript("__spec"),
              let request = spec.objectForKeyedSubscript("request"),
              let urlStr = request.objectForKeyedSubscript("url").toString(),
              let url = URL(string: urlStr) else {
            throw RunError.badRequestSpec
        }

        let method = request.objectForKeyedSubscript("method")?.toString() ?? "GET"
        let headers = request.objectForKeyedSubscript("headers")?.toDictionary() as? [String: String] ?? [:]

        // 3. 发请求
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw RunError.network(error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RunError.http(http.statusCode)
        }

        guard let bodyStr = String(data: data, encoding: .utf8) else {
            throw RunError.invalidJSON
        }

        // 4. 跑 extractor(response) —— response 是 JSON 解析后的对象
        let extractorCall = """
        (function(){
            try {
                var response = JSON.parse(\(jsString(bodyStr)));
                var r = __spec.extractor(response);
                return JSON.stringify(r);
            } catch (e) {
                return JSON.stringify({ isValid: false, invalidMessage: String(e) });
            }
        })()
        """
        guard let resultJsonStr = ctx.evaluateScript(extractorCall)?.toString(),
              let resultData = resultJsonStr.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw RunError.jsEvalFailed("extractor 失败")
        }

        return Balance(
            providerName: provider.name,
            remaining: result["remaining"] as? Double,
            used: result["used"] as? Double,
            total: result["total"] as? Double,
            unit: result["unit"] as? String,
            planName: result["planName"] as? String,
            isValid: result["isValid"] as? Bool ?? true,
            invalidMessage: result["invalidMessage"] as? String
        )
    }

    /// 把任意字符串安全嵌入到 JS 源里（带引号）
    private static func jsString(_ s: String) -> String {
        // 用 JSONSerialization 编码字符串，保证转义正确
        if let data = try? JSONSerialization.data(
                withJSONObject: [s], options: [.fragmentsAllowed]),
           let arr = String(data: data, encoding: .utf8) {
            // arr = "[\"...\"]"，取中间那段
            var s = arr
            s.removeFirst(); s.removeLast()
            return s
        }
        return "\"\""
    }
}

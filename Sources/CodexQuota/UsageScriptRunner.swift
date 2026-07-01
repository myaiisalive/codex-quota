import Foundation
import JavaScriptCore

/// 调用 CC Switch 的 usage_script 拿到余额
/// 流程：模板替换 → JS eval 拿 request 配置 → URLSession 发请求 → JS eval extractor(response)
enum UsageScriptRunner {

    struct Balance: Codable, Equatable {
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
        case badRequestBody
        case http(Int)
        case network(Error)
        case invalidJSON
    }

    static func run(provider: CCSwitchProvider, codexApiKey: String? = nil) async throws -> Balance {
        let baseUrl = provider.baseUrl.hasSuffix("/")
            ? String(provider.baseUrl.dropLast())
            : provider.baseUrl
        // codexApiKey 优先：codex auth.json 里的 key 才是实际使用的那个
        let apiKey = codexApiKey ?? provider.apiKey ?? ""
        let filled = provider.usageScriptCode
            .replacingOccurrences(of: "{{baseUrl}}", with: baseUrl)
            .replacingOccurrences(of: "{{apiKey}}", with: apiKey)
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
        let headers = headerMap(from: request.objectForKeyedSubscript("headers"))
        let body = try requestBodyData(from: request)

        // 3. 发请求
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = provider.timeoutSeconds ?? 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

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

        return parseBalance(providerName: provider.name, result: result)
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

    private static func headerMap(from value: JSValue?) -> [String: String] {
        guard let raw = value?.toDictionary() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let text = stringValue(value) {
                result[key] = text
            }
        }
        return result
    }

    private static func requestBodyData(from request: JSValue) throws -> Data? {
        for key in ["body", "data"] {
            guard let value = request.objectForKeyedSubscript(key),
                  !value.isUndefined,
                  !value.isNull else { continue }

            if let body = bodyData(from: value) {
                return body
            }
            throw RunError.badRequestBody
        }
        return nil
    }

    private static func bodyData(from value: JSValue) -> Data? {
        if value.isString {
            return value.toString()?.data(using: .utf8)
        }

        if let dict = value.toDictionary(),
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict) {
            return data
        }

        if let array = value.toArray(),
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array) {
            return data
        }

        if value.isBoolean || value.isNumber {
            return value.toString()?.data(using: .utf8)
        }
        return nil
    }

    private static func parseBalance(providerName: String, result: [String: Any]) -> Balance {
        var remaining = doubleValue(result["remaining"])
        var used = doubleValue(result["used"])
        var total = doubleValue(result["total"])

        if remaining == nil, let used, let total { remaining = total - used }
        if used == nil, let remaining, let total { used = total - remaining }
        if total == nil, let remaining, let used { total = remaining + used }

        remaining = normalizeNearZero(remaining)
        used = normalizeNearZero(used)
        total = normalizeNearZero(total)

        let invalidMessage = stringValue(result["invalidMessage"]) ?? stringValue(result["message"])
        return Balance(
            providerName: providerName,
            remaining: remaining,
            used: used,
            total: total,
            unit: stringValue(result["unit"]),
            planName: stringValue(result["planName"]),
            isValid: boolValue(result["isValid"]) ?? true,
            invalidMessage: invalidMessage
        )
    }

    private static func normalizeNearZero(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return abs(value) < 0.000_001 ? 0 : value
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

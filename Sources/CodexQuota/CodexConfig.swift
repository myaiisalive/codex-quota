import Foundation

/// 从 ~/.codex/config.toml 读出当前活跃的第三方 provider 信息
struct CodexConfig: Equatable {
    let providerKey: String
    let providerName: String
    let baseUrl: String
    let apiKey: String       // auth.json 里 OPENAI_API_KEY 的实际值（空字符串表示未配置）

    /// loadActive() 只会返回非官方 provider，所以这里恒为第三方模式
    var isThirdPartyApiMode: Bool { true }

    static func loadActive() -> CodexConfig? {
        let configPath = NSString(string: "~/.codex/config.toml").expandingTildeInPath
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let configText = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath))
        return parse(configText: configText, authData: authData)
    }

    private static func parse(configText: String, authData: Data?) -> CodexConfig? {
        guard let providerKey = topLevelString(in: configText, key: "model_provider") else { return nil }
        guard let providerSection = section(in: configText, providerKey: providerKey) else { return nil }
        guard let baseUrl = topLevelString(in: providerSection, key: "base_url") else { return nil }
        if isOpenAIOfficial(baseUrl) { return nil }

        let providerName = topLevelString(in: providerSection, key: "name") ?? providerKey
        return CodexConfig(
            providerKey: providerKey,
            providerName: providerName,
            baseUrl: baseUrl,
            apiKey: loadApiKey(from: authData)
        )
    }

    private static func loadApiKey(from authData: Data?) -> String {
        guard let authData,
              let data = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let key = data["OPENAI_API_KEY"] as? String
        else { return "" }
        return key
    }

    var normalizedBaseURL: String {
        Self.normalizeURLString(baseUrl)
    }

    private static func normalizeURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var normalized = components.string ?? trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    var host: String {
        URL(string: baseUrl)?.host?.lowercased() ?? ""
    }

    /// 只取域名末两段，用于跨子域匹配 (api.x.com 和 x.com)
    var rootDomain: String {
        let h = host
        let parts = h.split(separator: ".")
        guard parts.count >= 2 else { return h }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func isOpenAIOfficial(_ url: String) -> Bool {
        guard let h = URL(string: url)?.host?.lowercased() else { return false }
        // ChatGPT 登录态的 Codex 官方请求会走 chatgpt.com，不应误判成第三方接口。
        return h.hasSuffix("openai.com") || h.hasSuffix("openai.azure.com") || h.hasSuffix("chatgpt.com")
    }

    /// 在指定文本（整篇或某个 section 内）查找顶层配置值。
    /// 兼容双引号、单引号和 bare value 三种常见写法。
    private static func topLevelString(in text: String, key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"(?m)^\s*__KEY__\s*=\s*"([^"]*)""#,
            #"(?m)^\s*__KEY__\s*=\s*'([^']*)'"#,
            #"(?m)^\s*__KEY__\s*=\s*([^#\r\n]+)"#
        ].map { $0.replacingOccurrences(of: "__KEY__", with: escapedKey) }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text)
            else { continue }

            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 把目标 provider 的 table 文本截出来。
    /// 兼容 [model_providers.foo]、[model_providers."foo"]、[model_providers.'foo']。
    private static func section(in text: String, providerKey: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: providerKey)
        let headerPatterns = [
            #"(?m)^\s*\[\s*model_providers\.__KEY__\s*\]\s*$"#,
            #"(?m)^\s*\[\s*model_providers\."__KEY__"\s*\]\s*$"#,
            #"(?m)^\s*\[\s*model_providers\.'__KEY__'\s*\]\s*$"#
        ].map { $0.replacingOccurrences(of: "__KEY__", with: escapedKey) }

        for pattern in headerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let matchRange = Range(match.range, in: text)
            else { continue }

            let after = text[matchRange.upperBound...]
            if let nextHeader = after.range(of: #"(?m)^\s*\["#, options: .regularExpression) {
                return String(after[..<nextHeader.lowerBound])
            }
            return String(after)
        }
        return nil
    }
}

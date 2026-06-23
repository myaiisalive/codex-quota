import Foundation

/// 从 ~/.codex/config.toml 读出当前活跃的第三方 provider 信息
struct CodexConfig {
    let providerKey: String
    let providerName: String
    let baseUrl: String
    let apiKey: String       // auth.json 里 OPENAI_API_KEY 的实际值（空字符串表示未配置）

    var isThirdPartyApiMode: Bool { !apiKey.isEmpty }

    static func loadActive() -> CodexConfig? {
        let path = NSString(string: "~/.codex/config.toml").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        guard let providerKey = topLevelString(in: text, key: "model_provider") else { return nil }
        guard let section = section(in: text, name: "model_providers.\(providerKey)") else { return nil }
        guard let baseUrl = topLevelString(in: section, key: "base_url") else { return nil }

        if isOpenAIOfficial(baseUrl) { return nil }

        let name = topLevelString(in: section, key: "name") ?? providerKey
        return CodexConfig(
            providerKey: providerKey,
            providerName: name,
            baseUrl: baseUrl,
            apiKey: loadApiKey()
        )
    }

    private static func loadApiKey() -> String {
        let path = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["OPENAI_API_KEY"] as? String
        else { return "" }
        return key
    }

    var host: String {
        URL(string: baseUrl)?.host ?? ""
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
        return h.hasSuffix("openai.com") || h.hasSuffix("openai.azure.com")
    }

    /// 在指定文本（整篇或某个 section 内）查找顶层 `key = "value"`
    private static func topLevelString(in text: String, key: String) -> String? {
        let pattern = "(?m)^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]*)\""
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2,
              let range = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// 把 [section.name] 到下一个 [ 之间的文本截出来
    private static func section(in text: String, name: String) -> String? {
        let header = "[\(name)]"
        guard let start = text.range(of: header) else { return nil }
        let after = text[start.upperBound...]
        // 找下一个 "[" 开头的行
        if let nextHeader = after.range(of: "(?m)^\\[", options: .regularExpression) {
            return String(after[..<nextHeader.lowerBound])
        }
        return String(after)
    }
}

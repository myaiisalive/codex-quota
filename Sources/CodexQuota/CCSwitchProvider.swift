import Foundation
import SQLite3

/// 从 CC Switch 的 sqlite 数据库中按域名找匹配的 provider 配置
struct CCSwitchProvider {
    let name: String
    let usageScriptCode: String     // 整段 JS：({ request: ..., extractor: ... })
    let apiKey: String?
    let baseUrl: String             // usage_script 里的 baseUrl，可能和 codex 的不完全相同
    let accessToken: String?
    let userId: String?

    /// 找到第一个 usage_script.baseUrl 的 host 与目标 host（或根域）匹配的 provider
    static func find(matchingHost host: String, rootDomain: String) -> CCSwitchProvider? {
        let dbPath = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        // 只读打开
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT name, meta FROM providers WHERE meta LIKE '%usage_script%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 0),
                  let metaC = sqlite3_column_text(stmt, 1) else { continue }
            let providerName = String(cString: nameC)
            let metaStr = String(cString: metaC)
            guard let candidate = parse(name: providerName, metaJson: metaStr) else { continue }

            if let candHost = URL(string: candidate.baseUrl)?.host?.lowercased() {
                if candHost == host || hostMatchesRoot(candHost, rootDomain) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func hostMatchesRoot(_ host: String, _ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        return host == root || host.hasSuffix(".\(root)")
    }

    private static func parse(name: String, metaJson: String) -> CCSwitchProvider? {
        guard let data = metaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let us = root["usage_script"] as? [String: Any],
              (us["enabled"] as? Bool ?? true),
              let code = us["code"] as? String,
              let baseUrl = us["baseUrl"] as? String
        else { return nil }

        return CCSwitchProvider(
            name: name,
            usageScriptCode: code,
            apiKey: us["apiKey"] as? String,
            baseUrl: baseUrl,
            accessToken: us["accessToken"] as? String,
            userId: us["userId"] as? String
        )
    }
}

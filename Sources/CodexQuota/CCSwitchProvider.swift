import Foundation
import SQLite3

/// 从 CC Switch 的 sqlite 数据库中按域名找匹配的 provider 配置
struct CCSwitchProvider: Equatable {
    let rowID: Int64
    let name: String
    let usageScriptCode: String     // 整段 JS：({ request: ..., extractor: ... })
    let apiKey: String?
    let baseUrl: String             // usage_script 里的 baseUrl，可能和 codex 的不完全相同
    let accessToken: String?
    let userId: String?
    let timeoutSeconds: Double?
    let isCurrent: Bool

    static func find(for codex: CodexConfig) -> CCSwitchProvider? {
        bestMatch(from: loadAllProviders(), codex: codex)
    }

    static func find(locator: ThirdPartySourceLocator) -> CCSwitchProvider? {
        if let rowID = locator.providerRowID,
           let provider = loadProvider(rowID: rowID),
           locator.matches(provider) {
            return provider
        }

        return loadAllProviders().first(where: { locator.matches($0) })
    }

    private static func loadAllProviders() -> [CCSwitchProvider] {
        let dbPath = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // ORDER BY rowid DESC → 分数相同的时候，继续沿用“最近添加优先”
        let sql = """
        SELECT rowid, name, is_current, meta
        FROM providers
        WHERE meta LIKE '%usage_script%'
        ORDER BY rowid DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var candidates: [CCSwitchProvider] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            guard let nameC = sqlite3_column_text(stmt, 1),
                  let metaC = sqlite3_column_text(stmt, 3) else { continue }
            let isCurrent = sqlite3_column_int(stmt, 2) != 0
            let candidate = parse(
                rowID: rowID,
                name: String(cString: nameC),
                isCurrent: isCurrent,
                metaJson: String(cString: metaC)
            )
            if let candidate { candidates.append(candidate) }
        }
        return candidates
    }

    private static func loadProvider(rowID: Int64) -> CCSwitchProvider? {
        let dbPath = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
        SELECT rowid, name, is_current, meta
        FROM providers
        WHERE rowid = ? AND meta LIKE '%usage_script%'
        LIMIT 1
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, rowID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let nameC = sqlite3_column_text(stmt, 1),
              let metaC = sqlite3_column_text(stmt, 3) else {
            return nil
        }

        return parse(
            rowID: sqlite3_column_int64(stmt, 0),
            name: String(cString: nameC),
            isCurrent: sqlite3_column_int(stmt, 2) != 0,
            metaJson: String(cString: metaC)
        )
    }

    private static func bestMatch(from candidates: [CCSwitchProvider], codex: CodexConfig) -> CCSwitchProvider? {
        var best: (provider: CCSwitchProvider, score: Int)?
        for candidate in candidates {
            guard let score = matchScore(for: candidate, codex: codex) else { continue }
            let resolved = candidate.resolvingMissingBaseURL(with: codex.baseUrl)
            if best == nil || score > best!.score {
                best = (resolved, score)
            }
        }
        return best?.provider
    }

    private static func matchScore(for candidate: CCSwitchProvider, codex: CodexConfig) -> Int? {
        let candHost = URL(string: candidate.baseUrl)?.host?.lowercased()
        let exactHost = candHost == codex.host
        let rootMatch = candHost.map { !exactHost && hostMatchesRoot($0, codex.rootDomain) } ?? false
        let nameMatch = normalize(candidate.name) == normalize(codex.providerName)
        let activeApiKey = codex.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyMatch = !activeApiKey.isEmpty
            && candidate.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) == activeApiKey

        guard exactHost || rootMatch || (candidate.baseUrl.isEmpty && (candidate.isCurrent || nameMatch || keyMatch)) else {
            return nil
        }

        var score: Int
        if exactHost {
            score = 400
        } else if rootMatch {
            score = 200
        } else {
            score = 120
        }
        if normalizeURL(candidate.baseUrl) == codex.normalizedBaseURL { score += 120 }
        if nameMatch { score += 80 }
        if candidate.isCurrent { score += 40 }
        if keyMatch {
            score += 160
        }
        return score
    }

    private static func hostMatchesRoot(_ host: String, _ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        return host == root || host.hasSuffix(".\(root)")
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return normalize(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var normalized = components.string ?? trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func parse(rowID: Int64, name: String, isCurrent: Bool, metaJson: String) -> CCSwitchProvider? {
        guard let data = metaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let us = root["usage_script"] as? [String: Any],
              (us["enabled"] as? Bool ?? true),
              let code = us["code"] as? String
        else { return nil }

        return CCSwitchProvider(
            rowID: rowID,
            name: name,
            usageScriptCode: code,
            apiKey: us["apiKey"] as? String,
            baseUrl: ((us["baseUrl"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: us["accessToken"] as? String,
            userId: us["userId"] as? String,
            timeoutSeconds: doubleValue(us["timeout"]),
            isCurrent: isCurrent
        )
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

    private func resolvingMissingBaseURL(with fallback: String) -> CCSwitchProvider {
        guard baseUrl.isEmpty else { return self }
        return CCSwitchProvider(
            rowID: rowID,
            name: name,
            usageScriptCode: usageScriptCode,
            apiKey: apiKey,
            baseUrl: fallback,
            accessToken: accessToken,
            userId: userId,
            timeoutSeconds: timeoutSeconds,
            isCurrent: isCurrent
        )
    }
}

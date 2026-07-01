import Foundation

enum UsageSourceKind: String, Codable {
    case officialAccount
    case thirdPartyAPI

    var symbolName: String {
        switch self {
        case .officialAccount:
            return "person.crop.circle"
        case .thirdPartyAPI:
            return "network"
        }
    }
}

enum UsageSourceSortBucket: Int {
    case officialAvailable = 0
    case apiAvailable = 1
    case officialEmpty = 2
    case apiEmpty = 3

    var title: String {
        switch self {
        case .officialAvailable:
            return "官方额度还有可用"
        case .apiAvailable:
            return "API 还有余额"
        case .officialEmpty:
            return "官方额度已用完"
        case .apiEmpty:
            return "API 余额为 0"
        }
    }
}

enum UsageSourceSortMode: String {
    case automatic
    case custom
}

struct ThirdPartySourceLocator: Codable, Equatable {
    let providerRowID: Int64?
    let providerName: String
    let baseURL: String
    let userID: String?

    func matches(_ provider: CCSwitchProvider) -> Bool {
        if let providerRowID, provider.rowID == providerRowID {
            return true
        }

        let lhsName = Self.normalize(providerName)
        let rhsName = Self.normalize(provider.name)
        let lhsBaseURL = Self.normalizeURL(baseURL)
        let rhsBaseURL = Self.normalizeURL(provider.baseUrl)
        let lhsUserID = Self.normalize(userID)
        let rhsUserID = Self.normalize(provider.userId)

        return lhsName == rhsName && lhsBaseURL == rhsBaseURL && lhsUserID == rhsUserID
    }

    private static func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func normalizeURL(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

struct UsageSourceEntry: Codable, Equatable, Identifiable {
    private static let sortValueEpsilon = 0.000_001

    let id: String
    let kind: UsageSourceKind
    var title: String
    var subtitle: String?
    var snapshot: QuotaSnapshot?
    var balance: UsageScriptRunner.Balance?
    var thirdPartyLocator: ThirdPartySourceLocator?
    var lastSeenAt: Date

    var compactLabel: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sortBucket(referenceDate: Date = Date()) -> UsageSourceSortBucket {
        switch kind {
        case .officialAccount:
            return sortValue(referenceDate: referenceDate) > Self.sortValueEpsilon
                ? .officialAvailable
                : .officialEmpty
        case .thirdPartyAPI:
            return sortValue(referenceDate: referenceDate) > Self.sortValueEpsilon
                ? .apiAvailable
                : .apiEmpty
        }
    }

    func sortValue(referenceDate: Date = Date()) -> Double {
        switch kind {
        case .officialAccount:
            let refreshedSnapshot = snapshot?.resetExpiredWindows(referenceDate: referenceDate)
            let primaryRemaining = refreshedSnapshot?.limits.primary?.remainingPercent
            let secondaryRemaining = refreshedSnapshot?.limits.secondary?.remainingPercent
            return max(primaryRemaining ?? secondaryRemaining ?? 0, 0)
        case .thirdPartyAPI:
            return max(balance?.remaining ?? 0, 0)
        }
    }

    static func official(profile: CodexAccountProfile, snapshot: QuotaSnapshot?) -> UsageSourceEntry? {
        guard let id = officialID(for: profile) else { return nil }

        let trimmedName = trim(profile.name)
        let trimmedEmail = trim(profile.email)
        let title: String
        let subtitle: String?

        if let trimmedName,
           let trimmedEmail,
           trimmedName.caseInsensitiveCompare(trimmedEmail) != .orderedSame {
            title = trimmedName
            subtitle = trimmedEmail
        } else {
            title = trimmedName ?? trimmedEmail ?? trim(profile.accountId) ?? "官方账号"
            subtitle = nil
        }

        return UsageSourceEntry(
            id: id,
            kind: .officialAccount,
            title: title,
            subtitle: subtitle,
            snapshot: snapshot,
            balance: nil,
            thirdPartyLocator: nil,
            lastSeenAt: Date()
        )
    }

    static func thirdParty(provider: CCSwitchProvider, balance: UsageScriptRunner.Balance?) -> UsageSourceEntry {
        let title = trim(provider.name) ?? "第三方 API"
        let subtitle = URL(string: provider.baseUrl)?.host?.lowercased()

        return UsageSourceEntry(
            id: thirdPartyID(provider: provider),
            kind: .thirdPartyAPI,
            title: title,
            subtitle: subtitle,
            snapshot: nil,
            balance: balance,
            thirdPartyLocator: ThirdPartySourceLocator(
                providerRowID: provider.rowID,
                providerName: provider.name,
                baseURL: provider.baseUrl,
                userID: provider.userId
            ),
            lastSeenAt: Date()
        )
    }

    private static func officialID(for profile: CodexAccountProfile) -> String? {
        if let accountId = trim(profile.accountId) {
            return "official:\(accountId)"
        }
        if let email = trim(profile.email)?.lowercased() {
            return "official:\(email)"
        }
        if let name = trim(profile.name)?.lowercased() {
            return "official:\(name)"
        }
        return nil
    }

    private static func thirdPartyID(provider: CCSwitchProvider) -> String {
        "api:\(provider.rowID)"
    }

    private static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum UsageSourceHistoryStore {
    static let storageKey = "usageSourceHistory.v1"

    static func load() -> [UsageSourceEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([UsageSourceEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [UsageSourceEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum UsageSourceOrderStore {
    static let modeKey = "usageSourceSortMode"
    static let customOrderKey = "usageSourceCustomOrder.v1"

    static func loadMode() -> UsageSourceSortMode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey),
              let mode = UsageSourceSortMode(rawValue: raw) else {
            return .automatic
        }
        return mode
    }

    static func saveMode(_ mode: UsageSourceSortMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    static func loadCustomOrderIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: customOrderKey) ?? []
    }

    static func saveCustomOrderIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: customOrderKey)
    }
}

enum UsageSourceDisplaySettings {
    static let showInactiveSourcesKey = "showInactiveUsageSources"
}

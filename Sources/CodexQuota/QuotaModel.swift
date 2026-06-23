import Foundation

struct RateWindow: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    var remainingPercent: Double { 100 - usedPercent }

    /// 窗口名称：5h / 1w 等
    var windowLabel: String {
        switch windowMinutes {
        case 0..<60:        return "\(windowMinutes)分钟"
        case 60..<60*24:    return "\(windowMinutes/60)小时"
        case 60*24..<60*24*7: return "\(windowMinutes/(60*24))天"
        default:            return "\(windowMinutes/(60*24*7))周"
        }
    }

    var resetDate: Date { Date(timeIntervalSince1970: resetsAt) }
}

struct RateLimits: Codable, Equatable {
    let limitId: String?
    let limitName: String?
    let individualLimit: String?
    let primary: RateWindow?
    let secondary: RateWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitId = "limit_id"
        case limitName = "limit_name"
        case individualLimit = "individual_limit"
        case primary, secondary
        case planType = "plan_type"
    }

    var hasQuotaWindows: Bool {
        primary != nil || secondary != nil
    }

    /// 账号总额度通常没有模型名；命名过的额度桶更像某个模型/子能力的单独额度。
    var isNamedModelQuota: Bool {
        guard let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !name.isEmpty
    }

    /// 分数越高越像“应该展示给用户的主额度”。
    var displayPriority: Int {
        guard hasQuotaWindows else { return -1 }

        var score = 0
        if primary != nil { score += 20 }
        if secondary != nil { score += 20 }
        if !isNamedModelQuota { score += 40 }
        if individualLimit == nil { score += 10 }
        return score
    }

    static let maxDisplayPriority = 90
}

struct QuotaSnapshot: Equatable {
    let limits: RateLimits
    let capturedAt: Date
}

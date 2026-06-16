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

    /// 真实剩余百分比：超过 resets_at 视为已重置
    var effectiveUsedPercent: Double {
        Date().timeIntervalSince1970 >= resetsAt ? 0 : usedPercent
    }

    var remainingPercent: Double { 100 - effectiveUsedPercent }

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
    let primary: RateWindow?
    let secondary: RateWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
    }
}

struct QuotaSnapshot: Equatable {
    let limits: RateLimits
    let capturedAt: Date
}

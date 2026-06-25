import Foundation

enum FloatingQuotaStyle: String, CaseIterable, Identifiable {
    case classic
    case capsule
    case orbit
    case card
    case minimal
    case spotlight

    static let storageKey = "floatingQuotaStyle"
    static let defaultValue: FloatingQuotaStyle = .classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:   return "经典横条"
        case .capsule:   return "胶囊悬浮"
        case .orbit:     return "圆形仪表"
        case .card:      return "信息卡片"
        case .minimal:   return "极简标签"
        case .spotlight: return "高亮提醒"
        }
    }

    var summary: String {
        switch self {
        case .classic:   return "现在这样，信息最全。"
        case .capsule:   return "更圆润，适合常驻桌面。"
        case .orbit:     return "中间看主额度，视觉更明显。"
        case .card:      return "像小卡片，更新时间更清楚。"
        case .minimal:   return "更轻，不容易挡住内容。"
        case .spotlight: return "颜色会跟剩余额度一起变化。"
        }
    }

    var symbol: String {
        switch self {
        case .classic:   return "rectangle.3.group"
        case .capsule:   return "capsule.portrait"
        case .orbit:     return "circle.grid.2x2"
        case .card:      return "rectangle.inset.filled"
        case .minimal:   return "text.line.first.and.arrowtriangle.forward"
        case .spotlight: return "sparkles.rectangle.stack"
        }
    }
}

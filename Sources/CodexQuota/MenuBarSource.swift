import Foundation

/// 菜单栏要显示几条额度
enum MenuBarCount: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2

    static let storageKey = "menuBarCount"
    static let defaultValue: MenuBarCount = .one
    static let showLabelKey = "menuBarShowLabel"

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .one: return "1 个"
        case .two: return "2 个（5 小时 + 周）"
        }
    }
}

/// 菜单栏只显示 1 条时，显示哪一条
enum MenuBarSource: String, CaseIterable, Identifiable {
    /// 自动：两条里更紧的那条
    case auto
    /// 5 小时窗口（rate_limits.primary）
    case primary
    /// 周窗口（rate_limits.secondary）
    case secondary

    static let storageKey = "menuBarSource"
    static let defaultValue: MenuBarSource = .primary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:      return "自动（取剩余更少的那条）"
        case .primary:   return "5 小时"
        case .secondary: return "周"
        }
    }
}

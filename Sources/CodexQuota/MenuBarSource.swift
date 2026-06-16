import Foundation

/// 菜单栏标题里要显示哪个窗口的剩余百分比
enum MenuBarSource: String, CaseIterable, Identifiable {
    /// 5 小时窗口（rate_limits.primary）—— 默认
    case primary
    /// 周窗口（rate_limits.secondary）
    case secondary

    static let storageKey = "menuBarSource"
    static let defaultValue: MenuBarSource = .primary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primary:   return "5 小时"
        case .secondary: return "周"
        }
    }
}

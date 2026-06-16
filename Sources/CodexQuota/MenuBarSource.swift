import Foundation

/// 菜单栏标题里要显示哪个窗口的剩余百分比
enum MenuBarSource: String, CaseIterable, Identifiable {
    /// 自动：两条里更紧的那条
    case auto
    /// 5 小时窗口（rate_limits.primary）
    case primary
    /// 周窗口（rate_limits.secondary）
    case secondary

    static let storageKey = "menuBarSource"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:      return "自动（取剩余更少的那条）"
        case .primary:   return "5 小时"
        case .secondary: return "周"
        }
    }
}

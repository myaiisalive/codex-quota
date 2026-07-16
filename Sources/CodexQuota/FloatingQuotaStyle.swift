import Foundation

enum FloatingQuotaStyle: String, CaseIterable, Identifiable {
    // 这些值已经上线，不能改名或复用为其他样式。
    case classic
    case capsule
    case orbit
    case card
    case minimal
    case spotlight
    case commandDeck
    case glassIsland
    case dualRing
    case receipt
    case edgeMeter
    case pulsePanel

    static let storageKey = "floatingQuotaStyle"
    static let defaultValue: FloatingQuotaStyle = .classic
    static let originalCases: [FloatingQuotaStyle] = [.classic, .capsule, .orbit, .card, .minimal, .spotlight]
    static let redesignedCases: [FloatingQuotaStyle] = [.commandDeck, .glassIsland, .dualRing, .receipt, .edgeMeter, .pulsePanel]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:   return "经典横条"
        case .capsule:   return "胶囊悬浮"
        case .orbit:     return "圆形仪表"
        case .card:      return "信息卡片"
        case .minimal:   return "极简标签"
        case .spotlight: return "高亮提醒"
        case .commandDeck: return "数据舱"
        case .glassIsland: return "玻璃浮岛"
        case .dualRing: return "双环刻度"
        case .receipt: return "额度票据"
        case .edgeMeter: return "边栏刻度"
        case .pulsePanel: return "脉冲面板"
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
        case .commandDeck: return "深色数据面板，数字层级更清楚。"
        case .glassIsland: return "半透明浮块，轻盈但信息完整。"
        case .dualRing: return "两个额度窗口并排显示为圆环。"
        case .receipt: return "像一张小票，项目之间更有秩序。"
        case .edgeMeter: return "侧边色条配细进度轨，快速扫读。"
        case .pulsePanel: return "突出最低额度，紧张程度更醒目。"
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
        case .commandDeck: return "rectangle.3.group.bubble.left.fill"
        case .glassIsland: return "square.stack.3d.up.fill"
        case .dualRing: return "circle.circle.fill"
        case .receipt: return "receipt.fill"
        case .edgeMeter: return "chart.bar.fill"
        case .pulsePanel: return "waveform.path.ecg.rectangle.fill"
        }
    }
}

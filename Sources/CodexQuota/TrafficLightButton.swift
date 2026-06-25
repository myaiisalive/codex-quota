import SwiftUI

/// macOS 红绿灯风格按钮：默认彩色圆点，hover 时显示内部图标
struct TrafficLightButton: View {
    let color: Color
    let glyph: String           // SF Symbol 名
    var dotSize: CGFloat = 12
    var hitSize: CGFloat = 12
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                if hovering {
                    Image(systemName: glyph)
                        .font(.system(size: max(7, dotSize * 0.58), weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: dotSize, height: dotSize)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 用于 traffic light 一组的颜色（贴近 macOS 默认值）
enum TrafficLight {
    static let red = Color(red: 1.0, green: 0.373, blue: 0.341)      // close
    static let yellow = Color(red: 0.996, green: 0.737, blue: 0.180) // minimize
    static let green = Color(red: 0.157, green: 0.784, blue: 0.251)  // expand（备用）
}

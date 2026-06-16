import AppKit
import SwiftUI

/// 无边框、可拖动、置顶、内容自适应大小的浮窗
final class FloatingPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 240, height: 140),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        titlebarAppearsTransparent = true

        // 还原上次位置（仅记忆左上角）
        if let originStr = UserDefaults.standard.string(forKey: Self.originKey) {
            setFrameTopLeftPoint(NSPointFromString(originStr))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.maxX - 260, y: f.maxY - 20))
        }
    }

    func setRoot<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = true
        contentView = host
    }

    /// 平滑改变窗口整体透明度（含阴影、边框）
    func setAlpha(_ value: Double, animated: Bool = true) {
        let target = max(0.05, min(1.0, CGFloat(value)))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.animator().alphaValue = target
            }
        } else {
            self.alphaValue = target
        }
    }

    /// 内容尺寸变化时调整 panel，保持左上角不动
    func applyContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let current = self.frame
        let topLeftY = current.origin.y + current.size.height
        let target = NSRect(
            x: current.origin.x,
            y: topLeftY - size.height,
            width: size.width,
            height: size.height
        )
        if target != current {
            setFrame(target, display: true, animate: false)
        }
    }

    override var canBecomeKey: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        let topLeft = NSPoint(x: frameRect.origin.x, y: frameRect.origin.y + frameRect.size.height)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.originKey)
    }

    private static let originKey = "FloatingPanel.topLeft"
}

import AppKit
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 无边框、可拖动、置顶、内容自适应大小的浮窗
final class FloatingPanel: NSPanel {
    static let originKey = "FloatingPanel.topLeft"

    var onDragging: ((NSRect) -> Void)?
    var onDragEnded: ((NSRect) -> Void)?

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
        isMovableByWindowBackground = false
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
        let host = FirstMouseHostingView(rootView: view)
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

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    private var dragOffset: NSPoint = .zero
    private var didDragWindow = false
    private var dragEndTask: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
        didDragWindow = false
        dragEndTask?.cancel()
        dragEndTask = nil
    }

    override func mouseDragged(with event: NSEvent) {
        didDragWindow = true
        let loc = event.locationInWindow
        let newOrigin = NSPoint(
            x: frame.origin.x + loc.x - dragOffset.x,
            y: frame.origin.y + loc.y - dragOffset.y
        )
        setFrameOrigin(newOrigin)
        onDragging?(frame)
        scheduleDragEndFallback()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard didDragWindow else { return }
        dragEndTask?.cancel()
        dragEndTask = nil
        onDragEnded?(frame)
    }

    private func scheduleDragEndFallback() {
        dragEndTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.didDragWindow else { return }
            if (NSEvent.pressedMouseButtons & 0x1) != 0 {
                self.scheduleDragEndFallback()
                return
            }
            self.onDragEnded?(self.frame)
        }
        dragEndTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        let topLeft = NSPoint(x: frameRect.origin.x, y: frameRect.origin.y + frameRect.size.height)
        Self.persistTopLeft(topLeft)
    }

    static func persistTopLeft(_ topLeft: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: originKey)
    }
}

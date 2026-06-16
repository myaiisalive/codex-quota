import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = QuotaStore()
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var cancellable: Any?
    private var minimizedToDock = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        setupStatusItem()
        showPanel()

        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusTitle() }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle() }
        }
        // 偏好设置（菜单栏数据源）改变时立即刷新标题
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle() }
        }
        updateStatusTitle()
    }

    /// 用户点 Dock 图标时回来：恢复浮窗，并把 Dock 图标移除
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if minimizedToDock { restoreFromDock() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if minimizedToDock { restoreFromDock() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Codex 额度")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func updateStatusTitle() {
        guard let snap = store.snapshot else {
            statusItem?.button?.title = " --"
            return
        }
        let source = MenuBarSource(
            rawValue: UserDefaults.standard.string(forKey: MenuBarSource.storageKey) ?? ""
        ) ?? MenuBarSource.defaultValue
        let chosen: RateWindow?
        switch source {
        case .primary:
            chosen = snap.limits.primary
        case .secondary:
            chosen = snap.limits.secondary
        }
        guard let w = chosen else {
            statusItem?.button?.title = " --"
            return
        }
        statusItem?.button?.title = " \(Int(w.remainingPercent.rounded()))%"
    }

    @objc private func togglePanel() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu(); return
        }
        if minimizedToDock { restoreFromDock() }
        showPanel()
    }

    private func showPanel() {
        if panel == nil {
            let p = FloatingPanel()
            let view = QuotaView(
                store: store,
                onSizeChange: { [weak p] size in p?.applyContentSize(size) },
                onHide: { [weak p] in p?.orderOut(nil) },
                onMinimize: { [weak self] in self?.minimizeToDock() },
                onRefresh: { [weak self] in self?.store.reload() },
                onAlphaChange: { [weak p] alpha in p?.setAlpha(alpha) }
            )
            p.setRoot(view)
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    /// 切到 .regular 让 Dock 出现图标，再把 panel 隐藏
    private func minimizeToDock() {
        guard !minimizedToDock else { return }
        minimizedToDock = true
        NSApp.setActivationPolicy(.regular)
        panel?.orderOut(nil)
    }

    /// 从 Dock 点回来：恢复 panel，切回 .accessory（Dock 图标消失）
    private func restoreFromDock() {
        minimizedToDock = false
        showPanel()
        NSApp.setActivationPolicy(.accessory)
    }

    private func showMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 CodexQuota", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView())
        let w = NSWindow(contentViewController: host)
        w.title = "偏好设置"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshNow() { store.reload() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
@MainActor
enum AppEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

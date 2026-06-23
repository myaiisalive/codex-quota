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
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func updateStatusTitle() {
        // 第三方 API 模式：菜单栏显示「↗ 已用 · $ 剩余」
        if store.thirdPartyApiOnly {
            if let bal = store.apiBalance {
                let countRaw = UserDefaults.standard.integer(forKey: MenuBarApiCount.storageKey)
                let count = MenuBarApiCount(rawValue: countRaw) ?? MenuBarApiCount.defaultValue
                let showIcon: Bool = {
                    if UserDefaults.standard.object(forKey: MenuBarApiCount.showIconKey) == nil { return true }
                    return UserDefaults.standard.bool(forKey: MenuBarApiCount.showIconKey)
                }()
                let s = NSMutableAttributedString()
                switch count {
                case .two:
                    if let used = bal.used {
                        if showIcon { s.append(symbolImage("arrow.up.forward", size: 8)) }
                        s.append(NSAttributedString(string: "\(showIcon ? " " : "")\(formatMoney(used))", attributes: smallAttrs()))
                    }
                    if bal.used != nil && bal.remaining != nil {
                        s.append(NSAttributedString(string: " · ", attributes: smallAttrs(secondary: true)))
                    }
                    if let r = bal.remaining {
                        if showIcon { s.append(symbolImage("dollarsign", size: 8)) }
                        s.append(NSAttributedString(string: "\(showIcon ? " " : "")\(formatMoney(r))", attributes: smallAttrs()))
                    }
                case .one:
                    let source = MenuBarApiSource(
                        rawValue: UserDefaults.standard.string(forKey: MenuBarApiSource.storageKey) ?? ""
                    ) ?? MenuBarApiSource.defaultValue
                    switch source {
                    case .used:
                        if let used = bal.used {
                            if showIcon { s.append(symbolImage("arrow.up.forward", size: 8)) }
                            s.append(NSAttributedString(string: "\(showIcon ? " " : "")\(formatMoney(used))", attributes: smallAttrs()))
                        }
                    case .remaining:
                        if let r = bal.remaining {
                            if showIcon { s.append(symbolImage("dollarsign", size: 8)) }
                            s.append(NSAttributedString(string: "\(showIcon ? " " : "")\(formatMoney(r))", attributes: smallAttrs()))
                        }
                    }
                }
                if s.length == 0 {
                    setStatusTitle(plain: "--")
                } else {
                    statusItem?.button?.attributedTitle = s
                }
            } else {
                setStatusTitle(plain: "--")
            }
            return
        }

        guard let snap = store.snapshot else {
            setStatusTitle(plain: "--")
            return
        }
        let countRaw = UserDefaults.standard.integer(forKey: MenuBarCount.storageKey)
        let count = MenuBarCount(rawValue: countRaw) ?? MenuBarCount.defaultValue
        let showLabel: Bool = {
            if UserDefaults.standard.object(forKey: MenuBarCount.showLabelKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: MenuBarCount.showLabelKey)
        }()

        switch count {
        case .two:
            let s = NSMutableAttributedString()
            s.append(part(snap.limits.primary, symbol: "h.square.fill", showLabel: showLabel))
            s.append(NSAttributedString(string: " · ", attributes: baseAttrs(secondary: true)))
            s.append(part(snap.limits.secondary, symbol: "w.square.fill", showLabel: showLabel))
            statusItem?.button?.attributedTitle = s
        case .one:
            let source = MenuBarSource(
                rawValue: UserDefaults.standard.string(forKey: MenuBarSource.storageKey) ?? ""
            ) ?? MenuBarSource.defaultValue
            let chosen: RateWindow?
            let symbol: String
            switch source {
            case .primary:
                chosen = snap.limits.primary;   symbol = "h.square.fill"
            case .secondary:
                chosen = snap.limits.secondary; symbol = "w.square.fill"
            case .auto:
                let pairs: [(RateWindow, String)] = [
                    snap.limits.primary.map { ($0, "h.square.fill") },
                    snap.limits.secondary.map { ($0, "w.square.fill") }
                ].compactMap { $0 }
                if let pick = pairs.min(by: { $0.0.remainingPercent < $1.0.remainingPercent }) {
                    chosen = pick.0; symbol = pick.1
                } else {
                    chosen = nil; symbol = "h.square.fill"
                }
            }
            statusItem?.button?.attributedTitle = part(chosen, symbol: symbol, showLabel: showLabel)
        }
    }

    private func setStatusTitle(plain: String) {
        let attr = NSAttributedString(string: " \(plain)", attributes: baseAttrs())
        statusItem?.button?.attributedTitle = attr
    }

    private func baseAttrs(secondary: Bool = false) -> [NSAttributedString.Key: Any] {
        let font = NSFont.menuBarFont(ofSize: 0)
        return [
            .font: font,
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
    }

    /// 比 baseAttrs 字号小一点，用于第三方 API 模式（一行要装很多东西）
    private func smallAttrs(secondary: Bool = false) -> [NSAttributedString.Key: Any] {
        let font = NSFont.menuBarFont(ofSize: 11)
        return [
            .font: font,
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
    }

    private func symbolImage(_ name: String, size: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            attachment.image = img
        }
        return NSAttributedString(attachment: attachment)
    }

    private func formatMoney(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    /// 一个「图标 + 百分比」组合
    private func part(_ w: RateWindow?, symbol: String, showLabel: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if showLabel {
            let attachment = NSTextAttachment()
            let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                img.isTemplate = true
                attachment.image = img
            }
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: baseAttrs()))
        }
        let pct = w.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
        result.append(NSAttributedString(string: pct, attributes: baseAttrs()))
        return result
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
                onRefresh: { [weak self] in
                    self?.store.reload()
                    self?.store.reloadApiBalance()
                },
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

    @objc private func refreshNow() {
        store.reload()
        store.reloadApiBalance()
    }
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

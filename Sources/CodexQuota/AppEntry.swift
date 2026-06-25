import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = QuotaStore()
    private let panelState = FloatingPanelState()
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var settingsWindow: NSWindow?
    private var cancellable: Any?
    private var minimizedToDock = false
    private var settingsWindowShown = false
    private var isRelaunchingForUpdate = false
    private var edgeCollapseTask: DispatchWorkItem?
    private var pendingAttachedEdge: FloatingEdgeAttachment?
    private var isPanelHovered = false
    private var isDraggingPanel = false
    private var restoredPanelTopLeft: NSPoint?
    private var needsRestoredPanelPosition = false

    private var edgeSnapEnabled: Bool {
        UserDefaults.standard.bool(forKey: FloatingPanelState.edgeSnapEnabledKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        setupStatusItem()
        showPanel(refreshWhenBecomingVisible: true)

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
            Task { @MainActor in
                self?.updateStatusTitle()
                self?.syncEdgeSnapPreference()
            }
        }
        updateStatusTitle()
        syncEdgeSnapPreference()
    }

    /// 用户点 Dock 图标时回来：恢复浮窗，并把 Dock 图标移除
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if relaunchIfInstalledVersionIsNewer() { return true }
        refreshAll()
        if minimizedToDock { restoreFromDock() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if relaunchIfInstalledVersionIsNewer() { return }
        refreshAll()
        if minimizedToDock { restoreFromDock() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistPanelPositionForNextLaunch()
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
        if relaunchIfInstalledVersionIsNewer() { return }
        if minimizedToDock { restoreFromDock() }
        refreshAll()
        showPanel(refreshWhenBecomingVisible: true)
    }

    private func showPanel(refreshWhenBecomingVisible: Bool = false) {
        if panel == nil {
            let p = FloatingPanel()
            let view = QuotaView(
                store: store,
                panelState: panelState,
                onSizeChange: { [weak self, weak p] size in
                    self?.handlePanelSizeChange(size, panel: p)
                },
                onHide: { [weak p] in p?.orderOut(nil) },
                onMinimize: { [weak self] in self?.minimizeToDock() },
                onRefresh: { [weak self] in
                    self?.store.reload()
                    self?.store.reloadApiBalance()
                },
                onAlphaChange: { [weak p] alpha in p?.setAlpha(alpha) },
                onHoverChange: { [weak self] isOver in
                    self?.handlePanelHover(isOver)
                }
            )
            p.setRoot(view)
            p.onDragging = { [weak self] frame in
                Task { @MainActor in
                    self?.handlePanelDragging(frame)
                }
            }
            p.onDragEnded = { [weak self] frame in
                Task { @MainActor in
                    self?.handlePanelDragEnded(frame)
                }
            }
            panel = p
        }
        panel?.orderFrontRegardless()
        refreshEdgeAttachmentForCurrentPosition()
        if refreshWhenBecomingVisible {
            refreshAll()
        }
    }

    /// 切到 .regular 让 Dock 出现图标，再把 panel 隐藏
    private func minimizeToDock() {
        guard !minimizedToDock else { return }
        minimizedToDock = true
        updateActivationPolicy()
        panel?.orderOut(nil)
    }

    /// 从 Dock 点回来：恢复 panel，切回 .accessory（Dock 图标消失）
    private func restoreFromDock() {
        minimizedToDock = false
        showPanel(refreshWhenBecomingVisible: true)
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let shouldShowDockIcon = minimizedToDock || settingsWindowShown
        NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }

    private func handlePanelSizeChange(_ size: CGSize, panel: FloatingPanel?) {
        guard let panel else { return }
        panel.applyContentSize(size)
        if edgeSnapEnabled, panelState.attachedEdge != nil, panelState.isEdgeBarVisible {
            applyAttachedEdgeFrame(panel)
        } else if needsRestoredPanelPosition {
            applyRestoredPanelFrame(panel)
            needsRestoredPanelPosition = false
        } else {
            refreshEdgeAttachmentForCurrentPosition(panel)
        }
    }

    private func handlePanelHover(_ isOver: Bool) {
        isPanelHovered = isOver
        guard edgeSnapEnabled else { return }
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil

        if isOver {
            if panelState.isEdgeBarVisible {
                needsRestoredPanelPosition = true
                panelState.showsEdgeBar = false
            }
            return
        }

        scheduleEdgeCollapseIfNeeded()
    }

    private func handlePanelDragging(_ frame: NSRect) {
        guard edgeSnapEnabled else {
            pendingAttachedEdge = nil
            return
        }
        isDraggingPanel = true
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil
        pendingAttachedEdge = nearestEdge(for: frame)
    }

    private func handlePanelDragEnded(_ frame: NSRect) {
        isDraggingPanel = false
        guard edgeSnapEnabled else {
            pendingAttachedEdge = nil
            panelState.attachedEdge = nil
            panelState.showsEdgeBar = false
            return
        }
        let edge = pendingAttachedEdge ?? nearestEdge(for: frame)
        pendingAttachedEdge = nil

        guard let edge else {
            panelState.attachedEdge = nil
            panelState.showsEdgeBar = false
            return
        }
        panelState.attachedEdge = edge
        panelState.showsEdgeBar = false
        scheduleEdgeCollapseIfNeeded()
    }

    private func syncEdgeSnapPreference() {
        guard edgeSnapEnabled else {
            pendingAttachedEdge = nil
            edgeCollapseTask?.cancel()
            edgeCollapseTask = nil
            isDraggingPanel = false
            restoredPanelTopLeft = nil
            needsRestoredPanelPosition = false
            panelState.attachedEdge = nil
            panelState.showsEdgeBar = false
            return
        }
        refreshEdgeAttachmentForCurrentPosition()
    }

    private func scheduleEdgeCollapseIfNeeded() {
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil
        guard edgeSnapEnabled,
              !isDraggingPanel,
              !isPanelHovered,
              panelState.attachedEdge != nil,
              !panelState.isEdgeBarVisible else {
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.edgeSnapEnabled,
                  !self.isDraggingPanel,
                  !self.isPanelHovered,
                  self.panelState.attachedEdge != nil,
                  !self.panelState.isEdgeBarVisible else {
                return
            }
            if let panel = self.panel {
                self.rememberRestoredPanelPosition(panel)
                self.applyAttachedEdgeFrame(panel)
            }
            self.panelState.showsEdgeBar = true
        }
        edgeCollapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func refreshEdgeAttachmentForCurrentPosition(_ panel: FloatingPanel? = nil) {
        guard edgeSnapEnabled, !isDraggingPanel else { return }
        guard let panel = panel ?? self.panel else { return }
        guard !panelState.isEdgeBarVisible else {
            applyAttachedEdgeFrame(panel)
            return
        }
        guard panelState.attachedEdge == nil else { return }
        guard let edge = nearestEdge(for: panel.frame) else { return }
        panelState.attachedEdge = edge
        panelState.showsEdgeBar = false
        scheduleEdgeCollapseIfNeeded()
    }

    private func persistPanelPositionForNextLaunch() {
        if panelState.isEdgeBarVisible, let restoredPanelTopLeft {
            FloatingPanel.persistTopLeft(restoredPanelTopLeft)
            return
        }
        guard let panel else { return }
        FloatingPanel.persistTopLeft(NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
    }

    private func rememberRestoredPanelPosition(_ panel: FloatingPanel) {
        restoredPanelTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    private func applyRestoredPanelFrame(_ panel: FloatingPanel) {
        guard let topLeft = restoredPanelTopLeft else { return }
        let target = NSRect(
            x: topLeft.x,
            y: topLeft.y - panel.frame.height,
            width: panel.frame.width,
            height: panel.frame.height
        )
        if target.integral != panel.frame.integral {
            panel.setFrame(target, display: true, animate: false)
        }
    }

    private func nearestEdge(for frame: NSRect) -> FloatingEdgeAttachment? {
        guard let visible = visibleFrame(for: frame) else { return nil }
        let threshold: CGFloat = 56
        let distances: [(FloatingEdgeAttachment, CGFloat)] = [
            (.left, frame.minX <= visible.minX ? 0 : frame.minX - visible.minX),
            (.right, frame.maxX >= visible.maxX ? 0 : visible.maxX - frame.maxX),
            (.top, frame.maxY >= visible.maxY ? 0 : visible.maxY - frame.maxY),
            (.bottom, frame.minY <= visible.minY ? 0 : frame.minY - visible.minY)
        ]
        guard let closest = distances.min(by: { $0.1 < $1.1 }),
              closest.1 <= threshold else {
            return nil
        }
        return closest.0
    }

    private func visibleFrame(for frame: NSRect) -> NSRect? {
        let probe = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(probe) || $0.frame.contains(probe) }) {
            return screen.visibleFrame
        }
        return panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func applyAttachedEdgeFrame(_ panel: FloatingPanel) {
        guard let edge = panelState.attachedEdge,
              let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        let current = panel.frame
        let targetSize = current.size
        let origin: NSPoint

        switch edge {
        case .left:
            let y = min(max(current.midY - targetSize.height / 2, visible.minY), visible.maxY - targetSize.height)
            origin = NSPoint(x: visible.minX, y: y)
        case .right:
            let y = min(max(current.midY - targetSize.height / 2, visible.minY), visible.maxY - targetSize.height)
            origin = NSPoint(x: visible.maxX - targetSize.width, y: y)
        case .top:
            let x = min(max(current.midX - targetSize.width / 2, visible.minX), visible.maxX - targetSize.width)
            origin = NSPoint(x: x, y: visible.maxY - targetSize.height)
        case .bottom:
            let x = min(max(current.midX - targetSize.width / 2, visible.minX), visible.maxX - targetSize.width)
            origin = NSPoint(x: x, y: visible.minY)
        }

        let target = NSRect(origin: origin, size: targetSize)
        if target.integral != current.integral {
            panel.setFrame(target, display: true, animate: false)
        }
    }

    private func refreshAll() {
        store.reload()
        store.reloadApiBalance()
    }

    private func relaunchIfInstalledVersionIsNewer() -> Bool {
        guard !isRelaunchingForUpdate else { return true }
        guard let diskVersion = diskBundleVersion(),
              compareVersions(diskVersion, runningBundleVersion()) == .orderedDescending else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]

        do {
            try process.run()
            isRelaunchingForUpdate = true
            NSApp.terminate(nil)
            return true
        } catch {
            showRelaunchFailureAlert()
            return false
        }
    }

    private func runningBundleVersion() -> BundleVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return BundleVersion(
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? ""
        )
    }

    private func diskBundleVersion() -> BundleVersion? {
        let infoPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist").path
        guard let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return nil }
        return BundleVersion(
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? ""
        )
    }

    private func compareVersions(_ lhs: BundleVersion, _ rhs: BundleVersion) -> ComparisonResult {
        let short = lhs.shortVersion.compare(rhs.shortVersion, options: .numeric)
        if short != .orderedSame { return short }
        return lhs.buildVersion.compare(rhs.buildVersion, options: .numeric)
    }

    private func showRelaunchFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "已经更新到新版本"
        alert.informativeText = "这次没能自动重新打开。请先退出，再重新打开 Codex 额度。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
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
            settingsWindowShown = true
            updateActivationPolicy()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView())
        let w = NSWindow(contentViewController: host)
        w.title = "偏好设置"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 620, height: 460))
        w.minSize = NSSize(width: 620, height: 460)
        w.center()
        settingsWindow = w
        settingsWindowShown = true
        updateActivationPolicy()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject? === settingsWindow else { return }
        settingsWindowShown = false
        updateActivationPolicy()
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

private struct BundleVersion {
    let shortVersion: String
    let buildVersion: String
}

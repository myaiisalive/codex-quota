import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = QuotaStore()
    private let panelState = FloatingPanelState()
    private let updateManager = UpdateManager()
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
    private var edgeBarNeedsReentry = false
    private var pendingEdgeBarReentryCheck = false
    private var isRestoringFromEdgeBar = false
    private var postRestoreGuardFrame: NSRect?
    private var postRestoreGuardTask: DispatchWorkItem?
    private var panelDragStartFrame: NSRect?
    private var dragStartRestoredPanelTopLeft: NSPoint?
    private var restoredPanelSize: CGSize?
    private var restoreExpansionEdgeBarFrame: NSRect?
    private var attachedEdgeCrossAxisCenter: CGFloat?

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
        Task { @MainActor in
            let hasUpdate = await updateManager.checkForUpdates(force: false)
            if hasUpdate,
               let available = updateManager.availableRelease,
               updateManager.shouldAutoPresent(available.release) {
                showUpdateAlert(
                    release: available.release,
                    method: available.method,
                    allowsIgnoreVersion: true
                )
            }
        }
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
            if pendingEdgeBarReentryCheck {
                edgeBarNeedsReentry = panel.frame.contains(NSEvent.mouseLocation)
                pendingEdgeBarReentryCheck = false
            }
        } else if edgeSnapEnabled,
                  panelState.attachedEdge != nil,
                  restoreExpansionEdgeBarFrame != nil {
            applyRestoredPanelFrame(panel)
            if needsRestoredPanelPosition {
                finishRestoringPanel(panel)
            }
        } else if needsRestoredPanelPosition {
            applyRestoredPanelFrame(panel)
            finishRestoringPanel(panel)
        } else {
            refreshEdgeAttachmentForCurrentPosition(panel)
        }
    }

    private func finishRestoringPanel(_ panel: FloatingPanel) {
        needsRestoredPanelPosition = false
        isPanelHovered = panelContainsMouse(panel)
        isRestoringFromEdgeBar = false
        if isPanelHovered {
            clearPostRestoreGuard()
        } else {
            armPostRestoreGuardIfNeeded()
        }
    }

    private func handlePanelHover(_ isOver: Bool) {
        let actuallyHovering = isOver || panelContainsMouse()
        isPanelHovered = actuallyHovering
        guard edgeSnapEnabled else { return }
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil

        if actuallyHovering {
            if panelState.isEdgeBarVisible {
                guard !edgeBarNeedsReentry else { return }
                edgeBarNeedsReentry = false
                isRestoringFromEdgeBar = true
                postRestoreGuardFrame = panel?.frame.insetBy(dx: -2, dy: -2)
                restoreExpansionEdgeBarFrame = panel?.frame
                needsRestoredPanelPosition = true
                panelState.showsEdgeBar = false
            } else {
                clearPostRestoreGuard()
            }
            return
        }

        guard !isRestoringFromEdgeBar, postRestoreGuardFrame == nil else { return }

        if panelState.isEdgeBarVisible {
            edgeBarNeedsReentry = false
        }
        scheduleEdgeCollapseIfNeeded(requiresEdgeBarReentry: true)
    }

    private func handlePanelDragging(_ frame: NSRect) {
        guard edgeSnapEnabled else {
            pendingAttachedEdge = nil
            return
        }
        isDraggingPanel = true
        restoreExpansionEdgeBarFrame = nil
        if panelDragStartFrame == nil {
            panelDragStartFrame = frame
            dragStartRestoredPanelTopLeft = restoredPanelTopLeft
        }
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil
        pendingAttachedEdge = nearestEdge(
            for: frame,
            dragStartFrame: panelDragStartFrame,
            currentEdge: panelState.attachedEdge
        )
    }

    private func handlePanelDragEnded(_ frame: NSRect) {
        let wasEdgeBarVisible = panelState.isEdgeBarVisible
        defer {
            panelDragStartFrame = nil
            dragStartRestoredPanelTopLeft = nil
        }
        isDraggingPanel = false
        guard edgeSnapEnabled else {
            pendingAttachedEdge = nil
            panelState.attachedEdge = nil
            attachedEdgeCrossAxisCenter = nil
            panelState.showsEdgeBar = false
            edgeBarNeedsReentry = false
            pendingEdgeBarReentryCheck = false
            isRestoringFromEdgeBar = false
            clearPostRestoreGuard()
            return
        }
        let edge = pendingAttachedEdge ?? nearestEdge(
            for: frame,
            dragStartFrame: panelDragStartFrame,
            currentEdge: panelState.attachedEdge
        )
        pendingAttachedEdge = nil

        guard let edge else {
            panelState.attachedEdge = nil
            attachedEdgeCrossAxisCenter = nil
            panelState.showsEdgeBar = false
            edgeBarNeedsReentry = false
            pendingEdgeBarReentryCheck = false
            isRestoringFromEdgeBar = false
            clearPostRestoreGuard()
            return
        }
        attachedEdgeCrossAxisCenter = edge.isHorizontalBar ? frame.midX : frame.midY
        if wasEdgeBarVisible {
            updateRestoredPositionAfterEdgeBarDrag(endFrame: frame, edge: edge)
            panelState.attachedEdge = edge
            panelState.showsEdgeBar = true
            edgeBarNeedsReentry = false
            pendingEdgeBarReentryCheck = false
            isRestoringFromEdgeBar = false
            clearPostRestoreGuard()
            if let panel {
                applyAttachedEdgeFrame(panel)
            }
            return
        }
        panelState.attachedEdge = edge
        panelState.showsEdgeBar = false
        isRestoringFromEdgeBar = false
        clearPostRestoreGuard()
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
            restoreExpansionEdgeBarFrame = nil
            attachedEdgeCrossAxisCenter = nil
            panelState.attachedEdge = nil
            panelState.showsEdgeBar = false
            edgeBarNeedsReentry = false
            pendingEdgeBarReentryCheck = false
            isRestoringFromEdgeBar = false
            clearPostRestoreGuard()
            return
        }
        refreshEdgeAttachmentForCurrentPosition()
    }

    private func scheduleEdgeCollapseIfNeeded(requiresEdgeBarReentry: Bool = false) {
        edgeCollapseTask?.cancel()
        edgeCollapseTask = nil
        guard edgeSnapEnabled,
              !isDraggingPanel,
              !isPanelHovered,
              !panelContainsMouse(),
              postRestoreGuardFrame == nil,
              panelState.attachedEdge != nil,
              !panelState.isEdgeBarVisible else {
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.edgeSnapEnabled,
                  !self.isDraggingPanel,
                  !self.isPanelHovered,
                  !self.panelContainsMouse(),
                  self.postRestoreGuardFrame == nil,
                  self.panelState.attachedEdge != nil,
                  !self.panelState.isEdgeBarVisible else {
                return
            }
            if let panel = self.panel {
                self.rememberRestoredPanelPosition(panel)
                self.applyAttachedEdgeFrame(panel)
            }
            self.edgeBarNeedsReentry = requiresEdgeBarReentry
            self.pendingEdgeBarReentryCheck = requiresEdgeBarReentry
            self.clearPostRestoreGuard()
            self.restoreExpansionEdgeBarFrame = nil
            self.panelState.showsEdgeBar = true
        }
        edgeCollapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func armPostRestoreGuardIfNeeded() {
        postRestoreGuardTask?.cancel()
        postRestoreGuardTask = nil
        guard edgeSnapEnabled,
              !isDraggingPanel,
              postRestoreGuardFrame != nil,
              panelState.attachedEdge != nil,
              !panelState.isEdgeBarVisible else {
            clearPostRestoreGuard()
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.edgeSnapEnabled,
                  !self.isDraggingPanel,
                  self.postRestoreGuardFrame != nil,
                  self.panelState.attachedEdge != nil,
                  !self.panelState.isEdgeBarVisible else {
                self.clearPostRestoreGuard()
                return
            }

            if self.panelContainsMouse() {
                self.isPanelHovered = true
                self.clearPostRestoreGuard()
                return
            }

            if let guardFrame = self.postRestoreGuardFrame,
               guardFrame.contains(NSEvent.mouseLocation) {
                self.armPostRestoreGuardIfNeeded()
                return
            }

            self.isPanelHovered = false
            self.clearPostRestoreGuard()
            self.scheduleEdgeCollapseIfNeeded(requiresEdgeBarReentry: true)
        }

        postRestoreGuardTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
    }

    private func clearPostRestoreGuard() {
        postRestoreGuardTask?.cancel()
        postRestoreGuardTask = nil
        postRestoreGuardFrame = nil
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
        attachedEdgeCrossAxisCenter = edge.isHorizontalBar ? panel.frame.midX : panel.frame.midY
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
        restoredPanelSize = panel.frame.size
    }

    private func applyRestoredPanelFrame(_ panel: FloatingPanel) {
        let size = panel.frame.size
        var target: NSRect

        if let edge = panelState.attachedEdge,
           let barFrame = restoreExpansionEdgeBarFrame,
           let screenFrame = screenForFrame(barFrame)?.frame {
            let origin: NSPoint
            switch edge {
            case .left:
                var y = barFrame.midY - size.height / 2
                y = min(max(y, screenFrame.minY), screenFrame.maxY - size.height)
                origin = NSPoint(x: screenFrame.minX, y: y)
            case .right:
                var y = barFrame.midY - size.height / 2
                y = min(max(y, screenFrame.minY), screenFrame.maxY - size.height)
                origin = NSPoint(x: screenFrame.maxX - size.width, y: y)
            case .top:
                var x = barFrame.midX - size.width / 2
                x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
                origin = NSPoint(x: x, y: screenFrame.maxY - size.height)
            case .bottom:
                var x = barFrame.midX - size.width / 2
                x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
                origin = NSPoint(x: x, y: screenFrame.minY)
            }
            target = NSRect(origin: origin, size: size)
        } else if let topLeft = restoredPanelTopLeft {
            target = NSRect(
                x: topLeft.x,
                y: topLeft.y - size.height,
                width: size.width,
                height: size.height
            )
            if let visible = screenForFrame(target)?.visibleFrame ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - target.width)
                target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
            }
        } else {
            return
        }

        if target.integral != panel.frame.integral {
            panel.setFrame(target, display: true, animate: false)
        }
    }

    private func updateRestoredPositionAfterEdgeBarDrag(endFrame: NSRect, edge: FloatingEdgeAttachment) {
        if let restoredPanelSize,
           let topLeft = restoredPanelTopLeft(for: edge, edgeBarFrame: endFrame, restoredSize: restoredPanelSize) {
            restoredPanelTopLeft = topLeft
            return
        }

        guard let startFrame = panelDragStartFrame else {
            restoredPanelTopLeft = NSPoint(x: endFrame.minX, y: endFrame.maxY)
            return
        }

        let deltaX = endFrame.origin.x - startFrame.origin.x
        let deltaY = endFrame.origin.y - startFrame.origin.y

        if let startTopLeft = dragStartRestoredPanelTopLeft {
            restoredPanelTopLeft = NSPoint(
                x: startTopLeft.x + deltaX,
                y: startTopLeft.y + deltaY
            )
        } else {
            restoredPanelTopLeft = NSPoint(x: endFrame.minX, y: endFrame.maxY)
        }
    }

    private func restoredPanelTopLeft(
        for edge: FloatingEdgeAttachment,
        edgeBarFrame: NSRect,
        restoredSize: CGSize
    ) -> NSPoint? {
        guard restoredSize.width > 0, restoredSize.height > 0 else { return nil }
        let visible = screenForFrame(edgeBarFrame)?.visibleFrame ?? panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visible else { return nil }

        let origin: NSPoint
        switch edge {
        case .left:
            let y = min(max(edgeBarFrame.midY - restoredSize.height / 2, visible.minY), visible.maxY - restoredSize.height)
            origin = NSPoint(x: visible.minX, y: y)
        case .right:
            let y = min(max(edgeBarFrame.midY - restoredSize.height / 2, visible.minY), visible.maxY - restoredSize.height)
            origin = NSPoint(x: visible.maxX - restoredSize.width, y: y)
        case .top:
            let x = min(max(edgeBarFrame.midX - restoredSize.width / 2, visible.minX), visible.maxX - restoredSize.width)
            origin = NSPoint(x: x, y: visible.maxY - restoredSize.height)
        case .bottom:
            let x = min(max(edgeBarFrame.midX - restoredSize.width / 2, visible.minX), visible.maxX - restoredSize.width)
            origin = NSPoint(x: x, y: visible.minY)
        }

        return NSPoint(x: origin.x, y: origin.y + restoredSize.height)
    }

    private func panelContainsMouse(_ panel: FloatingPanel? = nil) -> Bool {
        guard let panel = panel ?? self.panel else { return false }
        return panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    private func nearestEdge(
        for frame: NSRect,
        dragStartFrame: NSRect? = nil,
        currentEdge: FloatingEdgeAttachment? = nil
    ) -> FloatingEdgeAttachment? {
        guard let visible = visibleFrame(for: frame) else { return nil }
        let threshold: CGFloat = 56
        let distances: [(FloatingEdgeAttachment, CGFloat)] = [
            (.left, frame.minX <= visible.minX ? 0 : frame.minX - visible.minX),
            (.right, frame.maxX >= visible.maxX ? 0 : visible.maxX - frame.maxX),
            (.top, frame.maxY >= visible.maxY ? 0 : visible.maxY - frame.maxY),
            (.bottom, frame.minY <= visible.minY ? 0 : frame.minY - visible.minY)
        ]
        let candidates = distances.filter { $0.1 <= threshold }
        guard !candidates.isEmpty else {
            return nil
        }
        if candidates.count == 1 {
            return candidates[0].0
        }

        if let dragStartFrame {
            let deltaX = frame.origin.x - dragStartFrame.origin.x
            let deltaY = frame.origin.y - dragStartFrame.origin.y
            let horizontalPreferred = abs(deltaX) > abs(deltaY) + 6
            let verticalPreferred = abs(deltaY) > abs(deltaX) + 6

            if horizontalPreferred {
                let preferred: FloatingEdgeAttachment = deltaX < 0 ? .left : .right
                if candidates.contains(where: { $0.0 == preferred }) {
                    return preferred
                }
            }

            if verticalPreferred {
                let preferred: FloatingEdgeAttachment = deltaY < 0 ? .bottom : .top
                if candidates.contains(where: { $0.0 == preferred }) {
                    return preferred
                }
            }
        }

        if let currentEdge,
           candidates.contains(where: { $0.0 == currentEdge }) {
            return currentEdge
        }

        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func screenForFrame(_ frame: NSRect) -> NSScreen? {
        let probe = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) {
            return screen
        }

        var intersectingScreen: NSScreen?
        var largestIntersectionArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                continue
            }
            let area = intersection.width * intersection.height
            if area > largestIntersectionArea {
                largestIntersectionArea = area
                intersectingScreen = screen
            }
        }

        return intersectingScreen ?? panel?.screen ?? NSScreen.main
    }

    private func visibleFrame(for frame: NSRect) -> NSRect? {
        screenForFrame(frame)?.visibleFrame
    }

    private func applyAttachedEdgeFrame(_ panel: FloatingPanel) {
        guard let edge = panelState.attachedEdge,
              let screenFrame = screenForFrame(panel.frame)?.frame else {
            return
        }

        let current = panel.frame
        let targetSize = current.size
        let fallbackCross: CGFloat = edge.isHorizontalBar ? current.midX : current.midY
        let cross = attachedEdgeCrossAxisCenter ?? fallbackCross
        let origin: NSPoint

        switch edge {
        case .left:
            let y = min(max(cross - targetSize.height / 2, screenFrame.minY), screenFrame.maxY - targetSize.height)
            origin = NSPoint(x: screenFrame.minX, y: y)
        case .right:
            let y = min(max(cross - targetSize.height / 2, screenFrame.minY), screenFrame.maxY - targetSize.height)
            origin = NSPoint(x: screenFrame.maxX - targetSize.width, y: y)
        case .top:
            let x = min(max(cross - targetSize.width / 2, screenFrame.minX), screenFrame.maxX - targetSize.width)
            origin = NSPoint(x: x, y: screenFrame.maxY - targetSize.height)
        case .bottom:
            let x = min(max(cross - targetSize.width / 2, screenFrame.minX), screenFrame.maxX - targetSize.width)
            origin = NSPoint(x: x, y: screenFrame.minY)
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
        BundleVersion.current
    }

    private func diskBundleVersion() -> BundleVersion? {
        let infoURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? BoundedFileReader.data(from: infoURL, maxBytes: 1024 * 1024),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return BundleVersion(infoDictionary: info)
    }

    private func compareVersions(_ lhs: BundleVersion, _ rhs: BundleVersion) -> ComparisonResult {
        lhs.compare(to: rhs)
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
        let update = NSMenuItem(title: updateManager.menuItemTitle, action: #selector(checkForUpdatesNow), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
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
        let host = NSHostingController(rootView: SettingsView(store: store, updateManager: updateManager))
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
    @objc private func checkForUpdatesNow() {
        Task { @MainActor in
            if let available = updateManager.availableRelease {
                showUpdateAlert(
                    release: available.release,
                    method: available.method,
                    allowsIgnoreVersion: true
                )
                return
            }

            let hasUpdate = await updateManager.checkForUpdates(force: true)
            if hasUpdate, let available = updateManager.availableRelease {
                showUpdateAlert(
                    release: available.release,
                    method: available.method,
                    allowsIgnoreVersion: true
                )
                return
            }

            switch updateManager.state {
            case .upToDate:
                showSimpleAlert(title: "已经是最新版本", message: "现在这台电脑上的 CodexQuota 已经是最新版本。")
            case .failed(let message):
                showSimpleAlert(title: "检查新版本失败", message: message)
            default:
                break
            }
        }
    }

    private func showUpdateAlert(
        release: UpdateManager.ReleaseInfo,
        method: UpdateManager.InstallMethod,
        allowsIgnoreVersion: Bool
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(release.version.shortVersion)"
        alert.informativeText = method.summaryText
        alert.addButton(withTitle: method.primaryActionTitle)
        if allowsIgnoreVersion {
            alert.addButton(withTitle: "忽略这个版本")
        }
        alert.addButton(withTitle: "以后再说")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                do {
                    try await updateManager.performAvailableUpdate()
                } catch {
                    showSimpleAlert(
                        title: "更新没完成",
                        message: (error as? LocalizedError)?.errorDescription ?? "这次没有完成更新，请稍后再试。"
                    )
                }
            }
        case .alertSecondButtonReturn:
            if allowsIgnoreVersion {
                updateManager.ignore(release)
            } else {
                break
            }
        default:
            break
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
@MainActor
enum AppEntry {
    static func main() {
        if UsageScriptRunner.runWorkerIfRequested() {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

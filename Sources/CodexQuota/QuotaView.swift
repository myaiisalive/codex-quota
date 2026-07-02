import SwiftUI

private let sourceHistoryCoordinateSpace = "sourceHistorySection"

struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var panelState: FloatingPanelState
    @AppStorage("collapsed") private var collapsed = false
    @AppStorage(FloatingQuotaStyle.storageKey) private var styleRaw: String = FloatingQuotaStyle.defaultValue.rawValue
    @AppStorage(UsageSourceDisplaySettings.showInactiveSourcesKey) private var showInactiveSources = false
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5
    @State private var hovering = false
    @State private var dimmed = false
    @State private var dimTask: DispatchWorkItem?
    @State private var historyNow = Date()
    @State private var draggedSourceID: String?
    @State private var sourceRowFrames: [String: CGRect] = [:]
    @State private var pendingDeletionEntry: UsageSourceEntry?
    var onSizeChange: ((CGSize) -> Void)? = nil
    var onHide: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onRefresh: (() -> Void)? = nil
    var onAlphaChange: ((Double) -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil

    private var panelStyle: FloatingQuotaStyle {
        FloatingQuotaStyle(rawValue: styleRaw) ?? .classic
    }

    var body: some View {
        Group {
            if panelState.isEdgeBarVisible {
                edgeBarBody
            } else {
                styledBody
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { onSizeChange?(geo.size) }
                .onChange(of: geo.size) { new in onSizeChange?(new) }
        })
        .animation(.easeInOut(duration: 0.15), value: collapsed)
        .onChange(of: dimmed) { _ in pushAlpha() }
        .onChange(of: dimmedOpacity) { _ in pushAlpha() }
        .onHover { isOver in
            hovering = isOver
            if isOver {
                cancelDim()
                dimmed = false
            } else {
                scheduleDim()
            }
            onHoverChange?(isOver)
        }
        .onAppear {
            scheduleDim()
            pushAlpha()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            historyNow = now
        }
        .alert(item: $pendingDeletionEntry) { entry in
            Alert(
                title: Text("删除这条记录？"),
                message: Text("删掉后，这条记录会从列表里移除。以后再次用到这个账号或 API，它会自动重新出现。"),
                primaryButton: .destructive(Text("删除")) {
                    store.deleteSource(entry.id)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    @ViewBuilder
    private var styledBody: some View {
        switch panelStyle {
        case .classic:
            standardPanel(
                padding: collapsed ? 8 : 12,
                background: AnyView(
                    RoundedRectangle(cornerRadius: collapsed ? 8 : 12, style: .continuous)
                        .fill(.regularMaterial)
                ),
                overlay: AnyView(
                    RoundedRectangle(cornerRadius: collapsed ? 8 : 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            )
        case .capsule:
            if collapsed {
                standardPanel(
                    padding: 10,
                    background: AnyView(Capsule().fill(.ultraThinMaterial)),
                    overlay: AnyView(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                )
            } else {
                standardPanel(
                    padding: 14,
                    background: AnyView(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                    ),
                    overlay: AnyView(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                )
            }
        case .orbit:
            orbitPanel
        case .card:
            cardPanel
        case .minimal:
            if collapsed {
                standardPanel(
                    padding: 6,
                    background: AnyView(
                        Capsule()
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    ),
                    overlay: AnyView(
                        Capsule()
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                )
            } else {
                standardPanel(
                    padding: 10,
                    background: AnyView(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    ),
                    overlay: AnyView(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                )
            }
        case .spotlight:
            standardPanel(
                padding: collapsed ? 9 : 13,
                background: AnyView(
                    ZStack {
                        RoundedRectangle(cornerRadius: collapsed ? 12 : 16, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                        RoundedRectangle(cornerRadius: collapsed ? 12 : 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [urgencyTint.opacity(0.18), urgencyTint.opacity(0.04)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                ),
                overlay: AnyView(
                    RoundedRectangle(cornerRadius: collapsed ? 12 : 16, style: .continuous)
                        .stroke(urgencyTint.opacity(0.38), lineWidth: 1)
                )
            )
        }
    }

    private func standardPanel(
        padding: CGFloat,
        background: AnyView,
        overlay: AnyView
    ) -> some View {
        Group {
            if collapsed {
                collapsedBody
            } else {
                expandedBody(width: panelStyle == .card ? 252 : 240)
            }
        }
        .padding(padding)
        .background(background)
        .overlay(overlay)
    }

    @ViewBuilder
    private var edgeBarBody: some View {
        if let edge = panelState.attachedEdge {
            if edge.isHorizontalBar {
                horizontalEdgeBar
            } else {
                verticalEdgeBar
            }
        }
    }

    private var horizontalEdgeBar: some View {
        HStack(spacing: 7) {
            if let current = store.currentSourceEntry {
                edgeBarActiveSourceChip(current)
            }
            if store.thirdPartyApiOnly {
                edgeBarApiHorizontal
            } else {
                edgeBarQuotaHorizontal
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
        .fixedSize()
    }

    private var verticalEdgeBar: some View {
        VStack(spacing: 6) {
            if let current = store.currentSourceEntry {
                edgeBarActiveSourceVertical(current)
            }
            if store.thirdPartyApiOnly {
                edgeBarApiVertical
            } else {
                edgeBarQuotaVertical
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(width: 34)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
        .fixedSize()
    }

    private var cardPanel: some View {
        Group {
            if collapsed {
                cardCollapsedBody
            } else {
                cardExpandedBody
            }
        }
        .padding(collapsed ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: collapsed ? 14 : 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: collapsed ? 14 : 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private func pushAlpha() {
        let alpha = dimmed ? max(0.05, dimmedOpacity) : 1.0
        onAlphaChange?(alpha)
    }

    private func scheduleDim() {
        cancelDim()
        let task = DispatchWorkItem {
            if !hovering { dimmed = true }
        }
        dimTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + dimDelaySeconds, execute: task)
    }

    private func cancelDim() {
        dimTask?.cancel()
        dimTask = nil
    }

    // MARK: - Expanded

    private func expandedBody(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                trafficLights
                Image(systemName: "gauge.with.needle")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                Text("Codex 剩余额度")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.thirdPartyApiOnly, let plan = store.snapshot?.limits.planType {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                refreshButton()
                collapseButton()
            }

            sourceHistorySection

            if let snap = store.snapshot {
                if !store.thirdPartyApiOnly {
                    if let p = snap.limits.primary { QuotaRow(window: p) }
                    if let s = snap.limits.secondary { QuotaRow(window: s) }
                }
                if let bal = store.apiBalance {
                    ApiBalanceRow(balance: bal)
                } else if store.thirdPartyApiOnly, let msg = store.apiBalanceError {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                Text("更新于 \(timeAgo(snap.capturedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if store.thirdPartyApiOnly, let bal = store.apiBalance {
                // 第三方 API 模式且 sessions 还没数据：只显示余额
                ApiBalanceRow(balance: bal)
            } else if let err = store.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 220, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Collapsed (single line)

    private var collapsedBody: some View {
        HStack(spacing: 8) {
            trafficLights
            Image(systemName: store.thirdPartyApiOnly ? "creditcard" : "gauge.with.needle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if store.thirdPartyApiOnly, let bal = store.apiBalance {
                collapsedBalance(bal)
            } else if let snap = store.snapshot {
                let ws = windows(snap)
                HStack(spacing: 8) {
                    ForEach(Array(ws.enumerated()), id: \.offset) { idx, w in
                        HStack(spacing: 3) {
                            Text(w.windowLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("\(Int(w.remainingPercent.rounded()))%")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(rowColor(w))
                        }
                        if idx < ws.count - 1 {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("--").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            refreshButton()
            collapseButton()
        }
        .fixedSize()
    }

    private func collapsedBalance(_ bal: UsageScriptRunner.Balance) -> some View {
        HStack(spacing: 6) {
            if let used = bal.used {
                HStack(spacing: 3) {
                    Text("已用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(formatMoney(used))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if bal.used != nil && bal.remaining != nil {
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let r = bal.remaining {
                HStack(spacing: 3) {
                    Text("剩")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(formatMoney(r)) \(bal.unit ?? "")")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(balanceColor(r, total: bal.total))
                }
            }
        }
    }

    private func formatMoney(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func compactBalanceText(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 100 { return String(format: "%.0f", value) }
        if absValue >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func balanceColor(_ remaining: Double, total: Double?) -> Color {
        guard let total, total > 0 else { return .primary }
        let pct = remaining / total * 100
        if pct > 50 { return .green }
        if pct > 20 { return .orange }
        return .red
    }

    // MARK: - Header buttons

    private var trafficLights: some View {
        HStack(spacing: 6) {
            TrafficLightButton(color: TrafficLight.red, glyph: "xmark") {
                onHide?()
            }
            TrafficLightButton(color: TrafficLight.yellow, glyph: "minus") {
                onMinimize?()
            }
        }
    }

    @State private var refreshSpinAngle: Double = 0

    private func refreshButton(size: CGFloat = 18, iconSize: CGFloat = 10) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.7)) {
                refreshSpinAngle += 360
            }
            onRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(refreshSpinAngle))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("立即刷新")
    }

    private func collapseButton(size: CGFloat = 18, iconSize: CGFloat = 10) -> some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "展开" : "缩小为一行")
    }

    private func orbitCloseButton(hitSize: CGFloat = 28) -> some View {
        TrafficLightButton(color: TrafficLight.red, glyph: "xmark", dotSize: 12, hitSize: hitSize) {
            onHide?()
        }
    }

    private func orbitMinimizeButton(hitSize: CGFloat = 28) -> some View {
        TrafficLightButton(color: TrafficLight.yellow, glyph: "minus", dotSize: 12, hitSize: hitSize) {
            onMinimize?()
        }
    }

    private func orbitControl<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func orbitActionBar(
        actionSize: CGFloat,
        trafficHitSize: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            orbitCloseButton(hitSize: trafficHitSize)
            orbitMinimizeButton(hitSize: trafficHitSize)
            refreshButton(size: actionSize, iconSize: 13)
            collapseButton(size: actionSize, iconSize: 13)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            ZStack {
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
        .fixedSize()
    }

    private var edgeBarQuotaHorizontal: some View {
        Group {
            if snapshotWindows.isEmpty {
                Text("--")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { idx, window in
                        HStack(spacing: 3) {
                            Text(window.windowLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("\(Int(window.remainingPercent.rounded()))%")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(rowColor(window))
                        }
                        if idx < min(snapshotWindows.count, 2) - 1 {
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var edgeBarQuotaVertical: some View {
        Group {
            if snapshotWindows.isEmpty {
                Text("--")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                        VStack(spacing: 1) {
                            Text(window.windowLabel)
                                .font(.system(size: 6.5))
                                .foregroundStyle(.secondary)
                            Text("\(Int(window.remainingPercent.rounded()))%")
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(rowColor(window))
                        }
                    }
                }
            }
        }
    }

    private var edgeBarApiHorizontal: some View {
        Group {
            if let balance = store.apiBalance, let remaining = balance.remaining {
                HStack(spacing: 4) {
                    Text("剩")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(compactBalanceText(remaining))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(balanceColor(remaining, total: balance.total))
                }
            } else if let msg = store.apiBalanceError {
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var edgeBarApiVertical: some View {
        Group {
            if let balance = store.apiBalance, let remaining = balance.remaining {
                VStack(spacing: 2) {
                    Text("剩")
                        .font(.system(size: 6.5))
                        .foregroundStyle(.secondary)
                    Text(compactBalanceText(remaining))
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(balanceColor(remaining, total: balance.total))
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("--")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windows(_ snap: QuotaSnapshot) -> [RateWindow] {
        [snap.limits.primary, snap.limits.secondary].compactMap { $0 }
    }

    private var snapshotWindows: [RateWindow] {
        guard let snap = store.snapshot else { return [] }
        return windows(snap)
    }

    private var urgencyTint: Color {
        if store.thirdPartyApiOnly,
           let remaining = store.apiBalance?.remaining,
           let total = store.apiBalance?.total,
           total > 0 {
            return balanceColor(remaining, total: total)
        }
        if let window = headlineWindow {
            return rowColor(window)
        }
        return .accentColor
    }

    private var headlineWindow: RateWindow? {
        if let primary = store.snapshot?.limits.primary { return primary }
        return store.snapshot?.limits.secondary
    }

    private var secondaryHeadlineWindow: RateWindow? {
        guard store.snapshot?.limits.primary != nil else { return nil }
        return store.snapshot?.limits.secondary
    }

    private var orbitPanel: some View {
        Group {
            if collapsed {
                orbitCompactBody
            } else {
                orbitExpandedBody
            }
        }
    }

    private var orbitCompactBody: some View {
        orbitShell(diameter: 76) {
            Group {
                if store.thirdPartyApiOnly, let bal = store.apiBalance {
                    VStack(spacing: 2) {
                        Text(balanceBadgeText(bal))
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                            .foregroundStyle(balanceColor(bal.remaining ?? 0, total: bal.total))
                        Text(bal.providerName)
                            .font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let window = headlineWindow {
                    VStack(spacing: 1) {
                        Text(window.windowLabel)
                            .font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: 17, weight: .bold).monospacedDigit())
                            .foregroundStyle(rowColor(window))
                        if let extra = secondaryHeadlineWindow {
                            Text("\(extra.windowLabel) \(Int(extra.remainingPercent.rounded()))%")
                                .font(.system(size: 7, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(shortReset(window.resetDate))
                                .font(.system(size: 7).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let err = store.lastError {
                    Text(err)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 54)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var orbitExpandedBody: some View {
        VStack(spacing: 8) {
            orbitShell(diameter: 96, tintOpacity: 0.05) {
                Group {
                    if store.thirdPartyApiOnly, let bal = store.apiBalance {
                        VStack(spacing: 4) {
                            Text(balanceBadgeText(bal))
                                .font(.system(size: 18, weight: .bold).monospacedDigit())
                                .foregroundStyle(balanceColor(bal.remaining ?? 0, total: bal.total))
                            Text(bal.providerName)
                                .font(.system(size: 8, weight: .medium))
                                .lineLimit(1)
                            if let used = bal.used {
                                Text("已用 \(formatMoney(used))")
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let window = headlineWindow {
                        VStack(spacing: 3) {
                            CircleGauge(window: window)
                            if let extra = secondaryHeadlineWindow {
                                Text("\(extra.windowLabel) 剩 \(Int(extra.remainingPercent.rounded()))%")
                                    .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let snap = store.snapshot {
                                Text("更新于 \(timeAgo(snap.capturedAt))")
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else if let err = store.lastError {
                        Text(err)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 76)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !visibleSourceEntries.isEmpty {
                sourceHistorySection
                    .frame(width: 196, alignment: .leading)
            }
        }
    }

    private func orbitShell<Content: View>(
        diameter: CGFloat,
        tintOpacity: Double = 0,
        actionSize: CGFloat = 28,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let trafficHitSize: CGFloat = 26
        return VStack(spacing: -10) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                if tintOpacity > 0 {
                    Circle()
                        .fill(urgencyTint.opacity(tintOpacity))
                }
                Circle()
                    .stroke(urgencyTint.opacity(0.24), lineWidth: 1)
                content()
            }
            .frame(width: diameter, height: diameter)

            orbitControl {
                orbitActionBar(
                    actionSize: actionSize,
                    trafficHitSize: trafficHitSize
                )
            }
        }
        .contentShape(Rectangle())
    }

    private func balanceBadgeText(_ balance: UsageScriptRunner.Balance) -> String {
        if let remaining = balance.remaining {
            return formatMoney(remaining)
        }
        if let used = balance.used {
            return formatMoney(used)
        }
        return "--"
    }

    private func rowColor(_ w: RateWindow) -> Color {
        let r = w.remainingPercent
        if r > 50 { return .green }
        if r > 20 { return .orange }
        return .red
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s/60) 分钟前" }
        if s < 86400 { return "\(s/3600) 小时前" }
        return "\(s/86400) 天前"
    }

    private func shortReset(_ date: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "明"
            return f.string(from: date)
        }
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    private var cardCollapsedBody: some View {
        HStack(spacing: 8) {
            trafficLights

            if store.thirdPartyApiOnly, let bal = store.apiBalance {
                VStack(alignment: .leading, spacing: 3) {
                    Text("余额卡片")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("剩 \(balanceBadgeText(bal)) \(bal.unit ?? "")")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(balanceColor(bal.remaining ?? 0, total: bal.total))
                }
            } else if let first = snapshotWindows.first {
                HStack(spacing: 6) {
                    cardTag(window: first)
                    if let second = snapshotWindows.dropFirst().first {
                        cardTag(window: second)
                    }
                }
            } else if let err = store.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 2)
            refreshButton()
            collapseButton()
        }
        .fixedSize()
    }

    private var cardExpandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                trafficLights
                Text("额度卡片")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.thirdPartyApiOnly, let plan = store.snapshot?.limits.planType {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                refreshButton()
                collapseButton()
            }

            sourceHistorySection

            if store.thirdPartyApiOnly, let bal = store.apiBalance {
                ApiBalanceRow(balance: bal)
            } else if !snapshotWindows.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { _, window in
                        CardQuotaTile(window: window)
                    }
                }
            } else if let err = store.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }

            if let snap = store.snapshot {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("更新于 \(timeAgo(snap.capturedAt))")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 248, alignment: .leading)
    }

    @ViewBuilder
    private var sourceHistorySection: some View {
        let entries = visibleSourceEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Text("账号和 API")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Toggle("显示其他", isOn: $showInactiveSources)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 10))
                    if store.sourceSortMode == .custom {
                        restoreSourceOrderButton()
                    }
                }

                ForEach(entries) { entry in
                    sourceEntryRow(
                        entry,
                        isCurrent: entry.id == store.currentSourceID,
                        canDrag: canDragSourceEntry(entry),
                        canDelete: entry.id != store.currentSourceID
                    )
                }
            }
            .coordinateSpace(name: sourceHistoryCoordinateSpace)
            .onPreferenceChange(SourceEntryFramePreferenceKey.self) { value in
                sourceRowFrames = value
            }
        }
    }

    private var visibleSourceEntries: [UsageSourceEntry] {
        guard let current = store.currentSourceEntry else {
            return showInactiveSources ? store.orderedSourceEntries : Array(store.orderedSourceEntries.prefix(1))
        }
        return [current] + (showInactiveSources ? store.inactiveSourceEntries : [])
    }

    private func canDragSourceEntry(_ entry: UsageSourceEntry) -> Bool {
        guard showInactiveSources, visibleSourceEntries.count > 1 else { return false }
        if let currentSourceID = store.currentSourceID {
            return entry.id != currentSourceID
        }
        return true
    }

    private func sourceEntryRow(_ entry: UsageSourceEntry, isCurrent: Bool, canDrag: Bool, canDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isCurrent {
                    Label("启用中", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 6)
                if canDrag {
                    dragHandle(for: entry)
                }
                sourceDeleteButton(entry: entry, isEnabled: canDelete)
                if let summary = sourceSummaryText(entry, isCurrent: isCurrent) {
                    Text(summary)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(sourceSummaryColor(entry, isCurrent: isCurrent))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }

            HStack(spacing: 4) {
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                }
                Text(isCurrent ? "当前启用" : "上次更新 \(timeAgo(entry.lastSeenAt))")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: SourceEntryFramePreferenceKey.self,
                        value: [entry.id: geo.frame(in: .named(sourceHistoryCoordinateSpace))]
                    )
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(draggedSourceID == entry.id ? 0.72 : 1)
    }

    private func sourceDeleteButton(entry: UsageSourceEntry, isEnabled: Bool) -> some View {
        Button {
            pendingDeletionEntry = entry
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.red.opacity(0.82) : Color.secondary.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? "删除这条记录" : "当前启用中的不能删除")
    }

    private func dragHandle(for entry: UsageSourceEntry) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(sourceHistoryCoordinateSpace))
                    .onChanged { value in
                        draggedSourceID = entry.id
                        updateDraggedSource(entry.id, locationY: value.location.y)
                    }
                    .onEnded { _ in
                        draggedSourceID = nil
                    }
            )
    }

    private func restoreSourceOrderButton(size: CGFloat = 18, iconSize: CGFloat = 10) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                store.resetSourceOrder()
            }
        } label: {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("恢复默认排序")
    }

    private func updateDraggedSource(_ draggedID: String, locationY: CGFloat) {
        let targets = visibleSourceEntries.filter { $0.id != draggedID }
        let targetFrames = targets.compactMap { entry -> (UsageSourceEntry, CGRect)? in
            guard let frame = sourceRowFrames[entry.id] else { return nil }
            return (entry, frame)
        }.sorted(by: { $0.1.midY < $1.1.midY })
        guard !targetFrames.isEmpty else {
            return
        }

        let target: (UsageSourceEntry, CGRect)
        if let containedTarget = targetFrames.first(where: { locationY >= $0.1.minY && locationY <= $0.1.maxY }) {
            target = containedTarget
        } else if let firstTarget = targetFrames.first, locationY < firstTarget.1.minY {
            target = firstTarget
        } else if let lastTarget = targetFrames.last, locationY > lastTarget.1.maxY {
            target = lastTarget
        } else {
            return
        }

        let placeAfter: Bool
        if let currentSourceID = store.currentSourceID,
           target.0.id == currentSourceID {
            placeAfter = true
        } else {
            placeAfter = locationY > target.1.midY
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            store.reorderSource(draggedID, targetID: target.0.id, placeAfter: placeAfter)
        }
    }

    private func edgeBarActiveSourceChip(_ entry: UsageSourceEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(entry.compactLabel)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    private func edgeBarActiveSourceVertical(_ entry: UsageSourceEntry) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(shortSourceLabel(entry))
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func shortSourceLabel(_ entry: UsageSourceEntry) -> String {
        let base = entry.compactLabel
        if let atIndex = base.firstIndex(of: "@"), atIndex > base.startIndex {
            return String(base[..<atIndex].prefix(4))
        }
        return String(base.prefix(4))
    }

    private func sourceSummaryText(_ entry: UsageSourceEntry, isCurrent: Bool) -> String? {
        switch entry.kind {
        case .officialAccount:
            guard let snapshot = historySnapshot(for: entry, isCurrent: isCurrent) else { return nil }
            let ws = windows(snapshot)
            guard !ws.isEmpty else { return nil }
            return ws.prefix(2).map { "\($0.windowLabel) \(Int($0.remainingPercent.rounded()))%" }.joined(separator: " · ")
        case .thirdPartyAPI:
            guard let balance = entry.balance else { return nil }
            if let remaining = balance.remaining {
                let unit = balance.unit.map { " \($0)" } ?? ""
                return "剩 \(compactBalanceText(remaining))\(unit)"
            }
            if let used = balance.used {
                let unit = balance.unit.map { " \($0)" } ?? ""
                return "已用 \(compactBalanceText(used))\(unit)"
            }
            return nil
        }
    }

    private func sourceSummaryColor(_ entry: UsageSourceEntry, isCurrent: Bool) -> Color {
        switch entry.kind {
        case .officialAccount:
            if let window = historySnapshot(for: entry, isCurrent: isCurrent).flatMap({ windows($0).first }) {
                return rowColor(window)
            }
        case .thirdPartyAPI:
            if let balance = entry.balance,
               let remaining = balance.remaining {
                return balanceColor(remaining, total: balance.total)
            }
        }
        return .secondary
    }

    private func historySnapshot(for entry: UsageSourceEntry, isCurrent: Bool) -> QuotaSnapshot? {
        guard let snapshot = entry.snapshot else { return nil }
        guard entry.kind == .officialAccount, !isCurrent else { return snapshot }
        return snapshot.resetExpiredWindows(referenceDate: historyNow)
    }

    private func cardTag(window: RateWindow) -> some View {
        HStack(spacing: 4) {
            Text(window.windowLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(rowColor(window))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(rowColor(window).opacity(0.10))
        )
    }
}

private struct SourceEntryFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CircleGauge: View {
    let window: RateWindow

    private var color: Color {
        let r = window.remainingPercent
        if r > 50 { return .green }
        if r > 20 { return .orange }
        return .red
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.04, CGFloat(window.remainingPercent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(window.windowLabel)
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
                Text(resetText(window.resetDate))
                    .font(.system(size: 7.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
    }

    private func resetText(_ date: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "明 HH:mm"
            return f.string(from: date)
        }
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}

private struct CardQuotaTile: View {
    let window: RateWindow

    private var color: Color {
        let r = window.remainingPercent
        if r > 50 { return .green }
        if r > 20 { return .orange }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.windowLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            Text(resetText(window.resetDate))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(window.remainingPercent / 100))
                }
            }
            .frame(height: 5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    private func resetText(_ date: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "今天 HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "明天 HH:mm"
            return f.string(from: date)
        }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }
}

private struct ApiBalanceRow: View {
    let balance: UsageScriptRunner.Balance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(balance.providerName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let r = balance.remaining {
                    Text("剩 \(format(r)) \(balance.unit ?? "")")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(remainingColor(r, total: balance.total))
                }
            }
            if let used = balance.used, let total = balance.total, total > 0 {
                Text("已用 \(format(used)) / \(format(total))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func format(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func remainingColor(_ remaining: Double, total: Double?) -> Color {
        guard let total, total > 0 else { return .primary }
        let pct = remaining / total * 100
        if pct > 50 { return .green }
        if pct > 20 { return .orange }
        return .red
    }
}

private struct QuotaRow: View {
    let window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.windowLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("剩 \(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(formatReset(window.resetDate))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(window.remainingPercent / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private var color: Color {
        let r = window.remainingPercent
        if r > 50 { return .green }
        if r > 20 { return .orange }
        return .red
    }

    private func formatReset(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInTomorrow(d) {
            f.dateFormat = "明 HH:mm"
            return f.string(from: d)
        }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
}

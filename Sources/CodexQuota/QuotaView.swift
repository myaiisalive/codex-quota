import SwiftUI

private let sourceHistoryCoordinateSpace = "sourceHistorySection"

private enum CompactCodexTaskPlacement {
    case smallWindow
    case horizontalEdge
    case verticalEdge
}

struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var panelState: FloatingPanelState
    @AppStorage("collapsed") private var collapsed = false
    @AppStorage(FloatingQuotaStyle.storageKey) private var styleRaw: String = FloatingQuotaStyle.defaultValue.rawValue
    @AppStorage(CodexTaskDisplaySettings.showSessionsKey) private var showCodexSessions = true
    @AppStorage(CodexTaskCompactDisplayStyle.storageKey) private var compactSessionStyleRaw = CodexTaskCompactDisplayStyle.defaultValue.rawValue
    @AppStorage(UsageSourceDisplaySettings.showInactiveSourcesKey) private var showInactiveSources = false
    @AppStorage(UsageSourceDisplaySettings.showInactiveOfficialResetTimesKey) private var showInactiveOfficialResetTimes = true
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5
    @State private var hovering = false
    @State private var dimmed = false
    @State private var dimTask: DispatchWorkItem?
    @State private var historyNow = Date()
    @State private var sessionNow = Date()
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

    private var compactSessionStyle: CodexTaskCompactDisplayStyle {
        CodexTaskCompactDisplayStyle(rawValue: compactSessionStyleRaw) ?? .badge
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            sessionNow = now
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
        case .commandDeck, .glassIsland, .dualRing, .receipt, .edgeMeter, .pulsePanel:
            redesignedPanel(panelStyle)
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
                expandedBody(width: panelStyle == .card ? 252 : 300)
            }
        }
        .padding(padding)
        .background(background)
        .overlay(overlay)
    }

    private func redesignedPanel(_ style: FloatingQuotaStyle) -> some View {
        Group {
            if collapsed {
                compactCodexTaskLayout(
                    quota: AnyView(redesignedCollapsedRow(style)),
                    placement: .smallWindow
                )
            } else {
                redesignedExpandedBody(style)
            }
        }
        .padding(collapsed ? 9 : 13)
        .background(redesignedBackground(style))
        .clipShape(
            RoundedRectangle(
                cornerRadius: redesignedCornerRadius(style),
                style: .continuous
            )
        )
        .overlay(redesignedBorder(style))
        .shadow(color: redesignedAccent(style).opacity(0.12), radius: 10, y: 4)
        .fixedSize()
    }

    private func redesignedCollapsedRow(_ style: FloatingQuotaStyle) -> some View {
        HStack(spacing: 8) {
            trafficLights
            redesignedCompactQuota(style)
            refreshButton()
            collapseButton()
        }
    }

    private func redesignedExpandedBody(_ style: FloatingQuotaStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            redesignedHeader(style)
            sourceHistorySection
            codexTaskSessionSection
            redesignedExpandedQuota(style)

            if let snap = store.snapshot {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("更新于 \(timeAgo(snap.capturedAt))")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: style == .dualRing ? 320 : 300, alignment: .leading)
    }

    private func redesignedHeader(_ style: FloatingQuotaStyle) -> some View {
        HStack(spacing: 7) {
            trafficLights
            Image(systemName: style.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(redesignedAccent(style))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(redesignedAccent(style).opacity(0.13))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(style.title)
                    .font(.system(size: 11.5, weight: .bold))
                Text(redesignedHeaderSubtitle(style))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if !store.thirdPartyApiOnly, let plan = store.snapshot?.limits.planType {
                Text(plan.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(redesignedAccent(style).opacity(0.12), in: Capsule())
                    .foregroundStyle(redesignedAccent(style))
            }
            refreshButton()
            collapseButton()
        }
    }

    @ViewBuilder
    private func redesignedCompactQuota(_ style: FloatingQuotaStyle) -> some View {
        if store.thirdPartyApiOnly, let balance = store.apiBalance {
            VStack(alignment: .leading, spacing: 1) {
                Text(balance.providerName)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("剩 \(balanceBadgeText(balance)) \(balance.unit ?? "")")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(balanceColor(balance.remaining ?? 0, total: balance.total))
            }
        } else if snapshotWindows.isEmpty {
            Text("--")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            switch style {
            case .commandDeck:
                redesignedCommandDeckCompact
            case .glassIsland:
                redesignedGlassCompact
            case .dualRing:
                HStack(spacing: 7) {
                    ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                        CircleGauge(window: window)
                    }
                }
            case .receipt:
                redesignedReceiptCompact
            case .edgeMeter:
                redesignedEdgeMeterCompact
            case .pulsePanel:
                redesignedPulseCompact
            case .classic, .capsule, .orbit, .card, .minimal, .spotlight:
                collapsedQuotaContent
            }
        }
    }

    @ViewBuilder
    private func redesignedExpandedQuota(_ style: FloatingQuotaStyle) -> some View {
        if store.thirdPartyApiOnly, let balance = store.apiBalance {
            ApiBalanceRow(balance: balance)
        } else if !snapshotWindows.isEmpty {
            switch style {
            case .commandDeck:
                HStack(spacing: 7) {
                    ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { _, window in
                        redesignedCommandDeckTile(window)
                    }
                }
            case .glassIsland:
                HStack(spacing: 7) {
                    ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { _, window in
                        redesignedGlassTile(window)
                    }
                }
            case .dualRing:
                redesignedDualRingExpanded
            case .receipt:
                VStack(spacing: 0) {
                    ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { index, window in
                        redesignedReceiptRow(window)
                        if index < snapshotWindows.count - 1 {
                            Text("· · · · · · · · · · · · · · · · · ·")
                                .font(.system(size: 7).monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            case .edgeMeter:
                VStack(spacing: 8) {
                    ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { _, window in
                        redesignedEdgeMeterRow(window)
                    }
                }
            case .pulsePanel:
                redesignedPulseExpanded
            case .classic, .capsule, .orbit, .card, .minimal, .spotlight:
                EmptyView()
            }
        } else if let err = store.lastError {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var redesignedCommandDeckCompact: some View {
        HStack(spacing: 5) {
            ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(rowColor(window))
                        .frame(width: 3, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(window.windowLabel)
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(rowColor(window))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
    }

    private var redesignedGlassCompact: some View {
        HStack(spacing: 5) {
            ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                VStack(spacing: 1) {
                    Text(window.windowLabel)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
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
    }

    private var redesignedReceiptCompact: some View {
        HStack(spacing: 6) {
            ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { index, window in
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.windowLabel)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.secondary)
                    Text("剩 \(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(rowColor(window))
                }
                if index < min(snapshotWindows.count, 2) - 1 {
                    Text("···")
                        .font(.system(size: 8).monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var redesignedEdgeMeterCompact: some View {
        VStack(spacing: 4) {
            ForEach(Array(snapshotWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                HStack(spacing: 5) {
                    Text(window.windowLabel)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    redesignedProgressTrack(window, width: 72, height: 4)
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(rowColor(window))
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var redesignedPulseCompact: some View {
        if let window = redesignedPulseWindow {
            HStack(spacing: 5) {
                Circle()
                    .fill(rowColor(window))
                    .frame(width: 7, height: 7)
                    .shadow(color: rowColor(window).opacity(0.5), radius: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text("最低额度 · \(window.windowLabel)")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 15, weight: .heavy).monospacedDigit())
                        .foregroundStyle(rowColor(window))
                }
            }
        }
    }

    private var redesignedPulseWindow: RateWindow? {
        snapshotWindows.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    private func redesignedAccent(_ style: FloatingQuotaStyle) -> Color {
        switch style {
        case .commandDeck: return Color(red: 0.12, green: 0.45, blue: 0.86)
        case .glassIsland: return Color(red: 0.05, green: 0.62, blue: 0.60)
        case .dualRing: return Color(red: 0.15, green: 0.64, blue: 0.38)
        case .receipt: return Color(red: 0.88, green: 0.48, blue: 0.12)
        case .edgeMeter: return Color(red: 0.03, green: 0.55, blue: 0.72)
        case .pulsePanel: return urgencyTint
        case .classic, .capsule, .orbit, .card, .minimal, .spotlight: return .accentColor
        }
    }

    private func redesignedCornerRadius(_ style: FloatingQuotaStyle) -> CGFloat {
        switch style {
        case .glassIsland, .dualRing: return collapsed ? 22 : 26
        case .receipt: return 11
        case .edgeMeter: return 11
        case .pulsePanel: return collapsed ? 14 : 18
        default: return collapsed ? 12 : 16
        }
    }

    private func redesignedBackground(_ style: FloatingQuotaStyle) -> AnyView {
        let radius = redesignedCornerRadius(style)
        switch style {
        case .commandDeck:
            return AnyView(
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [redesignedAccent(style).opacity(0.18), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    LinearGradient(
                        colors: [redesignedAccent(style), Color.cyan.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 3)
                    .clipShape(Capsule())
                    .padding(.horizontal, 13)
                    .padding(.top, 2)
                }
            )
        case .glassIsland:
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 120, height: 120)
                        .offset(x: -95, y: -65)
                    Circle()
                        .fill(Color.green.opacity(0.10))
                        .frame(width: 110, height: 110)
                        .offset(x: 105, y: 75)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
        case .dualRing:
            return AnyView(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RadialGradient(
                            colors: [redesignedAccent(style).opacity(0.12), Color.clear],
                            center: .topTrailing,
                            startRadius: 0,
                            endRadius: 220
                        )
                    )
            )
        case .receipt:
            return AnyView(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                    .overlay(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.10), Color.yellow.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        case .edgeMeter:
            return AnyView(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [redesignedAccent(style), Color.cyan],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 4)
                        .padding(.vertical, 7)
                        .padding(.leading, 3)
                }
            )
        case .pulsePanel:
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [urgencyTint.opacity(0.22), urgencyTint.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
        case .classic, .capsule, .orbit, .card, .minimal, .spotlight:
            return AnyView(Color.clear)
        }
    }

    private func redesignedBorder(_ style: FloatingQuotaStyle) -> AnyView {
        let radius = redesignedCornerRadius(style)
        let opacity: Double = style == .pulsePanel ? 0.42 : 0.24
        return AnyView(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(redesignedAccent(style).opacity(opacity), lineWidth: style == .receipt ? 0.8 : 1)
        )
    }

    private func redesignedHeaderSubtitle(_ style: FloatingQuotaStyle) -> String {
        switch style {
        case .commandDeck: return "额度控制台"
        case .glassIsland: return "轻盈悬浮信息"
        case .dualRing: return "双周期刻度"
        case .receipt: return "本次额度清单"
        case .edgeMeter: return "快速状态扫读"
        case .pulsePanel: return "最低额度提醒"
        case .classic, .capsule, .orbit, .card, .minimal, .spotlight: return "Codex 额度"
        }
    }

    private func redesignedCommandDeckTile(_ window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(rowColor(window))
                    .frame(width: 4, height: 14)
                Text(window.windowLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .foregroundStyle(rowColor(window))
            Text("刷新 \(shortReset(window.resetDate))")
                .font(.system(size: 8.5).monospacedDigit())
                .foregroundStyle(.secondary)
            redesignedProgressTrack(window, width: 126, height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func redesignedGlassTile(_ window: RateWindow) -> some View {
        VStack(spacing: 6) {
            Text(window.windowLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 21, weight: .bold).monospacedDigit())
                .foregroundStyle(rowColor(window))
            Text("刷新 \(shortReset(window.resetDate))")
                .font(.system(size: 8.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(rowColor(window).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.38), lineWidth: 1)
        )
    }

    private func redesignedReceiptRow(_ window: RateWindow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(window.windowLabel)
                    .font(.system(size: 10, weight: .bold))
                Text("刷新 \(shortReset(window.resetDate))")
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("剩 \(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 16, weight: .heavy).monospacedDigit())
                .foregroundStyle(rowColor(window))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var redesignedDualRingExpanded: some View {
        if snapshotWindows.count == 1, let window = snapshotWindows.first {
            HStack(spacing: 16) {
                CircleGauge(window: window)
                    .scaleEffect(1.15)
                    .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 7) {
                    Text("当前额度周期")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(window.windowLabel)
                            .font(.system(size: 12, weight: .bold))
                        Text("剩 \(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: 14, weight: .heavy).monospacedDigit())
                            .foregroundStyle(rowColor(window))
                    }
                    Text("刷新 \(shortReset(window.resetDate))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    redesignedProgressTrack(window, width: 170, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(rowColor(window).opacity(0.07))
            )
        } else {
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                ForEach(Array(snapshotWindows.enumerated()), id: \.offset) { _, window in
                    CircleGauge(window: window)
                        .scaleEffect(1.18)
                        .frame(width: 72, height: 72)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
        }
    }

    private func redesignedEdgeMeterRow(_ window: RateWindow) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(rowColor(window))
                .frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(window.windowLabel)
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    Text("剩 \(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(rowColor(window))
                    Text(shortReset(window.resetDate))
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                redesignedProgressTrack(window, width: 270, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder
    private var redesignedPulseExpanded: some View {
        if let window = redesignedPulseWindow {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(rowColor(window).opacity(0.12))
                    Circle()
                        .stroke(rowColor(window).opacity(0.26), lineWidth: 1)
                    VStack(spacing: 1) {
                        Text(window.windowLabel)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: 22, weight: .heavy).monospacedDigit())
                            .foregroundStyle(rowColor(window))
                    }
                }
                .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: 7) {
                    Text("当前最低额度")
                        .font(.system(size: 10, weight: .bold))
                    Text("\(window.windowLabel)将在 \(shortReset(window.resetDate)) 刷新")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    ForEach(Array(snapshotWindows.filter { $0.windowMinutes != window.windowMinutes }.enumerated()), id: \.offset) { _, other in
                        HStack(spacing: 5) {
                            Text(other.windowLabel)
                            Text("剩 \(Int(other.remainingPercent.rounded()))%")
                                .foregroundStyle(rowColor(other))
                        }
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(rowColor(window).opacity(0.07))
            )
        }
    }

    private func redesignedProgressTrack(
        _ window: RateWindow,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let ratio = min(1, max(0, window.remainingPercent / 100))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(rowColor(window))
                .frame(width: width * CGFloat(ratio))
        }
        .frame(width: width, height: height)
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
        compactCodexTaskLayout(
            quota: AnyView(horizontalEdgeQuotaContent),
            placement: .horizontalEdge
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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

    private var verticalEdgeBar: some View {
        compactCodexTaskLayout(
            quota: AnyView(verticalEdgeQuotaContent),
            placement: .verticalEdge
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(width: visibleCodexTaskSessions.isEmpty || !compactSessionStyle.showsAllSessions ? 34 : 220)
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
            codexTaskSessionSection

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
                        .frame(maxWidth: 280, alignment: .leading)
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
                    .frame(maxWidth: 280, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Collapsed (single line)

    private var collapsedBody: some View {
        Group {
            if let session = compactCodexTaskSession, !compactSessionStyle.showsAllSessions {
                switch compactSessionStyle {
                case .stacked:
                    VStack(alignment: .leading, spacing: 4) {
                        collapsedMainRow()
                        legacyCompactTaskFullRow(session)
                    }
                case .capsule:
                    HStack(spacing: 5) {
                        collapsedMainRow()
                        legacyCompactTaskCapsule(session)
                    }
                case .badge:
                    collapsedMainRow(badgeSession: session)
                case .carousel:
                    collapsedMainRow(carouselSession: session)
                case .layered, .taskRail, .statusCards, .timeline:
                    collapsedMainRow()
                }
            } else {
                compactCodexTaskLayout(
                    quota: AnyView(collapsedMainRow()),
                    placement: .smallWindow
                )
            }
        }
        .fixedSize()
    }

    private func collapsedMainRow(
        badgeSession: CodexTaskSession? = nil,
        carouselSession: CodexTaskSession? = nil
    ) -> some View {
        HStack(spacing: 8) {
            trafficLights

            ZStack {
                Image(systemName: store.thirdPartyApiOnly ? "creditcard" : "gauge.with.needle")
                    .opacity(carouselSession == nil || !compactCarouselShowsSession ? 1 : 0)
                if carouselSession != nil {
                    Image(systemName: "terminal")
                        .foregroundStyle(Color.accentColor)
                        .opacity(compactCarouselShowsSession ? 1 : 0)
                }
            }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let carouselSession {
                legacyCompactTaskCarousel(
                    quota: AnyView(collapsedQuotaContent),
                    session: carouselSession,
                    vertical: false,
                    includesIcon: false
                )
            } else {
                collapsedQuotaContent
            }

            if let badgeSession {
                legacyCompactTaskBadge(badgeSession)
            }

            refreshButton()
            collapseButton()
        }
    }

    @ViewBuilder
    private var collapsedQuotaContent: some View {
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

    private var horizontalEdgeQuotaContent: some View {
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
    }

    private var verticalEdgeQuotaContent: some View {
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
        Group {
            if !compactSessionStyle.showsAllSessions {
                orbitShell(diameter: 76) {
                    if let session = compactCodexTaskSession {
                        switch compactSessionStyle {
                        case .stacked:
                            VStack(spacing: 1) {
                                orbitCompactQuotaContent
                                legacyOrbitCompactTaskLine(session, capsule: false)
                            }
                        case .capsule:
                            VStack(spacing: 1) {
                                orbitCompactQuotaContent
                                legacyOrbitCompactTaskLine(session, capsule: true)
                            }
                        case .badge:
                            VStack(spacing: 1) {
                                orbitCompactQuotaContent
                                legacyOrbitCompactTaskBadge(session)
                            }
                        case .carousel:
                            legacyOrbitCompactCarousel(session)
                        case .layered, .taskRail, .statusCards, .timeline:
                            orbitCompactQuotaContent
                        }
                    } else {
                        orbitCompactQuotaContent
                    }
                }
            } else {
                compactCodexTaskLayout(
                    quota: AnyView(
                        HStack {
                            Spacer(minLength: 0)
                            orbitShell(diameter: 76) {
                                orbitCompactQuotaContent
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 340)
                    ),
                    placement: .smallWindow
                )
            }
        }
    }

    @ViewBuilder
    private var orbitCompactQuotaContent: some View {
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

    private func legacyOrbitCompactTaskLine(
        _ session: CodexTaskSession,
        capsule: Bool
    ) -> some View {
        let tint = codexTaskTint(session)
        return VStack(spacing: 1) {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 6.5, weight: .semibold))
                Text(session.taskName)
                    .font(.system(size: 6.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 40)
            }
            HStack(spacing: 3) {
                Text(session.status == .running ? "运行" : "结束")
                    .font(.system(size: 6.5, weight: .semibold))
                Text(legacyCompactTaskDurationText(session))
                    .font(.system(size: 6.5).monospacedDigit())
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, capsule ? 4 : 2)
        .padding(.vertical, 2)
        .background(
            Group {
                if capsule {
                    Capsule().fill(tint.opacity(0.12))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.07))
                }
            }
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func legacyOrbitCompactTaskBadge(_ session: CodexTaskSession) -> some View {
        let runningCount = visibleCodexTaskSessions.filter { $0.status == .running }.count
        let endedCount = visibleCodexTaskSessions.count - runningCount
        return HStack(spacing: 3) {
            if runningCount > 0 {
                HStack(spacing: 1) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                        .opacity(compactRunningIndicatorIsBright ? 1 : 0.35)
                    Text("运\(runningCount)")
                }
                .foregroundStyle(Color.accentColor)
            }
            if endedCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 6))
                    Text("结\(endedCount)")
                }
                .foregroundStyle(.secondary)
            }
            Text(legacyCompactTaskDurationText(session))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 6.5, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        )
        .help("\(compactCodexTaskCount) 个会话 · \(session.taskName)")
    }

    private func legacyOrbitCompactCarousel(_ session: CodexTaskSession) -> some View {
        ZStack {
            orbitCompactQuotaContent
                .opacity(compactCarouselShowsSession ? 0 : 1)

            VStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Text(session.taskName)
                    .font(.system(size: 7.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 54)
                Text(session.status == .running ? "运行" : "结束")
                    .font(.system(size: 7, weight: .semibold))
                Text(legacyCompactTaskDurationText(session))
                    .font(.system(size: 7).monospacedDigit())
            }
            .foregroundStyle(codexTaskTint(session))
            .opacity(compactCarouselShowsSession ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: compactCarouselShowsSession)
        .help("\(session.projectName) · \(session.taskName)")
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
            if !visibleCodexTaskSessions.isEmpty {
                codexTaskSessionSection
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
        Group {
            if let session = compactCodexTaskSession, !compactSessionStyle.showsAllSessions {
                switch compactSessionStyle {
                case .stacked:
                    VStack(alignment: .leading, spacing: 5) {
                        cardCollapsedMainRow()
                        legacyCompactTaskFullRow(session)
                    }
                case .capsule:
                    HStack(spacing: 5) {
                        cardCollapsedMainRow()
                        legacyCompactTaskCapsule(session)
                    }
                case .badge:
                    HStack(spacing: 6) {
                        cardCollapsedMainRow()
                        legacyCompactTaskBadge(session)
                    }
                case .carousel:
                    cardCollapsedMainRow(carouselSession: session)
                case .layered, .taskRail, .statusCards, .timeline:
                    cardCollapsedMainRow()
                }
            } else {
                compactCodexTaskLayout(
                    quota: AnyView(cardCollapsedMainRow()),
                    placement: .smallWindow
                )
            }
        }
        .fixedSize()
    }

    private func cardCollapsedMainRow(carouselSession: CodexTaskSession? = nil) -> some View {
        HStack(spacing: 8) {
            trafficLights

            if let carouselSession {
                legacyCompactTaskCarousel(
                    quota: AnyView(cardCollapsedQuotaContent),
                    session: carouselSession,
                    vertical: false
                )
            } else {
                cardCollapsedQuotaContent
            }

            Spacer(minLength: 2)
            refreshButton()
            collapseButton()
        }
    }

    @ViewBuilder
    private var cardCollapsedQuotaContent: some View {
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
            codexTaskSessionSection

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
        .frame(width: 308, alignment: .leading)
    }

    @ViewBuilder
    private var codexTaskSessionSection: some View {
        let sessions = visibleCodexTaskSessions
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Codex 会话")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                ForEach(sessions) { session in
                    codexTaskSessionRow(session)
                }
            }
        }
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

    private var visibleCodexTaskSessions: [CodexTaskSession] {
        guard showCodexSessions else { return [] }
        return store.visibleCodexTaskSessions(referenceDate: sessionNow)
    }

    @ViewBuilder
    private func compactCodexTaskLayout(
        quota: AnyView,
        placement: CompactCodexTaskPlacement
    ) -> some View {
        let sessions = visibleCodexTaskSessions
        if sessions.isEmpty {
            quota
        } else if !compactSessionStyle.showsAllSessions, let session = sessions.first {
            legacyCompactCodexTaskLayout(quota: quota, session: session, placement: placement)
        } else {
            switch placement {
            case .smallWindow:
                compactSmallWindowTaskLayout(quota: quota, sessions: sessions)
            case .horizontalEdge:
                compactHorizontalEdgeTaskLayout(quota: quota, sessions: sessions)
            case .verticalEdge:
                compactVerticalEdgeTaskLayout(quota: quota, sessions: sessions)
            }
        }
    }

    @ViewBuilder
    private func legacyCompactCodexTaskLayout(
        quota: AnyView,
        session: CodexTaskSession,
        placement: CompactCodexTaskPlacement
    ) -> some View {
        switch placement {
        case .smallWindow:
            switch compactSessionStyle {
            case .stacked:
                VStack(alignment: .leading, spacing: 4) {
                    quota
                    legacyCompactTaskFullRow(session)
                }
            case .capsule:
                HStack(spacing: 5) {
                    quota
                    legacyCompactTaskCapsule(session)
                }
            case .badge:
                HStack(spacing: 6) {
                    quota
                    legacyCompactTaskBadge(session)
                }
            case .carousel:
                legacyCompactTaskCarousel(quota: quota, session: session, vertical: false)
            case .layered, .taskRail, .statusCards, .timeline:
                quota
            }
        case .horizontalEdge:
            switch compactSessionStyle {
            case .stacked:
                VStack(spacing: 3) {
                    quota
                    legacyCompactTaskFullRow(session)
                }
            case .capsule:
                HStack(spacing: 5) {
                    quota
                    legacyCompactTaskCapsule(session)
                }
            case .badge:
                HStack(spacing: 6) {
                    quota
                    legacyCompactTaskBadge(session)
                }
            case .carousel:
                legacyCompactTaskCarousel(quota: quota, session: session, vertical: false)
            case .layered, .taskRail, .statusCards, .timeline:
                quota
            }
        case .verticalEdge:
            switch compactSessionStyle {
            case .stacked:
                VStack(spacing: 5) {
                    quota
                    legacyCompactTaskVertical(session, capsule: false)
                }
            case .capsule:
                VStack(spacing: 5) {
                    quota
                    legacyCompactTaskVertical(session, capsule: true)
                }
            case .badge:
                VStack(spacing: 5) {
                    quota
                    legacyCompactTaskVerticalBadge(session)
                }
            case .carousel:
                legacyCompactTaskCarousel(quota: quota, session: session, vertical: true)
            case .layered, .taskRail, .statusCards, .timeline:
                quota
            }
        }
    }

    private var compactCodexTaskSession: CodexTaskSession? {
        visibleCodexTaskSessions.first
    }

    private var compactCodexTaskCount: Int {
        visibleCodexTaskSessions.count
    }

    private var compactCarouselShowsSession: Bool {
        Int(sessionNow.timeIntervalSinceReferenceDate / 4).isMultiple(of: 2) == false
    }

    private func legacyCompactTaskFullRow(_ session: CodexTaskSession) -> some View {
        let tint = codexTaskTint(session)
        return HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .semibold))
            Text(session.taskName)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .leading)
            legacyCompactTaskStatusLabel(session)
            Text(legacyCompactTaskDurationText(session))
                .font(.system(size: 8.5).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func legacyCompactTaskCapsule(_ session: CodexTaskSession) -> some View {
        let tint = codexTaskTint(session)
        return HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 8.5, weight: .semibold))
            Text(session.taskName)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 62)
            legacyCompactTaskStatusLabel(session, short: true)
            Text(legacyCompactTaskDurationText(session))
                .font(.system(size: 8.5).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 1))
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func legacyCompactTaskBadge(_ session: CodexTaskSession) -> some View {
        HStack(spacing: 4) {
            legacyCompactTaskStatusCounts(vertical: false)
            Text(legacyCompactTaskDurationText(session))
                .font(.system(size: 8.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help("\(compactCodexTaskCount) 个会话 · \(session.taskName)")
    }

    private func legacyCompactTaskVertical(
        _ session: CodexTaskSession,
        capsule: Bool
    ) -> some View {
        let tint = codexTaskTint(session)
        return VStack(spacing: 2) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .semibold))
            legacyCompactTaskStatusLabel(session, short: true)
            Text(legacyCompactTaskDurationText(session))
                .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, capsule ? 5 : 0)
        .padding(.vertical, capsule ? 4 : 0)
        .background(
            Group {
                if capsule {
                    Capsule().fill(tint.opacity(0.12))
                }
            }
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func legacyCompactTaskVerticalBadge(_ session: CodexTaskSession) -> some View {
        VStack(spacing: 2) {
            legacyCompactTaskStatusCounts(vertical: true)
            Text(legacyCompactTaskDurationText(session))
                .font(.system(size: 7).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(compactCodexTaskCount) 个会话 · \(session.taskName)")
    }

    private func legacyCompactTaskCarousel(
        quota: AnyView,
        session: CodexTaskSession,
        vertical: Bool,
        includesIcon: Bool = true
    ) -> some View {
        ZStack {
            quota
                .opacity(compactCarouselShowsSession ? 0 : 1)

            Group {
                if vertical {
                    legacyCompactTaskVertical(session, capsule: true)
                } else {
                    HStack(spacing: 4) {
                        if includesIcon {
                            Image(systemName: "terminal")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        Text(session.taskName)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 72)
                        legacyCompactTaskStatusLabel(session, short: true)
                        Text(legacyCompactTaskDurationText(session))
                            .font(.system(size: 8.5).monospacedDigit())
                    }
                    .foregroundStyle(codexTaskTint(session))
                }
            }
            .opacity(compactCarouselShowsSession ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: compactCarouselShowsSession)
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func legacyCompactTaskStatusLabel(
        _ session: CodexTaskSession,
        short: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            compactCodexTaskStatusPoint(session, size: 5)
            Text(short ? (session.status == .running ? "运行" : "结束") : session.status.title)
                .font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(codexTaskTint(session))
        .fixedSize()
    }

    @ViewBuilder
    private func legacyCompactTaskStatusCounts(vertical: Bool) -> some View {
        let runningCount = visibleCodexTaskSessions.filter { $0.status == .running }.count
        let endedCount = visibleCodexTaskSessions.count - runningCount

        if vertical {
            VStack(spacing: 2) {
                if runningCount > 0 {
                    legacyCompactTaskVerticalStatusCount(status: .running, count: runningCount)
                }
                if endedCount > 0 {
                    legacyCompactTaskVerticalStatusCount(status: .ended, count: endedCount)
                }
            }
        } else {
            HStack(spacing: 4) {
                if runningCount > 0 {
                    legacyCompactTaskStatusCount(status: .running, count: runningCount)
                }
                if endedCount > 0 {
                    legacyCompactTaskStatusCount(status: .ended, count: endedCount)
                }
            }
        }
    }

    private func legacyCompactTaskStatusCount(
        status: CodexTaskSession.Status,
        count: Int
    ) -> some View {
        let tint = status == .running ? Color.accentColor : Color.secondary
        return HStack(spacing: 2) {
            legacyCompactTaskStatusSymbol(status: status, tint: tint)
            Text("\(status == .running ? "运行" : "结束")\(count)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }

    private func legacyCompactTaskVerticalStatusCount(
        status: CodexTaskSession.Status,
        count: Int
    ) -> some View {
        let tint = status == .running ? Color.accentColor : Color.secondary
        return VStack(spacing: 1) {
            legacyCompactTaskStatusSymbol(status: status, tint: tint)
            Text("\(status == .running ? "运行" : "结束")\(count)")
                .font(.system(size: 7, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }

    @ViewBuilder
    private func legacyCompactTaskStatusSymbol(
        status: CodexTaskSession.Status,
        tint: Color
    ) -> some View {
        if status == .running {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .opacity(compactRunningIndicatorIsBright ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.45), value: compactRunningIndicatorIsBright)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 7.5, weight: .semibold))
        }
    }

    private func legacyCompactTaskDurationText(_ session: CodexTaskSession) -> String {
        let endDate = session.endedAt ?? sessionNow
        let seconds = max(0, Int(endDate.timeIntervalSince(session.startedAt)))
        if seconds < 60 { return "<1分" }
        if seconds < 3600 { return "\(seconds / 60)分" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)时" : "\(hours)时\(minutes)分"
    }

    @ViewBuilder
    private func compactSmallWindowTaskLayout(
        quota: AnyView,
        sessions: [CodexTaskSession]
    ) -> some View {
        switch compactSessionStyle {
        case .layered:
            VStack(alignment: .leading, spacing: 5) {
                quota
                VStack(spacing: 4) {
                    ForEach(sessions) { session in
                        compactLayeredSessionRow(session, width: 340)
                    }
                }
            }
        case .taskRail:
            VStack(alignment: .leading, spacing: 6) {
                quota
                compactTaskRailGroups(sessions)
            }
        case .statusCards:
            VStack(alignment: .leading, spacing: 5) {
                quota
                ForEach(sessions) { session in
                    compactStatusCard(session, width: 340)
                }
            }
        case .timeline:
            VStack(alignment: .leading, spacing: 5) {
                quota
                compactTimeline(sessions, width: 340)
            }
        case .stacked, .capsule, .badge, .carousel:
            quota
        }
    }

    private func compactHorizontalEdgeTaskLayout(
        quota: AnyView,
        sessions: [CodexTaskSession]
    ) -> some View {
        if compactSessionStyle == .timeline {
            return AnyView(
                HStack(spacing: 8) {
                    quota
                    compactHorizontalTimeline(sessions)
                }
            )
        }

        let columnCount = min(3, max(1, sessions.count))
        let itemWidth: CGFloat = 176
        let spacing: CGFloat = 5
        let columns = Array(
            repeating: GridItem(.fixed(itemWidth), spacing: spacing),
            count: columnCount
        )
        let gridWidth = CGFloat(columnCount) * itemWidth + CGFloat(columnCount - 1) * spacing

        return AnyView(
            HStack(spacing: 8) {
                quota
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        compactSessionItem(
                            session,
                            index: index,
                            count: sessions.count,
                            width: itemWidth
                        )
                    }
                }
                .frame(width: gridWidth)
            }
        )
    }

    private func compactHorizontalTimeline(_ sessions: [CodexTaskSession]) -> some View {
        let rows = stride(from: 0, to: sessions.count, by: 3).map { start in
            Array(sessions[start..<min(start + 3, sessions.count)])
        }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, session in
                        compactHorizontalTimelineItem(
                            session,
                            isFirst: index == 0,
                            isLast: index == row.count - 1
                        )
                    }
                }
            }
        }
    }

    private func compactHorizontalTimelineItem(
        _ session: CodexTaskSession,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(isFirst ? 0 : 0.28))
                    .frame(width: 12, height: 1)
                compactCodexTaskStatusPoint(session, size: 7)
                Rectangle()
                    .fill(Color.secondary.opacity(isLast ? 0 : 0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
            HStack(spacing: 4) {
                Text(session.taskName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                compactCodexTaskStatusLabel(session)
            }
            HStack(spacing: 3) {
                Text(session.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(compactCodexTaskDurationText(session))
                    .monospacedDigit()
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(width: 176)
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func compactVerticalEdgeTaskLayout(
        quota: AnyView,
        sessions: [CodexTaskSession]
    ) -> some View {
        VStack(spacing: 6) {
            quota
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                compactSessionItem(
                    session,
                    index: index,
                    count: sessions.count,
                    width: 196
                )
            }
        }
    }

    @ViewBuilder
    private func compactSessionItem(
        _ session: CodexTaskSession,
        index: Int,
        count: Int,
        width: CGFloat
    ) -> some View {
        switch compactSessionStyle {
        case .layered:
            compactLayeredSessionRow(session, width: width)
        case .taskRail:
            compactTaskRailCard(session, width: width)
        case .statusCards:
            compactStatusCard(session, width: width)
        case .timeline:
            compactTimelineItem(session, index: index, count: count, width: width)
        case .stacked, .capsule, .badge, .carousel:
            EmptyView()
        }
    }

    private func compactLayeredSessionRow(
        _ session: CodexTaskSession,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(codexTaskTint(session))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.projectName)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                compactCodexTaskStatusLabel(session)
                Text(compactCodexTaskDurationText(session))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(codexTaskTint(session).opacity(session.status == .running ? 0.09 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(codexTaskTint(session).opacity(0.18), lineWidth: 1)
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func compactTaskRailGroups(_ sessions: [CodexTaskSession]) -> some View {
        let running = sessions.filter { $0.status == .running }
        let ended = sessions.filter { $0.status == .ended }
        return VStack(alignment: .leading, spacing: 6) {
            if !running.isEmpty {
                compactTaskRailGroup(title: "正在运行", sessions: running)
            }
            if !ended.isEmpty {
                compactTaskRailGroup(title: "最近结束", sessions: ended)
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private func compactTaskRailGroup(
        title: String,
        sessions: [CodexTaskSession]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) \(sessions.count)")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible())],
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(sessions) { session in
                    compactTaskRailCard(session, width: 165)
                }
            }
        }
    }

    private func compactTaskRailCard(
        _ session: CodexTaskSession,
        width: CGFloat
    ) -> some View {
        let tint = codexTaskTint(session)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                compactCodexTaskStatusPoint(session, size: 5)
                Text(session.taskName)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Text(session.status == .running ? "运行" : "结束")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tint)
            }
            HStack(spacing: 3) {
                Text(session.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(compactCodexTaskDurationText(session))
                    .monospacedDigit()
            }
            .font(.system(size: 7.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func compactStatusCard(
        _ session: CodexTaskSession,
        width: CGFloat
    ) -> some View {
        let running = session.status == .running
        return HStack(spacing: 7) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskName)
                    .font(.system(size: 9.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.projectName)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.78)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                compactCodexTaskStatusLabel(session, onAccent: running)
                Text(compactCodexTaskDurationText(session))
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(running ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(running ? Color.accentColor.opacity(0.88) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(running ? Color.accentColor.opacity(0.96) : Color.primary.opacity(0.09), lineWidth: 1)
        )
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func compactTimeline(
        _ sessions: [CodexTaskSession],
        width: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                compactTimelineItem(session, index: index, count: sessions.count, width: width)
            }
        }
    }

    private func compactTimelineItem(
        _ session: CodexTaskSession,
        index: Int,
        count: Int,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(index == 0 ? 0 : 0.28))
                    .frame(width: 1, height: 8)
                compactCodexTaskStatusPoint(session, size: 7)
                Rectangle()
                    .fill(Color.secondary.opacity(index == count - 1 ? 0 : 0.28))
                    .frame(width: 1)
            }
            .frame(width: 10, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.projectName)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                compactCodexTaskStatusLabel(session)
                Text(compactCodexTaskDurationText(session))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: 48)
        .help("\(session.projectName) · \(session.taskName)")
    }

    private func compactCodexTaskStatusLabel(
        _ session: CodexTaskSession,
        onAccent: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            compactCodexTaskStatusPoint(session, size: 5, onAccent: onAccent)
            Text(session.status == .running ? "运行中" : "已结束")
                .font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(onAccent ? Color.white : codexTaskTint(session))
        .fixedSize()
    }

    @ViewBuilder
    private func compactCodexTaskStatusPoint(
        _ session: CodexTaskSession,
        size: CGFloat,
        onAccent: Bool = false
    ) -> some View {
        if session.status == .running {
            Circle()
                .fill(onAccent ? Color.white : Color.accentColor)
                .frame(width: size, height: size)
                .opacity(compactRunningIndicatorIsBright ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.45), value: compactRunningIndicatorIsBright)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size + 2, weight: .semibold))
                .foregroundStyle(onAccent ? Color.white : Color.secondary)
        }
    }

    private var compactRunningIndicatorIsBright: Bool {
        Int(sessionNow.timeIntervalSinceReferenceDate).isMultiple(of: 2)
    }

    private func codexTaskTint(_ session: CodexTaskSession) -> Color {
        session.status == .running ? Color.accentColor : .secondary
    }

    private func compactCodexTaskDurationText(_ session: CodexTaskSession) -> String {
        let endDate = session.endedAt ?? sessionNow
        let seconds = max(0, Int(endDate.timeIntervalSince(session.startedAt)))
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分\(seconds % 60)秒" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainSeconds = seconds % 60
        if remainSeconds == 0 {
            return minutes == 0 ? "\(hours)时" : "\(hours)时\(minutes)分"
        }
        return "\(hours)时\(minutes)分\(remainSeconds)秒"
    }

    private func canDragSourceEntry(_ entry: UsageSourceEntry) -> Bool {
        guard showInactiveSources, visibleSourceEntries.count > 1 else { return false }
        if let currentSourceID = store.currentSourceID {
            return entry.id != currentSourceID
        }
        return true
    }

    private func codexTaskSessionRow(_ session: CodexTaskSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.status == .running ? Color.accentColor : .secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.taskName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Text(session.projectName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                codexTaskStatusBadge(session)

                Button {
                    store.dismissCodexTaskSession(session.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭这条会话显示")
            }

            Text(codexTaskDurationText(session))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(session.status == .running ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(session.status == .running ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func codexTaskStatusBadge(_ session: CodexTaskSession) -> some View {
        Text(session.status.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(session.status == .running ? Color.accentColor : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill((session.status == .running ? Color.accentColor : Color.secondary).opacity(0.12))
            )
    }

    private func codexTaskDurationText(_ session: CodexTaskSession) -> String {
        let endDate = session.endedAt ?? sessionNow
        let duration = max(0, Int(endDate.timeIntervalSince(session.startedAt)))
        let prefix = session.status == .running ? "已运行" : "共运行"
        return "\(prefix) \(durationText(duration, includeSeconds: session.status == .running))"
    }

    private func durationText(_ seconds: Int, includeSeconds: Bool) -> String {
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainSeconds = seconds % 60
            if includeSeconds {
                return "\(minutes) 分 \(remainSeconds) 秒"
            }
            return "\(minutes) 分钟"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if minutes == 0 {
            if includeSeconds {
                let remainSeconds = seconds % 60
                return remainSeconds == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainSeconds) 秒"
            }
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(minutes) 分钟"
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
                sourceSummaryView(entry, isCurrent: isCurrent)
                    .layoutPriority(1)
            }

            Text(sourceSubtitleText(entry))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(isCurrent ? "当前启用" : "上次更新 \(timeAgo(entry.lastSeenAt))")
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let resetSummary = inactiveOfficialResetSummaryText(entry, isCurrent: isCurrent) {
                    Text("刷新 \(resetSummary)")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private func sourceSummaryView(_ entry: UsageSourceEntry, isCurrent: Bool) -> some View {
        switch entry.kind {
        case .officialAccount:
            if let snapshot = historySnapshot(for: entry, isCurrent: isCurrent) {
                let summaryWindows = Array(windows(snapshot).prefix(2))
                if !summaryWindows.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(summaryWindows.enumerated()), id: \.offset) { index, window in
                            if index > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(window.windowLabel) \(Int(window.remainingPercent.rounded()))%")
                                .foregroundStyle(rowColor(window))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        case .thirdPartyAPI:
            if let balance = entry.balance {
                if let remaining = balance.remaining {
                    let unit = balance.unit.map { " \($0)" } ?? ""
                    Text("剩 \(compactBalanceText(remaining))\(unit)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(balanceColor(remaining, total: balance.total))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if let used = balance.used {
                    let unit = balance.unit.map { " \($0)" } ?? ""
                    Text("已用 \(compactBalanceText(used))\(unit)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func sourceSubtitleText(_ entry: UsageSourceEntry) -> String {
        guard let subtitle = entry.subtitle, !subtitle.isEmpty else {
            return " "
        }
        return subtitle
    }

    private func inactiveOfficialResetSummaryText(_ entry: UsageSourceEntry, isCurrent: Bool) -> String? {
        guard showInactiveOfficialResetTimes,
              !isCurrent,
              entry.kind == .officialAccount,
              let snapshot = historySnapshot(for: entry, isCurrent: isCurrent) else {
            return nil
        }

        let resetParts = windows(snapshot).prefix(2).map { window in
            "\(window.windowLabel) \(inactiveOfficialResetText(window.resetDate))"
        }
        guard !resetParts.isEmpty else { return nil }
        return resetParts.joined(separator: " · ")
    }

    private func historySnapshot(for entry: UsageSourceEntry, isCurrent: Bool) -> QuotaSnapshot? {
        guard let snapshot = entry.snapshot else { return nil }
        guard entry.kind == .officialAccount, !isCurrent else { return snapshot }
        return snapshot.resetExpiredWindows(referenceDate: historyNow)
    }

    private func inactiveOfficialResetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明 HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
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

import SwiftUI

struct QuotaView: View {
    @ObservedObject var store: QuotaStore
    @AppStorage("collapsed") private var collapsed = false
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5
    @State private var hovering = false
    @State private var dimmed = false
    @State private var dimTask: DispatchWorkItem?
    var onSizeChange: ((CGSize) -> Void)? = nil
    var onHide: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onRefresh: (() -> Void)? = nil
    var onAlphaChange: ((Double) -> Void)? = nil

    var body: some View {
        Group {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(collapsed ? 8 : 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: collapsed ? 8 : 12))
        .overlay(
            RoundedRectangle(cornerRadius: collapsed ? 8 : 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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
        }
        .onAppear {
            scheduleDim()
            pushAlpha()
        }
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

    private var expandedBody: some View {
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
                refreshButton
                collapseButton
            }

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
        .frame(width: 240, alignment: .leading)
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

            refreshButton
            collapseButton
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

    private var refreshButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.7)) {
                refreshSpinAngle += 360
            }
            onRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(refreshSpinAngle))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("立即刷新")
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "展开" : "缩小为一行")
    }

    private func windows(_ snap: QuotaSnapshot) -> [RateWindow] {
        [snap.limits.primary, snap.limits.secondary].compactMap { $0 }
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

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var updateManager: UpdateManager

    enum Tab: String, CaseIterable, Identifiable {
        case appearance, menuBar, refresh, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return "外观"
            case .menuBar:    return "菜单栏"
            case .refresh:    return "刷新"
            case .about:      return "关于"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .menuBar:    return "menubar.rectangle"
            case .refresh:    return "arrow.clockwise"
            case .about:      return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .appearance

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch tab {
                case .appearance: AppearanceTab(store: store)
                case .menuBar:    MenuBarTab()
                case .refresh:    RefreshTab()
                case .about:      AboutTab(store: store, updateManager: updateManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 460)
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @ObservedObject var store: QuotaStore
    @AppStorage(FloatingQuotaStyle.storageKey) private var panelStyleRaw: String = FloatingQuotaStyle.defaultValue.rawValue
    @AppStorage(FloatingPanelState.edgeSnapEnabledKey) private var edgeSnapEnabled = false
    @AppStorage(UsageSourceDisplaySettings.showInactiveSourcesKey) private var showInactiveSources = false
    @AppStorage(UsageSourceDisplaySettings.showInactiveOfficialResetTimesKey) private var showInactiveOfficialResetTimes = true
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5

    private var panelStyle: FloatingQuotaStyle {
        FloatingQuotaStyle(rawValue: panelStyleRaw) ?? .classic
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("悬浮样式")
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        ForEach(FloatingQuotaStyle.allCases) { style in
                            FloatingStyleCard(
                                style: style,
                                selected: style == panelStyle,
                                onSelect: { panelStyleRaw = style.rawValue }
                            )
                        }
                    }
                    Text("默认还是现在这个样式，旧版本用户不需要改设置也能保持原样。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("贴到屏幕边缘时自动收成窄条", isOn: $edgeSnapEnabled)
                    Text("默认关闭。打开后，拖到屏幕四边附近会自动吸附成横条或竖条，鼠标移上去再恢复原来的浮窗。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("显示其他未启用的账号和 API", isOn: $showInactiveSources)
                    Text("打开后，浮窗里会把以前用过但当前没有启用的账号和 API 也一起列出来；关闭后只显示当前启用的那一条。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("显示未启用官方账号的刷新时间", isOn: $showInactiveOfficialResetTimes)
                    Text("默认开启。打开后，其他官方账号会显示 5 小时和 1 周额度下次刷新的时间。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                SourceOrderSection(store: store)

                LabeledSliderRow(
                    title: "空闲时的透明度",
                    value: $dimmedOpacity,
                    range: 0.05...1.0,
                    step: 0.01,
                    valueText: "\(Int(dimmedOpacity * 100))%",
                    hint: "鼠标移开后浮窗会变成这个透明度，移上去时恢复 100%。"
                )
                LabeledSliderRow(
                    title: "变透明的延迟",
                    value: $dimDelaySeconds,
                    range: 1...30,
                    step: 1,
                    valueText: "\(Int(dimDelaySeconds)) 秒",
                    hint: nil
                )
            }
            .padding(20)
        }
    }
}

private struct SourceOrderSection: View {
    @ObservedObject var store: QuotaStore
    @State private var pendingDeletionEntry: UsageSourceEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账号和 API 排序")
                Spacer()
                if store.sourceSortMode == .custom {
                    Button("恢复默认顺序") {
                        store.resetSourceOrder()
                    }
                    .buttonStyle(.link)
                } else {
                    Text("当前使用默认顺序")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("当前启用的这一条会固定显示在最上面。默认顺序是：官方有额度、API 有余额、官方已用完、API 余额为 0。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if let current = store.currentSourceEntry {
                SourceOrderPinnedRow(entry: current)
            }

            let entries = store.sortableSourceEntries
            if entries.isEmpty {
                Text("暂时没有其他可调整顺序的账号或 API。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        SourceOrderRow(
                            entry: entry,
                            canMoveUp: index > 0,
                            canMoveDown: index < entries.count - 1,
                            onMoveUp: { store.moveSource(entry.id, direction: -1) },
                            onMoveDown: { store.moveSource(entry.id, direction: 1) },
                            onDelete: { pendingDeletionEntry = entry }
                        )
                    }
                }
            }
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
}

private struct SourceOrderPinnedRow: View {
    let entry: UsageSourceEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Label("启用中", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text("这条固定显示在最上面")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("当前启用中的不能删除")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct SourceOrderRow: View {
    let entry: UsageSourceEntry
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveUp)

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveDown)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var summaryText: String {
        let bucket = entry.sortBucket()
        if let subtitle = entry.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(bucket.title)"
        }
        return bucket.title
    }
}

private struct FloatingStyleCard: View {
    let style: FloatingQuotaStyle
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: style.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20)
                    Text(style.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(style.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 菜单栏

private struct MenuBarTab: View {
    @AppStorage(MenuBarSource.storageKey) private var menuBarSourceRaw: String = MenuBarSource.defaultValue.rawValue
    @AppStorage(MenuBarCount.storageKey) private var menuBarCountRaw: Int = MenuBarCount.defaultValue.rawValue
    @AppStorage(MenuBarCount.showLabelKey) private var showLabel: Bool = true
    @AppStorage(MenuBarApiCount.storageKey) private var apiCountRaw: Int = MenuBarApiCount.defaultValue.rawValue
    @AppStorage(MenuBarApiSource.storageKey) private var apiSourceRaw: String = MenuBarApiSource.defaultValue.rawValue
    @AppStorage(MenuBarApiCount.showIconKey) private var apiShowIcon: Bool = true
    @State private var thirdPartyApiOnly: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if thirdPartyApiOnly {
                    apiModeBody
                } else {
                    codexModeBody
                }
            }
            .padding(20)
        }
        .onAppear {
            thirdPartyApiOnly = CodexConfig.loadActive()?.isThirdPartyApiMode ?? false
        }
    }

    private var apiModeBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("显示额度数量")
                Spacer()
                Picker("", selection: $apiCountRaw) {
                    ForEach(MenuBarApiCount.allCases) { c in
                        Text(c.displayName).tag(c.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            }

            if apiCountRaw == MenuBarApiCount.one.rawValue {
                HStack {
                    Text("显示哪一条")
                    Spacer()
                    Picker("", selection: $apiSourceRaw) {
                        ForEach(MenuBarApiSource.allCases) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                }
            }

            Toggle("显示金额前的小图标", isOn: $apiShowIcon)

            Text(apiCountRaw == MenuBarApiCount.two.rawValue
                 ? "同时显示两条，左边是已用，右边是剩余。"
                 : "只显示一条额度。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var codexModeBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("显示额度数量")
                Spacer()
                Picker("", selection: $menuBarCountRaw) {
                    ForEach(MenuBarCount.allCases) { c in
                        Text(c.displayName).tag(c.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            }

            if menuBarCountRaw == MenuBarCount.one.rawValue {
                HStack {
                    Text("显示哪一条")
                    Spacer()
                    Picker("", selection: $menuBarSourceRaw) {
                        ForEach(MenuBarSource.allCases) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                }
            }

            Toggle("显示 H/W 小图标", isOn: $showLabel)

            Text(menuBarCountRaw == MenuBarCount.two.rawValue
                 ? "同时显示两条额度，左边是 5 小时，右边是周。"
                 : "只显示一条额度。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 刷新

private struct RefreshTab: View {
    @AppStorage(QuotaStore.refreshIntervalKey) private var refreshInterval: Double = QuotaStore.defaultRefreshInterval
    @State private var inputText: String = ""

    private let minSeconds: Double = 5
    private let maxSeconds: Double = 3600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("自动刷新间隔")
                    Spacer()
                    TextField("", text: $inputText, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $refreshInterval, in: minSeconds...maxSeconds, step: 5)

                Text("范围 \(Int(minSeconds))–\(Int(maxSeconds)) 秒。每隔这么久重新读一次额度数据，文件有变化时仍会立即刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .onAppear { syncInputFromValue() }
        .onChange(of: refreshInterval) { _ in syncInputFromValue() }
    }

    private func syncInputFromValue() {
        inputText = String(Int(refreshInterval.rounded()))
    }

    private func commit() {
        guard let raw = Double(inputText) else {
            syncInputFromValue(); return
        }
        let clamped = min(max(raw, minSeconds), maxSeconds)
        refreshInterval = clamped
        syncInputFromValue()
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("CodexQuota")
                .font(.system(size: 18, weight: .semibold))

            Text("版本 \(appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            VStack(spacing: 4) {
                Text("当前账号")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(store.accountProfile?.displayText ?? "还没有识别到")
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.top, 2)

            updateSection

            Link(destination: URL(string: "https://github.com/myaiisalive/codex-quota")!) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                    Text("github.com/myaiisalive/codex-quota")
                        .font(.system(size: 12))
                }
            }

            Text("额度数据仍是本地读取；只有检查新版本时才会联网看看有没有新版本。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            if let ignoredVersion = updateManager.ignoredVersionText {
                Text("已忽略版本：\(ignoredVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var appVersion: String {
        updateManager.currentVersionText
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 8) {
            Text(updateManager.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            switch updateManager.state {
            case .checking, .installing:
                ProgressView()
                    .controlSize(.small)
            case .available:
                HStack(spacing: 8) {
                    Button("查看发布说明") {
                        updateManager.openReleasePage()
                    }
                    Button(primaryActionTitle) {
                        Task { @MainActor in
                            try? await updateManager.performAvailableUpdate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            default:
                Button("检查新版本") {
                    Task { @MainActor in
                        _ = await updateManager.checkForUpdates(force: true)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var primaryActionTitle: String {
        if case .available(_, let method) = updateManager.state {
            return method.primaryActionTitle
        }
        return "更新"
    }
}

// MARK: - 通用：滑块行

private struct LabeledSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
            if let h = hint {
                Text(h)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

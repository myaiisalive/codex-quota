import SwiftUI

struct SettingsView: View {
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
                case .appearance: AppearanceTab()
                case .menuBar:    MenuBarTab()
                case .refresh:    RefreshTab()
                case .about:      AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 460)
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @AppStorage(FloatingQuotaStyle.storageKey) private var panelStyleRaw: String = FloatingQuotaStyle.defaultValue.rawValue
    @AppStorage(FloatingPanelState.edgeSnapEnabledKey) private var edgeSnapEnabled = false
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

            Link(destination: URL(string: "https://github.com/myaiisalive/codex-quota")!) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                    Text("github.com/myaiisalive/codex-quota")
                        .font(.system(size: 12))
                }
            }

            Text("本地读取额度数据，不联网。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty || b == v ? v : "\(v) (\(b))"
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

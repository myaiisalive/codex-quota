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
        .frame(width: 480, height: 340)
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

// MARK: - 菜单栏

private struct MenuBarTab: View {
    @AppStorage(MenuBarSource.storageKey) private var menuBarSourceRaw: String = MenuBarSource.defaultValue.rawValue
    @AppStorage(MenuBarCount.storageKey) private var menuBarCountRaw: Int = MenuBarCount.defaultValue.rawValue
    @AppStorage(MenuBarCount.showLabelKey) private var showLabel: Bool = true

    var body: some View {
        ScrollView {
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
            .padding(20)
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

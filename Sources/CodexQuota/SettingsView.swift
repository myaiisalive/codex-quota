import SwiftUI

struct SettingsView: View {
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5
    @AppStorage(QuotaStore.refreshIntervalKey) private var refreshInterval: Double = QuotaStore.defaultRefreshInterval
    @AppStorage(MenuBarSource.storageKey) private var menuBarSourceRaw: String = MenuBarSource.auto.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("外观")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("空闲时的透明度")
                    Spacer()
                    Text("\(Int(dimmedOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $dimmedOpacity, in: 0.05...1.0)
                Text("鼠标移开后浮窗会变成这个透明度，移上去时恢复 100%。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("变透明的延迟")
                    Spacer()
                    Text("\(Int(dimDelaySeconds)) 秒")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $dimDelaySeconds, in: 1...30, step: 1)
            }

            Divider().padding(.vertical, 2)

            Text("菜单栏")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("菜单栏显示")
                    Spacer()
                    Picker("", selection: $menuBarSourceRaw) {
                        ForEach(MenuBarSource.allCases) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
                Text("决定菜单栏图标旁边的百分比代表 5 小时还是周。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.vertical, 2)

            Text("刷新")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("自动刷新间隔")
                    Spacer()
                    Text(intervalLabel(refreshInterval))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $refreshInterval, in: 5...600, step: 5)
                Text("每隔这么久自动重新读取一次额度数据。文件有变化时仍会立即刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 440)
    }

    private func intervalLabel(_ s: Double) -> String {
        let i = Int(s)
        if i < 60 { return "\(i) 秒" }
        let m = i / 60
        let r = i % 60
        return r == 0 ? "\(m) 分钟" : "\(m) 分 \(r) 秒"
    }
}

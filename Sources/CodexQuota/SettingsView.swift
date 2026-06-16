import SwiftUI

struct SettingsView: View {
    @AppStorage("dimmedOpacity") private var dimmedOpacity: Double = 0.35
    @AppStorage("dimDelaySeconds") private var dimDelaySeconds: Double = 5

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

            Spacer()
        }
        .padding(20)
        .frame(width: 360, height: 240)
    }
}

import Foundation
import Combine

/// 全局状态：当前快照 + 自动刷新
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var apiBalance: UsageScriptRunner.Balance?
    @Published private(set) var apiBalanceError: String?
    /// 第三方 API 模式：auth.json 有 key 且 base_url 不是 OpenAI 官方
    /// 此时只显示 API 余额，不显示 5 小时/周
    @Published private(set) var thirdPartyApiOnly: Bool = false

    private var watcher: SessionsWatcher?
    private var timer: Timer?
    private var balanceTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    /// 当前使用的刷新间隔（秒）。默认 30s。
    static let refreshIntervalKey = "refreshIntervalSeconds"
    static let defaultRefreshInterval: Double = 30

    private var currentInterval: Double {
        let v = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        return v > 0 ? v : Self.defaultRefreshInterval
    }

    func start() {
        reload()
        watcher = SessionsWatcher(
            path: QuotaReader.sessionsRoot.path,
            onChange: { [weak self] in self?.reload() }
        )
        watcher?.start()
        rebuildTimer()
        reloadApiBalance()
        rebuildBalanceTimer()

        // 监听设置变化，自动重建 timer
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildTimerIfNeeded() }
        }
    }

    private func rebuildBalanceTimer() {
        balanceTimer?.invalidate()
        balanceTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadApiBalance() }
        }
    }

    func reloadApiBalance() {
        guard let codex = CodexConfig.loadActive() else {
            self.apiBalance = nil
            self.apiBalanceError = nil
            self.thirdPartyApiOnly = false
            return
        }
        self.thirdPartyApiOnly = codex.isThirdPartyApiMode
        guard let provider = CCSwitchProvider.find(
            matchingHost: codex.host,
            rootDomain: codex.rootDomain
        ) else {
            self.apiBalance = nil
            self.apiBalanceError = "CC Switch 中未找到 \(codex.host) 的配置"
            return
        }

        Task { [weak self] in
            do {
                let balance = try await UsageScriptRunner.run(provider: provider)
                await MainActor.run {
                    self?.apiBalance = balance
                    self?.apiBalanceError = balance.isValid ? nil : (balance.invalidMessage ?? "余额查询失败")
                }
            } catch {
                await MainActor.run {
                    self?.apiBalanceError = "余额查询失败：\(error)"
                }
            }
        }
    }

    private var lastBuiltInterval: Double = 0

    private func rebuildTimerIfNeeded() {
        if abs(currentInterval - lastBuiltInterval) > 0.01 {
            rebuildTimer()
            rebuildBalanceTimer()
        }
    }

    private func rebuildTimer() {
        timer?.invalidate()
        let interval = currentInterval
        lastBuiltInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        if let snap = QuotaReader.loadLatest() {
            self.snapshot = snap
            self.lastError = nil
        } else if snapshot == nil {
            self.lastError = "未找到 ~/.codex/sessions 中的额度数据，请先运行一次 codex"
        }
    }
}

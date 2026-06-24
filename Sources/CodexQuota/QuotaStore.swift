import Foundation
import Combine

/// 全局状态：当前快照 + 自动刷新
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var apiBalance: UsageScriptRunner.Balance?
    @Published private(set) var apiBalanceError: String?
    /// 第三方 API 模式：当前激活的是非官方 provider
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
        Task {
            // CodexConfig + CCSwitchProvider 都是同步文件/SQLite I/O，移到后台
            let result = await Task.detached(priority: .utility) { () -> (CodexConfig, CCSwitchProvider?)? in
                guard let codex = CodexConfig.loadActive() else { return nil }
                let provider = CCSwitchProvider.find(for: codex)
                return (codex, provider)
            }.value

            guard let (codex, provider) = result else {
                self.thirdPartyApiOnly = false
                self.apiBalance = nil
                self.apiBalanceError = nil
                return
            }

            self.thirdPartyApiOnly = codex.isThirdPartyApiMode
            guard let provider else {
                self.apiBalance = nil
                self.apiBalanceError = "CC Switch 中未找到对应配置"
                return
            }

            do {
                let balance = try await UsageScriptRunner.run(provider: provider, codexApiKey: codex.apiKey.isEmpty ? nil : codex.apiKey)
                if balance.isValid {
                    self.apiBalance = balance
                    self.apiBalanceError = nil
                } else {
                    self.apiBalance = nil
                    self.apiBalanceError = balance.invalidMessage ?? "余额查询失败"
                }
            } catch {
                self.apiBalance = nil
                self.apiBalanceError = "余额查询失败：\(error)"
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
        Task {
            let snap = await Task.detached(priority: .utility) { () -> QuotaSnapshot? in
                if let official = await OfficialQuotaReader.loadLatest() {
                    return official
                }
                return QuotaReader.loadLatest()
            }.value
            if let snap {
                self.snapshot = snap
                self.lastError = nil
            } else if self.snapshot == nil {
                self.lastError = "还没有读到额度，请先打开一次 Codex 并确认已登录"
            }
        }
    }
}

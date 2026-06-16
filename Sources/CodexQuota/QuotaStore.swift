import Foundation
import Combine

/// 全局状态：当前快照 + 自动刷新
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var lastError: String?

    private var watcher: SessionsWatcher?
    private var timer: Timer?
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

        // 监听设置变化，自动重建 timer
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildTimerIfNeeded() }
        }
    }

    private var lastBuiltInterval: Double = 0

    private func rebuildTimerIfNeeded() {
        if abs(currentInterval - lastBuiltInterval) > 0.01 {
            rebuildTimer()
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

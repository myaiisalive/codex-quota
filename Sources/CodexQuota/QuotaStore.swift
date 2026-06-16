import Foundation
import Combine

/// 全局状态：当前快照 + 自动刷新
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var lastError: String?

    private var watcher: SessionsWatcher?
    private var timer: Timer?

    func start() {
        reload()
        watcher = SessionsWatcher(
            path: QuotaReader.sessionsRoot.path,
            onChange: { [weak self] in self?.reload() }
        )
        watcher?.start()
        // 兜底：每 30 秒强制刷新一次（让"重置倒计时"显示更顺畅）
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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

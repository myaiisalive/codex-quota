import Foundation
import Combine

/// 全局状态：当前快照 + 自动刷新
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var apiBalance: UsageScriptRunner.Balance?
    @Published private(set) var apiBalanceError: String?
    @Published private(set) var accountProfile: CodexAccountProfile?
    @Published private(set) var sourceHistory: [UsageSourceEntry] = UsageSourceHistoryStore.load()
    @Published private(set) var currentSourceID: String?
    @Published private(set) var sourceSortMode: UsageSourceSortMode = UsageSourceOrderStore.loadMode()
    @Published private(set) var customSourceOrderIDs: [String] = UsageSourceOrderStore.loadCustomOrderIDs()
    @Published private(set) var codexTaskSessions: [CodexTaskSession] = []
    /// 第三方 API 模式：当前激活的是非官方 provider
    /// 此时只显示 API 余额，不显示 5 小时/周
    @Published private(set) var thirdPartyApiOnly: Bool = false
    @Published private var dismissedCodexTaskSessionIDs: Set<String> = []

    private var watcher: SessionsWatcher?
    private var sessionIndexWatcher: SessionsWatcher?
    private var processActivityWatcher: SessionsWatcher?
    private var authWatcher: SessionsWatcher?
    private var timer: Timer?
    private var balanceTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var currentOfficialSourceID: String?
    private var currentThirdPartySourceID: String?
    private var inactiveThirdPartyRefreshTask: Task<Void, Never>?
    private var accountProfileReloadTask: Task<Void, Never>?
    private var accountProfileReloadPending = false
    private var officialReloadTask: Task<Void, Never>?
    private var officialReloadPending = false
    private var apiBalanceReloadTask: Task<Void, Never>?
    private var apiBalanceReloadPending = false
    private var displayedApiBalanceConfig: CodexConfig?
    private var displayedOfficialSnapshotSourceID: String?
    private var codexTaskReloadTask: Task<Void, Never>?
    private var codexTaskReloadPending = false
    private var codexTaskDisplayEnabled = CodexTaskDisplaySettings.isEnabled()

    private static let lastConfirmedOfficialSourceKey = "lastConfirmedOfficialSourceID"

    /// 当前使用的刷新间隔（秒）。默认 30s。
    static let refreshIntervalKey = "refreshIntervalSeconds"
    static let defaultRefreshInterval: Double = 30

    private var currentInterval: Double {
        let v = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        return v > 0 ? v : Self.defaultRefreshInterval
    }

    var currentSourceEntry: UsageSourceEntry? {
        guard let currentSourceID else { return nil }
        return sourceHistory.first(where: { $0.id == currentSourceID })
    }

    var inactiveSourceEntries: [UsageSourceEntry] {
        guard let currentSourceID else { return orderedSourceEntries }
        return orderedSourceEntries.filter { $0.id != currentSourceID }
    }

    var sortableSourceEntries: [UsageSourceEntry] {
        if currentSourceID == nil {
            return orderedSourceEntries
        }
        return inactiveSourceEntries
    }

    var orderedSourceEntries: [UsageSourceEntry] {
        let orderIndex = Dictionary(uniqueKeysWithValues: sourceHistory.enumerated().map { ($0.element.id, $0.offset) })
        let current = currentSourceID.flatMap { id in
            sourceHistory.first(where: { $0.id == id })
        }
        let others = sourceHistory.filter { $0.id != currentSourceID }
        let sortedOthers = sortEntries(others, orderIndex: orderIndex)

        if let current {
            return [current] + sortedOthers
        }
        return sortedOthers
    }

    func start() {
        reloadCodexState()
        watcher = SessionsWatcher(
            path: QuotaReader.sessionsRoot.path,
            onChange: { [weak self] in self?.reload() }
        )
        watcher?.start()
        sessionIndexWatcher = SessionsWatcher(
            path: CodexTaskSessionReader.sessionIndexWatchPath,
            debounceSeconds: 0.4,
            onChange: { [weak self] in self?.reloadCodexTaskSessions() }
        )
        sessionIndexWatcher?.start()
        processActivityWatcher = SessionsWatcher(
            path: CodexTaskSessionReader.processActivityWatchPath,
            debounceSeconds: 0.4,
            onChange: { [weak self] in self?.reloadCodexTaskSessions() }
        )
        processActivityWatcher?.start()
        authWatcher = SessionsWatcher(
            path: CodexAccountProfileReader.watchRootPath,
            debounceSeconds: 0.4,
            onChange: { [weak self] in self?.reloadCodexState() }
        )
        authWatcher?.start()
        rebuildTimer()
        rebuildBalanceTimer()

        // 监听设置变化，自动重建 timer
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildTimerIfNeeded()

                let isEnabled = CodexTaskDisplaySettings.isEnabled()
                if isEnabled != self.codexTaskDisplayEnabled {
                    self.codexTaskDisplayEnabled = isEnabled
                    self.reloadCodexTaskSessions()
                }
            }
        }
    }

    private func reloadCodexState() {
        reloadAccountProfile()
        reload()
        reloadApiBalance()
    }

    private func rebuildBalanceTimer() {
        balanceTimer?.invalidate()
        balanceTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadApiBalance(queueIfBusy: false) }
        }
    }

    func reloadAccountProfile() {
        guard accountProfileReloadTask == nil else {
            accountProfileReloadPending = true
            return
        }

        let worker = Task.detached(priority: .utility) {
            CodexAccountProfileReader.loadCurrent()
        }
        accountProfileReloadTask = Task { [weak self] in
            let profile = await worker.value
            guard let self else { return }
            self.accountProfileReloadTask = nil
            self.accountProfile = profile
            self.recordOfficialSource(profile: profile, snapshot: nil)
            self.refreshCurrentSourceSelection()
            self.syncDisplayedOfficialSnapshotWithCurrentProfile()

            let needsReload = self.accountProfileReloadPending
            self.accountProfileReloadPending = false
            if needsReload {
                self.reloadAccountProfile()
            }
        }
    }

    func reloadApiBalance(queueIfBusy: Bool = true) {
        guard apiBalanceReloadTask == nil else {
            if queueIfBusy {
                apiBalanceReloadPending = true
            }
            return
        }

        apiBalanceReloadTask = Task { [weak self] in
            guard let self else { return }
            await self.performApiBalanceReload()
            self.apiBalanceReloadTask = nil

            let needsReload = self.apiBalanceReloadPending
            self.apiBalanceReloadPending = false
            if needsReload {
                self.reloadApiBalance()
            }
        }
    }

    private func performApiBalanceReload() async {
        // CodexConfig + CCSwitchProvider 都是同步文件/SQLite I/O，移到后台。
        let result = await Task.detached(priority: .utility) { () -> (CodexConfig, CCSwitchProvider?)? in
            guard let codex = CodexConfig.loadActive() else { return nil }
            let provider = CCSwitchProvider.find(for: codex)
            return (codex, provider)
        }.value

        guard let (codex, provider) = result else {
            thirdPartyApiOnly = false
            currentThirdPartySourceID = nil
            displayedApiBalanceConfig = nil
            refreshCurrentSourceSelection()
            refreshInactiveThirdPartySources(excluding: nil)
            apiBalance = nil
            apiBalanceError = nil
            return
        }

        thirdPartyApiOnly = codex.isThirdPartyApiMode
        guard let provider else {
            currentThirdPartySourceID = nil
            displayedApiBalanceConfig = nil
            refreshCurrentSourceSelection()
            refreshInactiveThirdPartySources(excluding: nil)
            apiBalance = nil
            apiBalanceError = "CC Switch 中未找到对应配置"
            return
        }

        // 配置或 Key 已变化时，不能把上一张卡的余额继续显示在当前卡名下。
        if displayedApiBalanceConfig != codex {
            apiBalance = nil
            apiBalanceError = nil
        }
        recordThirdPartySource(provider: provider, balance: nil)
        refreshCurrentSourceSelection()
        refreshInactiveThirdPartySources(excluding: currentThirdPartySourceID)

        do {
            let balance = try await UsageScriptRunner.run(
                provider: provider,
                codexApiKey: codex.apiKey.isEmpty ? nil : codex.apiKey
            )
            guard await isCurrentThirdPartySelection(codex: codex, providerRowID: provider.rowID) else {
                apiBalanceReloadPending = true
                return
            }
            recordThirdPartySource(provider: provider, balance: balance)
            refreshCurrentSourceSelection()
            displayedApiBalanceConfig = codex
            if balance.isValid {
                apiBalance = balance
                apiBalanceError = nil
            } else {
                apiBalance = nil
                apiBalanceError = balance.invalidMessage ?? "余额查询失败"
            }
        } catch {
            guard await isCurrentThirdPartySelection(codex: codex, providerRowID: provider.rowID) else {
                apiBalanceReloadPending = true
                return
            }
            refreshCurrentSourceSelection()
            displayedApiBalanceConfig = codex
            apiBalance = nil
            apiBalanceError = "余额查询失败：\(error)"
        }
    }

    private func isCurrentThirdPartySelection(codex: CodexConfig, providerRowID: Int64) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let currentConfig = CodexConfig.loadActive(),
                  currentConfig == codex,
                  let currentProvider = CCSwitchProvider.find(for: currentConfig) else {
                return false
            }
            return currentProvider.rowID == providerRowID
        }.value
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
            Task { @MainActor in self?.reload(queueIfBusy: false) }
        }
    }

    func reload(queueIfBusy: Bool = true) {
        reloadCodexTaskSessions()
        guard officialReloadTask == nil else {
            if queueIfBusy {
                officialReloadPending = true
            }
            return
        }

        let worker = Task.detached(priority: .utility) { () -> OfficialReloadResult in
            let profile = CodexAccountProfileReader.loadCurrent()
            let authModifiedAt = CodexAccountProfileReader.authModifiedAt
            if let official = await OfficialQuotaReader.loadLatest() {
                return OfficialReloadResult(
                    snapshot: official,
                    profile: profile,
                    authModifiedAt: authModifiedAt,
                    source: .official
                )
            }
            return OfficialReloadResult(
                snapshot: QuotaReader.loadLatest(),
                profile: profile,
                authModifiedAt: authModifiedAt,
                source: .sessions
            )
        }
        officialReloadTask = Task { [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.officialReloadTask = nil
            self.applyOfficialReloadResult(result)

            let needsReload = self.officialReloadPending
            self.officialReloadPending = false
            if needsReload {
                self.reload()
            }
        }
    }

    private func applyOfficialReloadResult(_ result: OfficialReloadResult) {
        let snap = result.snapshot
        let profile = result.profile
        let officialSourceID = officialSourceID(for: profile)

        accountProfile = profile

        let acceptedSnapshot: QuotaSnapshot?
        switch result.source {
        case .official:
            recordOfficialSource(profile: profile, snapshot: snap)
            acceptedSnapshot = snap
        case .sessions:
            if shouldAcceptSessionsFallback(
                snapshot: snap,
                profile: profile,
                officialSourceID: officialSourceID,
                authModifiedAt: result.authModifiedAt
            ) {
                recordOfficialSource(profile: profile, snapshot: snap)
                acceptedSnapshot = snap
            } else {
                recordOfficialSource(profile: profile, snapshot: nil)
                acceptedSnapshot = nil
            }
        }

        refreshCurrentSourceSelection()

        if let acceptedSnapshot {
            snapshot = acceptedSnapshot
            displayedOfficialSnapshotSourceID = officialSourceID
            if let officialSourceID {
                UserDefaults.standard.set(officialSourceID, forKey: Self.lastConfirmedOfficialSourceKey)
            }
            lastError = nil
        } else {
            syncDisplayedOfficialSnapshotWithCurrentProfile()
            if snapshot == nil {
                lastError = profile == nil
                    ? "还没有读到额度，请先打开一次 Codex 并确认已登录"
                    : "已切换账号，正在等待这个账号的最新额度同步"
            }
        }
    }

    func dismissCodexTaskSession(_ id: String) {
        dismissedCodexTaskSessionIDs.insert(id)
    }

    func visibleCodexTaskSessions(referenceDate: Date = Date()) -> [CodexTaskSession] {
        codexTaskSessions.filter { session in
            session.shouldDisplay(referenceDate: referenceDate) &&
            !dismissedCodexTaskSessionIDs.contains(session.id)
        }
    }

    private func recordOfficialSource(profile: CodexAccountProfile?, snapshot: QuotaSnapshot?) {
        guard let profile,
              let entry = UsageSourceEntry.official(profile: profile, snapshot: snapshot) else {
            currentOfficialSourceID = nil
            return
        }
        currentOfficialSourceID = entry.id
        upsertSource(entry)
    }

    private func recordThirdPartySource(provider: CCSwitchProvider, balance: UsageScriptRunner.Balance?) {
        let entry = UsageSourceEntry.thirdParty(provider: provider, balance: balance)
        currentThirdPartySourceID = entry.id
        upsertSource(entry)
    }

    private func refreshCurrentSourceSelection() {
        currentSourceID = thirdPartyApiOnly ? currentThirdPartySourceID : currentOfficialSourceID
    }

    private func syncDisplayedOfficialSnapshotWithCurrentProfile() {
        let currentOfficialID = officialSourceID(for: accountProfile)
        guard displayedOfficialSnapshotSourceID != currentOfficialID else { return }

        displayedOfficialSnapshotSourceID = currentOfficialID
        if let currentOfficialID,
           let storedSnapshot = sourceHistory.first(where: { $0.id == currentOfficialID })?.snapshot {
            snapshot = storedSnapshot
        } else {
            snapshot = nil
        }
    }

    private func shouldAcceptSessionsFallback(
        snapshot: QuotaSnapshot?,
        profile: CodexAccountProfile?,
        officialSourceID: String?,
        authModifiedAt: Date?
    ) -> Bool {
        guard let snapshot else { return false }
        guard profile != nil else { return true }

        // 本地日志没有账号标识。当前账号已有快照时，接口偶发失败应保留旧值，
        // 不能用其他账号或历史会话里的额度覆盖。
        if let officialSourceID,
           sourceHistory.first(where: { $0.id == officialSourceID })?.snapshot != nil {
            return false
        }

        if let authModifiedAt,
           snapshot.capturedAt >= authModifiedAt.addingTimeInterval(-2) {
            return true
        }

        guard let officialSourceID else { return false }
        let lastConfirmedOfficialSourceID = UserDefaults.standard.string(forKey: Self.lastConfirmedOfficialSourceKey)
        return officialSourceID == lastConfirmedOfficialSourceID
    }

    private func officialSourceID(for profile: CodexAccountProfile?) -> String? {
        guard let profile else { return nil }
        return UsageSourceEntry.official(profile: profile, snapshot: nil)?.id
    }

    private func reloadCodexTaskSessions() {
        codexTaskDisplayEnabled = CodexTaskDisplaySettings.isEnabled()
        guard codexTaskDisplayEnabled else {
            codexTaskReloadPending = false
            codexTaskSessions = []
            dismissedCodexTaskSessionIDs = []
            return
        }

        // 文件监听、定时刷新可能同时到达；扫描期间只合并一次后续刷新。
        guard codexTaskReloadTask == nil else {
            codexTaskReloadPending = true
            return
        }

        let worker = Task.detached(priority: .utility) {
            CodexTaskSessionReader.loadRecentTasks()
        }
        codexTaskReloadTask = Task { [weak self] in
            let sessions = await worker.value
            guard let self else { return }
            self.codexTaskReloadTask = nil

            guard self.codexTaskDisplayEnabled,
                  CodexTaskDisplaySettings.isEnabled() else {
                self.codexTaskReloadPending = false
                self.codexTaskSessions = []
                self.dismissedCodexTaskSessionIDs = []
                return
            }

            self.codexTaskSessions = sessions
            let visibleIDs = Set(sessions.map(\.id))
            self.dismissedCodexTaskSessionIDs = self.dismissedCodexTaskSessionIDs.intersection(visibleIDs)

            let needsReload = self.codexTaskReloadPending
            self.codexTaskReloadPending = false
            if needsReload {
                self.reloadCodexTaskSessions()
            }
        }
    }

    private func upsertSource(_ incoming: UsageSourceEntry) {
        var entries = sourceHistory
        if let idx = entries.firstIndex(where: { $0.id == incoming.id }) {
            entries[idx] = merge(existing: entries[idx], incoming: incoming)
        } else {
            entries.append(incoming)
        }
        sourceHistory = entries
        UsageSourceHistoryStore.save(sourceHistory)
    }

    func moveSource(_ id: String, direction: Int) {
        var ids = sortableSourceEntries.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let targetIndex = index + direction
        guard ids.indices.contains(targetIndex) else { return }
        ids.swapAt(index, targetIndex)
        saveCustomSourceOrder(sortableIDs: ids)
    }

    func reorderSource(_ draggedID: String, targetID: String, placeAfter: Bool) {
        let originalIDs = sortableSourceEntries.map(\.id)
        guard draggedID != targetID,
              originalIDs.contains(draggedID) else { return }

        var reorderedIDs = originalIDs.filter { $0 != draggedID }
        let insertionIndex: Int

        if let currentSourceID, targetID == currentSourceID {
            insertionIndex = 0
        } else if let targetIndex = reorderedIDs.firstIndex(of: targetID) {
            insertionIndex = placeAfter ? targetIndex + 1 : targetIndex
        } else {
            return
        }

        reorderedIDs.insert(draggedID, at: max(0, min(insertionIndex, reorderedIDs.count)))
        guard reorderedIDs != originalIDs else { return }
        saveCustomSourceOrder(sortableIDs: reorderedIDs)
    }

    func resetSourceOrder() {
        sourceSortMode = .automatic
        customSourceOrderIDs = []
        UsageSourceOrderStore.saveMode(.automatic)
        UsageSourceOrderStore.saveCustomOrderIDs([])
    }

    func deleteSource(_ id: String) {
        guard id != currentSourceID else { return }
        guard sourceHistory.contains(where: { $0.id == id }) else { return }

        inactiveThirdPartyRefreshTask?.cancel()

        sourceHistory.removeAll { $0.id == id }
        UsageSourceHistoryStore.save(sourceHistory)

        if sourceSortMode == .custom {
            customSourceOrderIDs.removeAll { $0 == id }
            if sourceHistory.filter({ $0.id != currentSourceID }).isEmpty {
                resetSourceOrder()
            } else {
                UsageSourceOrderStore.saveCustomOrderIDs(customSourceOrderIDs)
            }
        }
    }

    private func merge(existing: UsageSourceEntry, incoming: UsageSourceEntry) -> UsageSourceEntry {
        UsageSourceEntry(
            id: incoming.id,
            kind: incoming.kind,
            title: incoming.title,
            subtitle: incoming.subtitle ?? existing.subtitle,
            snapshot: incoming.snapshot ?? existing.snapshot,
            balance: incoming.balance ?? existing.balance,
            thirdPartyLocator: incoming.thirdPartyLocator ?? existing.thirdPartyLocator,
            lastSeenAt: incoming.lastSeenAt
        )
    }

    private func refreshInactiveThirdPartySources(excluding excludedID: String?) {
        inactiveThirdPartyRefreshTask?.cancel()

        let entries = sourceHistory.filter {
            $0.kind == .thirdPartyAPI &&
            $0.id != excludedID &&
            $0.thirdPartyLocator != nil
        }
        guard !entries.isEmpty else { return }

        inactiveThirdPartyRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var refreshedEntries: [UsageSourceEntry] = []

            for entry in entries {
                if Task.isCancelled { return }
                guard let locator = entry.thirdPartyLocator,
                      let provider = CCSwitchProvider.find(locator: locator) else {
                    continue
                }
                guard let balance = try? await UsageScriptRunner.run(provider: provider) else {
                    continue
                }
                refreshedEntries.append(UsageSourceEntry.thirdParty(provider: provider, balance: balance))
            }

            if Task.isCancelled || refreshedEntries.isEmpty { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for entry in refreshedEntries {
                    self.upsertSource(entry)
                }
            }
        }
    }

    private func sortEntries(_ entries: [UsageSourceEntry], orderIndex: [String: Int]) -> [UsageSourceEntry] {
        let referenceDate = Date()
        switch sourceSortMode {
        case .automatic:
            return entries.sorted { lhs, rhs in
                compareEntries(lhs, rhs, orderIndex: orderIndex, referenceDate: referenceDate)
            }
        case .custom:
            let customOrder = mergedCustomOrderIDs(for: entries)
            let customIndex = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($0.element, $0.offset) })
            return entries.sorted { lhs, rhs in
                let lhsCustom = customIndex[lhs.id] ?? Int.max
                let rhsCustom = customIndex[rhs.id] ?? Int.max
                if lhsCustom != rhsCustom {
                    return lhsCustom < rhsCustom
                }
                return compareEntries(lhs, rhs, orderIndex: orderIndex, referenceDate: referenceDate)
            }
        }
    }

    private func compareEntries(
        _ lhs: UsageSourceEntry,
        _ rhs: UsageSourceEntry,
        orderIndex: [String: Int],
        referenceDate: Date
    ) -> Bool {
        let lhsBucket = lhs.sortBucket(referenceDate: referenceDate)
        let rhsBucket = rhs.sortBucket(referenceDate: referenceDate)
        if lhsBucket.rawValue != rhsBucket.rawValue {
            return lhsBucket.rawValue < rhsBucket.rawValue
        }

        switch lhsBucket {
        case .officialAvailable, .apiAvailable:
            let lhsValue = lhs.sortValue(referenceDate: referenceDate)
            let rhsValue = rhs.sortValue(referenceDate: referenceDate)
            if abs(lhsValue - rhsValue) > 0.000_001 {
                return lhsValue > rhsValue
            }
        case .officialEmpty, .apiEmpty:
            break
        }

        return (orderIndex[lhs.id] ?? Int.max) < (orderIndex[rhs.id] ?? Int.max)
    }

    private func mergedCustomOrderIDs(for entries: [UsageSourceEntry]) -> [String] {
        let entryIDs = Set(entries.map(\.id))
        var merged = customSourceOrderIDs.filter { entryIDs.contains($0) }
        let missingEntries = sortEntriesForAutomaticAppend(entries.filter { !merged.contains($0.id) })
        merged.append(contentsOf: missingEntries.map(\.id))
        return merged
    }

    private func sortEntriesForAutomaticAppend(_ entries: [UsageSourceEntry]) -> [UsageSourceEntry] {
        let orderIndex = Dictionary(uniqueKeysWithValues: sourceHistory.enumerated().map { ($0.element.id, $0.offset) })
        let referenceDate = Date()
        return entries.sorted { lhs, rhs in
            compareEntries(lhs, rhs, orderIndex: orderIndex, referenceDate: referenceDate)
        }
    }

    private func saveCustomSourceOrder(sortableIDs: [String]) {
        let combinedIDs: [String]
        if let currentSourceID {
            combinedIDs = [currentSourceID] + sortableIDs
        } else {
            combinedIDs = sortableIDs
        }

        sourceSortMode = .custom
        customSourceOrderIDs = combinedIDs
        UsageSourceOrderStore.saveMode(.custom)
        UsageSourceOrderStore.saveCustomOrderIDs(combinedIDs)
    }
}

private extension QuotaStore {
    struct OfficialReloadResult {
        let snapshot: QuotaSnapshot?
        let profile: CodexAccountProfile?
        let authModifiedAt: Date?
        let source: Source
    }

    enum Source {
        case official
        case sessions
    }
}

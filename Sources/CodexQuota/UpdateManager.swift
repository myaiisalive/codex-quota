import AppKit
import Combine
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    enum InstallMethod {
        case manual
        case brew

        var primaryActionTitle: String {
            switch self {
            case .manual: return "自动更新"
            case .brew: return "打开终端更新"
            }
        }

        var summaryText: String {
            switch self {
            case .manual:
                return "会自动下载安装新版本，替换当前软件，然后重新打开。"
            case .brew:
                return "会打开终端并自动执行 Homebrew 更新命令，方便直接看到进度和系统提示。"
            }
        }
    }

    struct ReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct ReleaseInfo: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String
        let assets: [ReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }

        var version: BundleVersion {
            let raw = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            return BundleVersion(shortVersion: raw, buildVersion: raw)
        }
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo, InstallMethod)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?

    private static let lastCheckedAtKey = "UpdateManager.lastCheckedAt"
    private static let checkInterval: TimeInterval = 12 * 60 * 60
    private static let releaseURL = URL(string: "https://api.github.com/repos/myaiisalive/codex-quota/releases/latest")!
    private static let bundleID = "com.local.codexquota"
    private static let knownBrewPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]

    init() {
        lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedAtKey) as? Date
    }

    var menuItemTitle: String {
        switch state {
        case .checking:
            return "正在检查新版本…"
        case .available(let release, _):
            return "更新到 \(release.version.shortVersion)…"
        case .installing(let message):
            return message
        default:
            return "检查新版本…"
        }
    }

    var currentVersionText: String {
        BundleVersion.current.displayString
    }

    var availableRelease: (release: ReleaseInfo, method: InstallMethod)? {
        guard case .available(let release, let method) = state else { return nil }
        return (release, method)
    }

    var statusText: String {
        switch state {
        case .idle:
            return "会联网到 GitHub 看看有没有新版本。"
        case .checking:
            return "正在检查新版本…"
        case .upToDate:
            return "已经是最新版本。"
        case .available(let release, let method):
            return "发现新版本 \(release.version.shortVersion)。\(method.summaryText)"
        case .installing(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    @discardableResult
    func checkForUpdates(force: Bool) async -> Bool {
        if !force,
           let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < Self.checkInterval,
           case .available = state {
            return true
        }
        if !force,
           let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < Self.checkInterval,
           case .upToDate = state {
            return false
        }

        state = .checking
        do {
            let release = try await fetchLatestRelease()
            let installMethod = try await detectInstallMethod()
            let hasUpdate = release.version.compare(to: .current) == .orderedDescending
            let now = Date()
            lastCheckedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckedAtKey)
            state = hasUpdate ? .available(release, installMethod) : .upToDate
            return hasUpdate
        } catch {
            state = .failed(userFacingErrorMessage(for: error))
            return false
        }
    }

    func openReleasePage() {
        let url: URL
        if case .available(let release, _) = state {
            url = release.htmlURL
        } else {
            url = URL(string: "https://github.com/myaiisalive/codex-quota/releases")!
        }
        NSWorkspace.shared.open(url)
    }

    func performAvailableUpdate() async throws {
        guard case .available(let release, let method) = state else { return }
        switch method {
        case .manual:
            try await installManualUpdate(from: release)
        case .brew:
            try await launchBrewUpgradeInTerminal()
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.releaseURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuota/\(BundleVersion.current.shortVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.networkUnavailable
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private func detectInstallMethod() async throws -> InstallMethod {
        guard let brewPath = Self.knownBrewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .manual
        }
        let result = try await Self.runProcess(
            executableURL: URL(fileURLWithPath: brewPath),
            arguments: ["list", "--cask", "--versions", "codex-quota"]
        )
        if result.status == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .brew
        }
        return .manual
    }

    private func installManualUpdate(from release: ReleaseInfo) async throws {
        state = .installing("正在下载安装新版本…")
        let asset = try preferredZipAsset(from: release)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let zipURL = workspace.appendingPathComponent(asset.name)
        let extractURL = workspace.appendingPathComponent("Extract", isDirectory: true)
        let scriptURL = workspace.appendingPathComponent("install-update.sh")

        do {
            let (downloadedURL, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            try FileManager.default.moveItem(at: downloadedURL, to: zipURL)
            _ = try await Self.runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", zipURL.path, extractURL.path]
            )
            let stagedApp = try findAppBundle(in: extractURL)
            try writeInstallerScript(scriptURL: scriptURL, sourceAppURL: stagedApp, workspaceURL: workspace)
            try launchInstallerScript(scriptURL: scriptURL)
            NSApp.terminate(nil)
        } catch {
            state = .available(release, .manual)
            throw error
        }
    }

    private func preferredZipAsset(from release: ReleaseInfo) throws -> ReleaseAsset {
        let preferredNames: [String] = {
#if arch(arm64)
            return ["arm64.zip", "universal.zip"]
#else
            return ["universal.zip"]
#endif
        }()
        for suffix in preferredNames {
            if let asset = release.assets.first(where: { $0.name.hasSuffix(suffix) }) {
                return asset
            }
        }
        throw UpdateError.missingInstaller
    }

    private func findAppBundle(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw UpdateError.missingInstaller
        }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        throw UpdateError.missingInstaller
    }

    private func writeInstallerScript(scriptURL: URL, sourceAppURL: URL, workspaceURL: URL) throws {
        let destinationPath = Bundle.main.bundlePath
        let backupPath = destinationPath + ".old"
        let script = """
        #!/bin/zsh
        set -e
        APP_SRC=\(Self.shellQuote(sourceAppURL.path))
        APP_DST=\(Self.shellQuote(destinationPath))
        APP_BACKUP=\(Self.shellQuote(backupPath))
        WORK_DIR=\(Self.shellQuote(workspaceURL.path))
        OLD_PID=\(ProcessInfo.processInfo.processIdentifier)

        while kill -0 "$OLD_PID" >/dev/null 2>&1; do
          sleep 0.2
        done

        rm -rf "$APP_BACKUP"
        if [ -e "$APP_DST" ]; then
          mv "$APP_DST" "$APP_BACKUP"
        fi
        mv "$APP_SRC" "$APP_DST"
        xattr -dr com.apple.quarantine "$APP_DST" >/dev/null 2>&1 || true
        open -n "$APP_DST"
        rm -rf "$APP_BACKUP" "$WORK_DIR"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private func launchInstallerScript(scriptURL: URL) throws {
        let installDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
        if FileManager.default.isWritableFile(atPath: installDir) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run()
            return
        }

        let command = "/bin/zsh \(Self.shellQuote(scriptURL.path)) >/dev/null 2>&1 &"
        let appleScript = "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installCancelled
        }
    }

    private func launchBrewUpgradeInTerminal() async throws {
        state = .installing("已打开终端，按里面提示完成更新。")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuotaBrew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let scriptURL = workspace.appendingPathComponent("brew-update.sh")
        let bundlePath = Bundle.main.bundlePath
        let script = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin:/usr/local/sbin:/usr/bin:/bin:$PATH"
        clear
        echo "CodexQuota 正在通过 Homebrew 更新..."
        echo
        if ! command -v brew >/dev/null 2>&1; then
          echo "这台电脑上没找到 Homebrew。"
          echo "请先安装 Homebrew，或者改用安装包更新。"
          echo
          read -k 1 '?按任意键关闭窗口...'
          exit 1
        fi
        HOMEBREW_NO_ASK=1 brew upgrade -y --cask codex-quota
        STATUS=$?
        echo
        if [ "$STATUS" -eq 0 ]; then
          echo "更新完成，软件会重新打开。"
          osascript -e 'tell application id "\(Self.bundleID)" to quit' >/dev/null 2>&1 || true
          open -n \(Self.shellQuote(bundlePath))
        else
          echo "更新没完成，请看上面的提示。"
        fi
        echo
        read -k 1 '?按任意键关闭窗口...'
        rm -rf \(Self.shellQuote(workspace.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let terminalScript = """
        tell application "Terminal"
          activate
          do script "/bin/zsh \(Self.terminalQuote(scriptURL.path))"
        end tell
        """
        let result = try await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", terminalScript]
        )
        guard result.status == 0 else {
            state = .failed("没能打开终端，请手动执行 brew upgrade --cask codex-quota。")
            throw UpdateError.cannotOpenTerminal
        }
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let updateError = error as? UpdateError else {
            return "现在没能检查新版本，请稍后再试。"
        }
        return updateError.message
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        }.value
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func terminalQuote(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum UpdateError: LocalizedError {
    case networkUnavailable
    case missingInstaller
    case installCancelled
    case cannotOpenTerminal

    var message: String {
        switch self {
        case .networkUnavailable:
            return "现在连不上更新服务，请稍后再试。"
        case .missingInstaller:
            return "这次没有找到可用的安装包，请先去发布页下载。"
        case .installCancelled:
            return "没有完成授权，更新已经取消。"
        case .cannotOpenTerminal:
            return "没能打开终端，请手动执行 brew upgrade --cask codex-quota。"
        }
    }

    var errorDescription: String? {
        message
    }
}

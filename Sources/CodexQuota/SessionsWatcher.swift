import Foundation
import CoreServices

/// 监听指定路径变化，触发回调
final class SessionsWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let watchPath: String
    private let targetFileName: String?
    private let debounceSeconds: Double
    private let onChange: () -> Void
    private var debounceWork: DispatchWorkItem?

    init(path: String, debounceSeconds: Double = 3.0, onChange: @escaping () -> Void) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        self.path = normalizedPath
        self.debounceSeconds = debounceSeconds
        self.onChange = onChange

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            self.watchPath = normalizedPath
            self.targetFileName = nil
        } else {
            let fileURL = URL(fileURLWithPath: normalizedPath)
            self.watchPath = fileURL.deletingLastPathComponent().path
            self.targetFileName = fileURL.lastPathComponent
        }
    }

    func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionsWatcher>.fromOpaque(info).takeUnretainedValue()
            let changedPaths = watcher.changedPaths(from: pathsPointer, count: count)
            guard watcher.shouldReload(for: changedPaths) else { return }
            DispatchQueue.main.async { watcher.scheduleReload() }
        }
        let paths = [watchPath] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // session 文件需要更长时间落盘；auth.json 这种小文件可以传更短延迟。
    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }

    private func changedPaths(from rawPaths: UnsafeMutableRawPointer?, count: Int) -> [String] {
        guard let rawPaths else { return [] }
        let array = unsafeBitCast(rawPaths, to: NSArray.self)
        return array
            .compactMap { $0 as? String }
            .prefix(count)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private func shouldReload(for changedPaths: [String]) -> Bool {
        guard let targetFileName else { return true }
        return changedPaths.contains { URL(fileURLWithPath: $0).lastPathComponent == targetFileName }
    }

    func stop() {
        debounceWork?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }
}

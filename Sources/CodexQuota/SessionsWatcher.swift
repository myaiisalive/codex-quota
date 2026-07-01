import Foundation
import CoreServices

/// 监听指定路径变化，触发回调
final class SessionsWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let debounceSeconds: Double
    private let onChange: () -> Void
    private var debounceWork: DispatchWorkItem?

    init(path: String, debounceSeconds: Double = 3.0, onChange: @escaping () -> Void) {
        self.path = path
        self.debounceSeconds = debounceSeconds
        self.onChange = onChange
    }

    func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionsWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.scheduleReload() }
        }
        let paths = [path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
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

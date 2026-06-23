import Foundation
import CoreServices

/// 监听 ~/.codex/sessions 下的目录变化，触发回调
final class SessionsWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    private var debounceWork: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
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

    // codex 写新 session 时先写 session_start（100%），再写实际消耗
    // 等 3 秒让 codex 完成写入，避免读到中间状态
    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
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

// Watches folders with FSEvents and coalesces bursts (a game save touches a
// dozen files; a Dropbox download lands them one by one) into a single call
// once things have been quiet for a moment.

import CoreServices
import Foundation

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "stagecoach.watcher")
    private var pending: DispatchWorkItem?
    private let quiet: TimeInterval
    private let onChange: () -> Void

    init(paths: [URL], quiet: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.quiet = quiet
        self.onChange = onChange
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().fired()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths.map(\.path) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func fired() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + quiet, execute: item)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

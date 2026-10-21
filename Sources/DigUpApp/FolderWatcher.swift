import CoreServices
import Foundation

/// File-level FSEvents on the chosen folders. Reports which paths changed, a batch at a time; the engine debounces
/// and syncs. Costs nothing while nothing changes (no polling), and hidden files (.DS_Store, editors' temp files)
/// are ignored, since browsing a folder in Finder writes those.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([Change]) -> Void

    /// A path that changed, and whether it's a folder.
    struct Change: Sendable {
        let path: String
        let isFolder: Bool
    }

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping @Sendable ([Change]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, folderWatcherCallback, &context,
                                               paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, FSEventStreamCreateFlags(flags)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    fileprivate func received(_ changes: [Change]) {
        let relevant = changes.filter { change in
            !change.path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        if !relevant.isEmpty { handler(relevant) }
    }
}

private nonisolated func folderWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    watcher.received(list.enumerated().map { index, path in
        FolderWatcher.Change(path: path,
                             isFolder: flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0)
    })
}

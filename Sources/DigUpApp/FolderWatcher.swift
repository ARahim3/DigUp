import CoreServices
import Foundation

/// File-level FSEvents on the chosen folders. Reports which paths changed, a batch at a time; the engine debounces
/// and syncs. Costs nothing while nothing changes (no polling), and hidden files (.DS_Store, editors' temp files)
/// are ignored, since browsing a folder in Finder writes those.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String], Bool) -> Void

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping @Sendable ([String], Bool) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
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

    fileprivate func received(_ paths: [String], fullScan: Bool) {
        // Git's hidden rules affect visible siblings too. Report their containing subtree so the engine can
        // apply its usual selection/exclusion filters before asking for a broader reconciliation.
        let relevant = paths.map { path in
            let name = (path as NSString).lastPathComponent
            if name == ".gitignore" || name == ".git" { return (path as NSString).deletingLastPathComponent }
            for suffix in ["/.git/info/exclude", "/.git/index"] where path.hasSuffix(suffix) {
                return String(path.dropLast(suffix.count))
            }
            return path
        }.filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        if fullScan || !relevant.isEmpty { handler(Array(Set(relevant)), fullScan) }
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
    let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
    let fullScan = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(rescan) != 0 }
    watcher.received(list, fullScan: fullScan)
}

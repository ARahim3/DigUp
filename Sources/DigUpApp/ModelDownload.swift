import DigUpLocalization
import AppKit
import DigUpKit
import Foundation
import Observation

/// Gets the model onto this Mac: ggml-org's two Q8_0 files from Hugging Face (865 MB), the text part first.
///
/// - Resumable: a file downloads into `<name>.partial`, and an interrupted download carries on from where it stopped
///   (an HTTP range), after a relaunch too.
/// - Checked: a finished file must have the exact size and SHA-256 in `ModelFiles` before it gets its real name, so a
///   file under its real name is always whole.
/// - Network problems retry by themselves (2 s, 5 s, 15 s, then every 30 s). A full disk, or a file that fails its
///   check twice, waits for the user (`start()` again).
/// - The folder is excluded from Time Machine: the files can always be downloaded again.
///
/// This is the app's only network use. It starts when onboarding's Get Started is clicked, or at launch when a set-up
/// app finds its model missing (an update that brings a new model). A file that's already in the Hugging Face cache
/// (`hf download`, llama.cpp users) is copied from there instead (an APFS clone: no time, no space), and checked the same.
/// So are files chosen by hand (`use`), for networks that block Hugging Face.
@Observable
final class ModelDownload {
    enum Phase: Equatable {
        case needed            // files missing, waiting for the go-ahead
        case downloading
        case verifying
        case retrying(String)  // a network problem: tries again by itself
        case failed(String)    // needs the user
        case ready
    }

    private(set) var phase: Phase
    /// Bytes on disk over both files, what earlier runs left included.
    private(set) var received: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    let total = ModelFiles.totalBytes
    let folder: URL

    @ObservationIgnored var onReady: () -> Void = {}
    @ObservationIgnored private var fetcher: FileFetcher?
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private var failedChecks = 0
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []
    @ObservationIgnored private var fileStarted = Date()
    @ObservationIgnored private var lastLogged = Date.distantPast
    @ObservationIgnored private var attempt = 0
    /// Files whose `.partial` was chosen by hand (`use`): one that fails its check says so rather than downloading.
    @ObservationIgnored private var chosen = Set<String>()

    init(folder: URL) {
        self.folder = folder
        phase = ModelFiles.missing(in: folder).isEmpty ? .ready : .needed
        received = bytesOnDisk()
    }

    var isReady: Bool { phase == .ready }
    var isActive: Bool {
        switch phase {
        case .downloading, .verifying, .retrying: true
        default: false
        }
    }
    var fraction: Double { min(1, Double(received) / Double(total)) }
    var secondsLeft: Double? {
        guard phase == .downloading, bytesPerSecond > 0 else { return nil }
        return Double(total - received) / bytesPerSecond
    }

    /// "42% · about 1 min left", "Checking the download…", "Waiting for the network…"
    var progressText: String {
        switch phase {
        case .needed: return L10n.text("Not downloaded yet")
        case .downloading:
            let percent = "\(Int((fraction * 100).rounded(.down)))%"
            guard let left = secondsLeft else { return percent }
            return percent + " · " + (left < 50 ? L10n.text("less than a minute left") : L10n.format("about %1$@ left", String(describing: roughDuration(left))))
        case .verifying: return L10n.text("Checking the download…")
        case .retrying: return L10n.text("Waiting for the network…")
        case .failed(let message): return message
        case .ready: return L10n.text("Ready")
        }
    }

    /// Starts, resumes or retries; does nothing while it runs (waiting for the network included) or once it's done.
    func start() {
        switch phase {
        case .ready, .downloading, .verifying: return
        default: break
        }
        guard fetcher == nil else { return }   // one download at a time: two would write the same .partial
        retryWork?.cancel()
        failedChecks = 0
        next()
    }

    private func next() {
        guard let file = ModelFiles.missing(in: folder).first else {
            phase = .ready
            received = total
            log("model: ready in \(tildePath(folder.path))")
            onReady()
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = self.folder
            try folder.setResourceValues(values)
        } catch {
            phase = .failed(L10n.format("Can't create %1$@", String(describing: tildePath(folder.path))))
            log("model: can't create \(folder.path): \(error)")
            return
        }
        let needed = ModelFiles.missing(in: folder).reduce(0) { $0 + $1.bytes } - partialBytes(of: file) + 200_000_000
        if let free = freeSpace(), free < needed {
            phase = .failed(L10n.format("Needs %1$@ free on this disk", String(describing: bytes(needed))))
            log("model: needs \(bytes(needed)) free, \(bytes(free)) is free")
            return
        }
        if let cached = ModelFiles.cachedCopy(of: file) {
            phase = .verifying
            let partial = folder.appendingPathComponent(file.name + ".partial")
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: partial)
                let copied = (try? FileManager.default.copyItem(at: cached, to: partial)) != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    log("model: \(file.name) " + (copied ? "copied from the Hugging Face cache"
                                                          : "is in the Hugging Face cache but couldn't be copied"))
                    if copied {
                        fileStarted = Date()
                        finished(file, .downloaded(partial))
                    } else {
                        download(file)
                    }
                }
            }
            return
        }
        download(file)
    }

    private func download(_ file: ModelFiles.File) {
        let done = completedBytes()
        let resumeAt = partialBytes(of: file)
        log("model: downloading \(file.name)" + (resumeAt > 0 ? " from \(bytes(resumeAt)) (resumed)" : ""))
        phase = .downloading
        fileStarted = Date()
        samples = []
        attempt += 1
        let current = attempt   // callbacks from an earlier attempt are ignored
        let fetcher = FileFetcher(file: file, folder: folder, progress: { [weak self] written in
            DispatchQueue.main.async { [weak self] in
                guard let self, attempt == current else { return }
                progress(done + written)
            }
        }, waiting: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, attempt == current else { return }
                phase = .retrying(L10n.text("Waiting for a network connection"))
                log("model: waiting for a network connection")
            }
        }, done: { [weak self] outcome in
            DispatchQueue.main.async { [weak self] in
                guard let self, attempt == current else { return }
                finished(file, outcome)
            }
        })
        self.fetcher = fetcher
        fetcher.start()
    }

    private func progress(_ onDisk: Int64) {
        if phase != .downloading { phase = .downloading }
        if onDisk > received { failuresInARow = 0 }   // bytes came: the link works again (a failure reports too)
        received = onDisk
        let now = Date()
        samples.append((now, onDisk))
        samples.removeAll { now.timeIntervalSince($0.time) > 6 }
        if let first = samples.first, now.timeIntervalSince(first.time) >= 1 {
            bytesPerSecond = Double(onDisk - first.bytes) / now.timeIntervalSince(first.time)
        }
        if now.timeIntervalSince(lastLogged) >= 10 {
            lastLogged = now
            log("model: \(progressText) (\(bytes(onDisk)) of \(bytes(total)), \(bytes(Int64(bytesPerSecond)))/s)")
        }
    }

    private func finished(_ file: ModelFiles.File, _ outcome: FileFetcher.Outcome) {
        fetcher = nil
        switch outcome {
        case .downloaded(let partial):
            let seconds = Date().timeIntervalSince(fileStarted)
            phase = .verifying
            let started = Date()
            DispatchQueue.global(qos: .utility).async { [folder] in
                let size = FileFetcher.size(of: partial)
                let hash = size == file.bytes ? try? ModelFiles.sha256(of: partial) : nil
                let good = hash == file.sha256
                if good {
                    let destination = folder.appendingPathComponent(file.name)
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.moveItem(at: partial, to: destination)
                } else {
                    try? FileManager.default.removeItem(at: partial)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    log("model: \(file.name) \(good ? "checked" : "FAILED its check (\(size) of \(file.bytes) bytes)") in "
                        + "\(ms(since: started)), downloaded in \(String(format: "%.1f s", seconds))")
                    if good {
                        chosen.remove(file.name)
                        next()
                    } else if chosen.remove(file.name) != nil {
                        // Chosen by hand: say so, rather than download what the network may block.
                        phase = .failed(L10n.format("The chosen %1$@ isn't the right file", file.name))
                    } else {
                        failedChecks += 1
                        received = bytesOnDisk()
                        if failedChecks >= 2 {
                            phase = .failed(L10n.text("The download was damaged twice. Try again later."))
                        } else {
                            next()
                        }
                    }
                }
            }
        case .failed(let message, let retry):
            received = bytesOnDisk()
            bytesPerSecond = 0
            guard retry else {
                phase = .failed(message)
                log("model: stopped: \(message)")
                return
            }
            let delays: [Double] = [2, 5, 15, 30]
            let delay = delays[min(failuresInARow, delays.count - 1)]
            failuresInARow += 1
            phase = .retrying(message)
            log("model: \(message.trimmingCharacters(in: CharacterSet(charactersIn: "."))); trying again in \(Int(delay)) s")
            let work = DispatchWorkItem { [weak self] in
                guard let self, case .retrying = phase else { return }
                next()
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: Files chosen by hand

    /// The model's two files, got some other way (on another network, from a mirror, a colleague's copy) where
    /// Hugging Face is blocked. Each goes where a download would put it (`<name>.partial`; an APFS clone when it can
    /// be) and is checked the same way, size and SHA-256, before it's used. A file counts by its size, and so by its
    /// name only at the right size (a smaller one would be taken for a download to resume). What's still missing
    /// afterwards downloads as usual.
    func use(_ urls: [URL]) {
        var picked: [(file: ModelFiles.File, url: URL)] = []
        var problem = L10n.text("Those aren't the model's files")
        for url in urls {
            let size = FileFetcher.size(of: url)
            guard let file = ModelFiles.all.first(where: { $0.bytes == size }) else {
                if let named = ModelFiles.all.first(where: { $0.name == url.lastPathComponent }) {
                    problem = L10n.format("The chosen %1$@ is %2$@, not %3$@", named.name, bytes(size), bytes(named.bytes))
                }
                continue
            }
            let wanted = ModelFiles.missing(in: folder).contains(file) && !picked.contains { $0.file == file }
            if wanted { picked.append((file, url)) }
        }
        guard !picked.isEmpty else {
            log("model: none of the chosen files is a model file (\(urls.map(\.lastPathComponent))): \(problem)")
            if phase != .ready, !isActive { phase = .failed(problem) }
            return
        }
        // What was downloading stops: these take its place (a stopped fetcher's callbacks are ignored).
        fetcher?.cancel()
        fetcher = nil
        attempt += 1
        retryWork?.cancel()
        phase = .verifying
        DispatchQueue.global(qos: .utility).async { [folder, picked] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var copied: [String] = []
            for (file, url) in picked {
                let partial = folder.appendingPathComponent(file.name + ".partial")
                try? FileManager.default.removeItem(at: partial)
                if (try? FileManager.default.copyItem(at: url, to: partial)) != nil { copied.append(file.name) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("model: chosen by hand: \(copied.joined(separator: ", "))")
                chosen.formUnion(copied)
                phase = .needed
                start()   // checks them, and downloads what's still missing
            }
        }
    }

    /// An open panel for `use`, as a sheet on `window` when there is one.
    func chooseFiles(for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("Use")
        panel.message = L10n.format("Choose the model files you downloaded: %1$@.", ModelFiles.all.map(\.name).joined(separator: L10n.text(" and ")))
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            self?.use(panel.urls)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Where the two files download from (the pinned revision), one a line: to fetch them on another network.
    static var links: String {
        ModelFiles.all.map(\.url.absoluteString).joined(separator: "\n")
    }

    // MARK: Disk

    private func partialBytes(of file: ModelFiles.File) -> Int64 {
        size(of: folder.appendingPathComponent(file.name + ".partial"))
    }

    private func completedBytes() -> Int64 {
        ModelFiles.all.filter { !ModelFiles.missing(in: folder).contains($0) }.reduce(0) { $0 + $1.bytes }
    }

    private func bytesOnDisk() -> Int64 {
        completedBytes() + ModelFiles.missing(in: folder).reduce(0) { $0 + min(partialBytes(of: $1), $1.bytes) }
    }

    private func size(of url: URL) -> Int64 {
        FileFetcher.size(of: url)
    }

    private func freeSpace() -> Int64? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

/// "865 MB", "1.2 GB".
nonisolated func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

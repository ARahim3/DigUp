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
        case .needed: return "Not downloaded yet"
        case .downloading:
            let percent = "\(Int((fraction * 100).rounded(.down)))%"
            guard let left = secondsLeft else { return percent }
            return percent + " · " + (left < 50 ? "less than a minute left" : "about \(roughDuration(left)) left")
        case .verifying: return "Checking the download…"
        case .retrying: return "Waiting for the network…"
        case .failed(let message): return message
        case .ready: return "Ready"
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
            phase = .failed("Can't create \(tildePath(folder.path))")
            log("model: can't create \(folder.path): \(error)")
            return
        }
        let needed = ModelFiles.missing(in: folder).reduce(0) { $0 + $1.bytes } - partialBytes(of: file) + 200_000_000
        if let free = freeSpace(), free < needed {
            phase = .failed("Needs \(bytes(needed)) free on this disk")
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
                phase = .retrying("Waiting for a network connection")
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
                        next()
                    } else {
                        failedChecks += 1
                        received = bytesOnDisk()
                        if failedChecks >= 2 {
                            phase = .failed("The download was damaged twice. Try again later.")
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

/// Downloads one file into `<name>.partial`, carrying on from what's there (an HTTP range). Reports the bytes on disk
/// at most 5 times a second, then how it went, on its own queue.
nonisolated final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        case downloaded(URL)
        case failed(String, retry: Bool)
    }

    private let file: ModelFiles.File
    private let partial: URL
    private let progress: @Sendable (Int64) -> Void
    private let waiting: @Sendable () -> Void
    private let done: @Sendable (Outcome) -> Void
    // The session's delegate queue only (after `start`).
    private var session: URLSession?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var problem: (message: String, retry: Bool)?
    private var reported = Date.distantPast

    init(file: ModelFiles.File, folder: URL, progress: @escaping @Sendable (Int64) -> Void,
         waiting: @escaping @Sendable () -> Void, done: @escaping @Sendable (Outcome) -> Void) {
        self.file = file
        partial = folder.appendingPathComponent(file.name + ".partial")
        self.progress = progress
        self.waiting = waiting
        self.done = done
    }

    /// The file's size now. (Not through URL resource values: a URL keeps the first size it read, so asking the same
    /// URL again after the download said the resumed file was still as small as when it resumed.)
    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func start() {
        written = Self.size(of: partial)
        if written > file.bytes {
            try? FileManager.default.removeItem(at: partial)
            written = 0
        }
        if written == file.bytes { return done(.downloaded(partial)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true        // offline: wait for the network instead of failing
        configuration.timeoutIntervalForRequest = 60     // no bytes for a minute: fail, then retry from here
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: file.url)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        session.dataTask(with: request).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    // Hugging Face redirects to its CDN; the range has to come along.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        waiting()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard range.hasPrefix("bytes \(written)-") else {
                // Not where we asked: start the file over next time.
                try? FileManager.default.removeItem(at: partial)
                problem = ("The download couldn't resume", true)
                return completionHandler(.cancel)
            }
        case 200:
            written = 0   // the whole file, from the start
        default:
            problem = ("Hugging Face answered \(status)", status == 429 || status >= 500)
            return completionHandler(.cancel)
        }
        do {
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(written))
            try handle.seekToEnd()
            self.handle = handle
            completionHandler(.allow)
        } catch {
            problem = ("Can't save the model: \(error.localizedDescription)", false)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            problem = ("Can't save the model: \(error.localizedDescription)", false)
            dataTask.cancel()
            return
        }
        let now = Date()
        if now.timeIntervalSince(reported) >= 0.2 {
            reported = now
            progress(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        progress(written)
        if let problem {
            done(.failed(problem.message, retry: problem.retry))
        } else if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }   // cancel()
            done(.failed(error.localizedDescription, retry: true))
        } else if written == file.bytes {
            done(.downloaded(partial))
        } else {
            done(.failed("The download stopped early", retry: true))
        }
    }
}

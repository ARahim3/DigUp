import DigUpKit
import Foundation

/// What the menubar shows about the index.
nonisolated struct EngineStatus: Sendable, Equatable {
    enum Activity: Sendable, Equatable {
        case starting
        case idle
        case syncing
        case indexing(done: Int, total: Int)
        /// The rest of long PDFs and documents (`Indexer.finishLongFiles`): `done` of the `total` pages and chunks this
        /// pass set out to read, `files` long files still unfinished.
        case finishing(done: Int, total: Int, files: Int)
        case failed(String)
    }

    /// The query encoder: a text-only worker process started when the panel opens.
    enum Encoder: Sendable, Equatable {
        case stopped
        case starting
        case ready
        case unavailable
    }

    var activity = Activity.starting
    var encoder = Encoder.stopped
    var files = 0        // in the index, any state
    var searchable = 0   // done or partial
    var pending = 0      // waiting to be embedded
    var unfinished = 0   // long files with pages or chunks still to read (the backfill's rules hold them up too)
    var vectors = 0
    var paused = false
    var waitingFor: String?   // why the backfill waits ("on battery"), if it does
    /// The helper found no model yet (it's downloading): files are found and named, nothing gets embedded.
    var waitingForModel = false
    /// Chosen folders that aren't there right now (an unplugged drive): skipped, and their files kept.
    var missingRoots: [String] = []
    /// Chosen folders macOS doesn't let DigUp read (Privacy & Security → Files and Folders): skipped, files kept.
    var unreadableRoots: [String] = []
    /// The code index, when code search is on.
    var code = Code()

    struct Code: Sendable, Equatable {
        var files = 0
        var searchable = 0
        var pending = 0
        var vectors = 0
        /// Files being read into the code index (`done` of `total`), or nil.
        var indexing: Progress?
        /// Code folders that aren't there right now (an unplugged drive): skipped, and their files kept.
        var missingRoots: [String] = []
    }

    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
    }
}

/// The engine host: search, the query encoder, and the indexing helper, all off the main thread.
///
/// Indexing runs in a helper process (`Contents/Helpers/digup index-service`) that exits when it's done:
/// extraction is heavy (Vision OCR alone keeps ~100 MB of models in the process that ran it), and the app has to stay
/// small while idle. The app watches the folders and tells the helper when to sync, pause, or run the backfill.
///
/// Every engine object is confined to one serial queue:
/// - `indexQueue` (utility QoS) talks to the indexing helper.
/// - `searchQueue` (user-initiated) owns the `Searcher` and its read connection. SQLite's WAL mode lets it read while
///   the helper writes, so a search never waits for indexing.
/// - `encoderQueue` (user-initiated) owns the query encoder, a worker process whose cold start (~0.35 s) must never
///   hold up keyword results.
/// The main thread never waits on any of them: work goes in with `async`, results come back through async
/// functions and `onStatus`.
///
/// The folders can change while it runs (`setFolders`): the watcher follows, and the helper restarts with them.
nonisolated final class Engine: @unchecked Sendable {
    /// A query's vector and the model that made it (vectors from different models can't be compared).
    struct QueryVector: Sendable {
        let values: [Float]
        let source: String
    }

    let indexDirectory: URL
    let modelsDirectory: URL
    let encoderIdleSeconds: Double
    private let indexQueue = DispatchQueue(label: "DigUp.index", qos: .utility)
    private let searchQueue = DispatchQueue(label: "DigUp.search", qos: .userInitiated)
    private let encoderQueue = DispatchQueue(label: "DigUp.encoder", qos: .userInitiated)

    private let watchQueue = DispatchQueue(label: "DigUp.watch", qos: .utility)

    // indexQueue only
    private var helper: Process?
    private var helperInput: FileHandle?
    private var helperStarted = Date()
    private var helperOutput = Data()
    /// The folders changed while a helper ran: start a new one with them when it's gone.
    private var restartHelper = false
    /// The next helper drops files under folders that are no longer chosen. At launch too, in case the folders
    /// changed while a helper had no time to; but an app with no folders at all never empties the index by itself.
    private var pruneWanted: Bool
    /// When a sync was last asked for that no helper has started yet; a helper that exits before doing it is
    /// restarted.
    private var syncWantedAt: Date?
    private var lastSearcherRefresh = Date.distantPast

    /// Code search: the code index once code has been quiet this long (a file being edited changes on every save, a
    /// branch switch or a build changes many at once), or at least this often while it keeps changing.
    let codeQuietSeconds: Double
    let codeLongestWait: Double = 600

    // watchQueue only
    private var watcher: FolderWatcher?
    private var syncDebounce: DispatchWorkItem?
    private var codeWatcher: FolderWatcher?
    private var codeSyncDebounce: DispatchWorkItem?
    private var codeChangedSince: Date?

    // Any thread, under `lock`
    private var paused = false
    private var backfillBlocker: String?
    private var roots: [URL]
    private var excluded: [URL]
    private var excludedTypes: [String]
    private var codeRoots: [URL]
    private var codeExcluded: [URL]

    // indexQueue only
    /// Code search was turned off: the code index goes once no helper has it open.
    private var deleteCodeIndex = false

    // searchQueue only
    private var searcher: Searcher?
    private var searchStore: IndexStore?
    private var codeSearcher: Searcher?
    private var codeStore: IndexStore?
    private var warnedAboutSource = false

    // encoderQueue only
    private var encoder: EmbeddingWorker?
    private var encoderFailed = false
    private var encoderIdleExit: DispatchWorkItem?
    private var vectorCache = QueryVectorCache(limit: 256)

    // Any thread, under `lock`: the newest text typed, so embed-ahead requests that went stale are skipped.
    private var newestTyped: String?

    // Any thread, under `lock`
    private let lock = NSLock()
    private var status = EngineStatus()
    private var statusPostPending = false
    private let onStatus: @MainActor @Sendable (EngineStatus) -> Void

    /// `backfillBlocker`: why the first full pass has to wait (see `PowerPolicy`), or nil.
    init(settings: AppSettings, backfillBlocker: String?,
         onStatus: @escaping @MainActor @Sendable (EngineStatus) -> Void) {
        indexDirectory = settings.indexDirectory
        modelsDirectory = settings.modelsDirectory
        encoderIdleSeconds = settings.encoderIdleSeconds
        roots = settings.roots
        excluded = settings.excludedFolders
        excludedTypes = settings.excludedTypes
        codeRoots = settings.codeRoots
        codeExcluded = settings.codeExcluded
        codeQuietSeconds = settings.codeQuietSeconds
        pruneWanted = !settings.roots.isEmpty
        self.backfillBlocker = backfillBlocker
        self.onStatus = onStatus
        status.waitingFor = backfillBlocker
    }

    // MARK: Status

    /// Changes the status and tells the main thread, at most ~10 times a second however often it changes.
    private func update(_ change: (inout EngineStatus) -> Void) {
        let post = lock.withLock {
            change(&status)
            defer { statusPostPending = true }
            return !statusPostPending
        }
        guard post else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            let latest = lock.withLock {
                statusPostPending = false
                return status
            }
            MainActor.assumeIsolated { onStatus(latest) }
        }
    }

    // MARK: Start

    /// Opens the searcher first (creating the index if it's new), so a search asked for right after launch already
    /// finds it on its queue; then starts the indexing helper, which syncs with the folders.
    func start() {
        searchQueue.async { [self] in
            guard openSearcher() else {
                update { $0.activity = .failed("Can't open the index") }
                return
            }
            indexQueue.async { [self] in startHelper() }
        }
        watchQueue.async { [self] in
            startWatching()
            startWatchingCode()
        }
    }

    var folders: (roots: [URL], excluded: [URL]) {
        lock.withLock { (roots, excluded) }
    }

    var hasCode: Bool { lock.withLock { !codeRoots.isEmpty } }

    /// New code folders (none: code search off). The helper restarts with them; without any, the code index is deleted
    /// once the helper is gone.
    func setCodeFolders(roots: [URL], excluded: [URL]) {
        let wasOn = lock.withLock { () -> Bool in
            defer {
                codeRoots = roots
                codeExcluded = excluded
            }
            return !codeRoots.isEmpty
        }
        log("code folders: \(roots.map { tildePath($0.path) })"
            + (excluded.isEmpty ? "" : " minus \(excluded.map { tildePath($0.path) })"))
        if roots.isEmpty { update { $0.code = EngineStatus.Code() } }
        watchQueue.async { [self] in startWatchingCode() }
        searchQueue.async { [self] in
            // The code index's own connection closes before the file can go.
            if roots.isEmpty {
                codeSearcher = nil
                codeStore = nil
            } else if codeSearcher == nil {
                openCodeSearcher()
            }
            indexQueue.async { [self] in
                pruneWanted = true
                // Off: the index goes once no helper has it open. On again before that: it stays (and is pruned).
                deleteCodeIndex = roots.isEmpty && (wasOn || deleteCodeIndex)
                if helper != nil {
                    restartHelper = true
                    send("stop")
                } else {
                    removeCodeIndexIfAsked()
                    startHelper()
                }
            }
        }
    }

    /// New folders or exclusions: the watcher follows, and the helper restarts with them once its current batch is
    /// done. Files under folders that are no longer chosen, or newly excluded, leave the index.
    func setFolders(roots: [URL], excluded: [URL], excludedTypes: [String]) {
        lock.withLock {
            self.roots = roots
            self.excluded = excluded
            self.excludedTypes = excludedTypes
        }
        log("folders: \(roots.map { tildePath($0.path) })" + (excluded.isEmpty ? "" : " minus \(excluded.map { tildePath($0.path) })")
            + (excludedTypes.isEmpty ? "" : " · skipping .\(excludedTypes.joined(separator: ", ."))"))
        update {
            $0.missingRoots = []
            $0.unreadableRoots = []
            if roots.isEmpty { $0.activity = .idle }
        }
        watchQueue.async { [self] in startWatching() }
        indexQueue.async { [self] in
            pruneWanted = true
            if helper != nil {
                restartHelper = true
                send("stop")
            } else {
                startHelper()
            }
        }
    }

    /// The model has finished downloading: index what's waiting, and meaning search may start.
    func modelArrived() {
        update { $0.waitingForModel = false }
        encoderQueue.async { [self] in encoderFailed = false }
        indexQueue.async { [self] in requestSync() }
    }

    /// A drive was connected or ejected: a missing folder may be back (or gone).
    func volumesChanged() {
        watchQueue.async { [self] in
            startWatching()
            startWatchingCode()
        }
        indexQueue.async { [self] in
            requestSync()
            if hasCode { send("sync code") }
        }
    }

    private func openSearcher() -> Bool {
        let started = Date()
        do {
            // Keyword search only until the panel opens: the vectors load then, and leave with the query encoder.
            let store = try IndexStore(directory: indexDirectory)
            let searcher = try Searcher(store: store, loadVectors: false)
            self.searcher = searcher
            searchStore = store
            if let counts = try? store.counts() { apply(counts) }
            log("engine: searcher ready in \(ms(since: started))")
            if hasCode { openCodeSearcher() }
            returnFreedMemory()
            return true
        } catch {
            log("can't open the index at \(indexDirectory.path): \(error)")
            return false
        }
    }

    /// The code index's searcher (searchQueue), when code search is on; its vectors load with the first search of code.
    private func openCodeSearcher() {
        do {
            let store = try IndexStore(directory: indexDirectory, file: IndexStore.codeFile)
            codeSearcher = try Searcher(store: store, loadVectors: false)
            codeStore = store
            if let counts = try? store.counts() { applyCode(counts) }
        } catch {
            log("can't open the code index: \(error)")
        }
    }

    /// Code search was turned off: its index goes (indexQueue, with no helper running).
    private func removeCodeIndexIfAsked() {
        guard deleteCodeIndex, helper == nil else { return }
        deleteCodeIndex = false
        let file = indexDirectory.appendingPathComponent(IndexStore.codeFile)
        for path in [file.path, file.path + "-wal", file.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        log("code search off: the code index was deleted")
    }

    private func applyCode(_ counts: IndexStore.Counts) {
        var files = 0, searchable = 0, pending = 0
        for states in counts.byKindAndState.values {
            for (state, count) in states {
                files += count
                if state == "done" || state == "partial" { searchable += count }
                if state == "pending" { pending += count }
            }
        }
        update {
            $0.code.files = files
            $0.code.searchable = searchable
            $0.code.pending = pending
            $0.code.vectors = counts.vectors
        }
    }

    private func apply(_ counts: IndexStore.Counts) {
        var files = 0, searchable = 0, pending = 0
        for states in counts.byKindAndState.values {
            for (state, count) in states {
                files += count
                if state == "done" || state == "partial" { searchable += count }
                if state == "pending" { pending += count }
            }
        }
        update {
            $0.files = files
            $0.searchable = searchable
            $0.pending = pending
            $0.vectors = counts.vectors
            $0.unfinished = counts.unfinished
        }
    }

    // MARK: Indexing (in the helper process)

    /// Watches the chosen folders that are there (a missing one is picked up when a drive connects).
    private func startWatching() {
        watcher = nil
        let present = lock.withLock { roots }.filter(AppSettings.isFolder)
        guard !present.isEmpty else { return }
        watcher = FolderWatcher(paths: present.map(\.path), latency: 0.25, queue: watchQueue) { [weak self] paths in
            self?.foldersChanged(paths)
        }
        log(watcher == nil ? "watch: can't watch the folders" : "watch: \(present.count) folders")
    }

    /// Watches the code folders that are there, as `startWatching` does the others.
    private func startWatchingCode() {
        codeWatcher = nil
        codeSyncDebounce?.cancel()
        codeChangedSince = nil
        let present = lock.withLock { codeRoots }.filter(AppSettings.isFolder)
        guard !present.isEmpty else { return }
        codeWatcher = FolderWatcher(paths: present.map(\.path), latency: 2, queue: watchQueue) { [weak self] paths in
            self?.codeChanged(paths)
        }
        log(codeWatcher == nil ? "watch: can't watch the code folders" : "watch: \(present.count) code folders")
    }

    /// FSEvents in the code folders, on watchQueue. Code that's being worked on changes all the time: the code index
    /// catches up once it's been quiet for `codeQuietSeconds` (or every `codeLongestWait` while it isn't). Changes
    /// code search never reads (git's own files, builds, dependencies) don't count.
    private func codeChanged(_ paths: [String]) {
        let relevant = paths.filter { path in
            !path.split(separator: "/").contains { part in
                part.hasPrefix(".") || Self.codeNoise.contains(String(part))
            }
        }
        guard !relevant.isEmpty else { return }
        let now = Date()
        if codeChangedSince == nil { codeChangedSince = now }
        codeSyncDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            codeChangedSince = nil
            log("watch: code changed (\((relevant.first as NSString?)?.lastPathComponent ?? ""))")
            indexQueue.async { [self] in requestCodeSync() }
        }
        codeSyncDebounce = work
        let waited = now.timeIntervalSince(codeChangedSince ?? now)
        watchQueue.asyncAfter(deadline: .now() + max(0, min(codeQuietSeconds, codeLongestWait - waited)), execute: work)
    }

    /// Folders whose changes don't concern the code index (what `Rules` keeps code search out of, by name).
    private static let codeNoise: Set<String> = [
        "node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage",
        "vendor", "Vendor", "third_party", "build", "Build", "dist", "out", "target", "obj", "coverage", "wandb",
        "mlruns", "lightning_logs",
    ]

    private func requestCodeSync() {
        if helper != nil { send("sync code") } else { startHelper() }
    }

    /// FSEvents, on watchQueue. Waits for things to settle (a copy in progress, a burst of screenshots), then asks
    /// the helper to sync; a running batch yields to that at its next boundary.
    private func foldersChanged(_ paths: [String]) {
        log("watch: \(paths.count) changed (\((paths.first as NSString?)?.lastPathComponent ?? ""))")
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            indexQueue.async { [self] in requestSync() }
        }
        syncDebounce = work
        watchQueue.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func requestSync() {
        syncWantedAt = Date()
        if helper != nil { send("sync") } else { startHelper() }
    }

    /// Starts `digup index-service` unless one is running (or indexing is paused). It syncs first, indexes up to
    /// 50 new files on any power source, then the backfill if the power policy allows; it exits a minute after
    /// its last file. Before the model has downloaded it only syncs (file names become searchable) and exits.
    private func startHelper() {
        let (roots, excluded, types, paused, backfill): ([URL], [URL], [String], Bool, Bool) = lock.withLock {
            (self.roots, self.excluded, self.excludedTypes, self.paused, backfillBlocker == nil)
        }
        let (codeRoots, codeExcluded) = lock.withLock { (self.codeRoots, self.codeExcluded) }
        guard helper == nil, !paused else { return }
        guard !roots.isEmpty || !codeRoots.isEmpty || pruneWanted else {
            update { $0.activity = .idle }
            return
        }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup")
        var arguments = ["index-service", "--index", indexDirectory.path]
        if backfill { arguments.append("--backfill") }
        if pruneWanted { arguments.append("--prune") }
        for folder in excluded { arguments += ["--exclude", folder.path] }
        for type in types { arguments += ["--exclude-ext", type] }
        for folder in codeRoots { arguments += ["--code-root", folder.path] }
        for folder in codeExcluded { arguments += ["--code-exclude", folder.path] }
        process.arguments = arguments + roots.map(\.path)
        process.environment = ProcessInfo.processInfo.environment.merging(["DIGUP_MODELS": modelsDirectory.path]) { $1 }
        process.qualityOfService = .utility
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.appendingHandle(indexDirectory.appendingPathComponent("indexer.log"))
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            indexQueue.async { self.received(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            indexQueue.async { self.helperExited(status: status) }
        }
        do {
            try process.run()
        } catch {
            log("indexer: can't start \(process.executableURL?.path ?? "the helper"): \(error)")
            update { $0.activity = .failed("Can't start indexing") }
            return
        }
        helper = process
        helperInput = input.fileHandleForWriting
        helperStarted = Date()
        helperOutput = Data()
        pruneWanted = false
        update {   // the helper says first if any are still missing or unreadable
            $0.missingRoots = []
            $0.unreadableRoots = []
            $0.code.missingRoots = []
        }
        log("indexer: started (pid \(process.processIdentifier))")
    }

    private func send(_ command: String) {
        do {
            try helperInput?.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            // It's on its way out; `helperExited` restarts it if a sync is still owed.
            log("indexer: couldn't send \"\(command)\": \(error)")
        }
    }

    private func received(_ data: Data) {
        helperOutput.append(data)
        while let newline = helperOutput.firstIndex(of: 0x0A) {
            let line = helperOutput[helperOutput.startIndex..<newline]
            helperOutput.removeSubrange(helperOutput.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        func int(_ key: String) -> Int { event[key] as? Int ?? 0 }
        if event["code"] as? Bool == true { return handleCode(event) }
        switch event["event"] as? String {
        case "sync":
            if let started = event["started"] as? Double, let wanted = syncWantedAt,
               started >= wanted.timeIntervalSince1970 {
                syncWantedAt = nil
            }
            applyCounts(event)
            if int("new") > 0 { update { $0.activity = .indexing(done: 0, total: int("new")) } }
            log("sync: \(int("added")) new · \(int("changed")) changed · \(int("moved")) moved · "
                + "\(int("removed")) removed · \(int("unchanged")) unchanged in \(int("ms")) ms")
        case "file":
            let (done, total) = (int("done"), int("total"))
            update { $0.activity = .indexing(done: done, total: total) }
            if event["new"] as? Bool == true, let path = event["path"] as? String {
                log(String(format: "index: %@ %@ in %.2f s", (path as NSString).lastPathComponent,
                           event["state"] as? String ?? "?", event["seconds"] as? Double ?? 0))
            }
            refreshSearcher(force: false)
        case "rest":
            update { $0.activity = .finishing(done: int("done"), total: int("total"), files: int("files")) }
            refreshSearcher(force: false)
        case "summary":
            let states = (event["states"] as? [String: Int] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }.joined(separator: " · ")
            let what = event["rest"] as? Bool == true ? "the rest of long files"
                : event["new"] as? Bool == true ? "new files" : "backfill"
            log("index: \(what): \(states) in \(int("ms")) ms")
        case "idle":
            applyCounts(event)
            update { $0.activity = .idle }
            refreshSearcher(force: true)
        case "waiting":
            applyCounts(event)
            update {
                $0.activity = .idle
                $0.waitingForModel = true
            }
            log("indexer: waiting for the model to download")
        case "missing":
            let folders = event["folders"] as? [String] ?? []
            let unreadable = event["unreadable"] as? [String] ?? []
            update {
                $0.missingRoots = folders
                $0.unreadableRoots = unreadable
            }
            if !folders.isEmpty { log("indexer: not connected: \(folders.map(tildePath))") }
            if !unreadable.isEmpty { log("indexer: no access: \(unreadable.map(tildePath))") }
        case "pruned":
            log("indexer: \(int("files")) files under folders no longer chosen left the index")
        case "reindex":
            log("indexer: the model or settings changed, indexing everything again (was: \(event["from"] as? String ?? "?"))")
        case "error":
            log("indexer: \(event["message"] as? String ?? "error")")
            if event["fatal"] as? Bool == true { update { $0.activity = .failed("Indexing stopped") } }
        default:
            break
        }
    }

    /// Events about the code index ("code": true).
    private func handleCode(_ event: [String: Any]) {
        func int(_ key: String) -> Int { event[key] as? Int ?? 0 }
        switch event["event"] as? String {
        case "sync":
            applyCounts(event)
            if int("new") > 0 { update { $0.code.indexing = .init(done: 0, total: int("new")) } }
            log("code sync: \(int("added")) new · \(int("changed")) changed · \(int("moved")) moved · "
                + "\(int("removed")) removed · \(int("unchanged")) unchanged in \(int("ms")) ms")
        case "file":
            update { $0.code.indexing = .init(done: int("done"), total: int("total")) }
            refreshCodeSearcher(force: false)
        case "summary":
            let states = (event["states"] as? [String: Int] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }.joined(separator: " · ")
            log("index: code: \(states) in \(int("ms")) ms")
            update { $0.code.indexing = nil }
            refreshCodeSearcher(force: true)
        case "missing":
            let folders = event["folders"] as? [String] ?? []
            update { $0.code.missingRoots = folders + (event["unreadable"] as? [String] ?? []) }
            if !folders.isEmpty { log("indexer: code folders not connected: \(folders.map(tildePath))") }
        case "pruned":
            log("indexer: \(int("files")) files under code folders no longer chosen left the code index")
        case "reindex":
            log("indexer: the model changed, the code index starts over")
        case "error":
            log("indexer: code: \(event["message"] as? String ?? "error")")
            if event["fatal"] as? Bool == true { update { $0.activity = .failed("Indexing stopped") } }
        default:
            break
        }
    }

    private func applyCounts(_ event: [String: Any]) {
        if let files = event["files"] as? Int {
            update {
                $0.files = files
                $0.searchable = event["searchable"] as? Int ?? 0
                $0.pending = event["pending"] as? Int ?? 0
                $0.vectors = event["vectors"] as? Int ?? 0
                $0.unfinished = event["unfinished"] as? Int ?? 0
            }
        }
        if let files = event["code_files"] as? Int {
            update {
                $0.code.files = files
                $0.code.searchable = event["code_searchable"] as? Int ?? 0
                $0.code.pending = event["code_pending"] as? Int ?? 0
                $0.code.vectors = event["code_vectors"] as? Int ?? 0
            }
        }
    }

    private func helperExited(status: Int32) {
        helper = nil
        helperInput = nil
        log("indexer: exited (\(status)) after \(ms(since: helperStarted))")
        update {
            if case .indexing = $0.activity { $0.activity = .idle }
            if case .finishing = $0.activity { $0.activity = .idle }
            if case .starting = $0.activity { $0.activity = .idle }
            $0.code.indexing = nil
        }
        refreshSearcher(force: true)
        refreshCodeSearcher(force: true)
        returnFreedMemory()
        removeCodeIndexIfAsked()
        if restartHelper {
            // The folders changed: a new helper with the new ones.
            restartHelper = false
            startHelper()
        } else if syncWantedAt != nil, status == 0 {
            // A sync asked for while it was on its way out still has to happen.
            startHelper()
        }
    }

    /// New vectors reach the panel: reload the searcher's copy, at most every 2 s during a long pass. If the panel
    /// hasn't been used lately the vectors aren't loaded at all, and they load fresh when it opens.
    private func refreshSearcher(force: Bool) {
        guard force || Date().timeIntervalSince(lastSearcherRefresh) > 2 else { return }
        lastSearcherRefresh = Date()
        searchQueue.async { [self] in
            guard let searcher, searcher.vectorsLoaded else { return }
            let started = Date()
            try? searcher.reload()
            log("engine: searcher reloaded, \(searcher.vectorCount) vectors in \(ms(since: started))")
        }
    }

    private var lastCodeRefresh = Date.distantPast

    /// New code vectors reach code search, as `refreshSearcher` does for the main index.
    private func refreshCodeSearcher(force: Bool) {
        guard force || Date().timeIntervalSince(lastCodeRefresh) > 2 else { return }
        lastCodeRefresh = Date()
        searchQueue.async { [self] in
            guard let codeSearcher, codeSearcher.vectorsLoaded else { return }
            try? codeSearcher.reload()
        }
    }

    /// Pause takes effect after the current batch (the helper finishes it and exits); Resume starts a new one.
    func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
        update { $0.paused = paused }
        log(paused ? "indexing paused" : "indexing resumed")
        indexQueue.async { [self] in
            if paused { send("stop") } else { startHelper() }
        }
    }

    /// From `PowerPolicy`: why the backfill has to wait now, or nil when it may run.
    func setBackfillBlocker(_ reason: String?) {
        lock.withLock { backfillBlocker = reason }
        update { $0.waitingFor = reason }
        indexQueue.async { [self] in
            if helper != nil {
                send(reason == nil ? "backfill on" : "backfill off")
            } else if reason == nil {
                startHelper()
            }
        }
    }

    private static func appendingHandle(_ url: URL) -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    // MARK: Search

    /// Hybrid search. Without a vector it's keyword-only (file names, OCR and document text), which is what the panel
    /// shows while the query encoder starts. Files that are gone (deleted since the last sync, or on a drive that's
    /// unplugged) are left out.
    /// `code`: the code index (its own folders), never anything else.
    func search(_ text: String, vector: QueryVector?, prefixLast: Bool, kinds: Set<FileKind>? = nil,
                limit: Int = 40, code: Bool = false) async -> [SearchHit] {
        if code { return await searchCode(text, vector: vector, prefixLast: prefixLast, limit: limit) }
        return await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                var values = vector?.values
                if let vector, let indexed = searcher?.vectorSource, indexed != vector.source {
                    if !warnedAboutSource {
                        log("meaning search is off: the index was built with \(indexed), the encoder is \(vector.source)")
                        warnedAboutSource = true
                    }
                    values = nil
                }
                let hits = try? searcher?.search(text, queryVector: values, kinds: kinds, limit: limit,
                                                 prefixLast: prefixLast)
                // Only files that are searched (`FolderSelection`'s rule, as the crawler walks them) and of types not
                // skipped: a removed folder's rows (or a newly skipped type's) can outlive it until a helper syncs
                // (indexing was paused, or the app quit first).
                let (chosen, excluded, types): ([URL], [URL], Set<String>) = lock.withLock {
                    (self.roots, self.excluded, Set(self.excludedTypes))
                }
                let folders = chosen.map(\.path), skipped = excluded.map(\.path)
                continuation.resume(returning: (hits ?? []).filter { hit in
                    FolderSelection.isSearched(hit.path, folders: folders, skipped: skipped)
                        && !types.contains((hit.path as NSString).pathExtension.lowercased())
                        && FileManager.default.fileExists(atPath: hit.path)
                })
            }
        }
    }

    private func searchCode(_ text: String, vector: QueryVector?, prefixLast: Bool, limit: Int) async -> [SearchHit] {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                let (roots, skipped) = lock.withLock { (codeRoots.map(\.path), codeExcluded.map(\.path)) }
                guard !roots.isEmpty, let codeSearcher else { return continuation.resume(returning: []) }
                var values = vector?.values
                if let vector, let indexed = codeSearcher.vectorSource, indexed != vector.source { values = nil }
                let hits = (try? codeSearcher.search(text, queryVector: values, limit: limit, prefixLast: prefixLast)) ?? []
                continuation.resume(returning: hits.filter { hit in
                    FolderSelection.isSearched(hit.path, folders: roots, skipped: skipped)
                        && FileManager.default.fileExists(atPath: hit.path)
                })
            }
        }
    }

    /// The text of the part of a file a hit points at (a document's passage, a page, a stretch of code), for the
    /// preview.
    func text(ofSegment id: Int64, code: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                continuation.resume(returning: (try? (code ? codeSearcher : searcher)?.text(ofSegment: id)) ?? nil)
            }
        }
    }

    // MARK: Index overview (main window)

    /// What's indexed under one folder.
    struct RootSummary: Sendable, Identifiable {
        let path: String
        var missing = false
        var unreadable = false
        var files = 0, indexed = 0, pending = 0, failed = 0, skipped = 0
        var unfinished = 0   // long files searchable but still being read (counted in `indexed` too)
        var kinds: [FileKind: Int] = [:]
        var id: String { path }
    }

    /// What's indexed under each folder; `code`: each code folder, in the code index.
    func rootSummaries(code: Bool = false) async -> [RootSummary] {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                let unreadable = Set(lock.withLock { code ? [] : status.unreadableRoots })
                let store = code ? codeStore : searchStore
                let summaries = lock.withLock { code ? codeRoots : roots }.map { root -> RootSummary in
                    var summary = RootSummary(path: root.path, missing: !AppSettings.isFolder(root),
                                              unreadable: unreadable.contains(root.path))
                    for file in (try? store?.files(under: [root.path])) ?? [] {
                        summary.files += 1
                        summary.kinds[file.kind, default: 0] += 1
                        switch file.state {
                        case "done": summary.indexed += 1
                        case "partial":
                            summary.indexed += 1
                            summary.unfinished += 1
                        case "pending": summary.pending += 1
                        case "failed": summary.failed += 1
                        default: summary.skipped += 1
                        }
                    }
                    return summary
                }
                continuation.resume(returning: summaries)
            }
        }
    }

    /// Bytes on disk: the database and its write-ahead log.
    var indexSize: Int64 {
        IndexStore.size(of: indexDirectory.appendingPathComponent(IndexStore.mainFile))
    }

    /// The code index's bytes on disk (0 without code search).
    var codeIndexSize: Int64 {
        IndexStore.size(of: indexDirectory.appendingPathComponent(IndexStore.codeFile))
    }

    // MARK: Query encoder

    /// Gets meaning search ready as the panel opens: starts the query encoder (~0.35 s cold) and loads the vectors,
    /// in parallel, so both are usually done by the time you've typed a few words.
    func prewarm() {
        encoderQueue.async { [self] in
            encoderFailed = false   // opening the panel is a fresh chance
            if runningEncoder() != nil { scheduleIdleExit() }
        }
        searchQueue.async { [self] in
            guard let searcher, !searcher.vectorsLoaded else { return }
            let started = Date()
            do {
                try searcher.reload()
                log("engine: \(searcher.vectorCount) vectors loaded in \(ms(since: started))")
            } catch {
                log("can't load vectors: \(error)")
            }
        }
    }

    /// Embeds what's typed so far, right away, and caches it. The panel calls this on every keystroke: the GPU stays
    /// awake (after even 150 ms idle a query takes ~19 ms instead of ~6), and when typing pauses the vector is
    /// usually ready. Skipped when newer text arrives before its turn.
    func embedAhead(_ text: String, code: Bool = false) {
        let key = Self.cacheKey(text, code: code)
        lock.withLock { newestTyped = key }
        encoderQueue.async { [self] in
            guard lock.withLock({ newestTyped }) == key else { return }
            _ = vector(for: text, code: code)
        }
    }

    /// A query's vector depends on its prompt: a search of code (`Prompts.codeQuery`) or of everything else.
    private static func cacheKey(_ text: String, code: Bool) -> String { code ? "code\u{0}" + text : text }

    /// The query's vector, or nil when the encoder can't run (keyword results still work). Also nil, at once, for
    /// text that's no longer the newest typed: its results would be thrown away.
    func embedQuery(_ text: String, code: Bool = false) async -> QueryVector? {
        let key = Self.cacheKey(text, code: code)
        return await withCheckedContinuation { continuation in
            encoderQueue.async { [self] in
                if vectorCache[key] == nil, let newest = lock.withLock({ newestTyped }), newest != key {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: vector(for: text, code: code))
            }
        }
    }

    private func vector(for text: String, code: Bool) -> QueryVector? {
        let key = Self.cacheKey(text, code: code)
        if let cached = vectorCache[key] { return cached }
        guard let worker = runningEncoder() else { return nil }
        defer { scheduleIdleExit() }
        do {
            let values = try worker.embedTexts([code ? Prompts.codeQuery(text) : Prompts.query(text)]).first ?? []
            let vector = QueryVector(values: values, source: worker.info.vectorSource)
            vectorCache[key] = vector
            return vector
        } catch {
            log("encoder: \(error)")
            stopEncoder()   // the next query starts a new one
            return nil
        }
    }

    private func runningEncoder() -> EmbeddingWorker? {
        if let encoder { return encoder }
        guard !encoderFailed else { return nil }
        let python = try? WorkerConfig.fromEnvironment()
        // Still downloading: no meaning search yet, which isn't a failure.
        guard python != nil || FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent(ModelFiles.text.name).path) else { return nil }
        update { $0.encoder = .starting }
        let started = Date()
        do {
            // The bundled helper runs the model (`digup worker`); DIGUP_WORKER_DIR swaps in another worker.
            var config = python ?? .helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup"))
            config.environment["DIGUP_MODELS"] = modelsDirectory.path
            config.log = indexDirectory.appendingPathComponent("worker-query.log")
            config.qos = .userInitiated
            let worker = try EmbeddingWorker(config, textOnly: true)
            encoder = worker
            log("encoder: ready in \(ms(since: started)) (model load and warm-up \(worker.info.loadSeconds ?? 0) s)")
            update { $0.encoder = .ready }
            return worker
        } catch {
            encoderFailed = true
            log("encoder: can't start: \(error)")
            update { $0.encoder = .unavailable }
            return nil
        }
    }

    /// The encoder exits after `encoderIdleSeconds` without a query (its ~0.25 GB goes back to the system), and the
    /// vectors go with it; keyword search keeps working, and the next panel open brings both back.
    private func scheduleIdleExit() {
        encoderIdleExit?.cancel()
        let exit = DispatchWorkItem { [self] in
            guard encoder != nil else { return }
            log("encoder: idle for \(Int(encoderIdleSeconds)) s, stopping")
            stopEncoder()
            searchQueue.async { [self] in
                searcher?.releaseVectors()
                codeSearcher?.releaseVectors()
                returnFreedMemory()
            }
        }
        encoderIdleExit = exit
        encoderQueue.asyncAfter(deadline: .now() + encoderIdleSeconds, execute: exit)
    }

    private func stopEncoder() {
        encoder?.close()
        encoder = nil
        vectorCache.removeAll()
        encoderIdleExit?.cancel()
        encoderIdleExit = nil
        update { $0.encoder = .stopped }
    }
}

/// Recent query vectors by text: retyping or going back to an earlier query costs nothing.
nonisolated struct QueryVectorCache {
    let limit: Int
    private var vectors: [String: Engine.QueryVector] = [:]
    private var order: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    subscript(text: String) -> Engine.QueryVector? {
        get { vectors[text] }
        set {
            guard let newValue else { return }
            if vectors.updateValue(newValue, forKey: text) == nil { order.append(text) }
            if order.count > limit { vectors[order.removeFirst()] = nil }
        }
    }

    mutating func removeAll() {
        vectors = [:]
        order = []
    }
}

/// Hands pages that malloc has freed back to the OS. A crawl or an indexing batch leaves megabytes of freed but still
/// dirty pages, which count against the app's footprint until something else asks for memory.
nonisolated func returnFreedMemory() {
    malloc_zone_pressure_relief(nil, 0)
}

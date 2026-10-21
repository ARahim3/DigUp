import DigUpKit
import Foundation
import LlamaRuntime

// DigUp's developer CLI. Every command works on an explicit index folder, so tests never touch the real one.

#if !os(Windows)
signal(SIGPIPE, SIG_IGN)   // a dead worker must surface as an error, not kill us (Windows has no SIGPIPE)
#endif

let usage = """
    digup: search your files by meaning (DigUp developer CLI)

      digup estimate <folder>... [--json]     what would be indexed, and how long the first pass takes
      digup index <folder>... [--limit N]     sync the index with these folders, embed what's new, then the rest
                                              of long PDFs and documents
      digup search <words>... [--kind K,K] [-n 10] [--json]
                                              "code: <words>" searches the code index
      digup status                            what's in the index
      digup speed [--model [--if-needed] [--when-quiet S] [--tries N]] [--json]
                                              this machine's speed next to the M4 Pro behind the estimates, and
                                              what indexing has measured here (costs.json in the index folder);
                                              --model times the model itself (Linux and Windows) and keeps it
      digup eval <queries.json> [-n 10]       recall of known answers (see evals/; "code: …" queries search code)
      digup index-service <folder>... [--code-root DIR]... [--code-exclude DIR]... [--backfill] [--prune]
                          [--memory-limit MB] [--time-limit S]
                                              the app's indexing helper (JSON lines; see IndexService); it stops
                                              on a file whose reading passes the limits (see Watchdog)
      digup worker [--text-only]              the model as a process (JSON lines; the app's query encoder)
      digup search-service <folder>... [--code-root DIR]... [--encoder-idle S]
                                              the searcher as a process, index open and encoder warm (JSON lines;
                                              see SearchService): for shells that can't link DigUpKit
      digup download-model [--to DIR]         the model files, from the Hugging Face cache or downloaded with
                                              resume, checked (JSON lines: see DownloadModel)

    Options:
      --index DIR          index folder (default: DigUp's Application Support folder; see `digup status`)
      --code               estimate, index or show the code index of these folders (code.sqlite in the index
                           folder): source files, their repos' docs and notebooks, minus what git ignores
      --kind K,K           screenshot, image, pdf, doc, audio, video
      --include-code       also index loose source code and data files as documents (outside code projects)
      --include-datasets   don't skip folders that look like datasets
      --exclude DIR        don't index this folder (repeatable)
      --exclude-ext EXT    don't index files with this extension (repeatable, or comma-separated: "heic,txt")
      --reindex            drop vectors and embed everything again (after changing settings or model)
      --zgate Z            how far a meaning match must stand out (default 2.0)
      --word-weight W      bonus for containing all of the query's words (default 2.0, and for code see Searcher)
      --shot-tokens N      vision tokens per screenshot (default 280; 560 was 2× slower, no better on real shots)
      --code-stretch N     characters a stretch of code holds at most (default 1800; 1200 and 3600 lost on the evals)

    The model: EmbeddingGemma 2 on llama.cpp, from $DIGUP_MODELS (only there, when set), else
    ~/Library/Application Support/DigUp/Models or the Hugging Face cache. DIGUP_WORKER_DIR=worker uses the
    mlx-vlm reference worker instead (evals).
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    var positional: [String] = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["--index", "--limit", "--kind", "-n", "--zgate", "--word-weight", "--new-limit",
                                      "--linger", "--shot-tokens", "--code-stretch", "--encoder-idle", "--to",
                                      "--memory-limit", "--time-limit", "--tries", "--when-quiet"]
    static let repeated: Set<String> = ["--exclude", "--exclude-ext", "--code-root", "--code-exclude"]

    init(_ raw: ArraySlice<String>) throws {
        var index = raw.startIndex
        while index < raw.endIndex {
            let argument = raw[index]
            if Self.valued.contains(argument) || Self.repeated.contains(argument) {
                guard index + 1 < raw.endIndex else { throw CLIError("\(argument) needs a value") }
                if Self.repeated.contains(argument) {
                    lists[argument, default: []].append(raw[index + 1])
                } else {
                    values[argument] = raw[index + 1]
                }
                index += 2
            } else if argument.hasPrefix("--") || argument == "-h" {
                flags.insert(argument)
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    var indexFolder: URL {
        guard let chosen = values["--index"] else { return AppPaths.defaultIndex.standardizedFileURL }
        return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// `--code`: the code index, not the main one.
    var code: Bool { flags.contains("--code") }

    func store() throws -> IndexStore {
        try IndexStore(directory: indexFolder, file: code ? IndexStore.codeFile : IndexStore.mainFile)
    }

    var options: IndexOptions {
        var options = IndexOptions()
        options.code = code
        options.includeCode = flags.contains("--include-code")
        options.includeDatasets = flags.contains("--include-datasets")
        options.excludedFolders = (lists["--exclude"] ?? []).map { Self.folderURL($0).path }
        options.excludedExtensions = IndexOptions.extensions((lists["--exclude-ext"] ?? []).joined(separator: ","))
        if let tokens = values["--shot-tokens"].flatMap(Int.init) { options.screenshotBudget = tokens }
        if let characters = values["--code-stretch"].flatMap(Int.init) { options.codeStretch = characters }
        return options
    }

    func folders() throws -> [URL] {
        guard !positional.isEmpty else { throw CLIError("which folders? e.g. digup index ~/DigUpTestbed") }
        return try positional.map {
            let url = Self.folderURL($0)
            guard Self.isFolder(url) else { throw CLIError("not a folder: \($0)") }
            guard Self.isReadable(url) else { throw CLIError("can't read \($0) (macOS privacy settings?)") }
            return url
        }
    }

    static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The folder can be opened for listing. One that macOS won't let us read (Files and Folders privacy) looks empty
    /// to a crawl, which must never be mistaken for "everything in it was deleted". (The first look may bring up
    /// macOS's prompt.) Opening, not listing: a cloud folder's top level can take a while to list, at every sync.
    static func isReadable(_ url: URL) -> Bool { Crawler.canList(url) }

    /// Dev knobs for A/B runs in evals/.
    var zGate: Double { values["--zgate"].flatMap(Double.init) ?? 2.0 }
    var wordWeight: Double? { values["--word-weight"].flatMap(Double.init) }   // nil: the index's own (`Searcher`)

    func kinds() throws -> Set<FileKind>? {
        guard let list = values["--kind"] else { return nil }
        return Set(try list.split(separator: ",").map {
            guard let kind = FileKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) else {
                throw CLIError("unknown kind \($0); use screenshot, image, pdf, doc, audio, video")
            }
            return kind
        })
    }
}

// MARK: Formatting

let home = FileManager.default.homeDirectoryForCurrentUser.path
func tilde(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }
func number(_ value: Int) -> String { value.formatted(.number) }

func duration(_ seconds: Double) -> String {
    switch seconds {
    case ..<90: "\(Int(seconds.rounded())) s"
    case ..<5400: "\(Int((seconds / 60).rounded())) min"
    default: String(format: "%.1f h", seconds / 3600)
    }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%d:%02d", total / 60, total % 60)
}

func location(_ hit: SearchHit) -> String {
    switch hit.segment {
    case .page, .pageImage: hit.loc.map { "p. \(Int($0))" } ?? ""
    case .audio, .frame: hit.loc.map { "at \(clock($0))" + (hit.segment == .audio ? " (sound)" : "") } ?? ""
    case .chunk: hit.loc.map { "part \(Int($0))" } ?? ""
    case .lines: hit.loc.map { "lines \(Int($0))–\(Int(hit.locEnd ?? $0))" + (hit.focus.map { ", opens at \(Int($0))" } ?? "") } ?? ""
    case .cells: hit.loc.map { $0 == hit.locEnd ? "cell \(Int($0))" : "cells \(Int($0))–\(Int(hit.locEnd ?? $0))" } ?? ""
    case .ocr: "text in image"
    default: ""
    }
}

func skippedLine(_ skipped: [String: Int]) -> String {
    skipped.sorted { $0.value > $1.value }.map { "\(number($0.value)) \($0.key)" }.joined(separator: " · ")
}

// MARK: Commands

/// The embedding runtime: llama.cpp in this process, or the worker in $DIGUP_WORKER_DIR (the mlx-vlm reference).
func makeEmbedder(textOnly: Bool, log: URL, qos: QualityOfService = .default) throws -> any Embedder {
    if var config = try WorkerConfig.fromEnvironment() {
        config.log = log
        config.qos = qos
        return try EmbeddingWorker(config, textOnly: textOnly)
    }
    return try LlamaEmbedder(models: try LlamaModels.locate(), textOnly: textOnly, log: log)
}

/// `makeEmbedder`'s vector source when it's known without starting it: llama.cpp's always is.
func embedderSource() -> String? {
    ProcessInfo.processInfo.environment["DIGUP_WORKER_DIR"] == nil ? LlamaEmbedder.modelInfo.vectorSource : nil
}

func estimate(_ args: Arguments) throws {
    guard !args.positional.isEmpty else { throw CLIError("which folders? e.g. digup estimate ~/Documents") }
    let options = args.options
    // What indexing costs on this machine: as measured by indexing here, kind by kind, once there's enough of it;
    // until then the M4 Pro's fixed costs, scaled by a second's speed check (done once and kept beside the index).
    var measured = MeasuredCosts.load(from: args.indexFolder)
    if measured.speed == nil, let speed = MeasuredCosts.Speed.measure() {
        measured.speed = speed
        MeasuredCosts.setSpeed(speed, in: args.indexFolder)
    }
    let costs = measured.costs
    // The times are this machine's (a speed check or indexing measured it); off the Mac, before `digup speed --model`
    // has run, they're the M4 Pro's, far too short for most PCs.
    let calibrated = measured.speed != nil || !measured.tallies.isEmpty
    var total = 0.0
    for folder in args.positional.map(Arguments.folderURL) {
        // One folder that isn't there or can't be read (a denied privacy prompt) mustn't sink the others.
        guard Arguments.isFolder(folder), Arguments.isReadable(folder) else {
            if args.flags.contains("--json") {
                emit(["folder": folder.path, "readable": false, "seconds": 0, "files": [String: Int](),
                      "pdf_pages": 0, "audio_seconds": 0, "video_seconds": 0])
            } else {
                print("\(tilde(folder.path))    can't read it (not there, or not allowed in macOS privacy settings)")
            }
            continue
        }
        let started = Date()
        let crawl = Crawler.crawl([folder], options: options)
        let parts = Estimator.estimates(bySubfolder: crawl.candidates, of: folder.path, options: options, costs: costs)
        let estimate = parts.values.reduce(Estimate(), +)
        // Biggest first; the app lists them under the folder, so that a long first pass can be cut down.
        let subfolders = parts.filter { $0.key != folder.path }.sorted {
            $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key
        }
        total += estimate.seconds
        if args.flags.contains("--json") {
            func files(_ estimate: Estimate) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: estimate.files.map { ($0.key.rawValue, $0.value) })
            }
            // One line per folder, as soon as it's done (the app's onboarding shows them as they come).
            emit(["folder": folder.path, "seconds": estimate.seconds, "readable": true, "files": files(estimate),
                  "kind_seconds": Dictionary(uniqueKeysWithValues: estimate.kindSeconds.map { ($0.key.rawValue, $0.value) }),
                  "calibrated": calibrated,
                  "pdf_pages": estimate.pdfPages, "pdf_pages_total": estimate.pdfPagesTotal,
                  "audio_seconds": estimate.audioSeconds, "video_seconds": estimate.videoSeconds,
                  "long_files": estimate.longFiles, "later_seconds": estimate.laterSeconds,
                  "code_stretches": estimate.codeStretches, "bytes": estimate.bytes,
                  "subfolders": subfolders.prefix(500).map {
                      ["folder": $0.key, "seconds": $0.value.seconds, "files": files($0.value),
                       "kind_seconds": Dictionary(uniqueKeysWithValues: $0.value.kindSeconds.map { ($0.key.rawValue, $0.value) }),
                       "long_files": $0.value.longFiles, "later_seconds": $0.value.laterSeconds,
                       "bytes": $0.value.bytes] as [String: Any]
                  },
                  "skipped": crawl.skipped.values.reduce(0, +), "left_out": crawl.skipped, "datasets": crawl.datasets.count,
                  "ms": Int(Date().timeIntervalSince(started) * 1000)])
            continue
        }
        var kinds: [String] = []
        for kind in FileKind.allCases {
            guard let count = estimate.files[kind], count > 0 else { continue }
            switch kind {
            case .pdf: kinds.append("\(number(count)) PDFs (\(number(estimate.pdfPagesTotal)) pages; \(number(estimate.pdfPages)) in the first pass)")
            case .audio: kinds.append("\(number(count)) audio (\(duration(estimate.audioSeconds)))")
            case .video: kinds.append("\(number(count)) video (\(duration(estimate.videoSeconds)))")
            case .code: kinds.append("\(number(count)) code \(count == 1 ? "file" : "files") "
                                     + "(\(number(estimate.codeStretches)) stretches)")
            default: kinds.append("\(number(count)) \(kind.rawValue)\(count == 1 ? "" : "s")")
            }
        }
        print("\(tilde(folder.path))    first index ≈ \(duration(estimate.seconds))"
              + (args.code ? ", index ≈ \(ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file))" : ""))
        print("  " + (kinds.isEmpty ? "nothing to index" : kinds.joined(separator: " · ")))
        if estimate.longFiles > 0 {
            print("  then the rest of \(number(estimate.longFiles)) long \(estimate.longFiles == 1 ? "file" : "files") "
                  + "≈ \(duration(estimate.laterSeconds))")
        }
        if !subfolders.isEmpty {
            print("  biggest subfolders: " + subfolders.prefix(5).map {
                "\(($0.key as NSString).lastPathComponent) ≈ \(duration($0.value.seconds))"
            }.joined(separator: " · ") + (subfolders.count > 5 ? " · \(subfolders.count - 5) more" : ""))
        }
        if !crawl.skipped.isEmpty { print("  skipped: " + skippedLine(crawl.skipped)) }
        if !crawl.skippedFolders.isEmpty { print("  folders not walked: " + skippedLine(crawl.skippedFolders)) }
        for (folder, count) in crawl.datasets.sorted(by: { $0.value > $1.value }) {
            print("  looks like a dataset (skipped): \(tilde(folder)) (\(number(count)) files)")
        }
        print(String(format: "  (looked at it in %.2f s)", Date().timeIntervalSince(started)))
    }
    if args.positional.count > 1, !args.flags.contains("--json") { print("all together ≈ \(duration(total))") }
}

func index(_ args: Arguments) throws {
    let store = try args.store()
    if args.flags.contains("--reindex") { try store.resetAll() }
    let indexer = try Indexer(store: store, options: args.options, makeEmbedder: {
        try makeEmbedder(textOnly: false, log: store.directory.appendingPathComponent("worker.log"))
    })
    indexer.embedderSource = embedderSource()
    indexer.costsFolder = store.directory
    try store.readAgainOnce()   // what older indexes couldn't read: scanned pages' words, SVGs
    try indexer.checkModel()
    let folders = try args.folders()
    let sync = try indexer.sync(folders)
    print("index: \(tilde(store.file.path))")
    print("sync: \(sync.added) new · \(sync.changed) changed · \(sync.moved) moved · \(sync.removed) removed · \(sync.unchanged) unchanged")
    if !sync.crawl.skipped.isEmpty { print("skipped: " + skippedLine(sync.crawl.skipped)) }
    for (folder, count) in sync.crawl.datasets { print("looks like a dataset (skipped): \(tilde(folder)) (\(number(count)) files)") }

    let limit = args.values["--limit"].flatMap(Int.init)
    var started = Date()
    let states = try indexer.run(limit: limit, onEvent: { event in
        let name = (event.path as NSString).lastPathComponent
        let note = event.note.map { "  (\($0))" } ?? ""
        print("[\(lpad("\(event.done)", 4))/\(event.total)] \(pad(event.kind.rawValue, 10)) \(pad(event.state, 7)) "
              + String(format: "%5.2fs  ", event.seconds) + name + note)
    })
    if states.isEmpty {
        print("nothing pending")
    } else {
        print("done in \(duration(Date().timeIntervalSince(started))): " + statesLine(states))
    }
    // The rest of long files, as the app does once nothing is pending (not after a --limit run: things still are).
    guard limit == nil, try store.unfinishedCount().files > 0 else { return }
    started = Date()
    let finished = try indexer.finishLongFiles(onStep: { step in
        let name = (step.path as NSString).lastPathComponent
        let note = step.note.map { "  (\($0))" } ?? ""
        print("[rest \(lpad("\(step.done)", 5))/\(step.total)] \(pad(step.kind.rawValue, 4)) \(pad(step.state, 7)) "
              + String(format: "%5.2fs  ", step.seconds) + name + note)
    })
    print("the rest of long files in \(duration(Date().timeIntervalSince(started))): "
          + (finished.isEmpty ? "none finished" : statesLine(finished)))
}

func statesLine(_ states: [String: Int]) -> String {
    states.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
}

/// Embeds queries with the text model alone (0.3B params, ~0.25 GB): the query encoder. `prompt`: the search's
/// (`Prompts.query`, or `Prompts.codeQuery` for the code index).
func queryVectors(_ queries: [String], store: IndexStore, searcher: Searcher,
                  prompt: (String) -> String = Prompts.query) throws -> [[Float]]? {
    guard searcher.vectorCount > 0, !queries.isEmpty else { return nil }
    let worker = try makeEmbedder(textOnly: true, log: store.directory.appendingPathComponent("worker-query.log"))
    defer { worker.close() }
    if let source = searcher.vectorSource, source != worker.info.vectorSource {
        throw CLIError("index vectors come from \(source) but the query encoder is \(worker.info.vectorSource)")
    }
    return try worker.embedTexts(queries.map(prompt))
}

func search(_ args: Arguments) throws {
    var query = args.positional.joined(separator: " ")
    guard !query.isEmpty else { throw CLIError("search for what?") }
    let code = CodeQuery.text(of: query)
    if let code { query = code }
    guard !query.isEmpty else { throw CLIError("search the code for what?") }
    let store = try IndexStore(directory: args.indexFolder, file: code == nil ? IndexStore.mainFile : IndexStore.codeFile)
    let searcher = try Searcher(store: store)
    let started = Date()
    let vector = try queryVectors([query], store: store, searcher: searcher,
                                  prompt: code == nil ? Prompts.query : Prompts.codeQuery)?.first
    let encoded = Date()
    let hits = try searcher.search(query, queryVector: vector, kinds: try args.kinds(),
                                   limit: args.values["-n"].flatMap(Int.init) ?? 10, zGate: args.zGate,
                                   wordWeight: args.wordWeight)
    let searched = Date()
    if args.flags.contains("--json") {
        let rows = hits.map(hitFields)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "[]")
        return
    }
    if hits.isEmpty { print("no good matches") }
    for (rank, hit) in hits.enumerated() {
        let why = [hit.z.map { String(format: "z %.1f", $0) }, hit.keywordRank.map { "words #\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let place = location(hit)
        print("\(lpad("\(rank + 1)", 2)). \(pad(hit.kind.rawValue, 10)) \((hit.path as NSString).lastPathComponent)"
              + (place.isEmpty ? "" : "  [\(place)]") + "   (\(why))")
        print("      \(tilde((hit.path as NSString).deletingLastPathComponent))")
        if let excerpt = hit.excerpt, !excerpt.isEmpty { print("      “\(excerpt.prefix(160))”") }
    }
    print(String(format: "(%d vectors · query encoder %.2f s incl. start-up · search %.0f ms)", searcher.vectorCount,
                 encoded.timeIntervalSince(started), searched.timeIntervalSince(encoded) * 1000))
}

func status(_ args: Arguments) throws {
    let store = try args.store()
    let counts = try store.counts()
    print("index: \(tilde(store.file.path))")
    print("vectors: \(number(counts.vectors)) in \(number(counts.segments)) segments")
    for kind in FileKind.allCases {
        guard let states = counts.byKindAndState[kind.rawValue] else { continue }
        let total = states.values.reduce(0, +)
        print("  \(pad(kind.rawValue, 11)) \(lpad(number(total), 6))   " + statesLine(states))
    }
    if counts.unfinished > 0 {
        print("long files still being read: \(number(counts.unfinished)) (\(number(counts.left)) pages and chunks left)")
    }
    if let fingerprint = try store.meta("fingerprint") { print("built with: \(fingerprint)") }
    print("this digup: llama.cpp \(LlamaEmbedder.buildTag), vectors \(LlamaEmbedder.vectorVersion)")
    print("size: \(ByteCountFormatter.string(fromByteCount: IndexStore.size(of: store.file), countStyle: .file))")
}

/// The app's indexing helper: sync + index on request, JSON events out (IndexService.swift).
func indexService(_ args: Arguments) throws -> Int32 {
    // One model for both indexes, started when the first file needs it (`SharedEmbedder`).
    let model = SharedEmbedder {
        try makeEmbedder(textOnly: false, log: args.indexFolder.appendingPathComponent("worker.log"), qos: .utility)
    }
    func part(_ file: String, options: IndexOptions, roots: [URL]) throws -> IndexService.Part {
        let store = try IndexStore(directory: args.indexFolder, file: file)
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { try model.embedder() })
        indexer.costsFolder = args.indexFolder   // what indexing costs here, for later estimates
        // A new app version may bring a new model: the index starts over by itself (keyword search on names goes on).
        indexer.embedderSource = embedderSource()
        indexer.resetOnModelChange = { indexed, now in
            emit(["event": "reindex", "from": indexed, "to": now, "code": options.code])
        }
        // A chosen folder that isn't there now (an unplugged drive) is skipped, not an error, and its files stay
        // indexed. With --prune, files under none of the given folders leave the index (the app passes all its folders).
        return IndexService.Part(store: store, indexer: indexer, roots: roots,
                                 keepOnly: args.flags.contains("--prune") ? roots : nil)
    }
    var codeOptions = args.options
    codeOptions.code = true
    codeOptions.excludedFolders = (args.lists["--code-exclude"] ?? []).map { Arguments.folderURL($0).path }
    let codeRoots = (args.lists["--code-root"] ?? []).map(Arguments.folderURL)
    // A file whose reading runs away ends this helper, noted for the next one (`Watchdog`).
    Watchdog(folder: args.indexFolder,
             memoryLimit: args.values["--memory-limit"].flatMap(UInt64.init).map { $0 << 20 } ?? Watchdog.defaultMemoryLimit,
             timeLimit: args.values["--time-limit"].flatMap(Double.init) ?? Watchdog.defaultTimeLimit).start()
    let service = IndexService(main: try part(IndexStore.mainFile, options: args.options,
                                              roots: args.positional.map(Arguments.folderURL)),
                               code: codeRoots.isEmpty ? nil : try part(IndexStore.codeFile, options: codeOptions,
                                                                        roots: codeRoots),
                               folder: args.indexFolder,
                               model: model,
                               modelReady: { embedderSource() == nil || LlamaModels.complete },
                               backfill: args.flags.contains("--backfill"),
                               newFilesLimit: args.values["--new-limit"].flatMap(Int.init) ?? 50,
                               linger: args.values["--linger"].flatMap(Double.init) ?? 60)
    return service.serve()
}

/// `digup speed`: the speed check estimates start from, and what indexing has measured on this machine. `--model`
/// times the model itself instead (`ModelSpeed`: Linux and Windows) and keeps the result beside the index.
func speed(_ args: Arguments) throws {
    if args.flags.contains("--model") { return try modelSpeed(args) }
    if let seconds = MeasuredCosts.Speed.measuredSeconds() {
        let speed = MeasuredCosts.Speed.compared(seconds)
        print(String(format: "20 float16 matrix multiplies (2048²) %.3f s · Vision on a made-up screenshot %.3f s",
                     seconds.multiplies, seconds.ocr))
        print(String(format: "next to the M4 Pro behind the fixed costs: the model's work ×%.2f, OCR ×%.2f (1 = as fast)",
                     speed.embedding, speed.ocr))
    } else {
        print("no speed check here (no Metal): the fixed costs stand in until indexing has measured this machine's")
    }
    let measured = MeasuredCosts.load(from: args.indexFolder)
    print("measured by indexing (\(tilde(MeasuredCosts.file(in: args.indexFolder).path))):"
          + (measured.tallies.isEmpty ? " nothing yet" : ""))
    for (name, tally) in measured.tallies.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %@ %.4f s each, over %.0f", name, tally.seconds / tally.units, tally.units))
    }
}

/// The model timed on the processor alone, in a process of its own (llama.cpp loads its backends once a process), with
/// the vectors it made, and how long it took to load.
func processorAlone(folder: URL, tries: Int) throws -> (measured: ModelSpeed.Measurement, load: Double) {
    guard let program = Bundle.main.executableURL else { throw CLIError("where is digup?") }
    let process = Process()
    process.executableURL = program
    process.arguments = ["speed", "--model", "--measure-only", "--json", "--tries", String(tries), "--index", folder.path]
    process.environment = ProcessInfo.processInfo.environment.merging(["DIGUP_DEVICE": "cpu"]) { $1 }
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    guard process.terminationStatus == 0,
          let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let seconds = reply["seconds"] as? [String: Double], let load = reply["load"] as? Double,
          let times = ModelSpeed.Times(fields: seconds)
    else { throw CLIError("the processor's speed check failed") }
    let vectors = (reply["vectors"] as? [String: [Double]] ?? [:]).mapValues { $0.map(Float.init) }
    return (ModelSpeed.Measurement(times: times, vectors: vectors, tries: reply["tries"] as? [Double] ?? [],
                                   steady: reply["steady"] as? Bool ?? true, others: reply["others"] as? Double ?? 0),
            load)
}

/// `digup speed --model [--if-needed] [--when-quiet S] [--tries N] [--json]`: the model timed on this machine, kept in
/// costs.json beside the index for estimates. Where there's a GPU it's timed against the processor alone, and the
/// faster is kept (`device`) for every helper: a weak integrated GPU can be slower than its processor (an i5-8350U's
/// UHD 620 under Vulkan: 76 s against 44 s). The GPU is kept only if its vectors are the processor's too (cosine 0.999,
/// as ReferenceVectorTests asks): Mesa's lavapipe made pictures and sound at 0.94–0.97. The processor goes first, so a
/// GPU that's clearly slower stops after two tries.
///
/// One check was timed at a bad moment (an RTX 4050 laptop taken for 30 times slower than its indexing went), so
/// `--when-quiet` waits up to S seconds for other programs to settle, each input's time is the best of up to `--tries`
/// (3), and a check with reason for doubt (its best try wasn't seen twice, or indexing went four times faster than it
/// said) is timed again by the next `--if-needed`, up to three checks. A machine that never settled isn't a reason by
/// itself: the same laptop kept 1.3 processors busy with other work through a whole minute, and its check came out
/// right (steady tries, the GPU's times as timed by hand). `--if-needed` otherwise leaves one measured before alone, unless it predates the GPU's choice.
/// The shell runs it once the model is in. `--measure-only`: the times, nothing kept (the processor's run).
func modelSpeed(_ args: Arguments) throws {
    let folder = args.indexFolder
    let json = args.flags.contains("--json")
    let tries = args.values["--tries"].flatMap(Int.init) ?? 3
    let log = folder.appendingPathComponent("worker.log")
    if args.flags.contains("--measure-only") {
        let started = Date()
        let model = try makeEmbedder(textOnly: false, log: log)
        let load = Date().timeIntervalSince(started)
        let measured = try ModelSpeed.measure(model, tries: tries)
        model.close()
        emit(["event": "speed", "seconds": measured.times.fields, "load": load, "vectors": measured.vectors,
              "tries": measured.tries, "steady": measured.steady, "others": measured.others])
        return
    }
    let saved = MeasuredCosts.load(from: folder)
    var speed = saved.speed ?? MeasuredCosts.Speed(embedding: 1, ocr: 1)
    let compares = !LlamaEmbedder.cpuOnly && LlamaEmbedder.hasGPU && embedderSource() != nil
    let checks = speed.kinds == nil ? 0 : speed.checks ?? 1
    let again = checks < 3 && (speed.doubtful == true || saved.pace.map { $0 < 0.25 } == true)
    if args.flags.contains("--if-needed"), let kinds = speed.kinds, speed.device != nil || !compares, !again {
        if json { emit(["event": "speed", "kinds": kinds, "measured": false]) }
        return
    }
    let quiet = args.values["--when-quiet"].flatMap(Double.init).map { SystemLoad.waitForQuiet(limit: $0) }
        ?? (waited: 0, settled: true, calmest: nil)
    let started = Date()
    let alone = compares ? try processorAlone(folder: folder, tries: tries) : nil
    let loading = Date()
    let model = try makeEmbedder(textOnly: false, log: log)
    var load = Date().timeIntervalSince(loading)
    let measured = try ModelSpeed.measure(model, tries: tries, rival: alone?.measured.total)
    model.close()
    var (kept, other) = (measured, alone?.measured)
    var compared: [String: Any] = [:]
    if let alone {
        let agreement = ModelSpeed.agreement(measured.vectors, alone.measured.vectors)
        func fields(_ run: ModelSpeed.Measurement, load: Double) -> [String: Any] {
            ["seconds": run.times.fields, "load": load, "tries": run.tries, "steady": run.steady, "others": run.others]
        }
        compared = ["gpu": fields(measured, load: load), "cpu": fields(alone.measured, load: alone.load),
                    "agreement": agreement]
        speed.device = agreement >= 0.999 && measured.total <= alone.measured.total ? "gpu" : "cpu"
        if speed.device == "cpu" { (kept, other, load) = (alone.measured, measured, alone.load) }
    }
    // Close times from a run whose best wasn't seen twice could have gone the other way. (Other programs' work while it
    // timed isn't a reason: with every processor busy, the system's count and this process's differ by more than they
    // do, and a busy machine shows as tries that don't match.)
    let close = other.map { !$0.steady && $0.total < kept.total * 1.3 } ?? false
    speed.kinds = ModelSpeed.factors(kept.times)
    speed.checks = checks + 1
    speed.doubtful = !kept.steady || close ? true : nil
    // What indexing measured on the other device doesn't hold on this one.
    MeasuredCosts.setSpeed(speed, in: folder, forgetTallies: saved.speed?.device.map { $0 != speed.device } ?? false)
    let total = Date().timeIntervalSince(started)
    if json {
        var fields: [String: Any] = ["event": "speed", "kinds": speed.kinds ?? [:], "seconds": kept.times.fields,
                                     "load": load, "total": total, "measured": true, "tries": kept.tries,
                                     "others": kept.others, "waited": quiet.waited, "settled": quiet.settled,
                                     "doubtful": speed.doubtful ?? false, "checks": checks + 1]
        if let calmest = quiet.calmest { fields["calmest"] = calmest }
        if let device = speed.device { fields["device"] = device }
        fields.merge(compared) { $1 }
        emit(fields)
        return
    }
    if quiet.waited > 0 {
        print(String(format: "waited %.0f s for other programs to settle%@", quiet.waited, quiet.settled ? "" : " (they didn't)"))
    }
    if let device = speed.device { print("runs on the \(device == "cpu" ? "processor (faster here than the GPU)" : "GPU")") }
    print(String(format: "the model loaded in %.2f s; the check took %.1f s; tries %@", load, total,
                 kept.tries.map { String(format: "%.2f s", $0) }.joined(separator: ", ")))
    for (name, seconds) in kept.times.fields.sorted(by: { $0.key < $1.key }) {
        let base = ModelSpeed.baseline.fields[name] ?? seconds
        print(String(format: "  %@ %.3f s (M4 Pro %.3f s, ×%.1f)", name, seconds, base, seconds / base))
    }
    if speed.doubtful == true { print("in doubt (a busy moment): timed again at the next --if-needed") }
    print("kept in \(tilde(MeasuredCosts.file(in: folder).path)): " + (speed.kinds ?? [:]).sorted { $0.key < $1.key }
        .map { String(format: "%@ ×%.1f", $0.key, $0.value) }.joined(separator: " · "))
}

// MARK: Eval

struct EvalFile: Decodable {
    struct Query: Decodable {
        let q: String
        let expect: [String]   // paths relative to `base`; "path@6-12" also requires the hit to start in [6, 12) s
        let tag: String?
        let kind: String?
    }
    let base: String
    let queries: [Query]
}

func evaluate(_ args: Arguments) throws {
    guard let file = args.positional.first else { throw CLIError("which eval file?") }
    let eval = try JSONDecoder().decode(EvalFile.self, from: Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)))
    var base = (eval.base as NSString).expandingTildeInPath
    // The testbed kept elsewhere (another drive on Windows, wherever CI puts it): DIGUP_TESTBED stands for
    // ~/DigUpTestbed in the eval's base.
    if let testbed = ProcessInfo.processInfo.environment["DIGUP_TESTBED"], eval.base.hasPrefix("~/DigUpTestbed") {
        base = testbed + eval.base.dropFirst("~/DigUpTestbed".count)
    }
    // "code: …" queries search the code index (with its prompt), the others the main one.
    let isCode = eval.queries.map { CodeQuery.text(of: $0.q) != nil }
    let texts = eval.queries.map { CodeQuery.text(of: $0.q) ?? $0.q }
    var searchers: [Bool: Searcher] = [:]
    var vectors = [[Float]?](repeating: nil, count: texts.count)
    for code in Set(isCode) {
        let store = try IndexStore(directory: args.indexFolder, file: code ? IndexStore.codeFile : IndexStore.mainFile)
        let searcher = try Searcher(store: store)
        searchers[code] = searcher
        let indices = texts.indices.filter { isCode[$0] == code }
        let embedded = try queryVectors(indices.map { texts[$0] }, store: store, searcher: searcher,
                                        prompt: code ? Prompts.codeQuery : Prompts.query)
        for (index, vector) in zip(indices, embedded ?? []) { vectors[index] = vector }
    }
    let depth = args.values["-n"].flatMap(Int.init) ?? 10

    var byTag: [String: (n: Int, at1: Int, at5: Int, at10: Int, mrr: Double)] = [:]
    var shown = 0, listed = 0, folded = 0   // the app's weaker-matches fold (Searcher.strongCount), over all queries
    for (index, query) in eval.queries.enumerated() {
        let kinds = query.kind.flatMap { FileKind(rawValue: $0) }.map { Set([$0]) }
        let hits = try searchers[isCode[index]]!.search(texts[index], queryVector: vectors[index], kinds: kinds,
                                                       limit: depth, zGate: args.zGate, wordWeight: args.wordWeight)
        let strong = Searcher.strongCount(hits)
        shown += strong
        listed += hits.count
        let targets: [(path: String, range: ClosedRange<Double>?)] = query.expect.map { entry in
            let parts = entry.split(separator: "@", maxSplits: 1)
            let range = parts.count == 2 ? parts[1].split(separator: "-").compactMap { Double($0) } : []
            return (base + "/" + parts[0], range.count == 2 ? range[0]...range[1] : nil)
        }
        // A place to be at: a page or moment starts in the range; a stretch of code overlaps it (its lines or cells).
        func at(_ hit: SearchHit, _ range: ClosedRange<Double>) -> Bool {
            guard let loc = hit.loc else { return false }
            if hit.segment == .lines || hit.segment == .cells { return loc <= range.upperBound && (hit.locEnd ?? loc) >= range.lowerBound }
            return range.contains(loc)
        }
        let rank = hits.firstIndex { hit in
            targets.contains { target in
                hit.path == target.path && (target.range.map { at(hit, $0) } ?? true)
            }
        }.map { $0 + 1 }
        if let rank, rank > strong { folded += 1 }
        let tag = query.tag ?? "all"
        for key in Set([tag, "ALL"]) {
            var row = byTag[key] ?? (0, 0, 0, 0, 0)
            row.n += 1
            if let rank {
                if rank <= 1 { row.at1 += 1 }
                if rank <= 5 { row.at5 += 1 }
                if rank <= 10 { row.at10 += 1 }
                row.mrr += 1 / Double(rank)
            }
            byTag[key] = row
        }
        let top = hits.first.map { "\(($0.path as NSString).lastPathComponent)" + (location($0).isEmpty ? "" : " [\(location($0))]") } ?? "-"
        print("\(rank.map { lpad("#\($0)", 4) } ?? "miss")  \(pad(tag, 11)) \(pad("“\(query.q)”", 42)) top: \(top)")
    }
    print("")
    print("\(pad("tag", 12)) \(lpad("n", 3))  \(lpad("R@1", 5))  \(lpad("R@5", 5))  \(lpad("R@10", 5))  \(lpad("MRR", 5))")
    for (tag, row) in byTag.sorted(by: { ($0.key == "ALL" ? "~" : $0.key) < ($1.key == "ALL" ? "~" : $1.key) }) {
        let n = Double(row.n)
        print("\(pad(tag, 12)) \(lpad("\(row.n)", 3))  " + String(format: "%5.2f  %5.2f  %5.2f  %5.2f",
              Double(row.at1) / n, Double(row.at5) / n, Double(row.at10) / n, row.mrr / n))
    }
    let count = Double(max(1, eval.queries.count))
    print(String(format: "weaker-matches fold (below 0.5× the top score): %.1f of %.1f results shown per query; ",
                 Double(shown) / count, Double(listed) / count)
          + "\(folded) expected \(folded == 1 ? "answer" : "answers") folded")
}

// MARK: Main

do {
    let raw = CommandLine.arguments.dropFirst()
    guard let command = raw.first, command != "-h", command != "--help", command != "help" else {
        print(usage)
        exit(0)
    }
    let args = try Arguments(raw.dropFirst())
    if ["index-service", "worker", "search-service", "download-model"].contains(command)
        || command == "estimate" && args.flags.contains("--json") {
        ParentWatch.start()   // an app's helper goes when the app does
    }
    // Where this machine's speed check found its processor faster than its GPU, the model runs on the processor.
    if command != "speed", MeasuredCosts.load(from: args.indexFolder).speed?.device == "cpu" {
        LlamaEmbedder.cpuOnly = true
    }
    #if !os(macOS)
    // Queries are a few words: the processor encodes one in hundredths of a second, and starts sooner than a GPU (an RTX
    // 4050 laptop: a search from scratch 1.8 s on its i7, 3.0 s on the GPU under Vulkan). Indexing keeps the GPU.
    if command == "search-service" {
        LlamaEmbedder.cpuOnly = true
    }
    #endif
    switch command {
    case "estimate": try estimate(args)
    case "index": try index(args)
    case "search": try search(args)
    case "status": try status(args)
    case "speed": try speed(args)
    case "eval": try evaluate(args)
    case "index-service":
        let status = try indexService(args)
        #if os(Linux)
        // glibc's exit() flushes the C streams under stdin's lock, which the command reader holds in readLine():
        // the helper would never end. Its events went straight to the file descriptor; nothing is left to flush.
        _exit(status)
        #else
        exit(status)
        #endif
    case "worker": exit(workerService(args))
    case "search-service": exit(try searchService(args))
    case "download-model": exit(try downloadModel(args))
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

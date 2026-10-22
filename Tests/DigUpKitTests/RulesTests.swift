import Foundation
import Testing
@testable import DigUpKit

@Suite struct RulesTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func typeScriptIsNotVideo() throws {
        let file = folder.appendingPathComponent("app.ts")
        try "export const x: number = 1;\n".write(to: file, atomically: false, encoding: .utf8)
        #expect(Rules.classify(file, values: nil, options: IndexOptions()) == .skip("code or data file"))
    }

    @Test func realTransportStreamIsVideo() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 4)
        for packet in 0..<4 { bytes[packet * 188] = 0x47 }
        let file = folder.appendingPathComponent("clip.ts")
        try Data(bytes).write(to: file)
        #expect(Rules.classify(file, values: nil, options: IndexOptions()) == .index(.video))
    }

    @Test func aPictureInAScreenshotsFolderIsAScreenshot() {
        #expect(Rules.isScreenshot(folder.appendingPathComponent("Screenshots/2026-02-10_10-10.png")))
        #expect(Rules.isScreenshot(folder.appendingPathComponent("screenshots/Screenshot_20260210_101010.png")))
        #expect(!Rules.isScreenshot(folder.appendingPathComponent("Pictures/2026-02-10_10-10.png")))
    }

    @Test func typstIsADocument() {
        let file = folder.appendingPathComponent("paper.typ")
        #expect(Rules.classify(file, values: nil, options: IndexOptions()) == .index(.doc))
    }

    @Test func foldersOpenForListingAndFilesDoNot() throws {
        #expect(Crawler.canList(folder))
        let file = folder.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: false, encoding: .utf8)
        #expect(!Crawler.canList(file))
        #expect(!Crawler.canList(folder.appendingPathComponent("missing")))
    }

    @Test func codeCanBeIncluded() {
        var options = IndexOptions()
        options.includeCode = true
        let file = folder.appendingPathComponent("main.py")
        #expect(Rules.classify(file, values: nil, options: options) == .index(.doc))
    }

    @Test func machineNames() {
        #expect(Rules.looksMachineNamed("clip_000123"))
        #expect(Rules.looksMachineNamed("frame-0042"))
        #expect(Rules.looksMachineNamed("3f9a1c0e-12ab-4cde"))
        #expect(Rules.looksMachineNamed("000123"))
        #expect(!Rules.looksMachineNamed("IMG_1234"))
        #expect(!Rules.looksMachineNamed("PXL_20260101_123456789"))
        #expect(!Rules.looksMachineNamed("20261021_143022"))
        #expect(!Rules.looksMachineNamed("2026-10-21 14.30.22"))
        #expect(!Rules.looksMachineNamed("20261021_143022(1)"))
        #expect(Rules.looksMachineNamed("20269921_143022"))
        #expect(!Rules.looksMachineNamed("Screenshot 2026-10-01 at 9.41.07 PM"))
        #expect(!Rules.looksMachineNamed("Tokyo itinerary"))
    }

    @Test func datasetNeedsManyMachineNamedFiles() {
        let clips = (0..<400).map { (folder: "/x/clips", stem: String(format: "clip_%06d", $0), kind: FileKind.audio) }
        let photos = (0..<400).map { (folder: "/x/camera", stem: "IMG_\(1000 + $0)", kind: FileKind.image) }
        let few = (0..<50).map { (folder: "/x/few", stem: "clip_\($0)", kind: FileKind.audio) }
        let phone = (0..<400).map { (folder: "/x/phone", stem: "20261021_\(100000 + $0)", kind: FileKind.image) }
        let datasets = Rules.datasetFolders(clips + photos + few + phone, roots: [])
        #expect(datasets == ["/x/clips": 400])
    }

    @Test func ftsQueryDropsStopwordsAndKindWords() {
        #expect(Searcher.ftsQuery("the screenshot of my payment error") == "\"payment\" OR \"error\"")
        #expect(Searcher.ftsQuery("zebr", prefixLast: true) == "\"zebr\"*")
        #expect(Searcher.ftsQuery("a screenshot") == nil)
    }

    @Test func chunksOverlapAndRespectWords() {
        let text = (1...600).map { "word\($0)" }.joined(separator: " ")
        let chunks = DocExtractor.chunks(text, size: 500, overlap: 100, limit: 100)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.allSatisfy { $0.hasPrefix("word") })   // never starts mid-word
        #expect(chunks.last?.hasSuffix("word600") == true)
    }

    @Test func htmlBecomesPlainText() {
        let html = """
            <html><head><title>T</title><style>p { color: red }</style></head>
            <body><h1>Trip &amp; plans</h1><p>Fly to <b>Tokyo</b>&nbsp;on Friday.</p><script>var x = 1;</script>
            <p>Caf&#233; &#x2014; ramen</p><!-- hidden --></body></html>
            """
        #expect(DocExtractor.plainText(fromHTML: html) == "Trip & plans\nFly to Tokyo on Friday.\nCafé — ramen")
    }

    @Test func halfVectorsConvertBackExactly() throws {
        let vector = (0..<Vectors.dimension).map { Float(sin(Double($0) * 0.37)) * 0.05 }
        let storage = try #require(VectorStorage(rows: 2))
        Vectors.half(vector).copyBytes(to: UnsafeMutableRawBufferPointer(start: storage.halves + Vectors.dimension,
                                                                         count: Vectors.dimension * 2))
        Vectors.floats(fromHalf: storage.halves, count: Vectors.dimension * 2, to: storage.block)
        let back = Array(UnsafeBufferPointer(start: storage.block + Vectors.dimension, count: Vectors.dimension))
        #expect(back == vector.map { Float(Float16($0)) })
        #expect(storage.block[0] == 0)   // fresh mmap'd memory is zeroed, and row 0 was left alone
    }

    @Test func meaningTakesOutEachModalitysLevelOnOneScale() {
        // Text scores sit higher than image scores here: that level comes out. The spread is shared, so a modality
        // whose scores are bunched up doesn't get its best ones inflated: 0.01 above average beats 0.002 above, 5:1.
        let text: [Float] = (0..<30).map { 0.70 + Float($0 % 3) * 0.01 }
        let image: [Float] = (0..<30).map { 0.55 + Float($0 % 3) * 0.002 }
        let scores = text + image
        let modality = Array(repeating: Modality.text, count: 30) + Array(repeating: Modality.image, count: 30)
        let z = Searcher.meaning(scores, modality)
        #expect(abs(z[1]) < 1e-4 && abs(z[31]) < 1e-4)   // 0.71 and 0.552: each at its modality's average
        #expect(abs(z[2] / z[32] - 5) < 0.01)
        let means = Searcher.modalityMeans(scores, modality)
        #expect(abs(means[.text]! - 0.71) < 0.001 && abs(means[.image]! - 0.552) < 0.001)
        #expect(abs(means[.audio]! - 0.631) < 0.001)   // no audio vectors: the average of all
    }

    @Test func laterPagesAreScoredWithoutMovingTheScale() {
        // A long book's later pages, far from the query, would pull the text average down and lift all text.
        let scores: [Float] = (0..<30).map { 0.70 + Float($0 % 3) * 0.01 } + (0..<30).map { 0.55 + Float($0 % 3) * 0.002 }
        let modality = Array(repeating: Modality.text, count: 30) + Array(repeating: Modality.image, count: 30)
        let book: [Float] = (0..<400).map { 0.60 + Float($0 % 5) * 0.004 } + [0.80]   // one page that matches
        let z = Searcher.meaning(scores, modality)
        let withBook = Searcher.meaning(scores + book, modality + Array(repeating: .text, count: book.count),
                                        setsScale: Array(repeating: true, count: 60) + Array(repeating: false, count: 401))
        for row in 0..<60 { #expect(abs(z[row] - withBook[row]) < 1e-9) }
        #expect(withBook.last! > z.max()!)   // the matching page stands out on the same scale
    }

    @Test func codesAndLongNumbersAreLookups() {
        #expect(Searcher.isLookup(["k7q2lm"]))
        #expect(Searcher.isLookup(["trx50"]))
        #expect(Searcher.isLookup(["4815162342"]))
        #expect(Searcher.isLookup(["2041"]))
        #expect(!Searcher.isLookup(["417"]))           // too short to be an ID
        #expect(!Searcher.isLookup(["inv", "2041"]))    // a word in it
        #expect(!Searcher.isLookup([]))
    }

    @Test func weakerMatchesFoldBelowHalfTheTopScore() {
        func hit(_ score: Double) -> SearchHit {
            SearchHit(path: "/\(score)", kind: .image, score: score, z: nil, cosine: nil, keywordRank: nil, segment: .image,
                      segmentID: 1, loc: nil, locEnd: nil, excerpt: nil, modified: 0, size: 0, info: [:])
        }
        #expect(Searcher.strongCount([hit(6), hit(4.1), hit(3), hit(2.9), hit(0.7)]) == 3)
        #expect(Searcher.strongCount([hit(0.71)]) == 1)
        #expect(Searcher.strongCount([]) == 0)
    }

    @Test func nestedRootsAreCrawledOnce() throws {
        let inner = folder.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("notes about the trip".utf8).write(to: inner.appendingPathComponent("trip.txt"))
        let report = Crawler.crawl([folder, inner], options: IndexOptions())
        #expect(report.candidates.map { ($0.path as NSString).lastPathComponent } == ["trip.txt"])
    }

    /// Apple Music downloads and old iTunes Store songs are FairPlay-protected: they'd only ever fail to read.
    @Test func copyProtectedMusicIsSkipped() throws {
        for name in ["Bought in 2007.m4p", "Ripped from a CD.m4a"] {
            try Data(count: 1024).write(to: folder.appendingPathComponent(name))
        }
        let report = Crawler.crawl([folder], options: IndexOptions())
        #expect(report.candidates.map { ($0.path as NSString).lastPathComponent } == ["Ripped from a CD.m4a"])
        #expect(report.candidates.first?.kind == .audio)
        #expect(report.skipped["copy-protected"] == 1)
    }

    /// A File Provider (iCloud Drive, Google Drive…) answers these with a round trip per entry: a sync over a few hundred
    /// thousand of them took ten minutes. A file that isn't downloaded is `dataless` instead.
    @Test func crawlDoesNotAskFileProvidersAboutEachEntry() {
        #if os(macOS)
        let keys = Set(FileSystem.crawlKeys)
        #expect(!keys.contains(.isUbiquitousItemKey))
        #expect(!keys.contains(.ubiquitousItemDownloadingStatusKey))
        #endif
    }

    // The folder watcher's filter is the Mac app's (FolderWatcher); the shell's watcher has its own rules.
    #if canImport(UniformTypeIdentifiers)
    @Test func changesCountOnlyForWhatCouldBeIndexed() throws {
        func matters(_ path: String, folder: Bool = false, skipping types: Set<String> = []) -> Bool {
            Rules.changeMayMatter(path, isFolder: folder, excludedExtensions: types)
        }
        #expect(matters("/Users/me/Desktop/trip.pdf"))
        #expect(matters("/Users/me/Pictures/beach.heic"))
        #expect(matters("/Users/me/Documents/notes.md"))
        #expect(matters("/Users/me/Desktop/New Folder", folder: true))
        // A database on the Desktop rewrote these every 10 s, and each asked for a sync of every folder.
        #expect(!matters("/Users/me/Desktop/LibreChat/data-node/WiredTiger.turtle.set"))
        #expect(!matters("/Users/me/Desktop/LibreChat/data-node/diagnostic.data/metrics.interim.temp"))
        #expect(!matters("/Users/me/Desktop/LibreChat/data-node/collection-0.wt"))
        #expect(!matters("/Users/me/Downloads/app/server.log"))
        // Inside a bundle the crawl skips whole (Photos' own library).
        let library = folder.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("database"),
                                                withIntermediateDirectories: true)
        #expect(!matters(library.path + "/originals/A/IMG_1.heic"))
        #expect(!matters(library.path + "/database", folder: true))
        #expect(!matters("/Users/me/Desktop/trip.pdf", skipping: ["pdf"]))
    }
    #endif

    @Test func changesCountOnlyWhereTheCrawlGoes() {
        let home = "/Users/me"
        func walked(_ path: String, root: String = home, skipping excluded: [String] = []) -> Bool {
            Rules.isWalked(path, root: root, home: home, excluded: excluded)
        }
        #expect(walked("/Users/me/Documents/trip.pdf"))
        #expect(walked("/Users/me"))
        // DigUp's own index and log, with the home folder chosen: a change there asked for a sync, whose log line was
        // a change again.
        #expect(!walked("/Users/me/Library/Application Support/DigUp/index.noindex/app.log"))
        #expect(!walked("/Users/me/Library/Caches/com.apple.Safari/Cache.db"))
        #expect(!walked("/Users/me/Projects/site/node_modules/left-pad/index.js"))
        #expect(!walked("/Users/me/Movies/Exports.noindex/clip.mov"))
        #expect(!walked("/Users/me/Documents/.git/index"))
        #expect(!walked("/Users/me/Downloads/big.iso", skipping: ["/Users/me/Downloads"]))
        // A folder chosen inside ~/Library (iCloud Drive) is walked.
        let drive = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(walked(drive + "/Notes/plan.md", root: drive))
        #expect(!walked("/Users/me/Documents/trip.pdf", root: drive))
        #expect(walked("/Users/me/Documentsx/a.pdf", root: "/Users/me/Documentsx"))
        #expect(!walked("/Users/me/Documentsx/a.pdf", root: "/Users/me/Documents"))
    }
}

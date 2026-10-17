#if os(macOS)
import AppKit
#endif
import Foundation
import Testing
@testable import DigUpKit

@Suite final class ChineseSearchTests {
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpChineseTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    func add(_ store: IndexStore, path: String, body: String? = nil, inode: UInt64 = 1) throws -> Int64 {
        let id = try store.insert(Candidate(path: path, kind: .doc, size: 1, mtime: 1, inode: inode, device: 1))
        if let body { try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: body) }
        return id
    }

    @Test func chineseLexicalEvalOnPublicSyntheticCorpus() throws {
        // Each case has its own index, so a keyword-only R@1 has one unambiguous answer.
        let cases: [(query: String, name: String, body: String?)] = [
            ("租房", "notes.txt", "这是一份关于租房费用的公开合成记录"),
            ("发票", "notes.txt", "本月发票金额已记录在公开合成表格中"),
            ("预算", "notes.txt", "年度预算安排来自公开合成资料"),
            ("北京", "notes.txt", "我们计划乘坐高铁前往北京游览"),
            ("高铁", "notes.txt", "乘坐高铁前往南方旅行"),
            ("苹果", "notes.txt", "桌上放着新鲜苹果和香蕉"),
            ("𠮷野", "notes.txt", "公开合成记录中的𠮷野家店铺"),
            ("年度租赁合同扫描备份", "年度租赁合同扫描备份.pdf", nil),

            ("payment error", "notes.txt", "A payment error appeared on the synthetic receipt."),
        ]
        var correct = 0
        for (index, item) in cases.enumerated() {
            let store = try IndexStore(directory: folder.appendingPathComponent("eval-\(index)"))
            let path = "/synthetic/\(item.name)"
            try add(store, path: path, body: item.body)
            let hits = try Searcher(store: store, loadVectors: false).search(item.query, queryVector: nil)
            if hits.first?.path == path { correct += 1 }
            #expect(hits.first?.path == path, "Keyword-only synthetic case: \(item.query)")
        }
        print("CHINESE_LEXICAL_EVAL keyword-only R@1: \(correct)/\(cases.count); no model inference")
    }

    @Test func chinesePhrasesAreContiguousAndHighlightedAsWritten() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("phrases"))
        try add(store, path: "/synthetic/good.txt", body: "租房合同已经签署", inode: 1)
        try add(store, path: "/synthetic/bad.txt", body: "租赁住房合同", inode: 2)
        let hits = try Searcher(store: store, loadVectors: false).search("租房", queryVector: nil)
        #expect(hits.map(\.path) == ["/synthetic/good.txt"])
        #expect(hits.first?.excerpt?.contains("«租房»合同") == true)
        #expect(Landmark.find(page: 2, texts: ["公开资料", "这份租房合同已签署"], words: ["合同"]) == "合同")
        #expect(SearchText.matches(of: "day", in: "Sunday day").map { String("Sunday day"[$0]) } == ["day"])
    }

    @Test func latinTermsBesideHanHighlightOriginalText() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("mixed-scripts"))
        try add(store, path: "/synthetic/mixed.txt", body: "学习Swift语言。")
        let hit = try #require(try Searcher(store: store, loadVectors: false).search("swift", queryVector: nil).first)
        #expect(hit.excerpt == "学习«Swift»语言。")
        #expect(hit.excerpt?.contains("\u{E000}") == false)
    }

    @Test func stemmingNeverShowsIndexedHanSeparators() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("stemmed-han"))
        try add(store, path: "/synthetic/stemmed.txt", body: "中文 running。")
        let hit = try #require(try Searcher(store: store, loadVectors: false).search("runs", queryVector: nil).first)
        #expect(hit.excerpt == "中文 running。")
        let text = String(repeating: "甲", count: 1000) + "Swift" + String(repeating: "乙", count: 1000)
        let snippet = try #require(SearchText.snippet(text, terms: ["swift"]))
        #expect(snippet.count < 150)
        #expect(snippet.contains("«Swift»"))
    }

    @Test func chineseChunksRetainOverlapWithoutWhitespace() {
        let text = String(repeating: "甲", count: 499) + "租房合同" + String(repeating: "乙", count: 1100) + "尾部标记"
        let chunks = DocExtractor.chunks(text, size: 500, overlap: 100, limit: 100)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks[1].prefix(100) == chunks[0].suffix(100))
        #expect(chunks.contains { $0.contains("租房合同") }) // phrase spans the first hard boundary.
        #expect(chunks.last?.hasSuffix("尾部标记") == true)
    }

    @Test func hanPhrasesDoNotBridgeSourceSeparatorsOrChooseTheWrongPage() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("separators"))
        let id = try add(store, path: "/synthetic/pages.pdf")
        try store.addSegment(file: id, kind: .page, modality: .text, loc: 1, text: "租，房 租。房 租\n房")
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("租房", queryVector: nil).isEmpty)
        try store.addSegment(file: id, kind: .page, modality: .text, loc: 2, text: "租房合同已经签署")
        let hits = try Searcher(store: store, loadVectors: false).search("租房", queryVector: nil)
        #expect(hits.first?.loc == 2)
        #expect(hits.first?.excerpt?.contains("«租房»") == true)
    }

    @Test func schemaFiveKeepsStoredTextSearchableAfterUpgrade() throws {
        let directory = folder.appendingPathComponent("migration")
        var store: IndexStore? = try IndexStore(directory: directory)
        let id = try add(store!, path: "/synthetic/年度合同备份.txt", body: "连续中文租房记录", inode: 1)
        // Model the old unsplit word representation, retaining its original text.
        try store!.db.run("UPDATE fts SET name = '年度合同备份.txt' WHERE rowid IN (SELECT id FROM segments WHERE kind = 'name')")
        try store!.db.run("UPDATE fts SET body = '连续中文租房记录', original = NULL WHERE rowid IN (SELECT id FROM segments WHERE kind = 'chunk')")
        try store!.finish(id, state: "done", detail: nil)
        try store!.db.execute("PRAGMA user_version = 5")
        store = nil
        let reopened = try IndexStore(directory: directory)
        let searcher = try Searcher(store: reopened, loadVectors: false)
        #expect(try searcher.search("租房", queryVector: nil).map(\.path) == ["/synthetic/年度合同备份.txt"])
        #expect(try searcher.search("年度合同备份", queryVector: nil).map(\.path) == ["/synthetic/年度合同备份.txt"])
    }

    @Test func bodySegmentationLeavesFilenameSubstringFallbackCompatible() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("name-compatibility"))
        let id = try add(store, path: "/synthetic/年度合同备份.txt", body: "连续中文租房记录")
        func namesContaining(_ needle: String) throws -> [Int64] {
            var files: [Int64] = []
            // Same unspaced representation required by the existing filename-fallback PR.
            try store.db.query("""
                SELECT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE s.kind = 'name' AND instr(fts.name, ?) > 0
                """, [.text(needle)]) { files.append($0.int(0)) }
            return files
        }
        #expect(try namesContaining("合同") == [id])
        #expect(try Searcher(store: store, loadVectors: false).search("年度合同", queryVector: nil).first?.path
            == "/synthetic/年度合同备份.txt")
        try store.move(id, to: "/synthetic/中文目录/年度发票备份.txt")
        #expect(try namesContaining("合同").isEmpty)
        #expect(try namesContaining("发票") == [id])
        let hits = try Searcher(store: store, loadVectors: false).search("目录", queryVector: nil)
        #expect(hits.first?.path == "/synthetic/中文目录/年度发票备份.txt")
        #expect(hits.first?.excerpt?.contains("«目录»") == true)
    }

    @Test func schemaFivePreservesOfflineCachedTextAndVectors() throws {
        let directory = folder.appendingPathComponent("migration-budget")
        var store: IndexStore? = try IndexStore(directory: directory)
        let short = try add(store!, path: "/synthetic/short.txt", body: "租房合同", inode: 1)
        let long = try add(store!, path: "/synthetic/long.txt", body: String(repeating: "甲", count: 1800), inode: 2)
        let code = try store!.insert(Candidate(path: "/synthetic/code.md", kind: .code, size: 9000,
                                               mtime: 1, inode: 3, device: 1))
        try store!.addSegment(file: code, kind: .lines, modality: .text, loc: 1, locEnd: 1,
                              text: String(repeating: "a", count: 4000), vector: FakeEmbedder.vector(for: "old"))
        for id in [short, long, code] { try store!.finish(id, state: "done") }
        try store!.db.execute("PRAGMA user_version = 5")
        store = nil
        let reopened = try IndexStore(directory: directory)
        var states: [Int64: String] = [:]
        try reopened.db.query("SELECT id, state FROM files") { states[$0.int(0)] = $0.text(1) }
        #expect(states[short] == "done")
        #expect(states[long] == "done")
        #expect(states[code] == "done")
        var version: Int64 = 0
        try reopened.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 6)
        var savedVectors = 0
        try reopened.db.query("SELECT count(*) FROM segments WHERE file = ? AND vec IS NOT NULL", [.int(code)]) {
            savedVectors = Int($0.int(0))
        }
        #expect(savedVectors == 1)
        var savedBody = ""
        try reopened.db.query("SELECT coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid WHERE s.file = ? AND s.kind = 'chunk'", [.int(long)]) {
            savedBody = $0.text(0) ?? ""
        }
        #expect(savedBody == String(repeating: "甲", count: 1800))
        #expect(try Searcher(store: reopened, loadVectors: false).search("租房", queryVector: nil).first?.path
            == "/synthetic/short.txt")
    }

    @Test func longDocumentTailReachesTheEmbedder() throws {
        let files = folder.appendingPathComponent("document-files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let url = files.appendingPathComponent("long.txt")
        let text = String(repeating: "公开合成的中文资料", count: 800) + "尾部检索标记"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let store = try IndexStore(directory: folder.appendingPathComponent("document-index"))
        let embedder = FakeEmbedder()
        var options = IndexOptions()
        options.docStep = 1
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        #expect(try indexer.run()["partial"] == 1)
        #expect(!embedder.textInputs.contains { $0.contains("尾部检索标记") })
        #expect(try indexer.finishLongFiles()["done"] == 1)
        #expect(embedder.textInputs.contains { $0.contains("尾部检索标记") })
        #expect(embedder.textInputs.allSatisfy { $0.utf8.count + 2 <= embedder.textTokenLimit })
        #expect(try Searcher(store: store, loadVectors: false).search("尾部检索标记", queryVector: nil).first?.path == url.path)
    }

    @Test func impossibleFileBudgetDoesNotBlockTheQueue() throws {
        let files = folder.appendingPathComponent("budget-files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in [String(repeating: "title", count: 20), "short"] {
            try "Public text.".write(to: files.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("failed-budget-index"))
        let embedder = SmallBudgetEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        let result = try indexer.run()
        #expect(result["failed"] == 1)
        #expect(result["done"] == 1)
        #expect(try store.pendingCount() == 0)
    }

    #if os(macOS)
    @Test func pdfTailIsEmbeddedAndKeepsTheOriginalPageNumber() throws {
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let url = files.appendingPathComponent("synthetic-long-page.pdf")
        var box = CGRect(x: 0, y: 0, width: 1600, height: 6000)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let long = String(repeating: "这是一段公开合成的中文资料。", count: 600) + "尾部检索标记"
        for text in [String(repeating: "First synthetic page. ", count: 20), long] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(in: CGRect(x: 60, y: 60, width: 1480, height: 5800),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let store = try IndexStore(directory: folder.appendingPathComponent("pdf-index"))
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        #expect(try indexer.run()["done"] == 1)
        #expect(embedder.textInputs.contains { $0.contains("尾部检索标记") })
        let hits = try Searcher(store: store, loadVectors: false).search("标记", queryVector: nil)
        #expect(hits.first?.path == url.path)
        #expect(hits.first?.loc == 2)
    }

    #endif

}

private final class SmallBudgetEmbedder: Embedder {
    private let base = FakeEmbedder()
    var info: WorkerInfo { base.info }
    var textTokenLimit: Int { 80 }
    func embedTexts(_ texts: [String]) throws -> [[Float]] { try base.embedTexts(texts) }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { try base.embedImages(paths, budget: budget) }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { try base.embedAudio(paths) }
    func close() {}
}

import Foundation
import Testing
@testable import DigUpKit

struct HanFilenameTests {
    func withStore(file: String = IndexStore.mainFile, _ body: (IndexStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HanFilenameTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(IndexStore(directory: folder, file: file))
    }

    @discardableResult
    func add(_ name: String, to store: IndexStore, kind: FileKind = .pdf) throws -> Int64 {
        try store.insert(Candidate(path: "/fixture/\(name)", kind: kind, size: 1, mtime: 1, inode: 1, device: 1))
    }

    @Test func findsTwoCharacterWordsAndInternalFilenameSubstringsWithoutVectors() throws {
        try withStore { store in
            try add("2026學生情緒輔導紀錄.pdf", to: store)
            let searcher = try Searcher(store: store, loadVectors: false)
            for query in ["輔導", "情緒", "情緒輔導", "學生情緒輔導", "２０２６學生", "輔導 PDF"] {
                for typing in [false, true] {
                    let hits = try searcher.search(query, queryVector: nil, prefixLast: typing)
                    #expect(hits.first?.path == "/fixture/2026學生情緒輔導紀錄.pdf", "query: \(query), typing: \(typing)")
                    #expect(hits.first?.segment == .name)
                    #expect(hits.first?.keywordRank != nil)
                }
            }
        }
    }

    @Test func exactStemRanksAheadOfPartialNamesAndContentMatches() throws {
        try withStore { store in
            try add("學生情緒輔導紀錄.pdf", to: store)
            let content = try add("其他資料.pdf", to: store)
            // A filename lookup must point at the file rather than a matching content page.
            try store.db.run("INSERT INTO segments(file, kind, modality, loc) VALUES(?, 'page', 'none', 5)", [.int(content)])
            try store.db.run("INSERT INTO fts(rowid, name, body) VALUES(?, '', '輔導')", [.int(store.db.lastInsertID)])
            try add("輔導.pdf", to: store)
            let hits = try Searcher(store: store).search("輔導", queryVector: nil)
            #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["輔導.pdf", "學生情緒輔導紀錄.pdf", "其他資料.pdf"])
            #expect(hits.first?.loc == nil)
        }
    }

    @Test func requiresAllFilenameTermsAndHonorsKindFilter() throws {
        try withStore { store in
            try add("2025學生輔導紀錄.pdf", to: store)
            try add("2026學生輔導紀錄.pdf", to: store)
            try add("2026學生輔導紀錄.txt", to: store, kind: .doc)
            let searcher = try Searcher(store: store)
            let hits = try searcher.search("輔導 2026", queryVector: nil, kinds: [.pdf])
            #expect(hits.map(\.path) == ["/fixture/2026學生輔導紀錄.pdf"])
            #expect(try searcher.search("輔導 不存在", queryVector: nil).isEmpty)
            #expect(try searcher.search("輔導", queryVector: nil, kinds: [.video]).isEmpty)
        }
    }

    @Test func readsExistingNameRowsAndTracksRenamesAndDeletion() throws {
        try withStore { store in
            let id = try add("學生情緒輔導紀錄.pdf", to: store)
            let searcher = try Searcher(store: store, loadVectors: false)
            #expect(try searcher.search("輔導", queryVector: nil).count == 1)
            try store.move(id, to: "/fixture/學生生涯探索紀錄.pdf")
            #expect(try searcher.search("輔導", queryVector: nil).isEmpty)
            #expect(try searcher.search("探索", queryVector: nil).count == 1)
            try store.delete(id)
            #expect(try searcher.search("探索", queryVector: nil).isEmpty)
        }
    }

    @Test func doesNotTreatFolderNamesOrLatinSubstringsAsHanFilenameMatches() throws {
        try withStore { store in
            try store.insert(Candidate(path: "/fixture/情緒輔導資料/別的檔案.pdf", kind: .pdf, size: 1, mtime: 1, inode: 1, device: 1))
            try add("教育簡報.pdf", to: store)
            try add("category.pdf", to: store)
            let searcher = try Searcher(store: store)
            #expect(try searcher.search("輔導", queryVector: nil).isEmpty)
            #expect(try searcher.search("育簡", queryVector: nil).first?.path == "/fixture/教育簡報.pdf")
            #expect(try searcher.search("tegory", queryVector: nil).isEmpty)
        }
    }

    @Test func filenameLookupWinsOverSemanticPagesAndHasNoDuplicateHits() throws {
        try withStore { store in
            let named = try add("學生情緒輔導紀錄.pdf", to: store)
            let query: [Float] = [1] + Array(repeating: 0, count: Vectors.dimension - 1)
            let other: [Float] = [0, 1] + Array(repeating: 0, count: Vectors.dimension - 2)
            try store.addSegment(file: named, kind: .page, modality: .text, loc: 3, text: "輔導", vector: query)
            for n in 0..<64 {
                let id = try add("其他檔案-\(n).pdf", to: store)
                try store.addSegment(file: id, kind: .page, modality: .text, loc: 1, text: "other", vector: n == 0 ? query : other)
            }
            let hits = try Searcher(store: store).search("輔導", queryVector: query)
            #expect(hits.first?.path == "/fixture/學生情緒輔導紀錄.pdf")
            #expect(hits.first?.segment == .name)
            #expect(hits.first?.loc == nil)
            #expect(hits.filter { $0.path == "/fixture/學生情緒輔導紀錄.pdf" }.count == 1)
            #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        }
    }

    @Test func exactNameIsNotLostBehindManyPartialMatches() throws {
        try withStore { store in
            try store.db.transaction {
                for n in 0..<1_100 { try add("學生輔導紀錄-\(n).pdf", to: store) }
                try add("輔導.pdf", to: store)
            }
            let hits = try Searcher(store: store, loadVectors: false).search("輔導", queryVector: nil, limit: 5)
            #expect(hits.count == 5)
            #expect(hits.first?.path == "/fixture/輔導.pdf")
        }
    }

    @Test func mixedLatinCaseAndCompatibilityCharactersMatch() throws {
        try withStore { store in
            try add("２０２６ＣＡＦÉ學生輔導紀錄.pdf", to: store)
            let hits = try Searcher(store: store).search("2026café學生輔導", queryVector: nil)
            #expect(hits.count == 1)
        }
    }

    @Test func codeIdentifierSearchKeepsItsExistingRules() throws {
        try withStore(file: IndexStore.codeFile) { store in
            try add("學生情緒輔導紀錄.swift", to: store)
            #expect(try Searcher(store: store).search("輔導", queryVector: nil).isEmpty)
        }
    }

}

import Foundation
import Testing
@testable import DigUpKit

/// "name: …" — a search of file and folder names only: `Searcher.search` reads the prefix the way it reads "code:"
/// and keywords the name segments, with no query vector and no model.
@Suite struct NameSearchTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let query = [Float](repeating: 1 / (768 as Float).squareRoot(), count: 768)   // a unit query vector

    func file(_ store: IndexStore, _ path: String, kind: FileKind = .doc) throws -> Int64 {
        try store.insert(Candidate(path: path, kind: kind, size: 10, mtime: 1, inode: UInt64(path.count), device: 1))
    }

    @Test func prefixIsParsedTheWayCodeIs() {
        #expect(NameQuery.text(of: "name: invoice 2024") == "invoice 2024")
        #expect(NameQuery.text(of: "  NAME:invoice") == "invoice")          // leading space, any case
        #expect(NameQuery.text(of: "name:") == "")                          // the prefix alone
        #expect(NameQuery.text(of: "nameless bond") == nil)                 // a word that starts like the prefix
        #expect(NameQuery.text(of: "code: name: refreshAccessToken") == nil)   // "code:" leads; CLI picks that first
    }

    @Test func namesOnlyIgnoresDocumentTextAndMeaning() throws {
        let store = try IndexStore(directory: folder)
        let lease = try file(store, "/a/notes/lease.txt")
        _ = try file(store, "/a/Invoices/scan-2024.pdf", kind: .pdf)
        let report = try file(store, "/a/notes/report.txt")
        // lease and report carry vectors that hit this query at the top of the index; "invoice" is in the lease's
        // body. A name search takes neither: not the score, not the body word — the file named by it, and only that.
        try store.addSegment(file: lease, kind: .chunk, modality: .text, loc: 1,
                             text: "The invoice for March is due with the lease", vector: query)
        try store.addSegment(file: report, kind: .chunk, modality: .text, loc: 1,
                             text: "Numbers, nothing about invoices", vector: query)
        let searcher = try Searcher(store: store)
        let hits = try searcher.search("name: invoice", queryVector: query)
        #expect(hits.map(\.path) == ["/a/Invoices/scan-2024.pdf"])
        #expect(hits.first?.z == nil && hits.first?.segment == .name)     // no meaning scored, points at the name
        // Half the words is the standing gate, the same as everywhere else.
        #expect(try searcher.search("name: invoice penguin", queryVector: query).map(\.path) == ["/a/Invoices/scan-2024.pdf"])
        #expect(try searcher.search("name:", queryVector: query).isEmpty)
        // The plain search keeps its meaning: both vectored files come up in it.
        let meaning = try searcher.search("invoice", queryVector: query).map(\.path)
        #expect(Set(["/a/notes/lease.txt", "/a/notes/report.txt"]).isSubset(of: Set(meaning)))
    }

    @Test func folderNamesCountToo() throws {
        let store = try IndexStore(directory: folder)
        _ = try file(store, "/a/Invoices/x-ray.png", kind: .image)
        _ = try file(store, "/a/Invoices/petri.png", kind: .image)
        _ = try file(store, "/b/Notes/visit.txt")
        let searcher = try Searcher(store: store, loadVectors: false)   // keyword-only ready, vectors never loaded
        // "Invoices" is in no file's name — it's the folder both images sit in. Names-only search finds them by it.
        #expect(Set(try searcher.search("name: invoices", queryVector: nil).map(\.path)) ==
                ["/a/Invoices/x-ray.png", "/a/Invoices/petri.png"])
        // A word of one letter drops out ("x ray" is "ray" alone), as in every search.
        #expect(try searcher.search("name: x ray", queryVector: nil).map(\.path) == ["/a/Invoices/x-ray.png"])
        #expect(try searcher.search("name: notes", queryVector: nil).map(\.path) == ["/b/Notes/visit.txt"])
    }

    @Test func aWordInNoNameIsFoundAtTheStartOfLongerNames() throws {
        let store = try IndexStore(directory: folder)
        let pets = try file(store, "/a/notes/pets.txt")
        try store.addSegment(file: pets, kind: .chunk, modality: .text, loc: 1, text: "A grok of a cat in the category")
        let searcher = try Searcher(store: store, loadVectors: false)
        // The plain search finds "grok" in the body, and "cat" too. Names-only: the probe looks at names, finds
        // neither there, expands to name prefixes — and nothing has a name starting with them.
        #expect(try searcher.search("grok", queryVector: nil).map(\.path) == ["/a/notes/pets.txt"])
        #expect(try searcher.search("name: grok", queryVector: nil).isEmpty)
        #expect(try searcher.search("name: cat", queryVector: nil).isEmpty)
    }
}

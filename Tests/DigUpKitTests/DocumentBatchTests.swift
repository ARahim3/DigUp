import Foundation
import Testing
@testable import DigUpKit

@Suite final class DocumentBatchTests {
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpDocumentBatchTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var files: URL { folder.appendingPathComponent("files") }

    func note(_ name: String, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let url = files.appendingPathComponent(name)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    func state(_ store: IndexStore, _ path: String) throws -> String? {
        var state: String?
        try store.db.query("SELECT state FROM files WHERE path = ?", [.text(path)]) { state = $0.text(0) }
        return state
    }

    func vector(_ store: IndexStore, _ path: String) throws -> Data? {
        var vector: Data?
        try store.db.query("""
            SELECT s.vec FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path = ? AND s.kind = 'chunk'
            """, [.text(path)]) { vector = $0.blob(0) }
        return vector
    }

    func chunkVectors(_ store: IndexStore, _ path: String) throws -> [(location: Int, vector: Data?)] {
        var vectors: [(location: Int, vector: Data?)] = []
        try store.db.query("""
            SELECT s.loc, s.vec FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path = ? AND s.kind = 'chunk' ORDER BY s.loc
            """, [.text(path)]) { vectors.append((Int($0.double(0)), $0.blob(1))) }
        return vectors
    }

    @Test func documentsShareAnEmbeddingCallAndKeepPerFileOutcomes() throws {
        let alphaText = "The alpine garden contains gentians, moss, and late summer flowers."
        let betaText = "The observatory measures distant stars and records changes in their brightness."
        let gammaText = "A field notebook connects each bird sighting to its location and date."
        let alpha = try note("alpha.txt", text: alphaText)
        let beta = try note("beta.txt", text: betaText)
        let gamma = try note("gamma.txt", text: gammaText)
        let numbers = try note("numbers.txt", text: "101 202 303 404 505")
        let empty = try note("empty.txt", text: "\n  \n")
        let removed = try note("removed.txt", text: "This file disappears after sync and must not fail its batch-mates.")

        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        try FileManager.default.removeItem(at: removed)

        #expect(try indexer.run() == ["done": 4, "failed": 1, "skipped": 1])
        #expect(embedder.textCalls == 1)
        #expect(embedder.texts == 3)

        let prompts = [
            Prompts.document(title: "alpha", text: DocExtractor.chunks(alphaText, limit: 10)[0]),
            Prompts.document(title: "beta", text: DocExtractor.chunks(betaText, limit: 10)[0]),
            Prompts.document(title: "gamma", text: DocExtractor.chunks(gammaText, limit: 10)[0]),
        ]
        #expect(Set(embedder.textBatches.flatMap { $0 }) == Set(prompts))
        for (file, prompt) in zip([alpha, beta, gamma], prompts) {
            #expect(try state(store, file.path) == "done")
            #expect(try vector(store, file.path) == Vectors.half(FakeEmbedder.vector(for: prompt)))
        }
        #expect(try state(store, numbers.path) == "done")
        #expect(try vector(store, numbers.path) == nil)
        #expect(try state(store, empty.path) == "skipped")
        #expect(try state(store, removed.path) == "failed")
    }

    @Test func chunksFromDifferentDocumentsShareACallAndReturnToTheirFiles() throws {
        let northText = String(repeating: "The northern survey records basalt ridges, cedar valleys, and spring water. ",
                               count: 35)
        let southText = String(repeating: "The southern route follows limestone cliffs, juniper slopes, and coastal fog. ",
                               count: 35)
        let north = try note("north.txt", text: northText)
        let south = try note("south.txt", text: southText)
        let northChunks = DocExtractor.chunks(northText, limit: 10)
        let southChunks = DocExtractor.chunks(southText, limit: 10)
        #expect(northChunks.count == 2 && southChunks.count == 2)

        let store = try IndexStore(directory: folder.appendingPathComponent("multi-index"))
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])

        #expect(try indexer.run() == ["done": 2])
        #expect(embedder.textCalls == 1)
        #expect(embedder.texts == 4)
        let prompts = northChunks.map { Prompts.document(title: "north", text: $0) }
            + southChunks.map { Prompts.document(title: "south", text: $0) }
        #expect(Set(embedder.textBatches.flatMap { $0 }) == Set(prompts))

        for (file, expected) in [(north, northChunks), (south, southChunks)] {
            let rows = try chunkVectors(store, file.path)
            let filePrompts = expected.map { Prompts.document(title: file.deletingPathExtension().lastPathComponent,
                                                               text: $0) }
            #expect(rows.map(\.location) == Array(1...expected.count))
            for (row, prompt) in zip(rows, filePrompts) {
                #expect(row.vector == Vectors.half(FakeEmbedder.vector(for: prompt)))
            }
        }
    }

    @Test func documentBatchesAreCappedAndProgressStillCountsFiles() throws {
        for number in 0..<20 {
            _ = try note("record-\(number).txt", text: "Record \(number) describes a distinct observation from the study.")
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        var events: [Indexer.Event] = []

        #expect(try indexer.run(onEvent: { events.append($0) }) == ["done": 20])
        #expect(embedder.texts == 20)
        #expect(embedder.textBatches.map(\.count) == [16, 4])
        #expect(events.map(\.done) == Array(1...20))
        #expect(events.allSatisfy { $0.total == 20 })
        #expect(try store.pendingCount() == 0)
    }
}

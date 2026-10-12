@testable import DigUpKit
import Foundation
import Testing
@testable import digup

@Suite final class IndexServiceTests {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("DigUpServiceTests-\(UUID().uuidString)")
    let embedder = ServiceEmbedder()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func part(code: Bool = false, texts: [String], docStep: Int = 40) throws -> IndexService.Part {
        let files = folder.appendingPathComponent(code ? "code" : "documents")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for (index, text) in texts.enumerated() {
            try text.write(to: files.appendingPathComponent("notes-\(index).txt"), atomically: true, encoding: .utf8)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"),
                                   file: code ? IndexStore.codeFile : IndexStore.mainFile)
        var options = IndexOptions()
        options.code = code
        options.docStep = docStep
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { [embedder] in embedder })
        #expect(try indexer.sync([files]).queued.count == texts.count)
        return IndexService.Part(store: store, indexer: indexer, roots: [files], keepOnly: nil)
    }

    func service(_ part: IndexService.Part) throws -> IndexService {
        let main = part.code ? try self.part(texts: []) : part
        return IndexService(main: main, code: part.code ? part : nil,
                            model: SharedEmbedder { [embedder] in embedder }, modelReady: { true },
                            backfill: true, newFilesLimit: 50, linger: 0)
    }

    @Test(arguments: [false, true], [false, true])
    func queuedSyncAllowsOneBatchPerPass(code: Bool, isNew: Bool) throws {
        let part = try part(code: code, texts: ["The harbour opens today.", "A field guide to birds.",
                                              "Notes from the meeting."])
        let service = try service(part)
        let ids = Set(try part.store.pending(limit: nil).map(\.id))
        // Sync is queued from startup and stays queued until the service's next crawl.
        for completed in 1...3 {
            #expect(service.run(part, only: isNew ? ids : nil))
            #expect(try part.store.pendingCount() == 3 - completed)
            #expect(embedder.texts == completed)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func stopPreventsTheFirstBatch(code: Bool, isNew: Bool) throws {
        let part = try part(code: code, texts: ["The harbour opens today."])
        let service = try service(part)
        let ids = Set(try part.store.pending(limit: nil).map(\.id))
        service.receive("stop")
        #expect(service.run(part, only: isNew ? ids : nil))
        #expect(try part.store.pendingCount() == 1)
        #expect(embedder.texts == 0)
    }

    @Test func recoveryDrainsPendingDespiteQueuedSync() throws {
        let part = try part(texts: ["The harbour opens today.", "A field guide to birds.",
                                   "Notes from the meeting."])
        let service = try service(part)
        #expect(service.run(part, only: nil, yieldToSync: false))
        #expect(try part.store.pendingCount() == 0)
        #expect(embedder.texts == 3)
    }

    @Test(arguments: ["stop", "backfill off"])
    func recoveryStillHonoursPause(command: String) throws {
        let part = try part(texts: ["The harbour opens today."])
        let service = try service(part)
        service.receive(command)
        #expect(service.run(part, only: nil, yieldToSync: false))
        #expect(try part.store.pendingCount() == 1)
        #expect(embedder.texts == 0)
    }

    @Test(arguments: ["stop", "backfill off"])
    func recoveryHonoursPauseAfterFirstBatch(command: String) throws {
        let part = try part(texts: ["The harbour opens today.", "A field guide to birds.",
                                   "Notes from the meeting."])
        let service = try service(part)
        embedder.onTexts = { service.receive(command) }
        #expect(service.run(part, only: nil, yieldToSync: false))
        #expect(try part.store.pendingCount() == 2)
        #expect(embedder.texts == 1)
    }

    @Test(arguments: [["--exclude", "/tmp/excluded"], ["--exclude-ext", "txt"]])
    func recoveryRejectsUnreconciledExclusions(exclusion: [String]) throws {
        let args = try Arguments((["--resume-pending", "--index", folder.appendingPathComponent("index").path]
                                  + exclusion)[...])
        #expect(throws: CLIError.self) { try indexService(args) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("index").path))
    }

    @Test(arguments: [false, true])
    func backfillOffStillAllowsNewFiles(code: Bool) throws {
        let part = try part(code: code, texts: ["The harbour opens today.", "A field guide to birds."])
        let service = try service(part)
        let ids = Set(try part.store.pending(limit: nil).map(\.id))
        service.receive("backfill off")
        #expect(service.run(part, only: nil))
        #expect(try part.store.pendingCount() == 2)
        #expect(embedder.texts == 0)
        #expect(service.run(part, only: ids))
        #expect(try part.store.pendingCount() == 1)
        #expect(embedder.texts == 1)
    }

    func longDocument() throws -> IndexService.Part {
        let text = String(repeating: "The harbour meeting covered maps, tides, and the field guide to birds.\n",
                          count: 120)
        let part = try part(texts: [text], docStep: 1)
        #expect(try part.indexer.run() == ["partial": 1])
        return part
    }

    @Test func queuedSyncAllowsOneLongDocumentStepPerPass() throws {
        let part = try longDocument()
        let service = try service(part)
        let remaining = try part.store.unfinishedCount().left
        try #require(remaining > 2)
        for completed in 1...2 {
            #expect(service.finishLongFiles())
            #expect(try part.store.unfinishedCount().left == remaining - completed)
            #expect(embedder.texts == 1 + completed)
        }
    }

    @Test(arguments: ["stop", "backfill off"])
    func pausePreventsTheFirstLongDocumentStep(command: String) throws {
        let part = try longDocument()
        let service = try service(part)
        let remaining = try part.store.unfinishedCount().left
        try #require(remaining > 0)
        service.receive(command)
        #expect(service.finishLongFiles())
        #expect(try part.store.unfinishedCount().left == remaining)
        #expect(embedder.texts == 1)
    }
}

final class ServiceEmbedder: Embedder {
    let info = WorkerInfo(model: "fake", revision: "0000000", runtime: "test", dtype: "f32", dim: Vectors.dimension,
                          textOnly: false, loadSeconds: nil)
    private(set) var texts = 0
    var onTexts: (() -> Void)?

    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        self.texts += texts.count
        onTexts?()
        return texts.map { _ in [1] + [Float](repeating: 0, count: Vectors.dimension - 1) }
    }

    enum UnexpectedMedia: Error { case image, audio }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { throw UnexpectedMedia.image }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { throw UnexpectedMedia.audio }
    func close() {}
}

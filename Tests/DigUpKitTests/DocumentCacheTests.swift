import Foundation
import Testing
@testable import DigUpKit

@Suite struct DocumentCacheTests {
    @Test func laterStepsKeepTheSameChunksAndNoticeFileChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpCacheTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long.txt")
        let text = String(repeating: "Meeting notes about the project schedule.\n", count: 5_000)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let cache = DocumentCache()
        let document = try cache.read(url, limit: 200)
        #expect(document.chunks == DocExtractor.chunks(text, limit: 200))
        #expect(document.characters == text.count)
        let file = FileRecord(id: 1, path: url.path, kind: .doc, size: 0, mtime: 0, inode: 0, device: 0, state: "partial")
        for step in [0..<40, 40..<80] {
            let output = folder.appendingPathComponent("step-\(step.lowerBound)")
            let prepared = Indexer.prepare(Indexer.Job(files: [file], step: step), options: IndexOptions(),
                                           into: output, documents: cache)
            guard case .doc(let chunks, let read, let total, let characters) = prepared.payload else {
                Issue.record("document extraction failed"); return
            }
            #expect(read == step)
            #expect(chunks == Array(document.chunks[step]))
            #expect(total == document.chunks.count)
            #expect(characters == text.count)
        }
        #expect(try cache.read(url, limit: 1).chunks.count == 1)
        try "replacement".write(to: url, atomically: true, encoding: .utf8)
        #expect(try cache.read(url, limit: 200).chunks == ["replacement"])
        cache.clear()
        #expect(try cache.read(url, limit: 200).characters == 11)
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try cache.read(url, limit: 200) }
    }
}

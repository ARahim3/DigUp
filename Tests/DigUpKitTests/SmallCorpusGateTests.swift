import Foundation
import Testing
@testable import DigUpKit

/// The z gate needs a corpus to stand out from: with n scale-setting vectors the top z tops out near √(n−1) under
/// the population deviation, so a tiny index can never pass it, however well a document matches (issue 151). Under
/// 8 scale-setting vectors a clearly relevant match is admitted by an absolute cosine floor, and an unrelated
/// query at a low cosine is still rejected. At 8 and up the group standardizes and the gate applies as before.
@Suite final class SmallCorpusGateTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpSmallCorpusTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Images whose cosine to the query vector is known (the vector's first component, both unit vectors):
    /// [1, 0, …] against [cos, sin, 0, …] is `cos`.
    private func cosineIndex(_ cosines: [Float], in subdir: String = "") throws -> (Searcher, [Float]) {
        let store = try IndexStore(directory: folder.appendingPathComponent(subdir))
        var query = [Float](repeating: 0, count: Vectors.dimension)
        query[0] = 1
        for (number, cosine) in cosines.enumerated() {
            let id = try store.insert(Candidate(path: "/small/photo-\(number).jpg", kind: .image, size: 1, mtime: 1,
                                                inode: UInt64(number + 1), device: 1))
            var vector = [Float](repeating: 0, count: Vectors.dimension)
            vector[0] = cosine
            vector[1] = max(0, 1 - cosine * cosine).squareRoot()
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        }
        return (try Searcher(store: store), query)
    }

    @Test func aSmallCorpusAdmitsByCosineAndStillRejectsUnrelated() throws {
        let (searcher, query) = try cosineIndex([0.9, 0.5, 0.5])
        let found = try searcher.search("something described elsewhere", queryVector: query)
        #expect(found.map(\.path) == ["/small/photo-0.jpg"])

        let none = try cosineIndex([0.5, 0.5, 0.5], in: "reject")
        let rejected = try none.0.search("something described elsewhere", queryVector: none.1)
        #expect(rejected.isEmpty)
    }

    @Test func aGroupLargeEnoughKeepsTheZGate() throws {
        let (searcher, query) = try cosineIndex([Float](repeating: 0.7, count: 7) + [0.95])
        let found = try searcher.search("something described elsewhere", queryVector: query)
        #expect(found.map(\.path) == ["/small/photo-7.jpg"])
    }
}

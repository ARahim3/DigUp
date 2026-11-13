import Foundation
import Testing
@testable import DigUpKit

@Suite struct GraphRAGTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpGraphTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func extractsFileRefsIdCodesAndSymbols() {
        let snippet = "In billing/auth.ts, function refreshAccessToken failed with ERR_TOKEN_401 on invoice INV-2026-041."
        let entities = IndexStore.extractGraphEntities(from: snippet)
        let keys = Set(entities.map(\.key))
        #expect(keys.contains("auth.ts"))
        #expect(keys.contains("refreshaccesstoken"))
        #expect(keys.contains("err_token_401"))
        #expect(keys.contains("inv-2026-041"))
    }

    @Test func storesAndTraversesGraphEdgesAcrossFiles() throws {
        let store = try IndexStore(directory: folder)
        let fileA = try store.insert(Candidate(path: "/repo/serviceA.py", kind: .code, size: 100, mtime: 1, inode: 1, device: 1))
        let fileB = try store.insert(Candidate(path: "/repo/serviceB.py", kind: .code, size: 100, mtime: 1, inode: 2, device: 1))

        let vec = [Float](repeating: 0.1, count: 768)
        try store.writeSegments(
            fileId: fileA,
            segments: [NewSegment(kind: .lines, loc: 1, locEnd: 20, text: "Calls validatePaymentSignature on invoice INV-2026-099", vector: vec)],
            state: "done",
            info: [:]
        )
        try store.writeSegments(
            fileId: fileB,
            segments: [NewSegment(kind: .lines, loc: 10, locEnd: 40, text: "def validatePaymentSignature(payload): # handles INV-2026-099", vector: vec)],
            state: "done",
            info: [:]
        )

        let neighbors = try store.graphNeighbors(forFileIds: [fileA], limit: 5)
        #expect(!neighbors.isEmpty)
        #expect(neighbors.first?.targetPath == "/repo/serviceB.py")
    }
}

import Foundation

/// Compile with DigUpKit's sources so this measures the actual extraction and storage paths without a model.
@main struct IndexBenchmark {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        func timed(_ name: String, _ work: () throws -> Void) rethrows {
            let start = Date()
            try work()
            print("\(name): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        }
        try timed("insert 10,000 files and 30,000 text segments") {
            try store.db.transaction {
                for i in 0..<10_000 {
                    let id = try store.insert(Candidate(path: "/bench/file-\(i).txt", kind: .doc, size: 10,
                                                        mtime: Double(i), inode: UInt64(i), device: 1))
                    for page in 0..<3 {
                        try store.addSegment(file: id, kind: .chunk, modality: .text, loc: Double(page),
                                             text: "Meeting notes about the quarterly invoice and project schedule \(i)")
                    }
                }
            }
        }
        try timed("100 pending queue reads, limit 40") {
            for _ in 0..<100 { _ = try store.pending(limit: 40) }
        }
        let document = folder.appendingPathComponent("long.txt")
        try String(repeating: "A document about the project schedule and meeting notes.\n", count: 40_000)
            .write(to: document, atomically: true, encoding: .utf8)
        let file = FileRecord(id: 1, path: document.path, kind: .doc, size: 0, mtime: 0, inode: 1, device: 1,
                              state: "partial")
        timed("prepare 30 steps of a 2.2 MB document") {
            let documents = DocumentCache()
            for step in 0..<30 {
                let output = folder.appendingPathComponent("step-\(step)")
                let prepared = Indexer.prepare(Indexer.Job(files: [file], step: step * 40..<(step + 1) * 40),
                                               options: IndexOptions(), into: output, documents: documents)
                guard case .doc = prepared.payload else { fatalError("document extraction failed") }
                try? FileManager.default.removeItem(at: output)
            }
        }
    }
}

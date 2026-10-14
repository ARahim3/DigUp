import Foundation

/// One document's split text, owned by the serial preparation queue for one indexing run.
/// Long documents reuse it between steps. Replacing it drops the previous document, and ending the run clears it.
final class DocumentCache: @unchecked Sendable {
    struct Document {
        let chunks: [String]
        let characters: Int
    }

    private struct Key: Equatable {
        let path: String
        let size: Int64
        let mtime: Double
        let inode: UInt64
        let device: UInt64
        let limit: Int
    }

    private var cached: (key: Key, document: Document)?

    func clear() { cached = nil }

    func read(_ url: URL, limit: Int) throws -> Document {
        let before = key(url, limit: limit)
        if let before, let cached, cached.key == before { return cached.document }
        clear()
        let text = try DocExtractor.text(of: url)
        let document = Document(chunks: DocExtractor.chunks(text, limit: limit), characters: text.count)
        // A file replaced or edited during extraction must be read again next time.
        if let before, key(url, limit: limit) == before { cached = (before, document) }
        return document
    }

    private func key(_ url: URL, limit: Int) -> Key? {
        guard let info = FileSystem.info(of: url.path), info.isRegular, !info.dataless else { return nil }
        return Key(path: url.path, size: info.size, mtime: info.mtime, inode: info.inode, device: info.device,
                   limit: limit)
    }
}

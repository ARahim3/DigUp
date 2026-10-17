import Foundation

/// Splits documents against a complete prompt's tokenizer budget. Callers provide
/// the runtime's real token count; character counts never decide what fits.
public enum TextBudget {
    /// A single file cannot fit; unlike a failed worker, this must not stop the indexing queue.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }
    public static func chunks(_ text: String, title: String?, limit: Int,
                              count: (String) throws -> Int) throws -> [String] {
        try ranges(text, title: title, limit: limit, count: count).map { String(text[$0]) }
    }

    /// Original offsets let code retain source lines even when repeated text is split.
    static func ranges(_ text: String, title: String?, limit: Int,
                       count: (String) throws -> Int) throws -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        func fits(_ body: String) throws -> Bool {
            try count(Prompts.document(title: title, text: body)) <= limit
        }
        if try fits(text) { return [text.startIndex..<text.endIndex] }
        let indices = Array(text.indices) + [text.endIndex]
        var start = 0, output: [Range<String.Index>] = []
        while start < indices.count - 1 {
            // Bound tokenizer work even for enormous pages. This bound is only
            // a probe size: every emitted piece is checked with the tokenizer.
            var low = start + 1, high = min(indices.count - 1, start + max(1800, limit * 4))
            var end = start
            while low <= high {
                let probe = low + (high - low) / 2
                if try fits(String(text[indices[start]..<indices[probe]])) {
                    end = probe
                    low = probe + 1
                } else { high = probe - 1 }
            }
            guard end > start else {
                throw Failure(description: "document title and one character exceed the \(limit)-token budget")
            }
            // Prefer a word boundary when one is nearby; no-space Han stays overlapped.
            if end < indices.count - 1,
               let space = text[indices[start]..<indices[end]].lastIndex(where: \.isWhitespace),
               text.distance(from: indices[start], to: space) > (end - start) / 2 {
                let candidate = start + text.distance(from: indices[start], to: space)
                if try fits(String(text[indices[start]..<indices[candidate]])) { end = candidate }
            }
            let piece = String(text[indices[start]..<indices[end]])
            // BPE token counts need not be monotonic; never infer the final count.
            guard try fits(piece) else { throw Failure(description: "document split exceeded its token budget") }
            output.append(indices[start]..<indices[end])
            guard end < indices.count - 1 else { break }
            var next = end - min(200, (end - start) / 4)
            while next < end, !text[indices[next]].isWhitespace, !SearchText.isHan(text[indices[next]]) { next += 1 }
            start = max(start + 1, next)
        }
        return output
    }
}

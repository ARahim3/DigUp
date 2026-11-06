import Foundation

enum ExtractError: Error, CustomStringConvertible {
    case unreadable(String)
    case tooSmall(Int, Int)
    case locked
    case empty(String)
    /// Not for the index after all, once read (code that a program made, or that holds a private key).
    case leftOut(String)

    var description: String {
        switch self {
        case .unreadable(let why): "unreadable: \(why)"
        case .tooSmall(let width, let height): "small image \(width)×\(height)"
        case .locked: "password-protected"
        case .empty(let why): why
        case .leftOut(let why): why
        }
    }
}

/// Pictures for the model: a downscaled copy of each image (`prepare`) and the camera's date. ImageIO on macOS (HEIC,
/// RAW, WebP and friends); stb_image elsewhere (Platform/). Public for the indexing helper to set its
/// `decodeMemoryBudget` at startup; `prepare` itself stays internal to the kit.
public enum ImageExtractor {
    struct Prepared: Sendable {
        let path: String
        let width: Int
        let height: Int
        let taken: String?   // EXIF DateTimeOriginal, as written by the camera
    }

    /// What reading one picture may cost the helper in memory, set at its start from `--memory-limit`
    /// (`main.swift`: the watchdog's own limit). A picture whose header says its reading would ask for more
    /// goes into the index as unreadable *without being decoded*: a 45 MP RAW has run to over 8 GB in the
    /// wild, killing the helper before the watchdog's tick could note the file, and every restart took that
    /// file first and died on it again (issue #182: 55,000 files stuck behind it). 0 = no preflight, for the
    /// tools that don't index under a watchdog.
    nonisolated(unsafe) public static var decodeMemoryBudget: UInt64 = 0

    /// Bytes the reading of one RAW pixel can take. Measured on 2026-11-05 on an Apple M1 with 8 GB RAM
    /// (macOS 26.5.1): the production thumbnail path on a real 45.4 MP Nikon Z9 NEF peaks at 782 MB, 17 B/px,
    /// so ImageIO of that macOS decodes RAW safely. The #182 reports — the same camera — are files whose
    /// reading ran past an 8 GB watchdog, which floors the coefficient at 176 B/px; 192 carries the guard.
    /// RAW is only read on the ImageIO side. Measured on one camera on one macOS, and taken for all makers.
    public static let rawDecodeBytesPerPixel = 192

    /// Bytes per pixel of a layered TIFF: every full-resolution layer decoded with its masks. A design
    /// estimate, not measured — Photoshop's layered files of the #182 reports can't be synthesized from
    /// nothing. Only files that say so themselves get it: `LayeredTIFF`.
    static let layeredTIFFBytesPerPixel = 16

    /// Bytes without ImageIO: stb decodes the whole picture, `oriented` copies it, and the scaling copies it
    /// again (3 B/px decoded, a 4-byte copy, the scaled copy). Estimated, not measured on Linux or Windows.
    static let portableDecodeBytesPerPixel = 8

    /// A size for the file's note: "4.1 GB", "900 MB".
    static func decodeSize(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) : "\(bytes >> 20) MB"
    }
}

/// The pixels of the layers of a Photoshop-style layered TIFF, nil when the file isn't layered. A layered
/// TIFF's master declares itself a reduced preview (`SubfileType & 1`) and keeps its full-size layers — the
/// colours, and alpha masks the same size — in sub-IFDs. A plain TIFF, including a page chain where every
/// IFD is full size, is not layered: ImageIO decodes those in streaming tiles, measured 2026-11-05 at a
/// 70 MB peak on a 2,125 MP file, so it gets no preflight. Only the headers are read: 8 bytes, 12 per
/// entry, 4 per sub-IFD — never pixels, of a file that may be 2 GB.
enum LayeredTIFF {
    /// A side above this is not a picture: 16,777,216 px on a side is 280 GB of pixels at the preflight's
    /// 16 B/px, and no file of it exists. The sizes come from 4-byte LONG tags, so a header saying
    /// 0xFFFFFFFF is garbage — and two of those multiplied overflowed the sum below, trapping *inside* the
    /// guard built to stop crashes (issue #182, pre-push review S4). Garbage gets no estimate: nil, meaning
    /// "not this file's shape", so nothing is marked on it.
    static let maxDimension = 1 << 24

    /// All pixels of master and layers, counted in `UInt64` for the same reason — and saturating, so a file
    /// that lies about its size produces a huge estimate, not a trap. `maxLayers`: more sub-IFDs than this
    /// is not Photoshop (which caps at 50) — a file pulling at the parser is left unguarded, and the
    /// watchdog ends the helper on it.
    static func layerPixels(in url: URL, maxLayers: Int = 64) -> UInt64? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func chunk(_ at: Int, _ count: Int) -> Data? {
            guard at >= 0, count > 0, count <= 1 << 20 else { return nil }
            do {
                try file.seek(toOffset: UInt64(at))
                guard let data = try file.read(upToCount: count), data.count == count else { return nil }
                return data
            } catch {
                return nil   // past the end, a closed file: the caller reads it as "not this file's shape"
            }
        }
        guard let header = chunk(0, 8), header[header.startIndex] == 0x49 || header[header.startIndex] == 0x4D
        else { return nil }
        let big = header[header.startIndex] == 0x4D   // "MM": Motorola (big-endian) order
        func number(_ at: Int, _ width: Int) -> Int? {
            guard let data = chunk(at, width) else { return nil }
            let bytes = big ? [UInt8](data) : [UInt8](data).reversed()
            return bytes.reduce(0) { $0 << 8 | Int($1) }
        }
        func ifd(_ at: Int) -> (subfileType: Int, width: Int, height: Int, subIFDs: [Int])? {
            guard let entries = number(at, 2), entries >= 1, entries <= 1024 else { return nil }
            var read = (0, 0, 0, [Int]())
            for i in 0..<entries {
                let e = at + 2 + i &* 12
                guard let tag = number(e, 2), let type = number(e + 2, 2), let count = number(e + 4, 4),
                      count >= 0, count <= 1 << 16 else { return nil }
                let unit = type == 3 || type == 8 ? 2 : type == 1 || type == 2 || type == 6 || type == 7 ? 1 : 4
                let total = count &* unit
                func value(_ index: Int) -> Int? {
                    if total <= 4 { return index == 0 ? number(e + 8, unit) : nil }
                    guard let base = number(e + 8, 4) else { return nil }
                    return number(base + index &* unit, unit)
                }
                switch tag {
                case 0x00FE: read.0 = value(0) ?? 0
                case 0x0100: read.1 = value(0) ?? 0
                case 0x0101: read.2 = value(0) ?? 0
                case 0x0145 where count >= 1 && count <= maxLayers:
                    read.3 = total <= 4 && count == 1 ? [number(e + 8, 4) ?? 0] : (0..<count).compactMap { value($0) }
                default: break
                }
            }
            return read
        }
        guard number(2, 2) == 42, let first = number(4, 4), first >= 8,
              let master = ifd(first), master.subfileType & 1 == 1,   // the master says "I am a preview"
              !master.subIFDs.isEmpty, master.width > 0, master.height > 0,
              master.width <= maxDimension, master.height <= maxDimension   // a header lying about its size
        else { return nil }
        var total = UInt64(master.width) &* UInt64(master.height)   // the preview decodes too
        for at in master.subIFDs {
            guard at >= 8, let layer = ifd(at), layer.subfileType & 1 == 0,   // a full-size layer, not a preview
                  layer.width > 0, layer.height > 0,
                  layer.width <= maxDimension, layer.height <= maxDimension else { continue }
            total = total &+ UInt64(layer.width) &* UInt64(layer.height)
        }
        return total
    }
}

/// Text recognition in screenshots, for keyword search only: Apple Vision on macOS, nothing elsewhere yet.
enum OCR {}

/// PDF pages as text, or as pictures when they have little text (scans, slides): PDFKit on macOS, PDFium elsewhere.
enum PDFExtractor {
    struct Page: Sendable {
        let number: Int        // 1-based
        let text: String       // may be empty for scans
        let imagePath: String? // set when the page had too little text and was rendered for the vision encoder
        var ocr = false        // the text came from OCR: the text layer was garbled (`PageTextProblem.lostLetters`)
        /// Text read in glyph order (`PageTextProblem.glyphOrder`): too garbled to show or match words against, but
        /// enough of its words survive for a meaning vector beside the page's picture.
        var garbled: String?
    }
}

enum DocExtractor {
    /// Plain text from txt/md directly, HTML by stripping tags, rtf/docx/doc/odt through `richText` (the Cocoa text
    /// system on macOS, the files' own XML elsewhere), and spreadsheets and presentations from their XML everywhere
    /// (`OfficeText`).
    static func text(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx", "doc", "odt", "rtf": return try richText(of: url, type: ext)
        case "xlsx", "pptx", "ods", "odp": return try OfficeText.text(of: url, type: ext)
        case "html", "htm": return plainText(fromHTML: try readText(url))
        default: return try readText(url)
        }
    }

    static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    /// Good enough for search: drops scripts, styles and comments, turns block ends into line breaks, strips the
    /// remaining tags, and decodes common entities.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        text = decodeNumericEntities(text)
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let codeRange = Range(match.range(at: 1), in: text)
            else { continue }
            let code = text[codeRange]
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += text[last..<range.lowerBound]
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " "
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// Splits text into ~`size`-character pieces (~450 tokens) that overlap a little, breaking at whitespace.
    static func chunks(_ text: String, size: Int = 1800, overlap: Int = 200, limit: Int) -> [String] {
        let clean = text
            // A plain string, so Swift puts the real tab and no-break space in the class: ICU doesn't read \u{…}, and
            // an invalid pattern leaves the text as it is on macOS but empties it on Linux (found by the port).
            .replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex, chunks.count < limit {
            var end = clean.index(start, offsetBy: size, limitedBy: clean.endIndex) ?? clean.endIndex
            if end < clean.endIndex, let space = clean[start..<end].lastIndex(where: \.isWhitespace),
               clean.distance(from: start, to: space) > size / 2 {
                end = space
            }
            let chunk = clean[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            guard end < clean.endIndex else { break }
            var next = clean.index(end, offsetBy: -overlap, limitedBy: start) ?? end
            if next <= start { next = end }
            // Start the next chunk on a word boundary.
            while next < end, !clean[next].isWhitespace { next = clean.index(after: next) }
            start = next < end ? next : end
        }
        return chunks
    }
}

/// One line, at most `limit` characters: for result lists.
func excerpt(_ text: String, limit: Int = 240) -> String {
    // Only the start is shown, so only the start is cleaned up (a page or a chunk can be thousands of characters).
    let start = text.prefix(limit * 8)
    let line = String(start).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return line.count > limit || start.endIndex < text.endIndex ? String(line.prefix(limit)) + "…" : line
}

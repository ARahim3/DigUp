import Foundation

/// Spreadsheets and presentations (xlsx, pptx, ods, odp), read for their words from the XML inside their zip, the same
/// way on every system: the Cocoa text system doesn't read them either. A sheet comes out as its name, then a line per
/// row with its cells separated by tabs; a presentation as its slides in order, each followed by its speaker notes.
/// Formulas (their last value is kept), styles, charts and pictures are left out. Old binary .xls and .ppt aren't read.
enum OfficeText {
    /// Reading stops past what the index keeps of a document (`IndexOptions.maxChunks`, 5,000 chunks of ~1,800
    /// characters), so a sheet of a million rows doesn't fill memory with text that would be cut anyway.
    static let maxCharacters = 10_000_000

    static func text(of url: URL, type ext: String) throws -> String {
        // An Office file with a password is an OLE compound file holding the encrypted zip.
        if isCompoundFile(url) { throw ExtractError.locked }
        let zip = try ZipArchive(url)
        var out = Output()
        switch ext {
        case "xlsx": try workbook(zip, into: &out)
        case "pptx": try presentation(zip, into: &out)
        case "ods": spreadsheet(try zip.required("content.xml"), into: &out)
        default: slides(try zip.required("content.xml"), into: &out)   // odp
        }
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCompoundFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)).map(Array.init) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    }

    // MARK: Office Open XML (xlsx, pptx)

    /// Sheets in the workbook's order, cells with their shared strings or their last computed value.
    private static func workbook(_ zip: ZipArchive, into out: inout Output) throws {
        let book = try mainPart(zip, default: "xl/workbook.xml")
        let links = try relationships(of: book, in: zip)
        var shared: [String] = []
        if let part = links.values.first(where: { $0.type.hasSuffix("/sharedStrings") })?.target,
           let xml = try zip.data(part) {
            shared = sharedStrings(xml)
        }
        var scan = XMLScanner(try zip.required(book))
        var sheets: [(name: String, part: String)] = []
        while let event = scan.next() {
            if case .open(let name, let attributes, _) = event, local(name) == "sheet",
               let id = scan.attribute(":id", in: attributes), let link = links[id], link.type.hasSuffix("/worksheet") {
                sheets.append((scan.attribute("name", in: attributes) ?? "", link.target))
            }
        }
        for sheet in sheets where !out.full {
            guard let xml = try zip.data(sheet.part) else { continue }
            out.paragraph()
            out.line(sheet.name)
            worksheet(xml, shared: shared, into: &out)
        }
    }

    /// The table of strings cells point to: the text of each `<si>`, its runs joined, phonetic readings left out.
    private static func sharedStrings(_ xml: [UInt8]) -> [String] {
        var scan = XMLScanner(xml)
        var strings: [String] = []
        var current = "", inText = false, phonetic = 0
        while let event = scan.next() {
            switch event {
            case .open(let name, _, let empty):
                switch local(name) {
                case "si": current = ""
                case "t": inText = !empty
                case "rPh": if !empty { phonetic += 1 }
                default: break
                }
                if empty, local(name) == "si" { strings.append("") }
            case .close(let name):
                switch local(name) {
                case "si": strings.append(current)
                case "t": inText = false
                case "rPh": phonetic -= 1
                default: break
                }
            case .text(let range, let raw):
                if inText, phonetic == 0 { current += scan.string(range, raw: raw) }
            }
        }
        return strings
    }

    private static func worksheet(_ xml: [UInt8], shared: [String], into out: inout Output) {
        var scan = XMLScanner(xml)
        var row: [String] = []
        var type = "n", value = ""
        var inValue = false, inline = false, inText = false, phonetic = 0
        while !out.full, let event = scan.next() {
            switch event {
            case .open(let name, let attributes, let empty):
                switch local(name) {
                case "row": row = []
                case "c":
                    (type, value) = (scan.attribute("t", in: attributes) ?? "n", "")
                case "v": inValue = !empty
                case "is": inline = !empty
                case "t": inText = !empty
                case "rPh": if !empty { phonetic += 1 }
                default: break
                }
            case .close(let name):
                switch local(name) {
                case "row":
                    if !row.isEmpty { out.line(row.joined(separator: "\t")) }
                case "c":
                    let shown: String
                    switch type {
                    case "s": shown = Int(value.trimmingCharacters(in: .whitespaces)).flatMap {
                        shared.indices.contains($0) ? shared[$0] : nil
                    } ?? ""
                    case "b", "e": shown = ""   // TRUE/FALSE and #N/A say nothing to search for
                    default: shown = value      // numbers, dates (as day counts), strings computed by formulas
                    }
                    let cell = shown.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cell.isEmpty { row.append(cell) }
                case "v": inValue = false
                case "is": inline = false
                case "t": inText = false
                case "rPh": phonetic -= 1
                default: break
                }
            case .text(let range, let raw):
                if inValue || (inline && inText && phonetic == 0) { value += scan.string(range, raw: raw) }
            }
        }
    }

    /// Slides in the presentation's order (not their file names'), each followed by its notes.
    private static func presentation(_ zip: ZipArchive, into out: inout Output) throws {
        let deck = try mainPart(zip, default: "ppt/presentation.xml")
        let links = try relationships(of: deck, in: zip)
        var scan = XMLScanner(try zip.required(deck))
        var slides: [String] = []
        while let event = scan.next() {
            if case .open(let name, let attributes, _) = event, local(name) == "sldId",
               let id = scan.attribute(":id", in: attributes), let link = links[id], link.type.hasSuffix("/slide") {
                slides.append(link.target)
            }
        }
        for slide in slides where !out.full {
            guard let xml = try zip.data(slide) else { continue }
            out.paragraph()
            drawingText(xml, into: &out)
            let links = try relationships(of: slide, in: zip)
            if let notes = links.values.first(where: { $0.type.hasSuffix("/notesSlide") }),
               let xml = try zip.data(notes.target) {
                drawingText(xml, into: &out)
            }
        }
    }

    /// The text of a slide or notes page: `<a:t>` runs, a line per paragraph. Fields (the slide number on a notes
    /// page, a date) are left out.
    private static func drawingText(_ xml: [UInt8], into out: inout Output) {
        var scan = XMLScanner(xml)
        var paragraph = ""
        var inText = false, field = 0
        while !out.full, let event = scan.next() {
            switch event {
            case .open(let name, _, let empty):
                switch local(name) {
                case "t": inText = !empty
                case "br": paragraph += "\n"
                case "fld": if !empty { field += 1 }
                default: break
                }
            case .close(let name):
                switch local(name) {
                case "t": inText = false
                case "fld": field -= 1
                case "p":
                    let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { out.line(line) }
                    paragraph = ""
                default: break
                }
            case .text(let range, let raw):
                if inText, field == 0 { paragraph += scan.string(range, raw: raw) }
            }
        }
    }

    /// The package's main part (`xl/workbook.xml`, `ppt/presentation.xml`) as `_rels/.rels` names it.
    private static func mainPart(_ zip: ZipArchive, default name: String) throws -> String {
        try relationships(of: "", in: zip).values.first { $0.type.hasSuffix("/officeDocument") }?.target ?? name
    }

    /// A part's links to other parts, by id, from the `_rels` file beside it, with their targets as zip entry names.
    private static func relationships(of part: String, in zip: ZipArchive) throws
        -> [String: (type: String, target: String)] {
        let folder = part.split(separator: "/").dropLast().joined(separator: "/")
        let file = part.split(separator: "/").last.map(String.init) ?? ""
        let rels = (folder.isEmpty ? "" : folder + "/") + "_rels/" + file + ".rels"
        guard let xml = try zip.data(rels) else { return [:] }
        var scan = XMLScanner(xml)
        var links: [String: (type: String, target: String)] = [:]
        while let event = scan.next() {
            guard case .open(let name, let attributes, _) = event, local(name) == "Relationship",
                  scan.attribute("TargetMode", in: attributes) != "External",
                  let id = scan.attribute("Id", in: attributes), let target = scan.attribute("Target", in: attributes)
            else { continue }
            links[id] = (scan.attribute("Type", in: attributes) ?? "", resolve(target, from: folder))
        }
        return links
    }

    /// A relationship's target as a zip entry name: absolute ones start at the package's root, others at the part's
    /// folder ("../notesSlides/notesSlide1.xml" from ppt/slides).
    static func resolve(_ target: String, from folder: String) -> String {
        var path: [Substring] = target.hasPrefix("/") ? [] : folder.split(separator: "/")
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": _ = path.popLast()
            default: path.append(piece)
            }
        }
        return path.joined(separator: "/")
    }

    // MARK: OpenDocument (ods, odp)

    /// Each sheet's name, then its rows, cells separated by tabs. Comments' authors and dates are left out.
    private static func spreadsheet(_ xml: [UInt8], into out: inout Output) {
        var scan = XMLScanner(xml)
        var row: [String] = [], cell = "", paragraph = ""
        var inCell = false, boolean = false, inParagraph = 0, skipped = 0
        while !out.full, let event = scan.next() {
            switch event {
            case .open(let name, let attributes, let empty):
                switch local(name) {
                case "table":
                    out.paragraph()
                    out.line(scan.attribute("table:name", in: attributes) ?? "")
                case "table-row": row = []
                case "table-cell", "covered-table-cell":
                    // TRUE/FALSE say nothing to search for, as in xlsx.
                    boolean = scan.attribute("office:value-type", in: attributes) == "boolean"
                    (inCell, cell) = (!empty, "")
                case "p", "h": if !empty { (inParagraph, paragraph) = (inParagraph + 1, "") }
                case "s", "tab", "line-break": if inParagraph > 0 { paragraph += " " }
                case "creator", "date": if !empty { skipped += 1 }
                default: break
                }
            case .close(let name):
                switch local(name) {
                case "table-row": if !row.isEmpty { out.line(row.joined(separator: "\t")) }
                case "table-cell", "covered-table-cell":
                    let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, !boolean { row.append(text) }
                    inCell = false
                case "p", "h":
                    inParagraph -= 1
                    let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { break }
                    if inCell { cell += (cell.isEmpty ? "" : " ") + text } else { out.line(text) }
                case "creator", "date": skipped -= 1
                default: break
                }
            case .text(let range, let raw):
                if inParagraph > 0, skipped == 0 { paragraph += scan.string(range, raw: raw) }
            }
        }
    }

    /// Each page's text, a line per paragraph, its notes at the end of it. Page numbers and dates are left out.
    private static func slides(_ xml: [UInt8], into out: inout Output) {
        var scan = XMLScanner(xml)
        var paragraph = ""
        var inParagraph = 0, skipped = 0
        while !out.full, let event = scan.next() {
            switch event {
            case .open(let name, _, let empty):
                switch local(name) {
                case "page": out.paragraph()
                case "p", "h": if !empty { (inParagraph, paragraph) = (inParagraph + 1, "") }
                case "s", "tab": if inParagraph > 0 { paragraph += " " }
                case "line-break": if inParagraph > 0 { paragraph += "\n" }
                case "page-number", "date-time", "creator", "date": if !empty { skipped += 1 }
                default: break
                }
            case .close(let name):
                switch local(name) {
                case "p", "h":
                    inParagraph -= 1
                    let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.line(text) }
                    paragraph = ""
                case "page-number", "date-time", "creator", "date": skipped -= 1
                default: break
                }
            case .text(let range, let raw):
                if inParagraph > 0, skipped == 0 { paragraph += scan.string(range, raw: raw) }
            }
        }
    }

    // MARK: Helpers

    /// A tag's name without its namespace prefix ("a:t" → "t"): writers don't all use the same prefixes.
    private static func local(_ name: String) -> Substring {
        name.lastIndex(of: ":").map { name[name.index(after: $0)...] } ?? name[...]
    }

    /// The text being built, a line at a time, up to `maxCharacters`.
    private struct Output {
        var text = ""
        var full: Bool { text.utf8.count >= OfficeText.maxCharacters }

        mutating func line(_ line: String) {
            guard !full else { return }
            text += line
            text += "\n"
        }

        /// A blank line between sheets or slides.
        mutating func paragraph() {
            if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n" }
        }
    }
}

extension ZipArchive {
    /// Larger entries aren't inflated (a zip bomb, or a sheet far past what the index keeps).
    static let maxEntrySize = 512 << 20

    /// An entry the format can't do without.
    func required(_ name: String) throws -> [UInt8] {
        guard let bytes = try data(name) else { throw ExtractError.unreadable("no \(name) inside") }
        return bytes
    }
}

/// A small XML reader for the parts of Office files, which programs write: tags with their attributes, and text with
/// entities decoded. No DTDs; namespace prefixes stay in the names ("a:t").
struct XMLScanner {
    enum Event {
        /// A start tag, its attributes as a range to read with `attribute`, and whether it closes itself (`<a/>`).
        case open(String, Range<Int>, empty: Bool)
        case close(String)
        /// Text between tags, read with `string`; `raw` for CDATA, whose `&` is a plain `&`.
        case text(Range<Int>, raw: Bool)
    }

    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> Event? {
        while position < bytes.count {
            let start = position
            guard bytes[start] == UInt8(ascii: "<") else {
                while position < bytes.count, bytes[position] != UInt8(ascii: "<") { position += 1 }
                return .text(start..<position, raw: false)
            }
            if starts(with: "<![CDATA[", at: start) {
                let end = find("]]>", from: start + 9) ?? bytes.count
                position = min(bytes.count, end + 3)
                return .text(start + 9..<end, raw: true)
            }
            if starts(with: "<!--", at: start) {
                position = min(bytes.count, (find("-->", from: start + 4) ?? bytes.count) + 3)
                continue
            }
            // The tag's end: the first `>` outside quotes.
            var end = start + 1, quote: UInt8 = 0
            while end < bytes.count {
                let byte = bytes[end]
                if quote != 0 { if byte == quote { quote = 0 } }
                else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { quote = byte }
                else if byte == UInt8(ascii: ">") { break }
                end += 1
            }
            position = min(bytes.count, end + 1)
            guard start + 1 < end else { continue }
            let first = bytes[start + 1]
            if first == UInt8(ascii: "?") || first == UInt8(ascii: "!") { continue }   // declarations, DOCTYPE
            let closing = first == UInt8(ascii: "/")
            var nameEnd = start + (closing ? 2 : 1)
            let nameStart = nameEnd
            while nameEnd < end, !isSpace(bytes[nameEnd]), bytes[nameEnd] != UInt8(ascii: "/") { nameEnd += 1 }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            if closing { return .close(name) }
            let empty = bytes[end - 1] == UInt8(ascii: "/")
            return .open(name, nameEnd..<(empty ? end - 1 : end), empty: empty)
        }
        return nil
    }

    /// The value of attribute `name` among a tag's `attributes`. A name starting with ":" matches any prefix
    /// (":id" finds "r:id" but not "id").
    func attribute(_ name: String, in attributes: Range<Int>) -> String? {
        let wanted = Array(name.utf8)
        let anyPrefix = name.hasPrefix(":")
        var i = attributes.lowerBound
        while i < attributes.upperBound {
            while i < attributes.upperBound, isSpace(bytes[i]) { i += 1 }
            let keyStart = i
            while i < attributes.upperBound, bytes[i] != UInt8(ascii: "="), !isSpace(bytes[i]) { i += 1 }
            let key = bytes[keyStart..<i]
            while i < attributes.upperBound, isSpace(bytes[i]) || bytes[i] == UInt8(ascii: "=") { i += 1 }
            guard i < attributes.upperBound else { return nil }
            let quote = bytes[i]
            guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return nil }
            let valueStart = i + 1
            i = valueStart
            while i < attributes.upperBound, bytes[i] != quote { i += 1 }
            let matches = anyPrefix ? key.count > wanted.count && key.suffix(wanted.count).elementsEqual(wanted)
                : key.elementsEqual(wanted)
            if matches { return string(valueStart..<min(i, attributes.upperBound), raw: false) }
            i += 1
        }
        return nil
    }

    /// Text or an attribute's value, with `&amp;`, `&#233;` and the like decoded.
    func string(_ range: Range<Int>, raw: Bool) -> String {
        let text = String(decoding: bytes[range], as: UTF8.self)
        guard !raw, text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semicolon = rest[amp...].prefix(12).firstIndex(of: ";") else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            let decoded: String? = switch entity {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    nil
                }
            }
            if let decoded {
                out += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
            }
        }
        return out + rest
    }

    private func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func starts(with prefix: String, at index: Int) -> Bool {
        let prefix = Array(prefix.utf8)
        return index + prefix.count <= bytes.count && bytes[index..<index + prefix.count].elementsEqual(prefix)
    }

    private func find(_ needle: String, from index: Int) -> Int? {
        let needle = Array(needle.utf8)
        var i = index
        while i + needle.count <= bytes.count {
            if bytes[i] == needle[0], bytes[i..<i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}

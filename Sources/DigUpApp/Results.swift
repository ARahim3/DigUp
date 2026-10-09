import AppKit
import DigUpKit

/// One search result as the panel and the window show it: a file, the part of it that matched, and why.
struct ResultRow: Identifiable, Equatable {
    let id: String          // the file's path
    let url: URL
    let name: String
    let folder: String      // "~/Downloads/Screenshots"
    let kind: FileKind
    let segment: SegmentKind
    let segmentID: Int64
    let loc: Double?        // PDF page, seconds into audio or video, or a stretch of code's first line
    let locEnd: Double?
    /// Code: the line to open at (where the name is defined, or the first line with the query's words).
    let focus: Double?
    let excerpt: String?    // matched words are wrapped in « »
    let matchedMeaning: Bool
    let matchedWords: Bool
    let modified: Date
    let size: Int64
    let info: [String: String]
    /// The query's words (`Searcher.terms`): what the preview highlights on a page or in a passage.
    let terms: [String]

    init(_ hit: SearchHit, terms: [String] = []) {
        id = hit.path
        url = URL(fileURLWithPath: hit.path)
        name = url.lastPathComponent
        // Code says where it is in its repo: "billing/payments".
        if hit.kind == .code, let repo = hit.info["repo"], hit.path.hasPrefix(repo + "/") {
            let parent = (repo as NSString).deletingLastPathComponent
            folder = String(url.deletingLastPathComponent().path.dropFirst(parent.count + 1))
        } else {
            folder = tildePath(url.deletingLastPathComponent().path)
        }
        kind = hit.kind
        segment = hit.segment
        segmentID = hit.segmentID
        loc = hit.loc
        locEnd = hit.locEnd
        focus = hit.focus
        excerpt = hit.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        matchedMeaning = (hit.z ?? 0) >= 2
        matchedWords = hit.keywordRank != nil
        modified = Date(timeIntervalSince1970: hit.modified)
        size = hit.size
        info = hit.info
        self.terms = terms
    }

    /// The name to show: left to right as Finder shows it, also when it starts in Arabic ("ملاحظة.md", not "md.ملاحظة").
    var title: String { "\u{200E}" + name }

    /// The words keyword search found in the excerpt (marked « »), as they're written there.
    var foundWords: [String] {
        guard let excerpt else { return [] }
        var words: [String] = []
        var rest = excerpt[...]
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            let word = String(rest[rest.index(after: open)..<close])
            if !word.isEmpty, !words.contains(word) { words.append(word) }
            rest = rest[rest.index(after: close)...]
        }
        return words
    }

    /// The page or moment that matched, as a badge: "p. 3", "0:06", "♪ 0:25" (a video's sound), "L12–40" (code).
    var place: String? {
        guard let loc else { return nil }
        switch segment {
        case .page, .pageImage: return "p. \(Int(loc))"
        case .frame: return Self.clock(loc)
        case .audio: return kind == .video ? "♪ \(Self.clock(loc))" : Self.clock(loc)
        case .lines: return Int(loc) == Int(locEnd ?? loc) ? "L\(Int(loc))" : "L\(Int(loc))–\(Int(locEnd ?? loc))"
        case .cells: return span
        default: return nil
        }
    }

    /// The lines (or a notebook's cells) of code that matched: "lines 12–40", "cell 3".
    var span: String? {
        guard let loc else { return nil }
        let (first, last) = (Int(loc), Int(locEnd ?? loc))
        switch segment {
        case .lines: return first == last ? "line \(first)" : "lines \(first)–\(last)"
        case .cells: return first == last ? "cell \(first)" : "cells \(first)–\(last)"
        default: return nil
        }
    }

    /// What the preview shows: the moment or the page that matched, else the file.
    var previewKey: String { "\(id)|\(loc.map { "\($0)" } ?? "")" }

    var duration: Double? { info["duration"].flatMap(Double.init) }

    /// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06".
    var reason: String {
        guard matchedMeaning else { return matchedWords ? "Has your words" : "Matches its name" }
        let place = loc.map(Self.clock) ?? ""
        let page = loc.map { "page \(Int($0))" } ?? "a page"
        switch segment {
        case .image: return kind == .screenshot ? "Matches what's on screen" : "Matches the picture"
        case .ocr: return "Matches the text in it"
        case .frame: return "Matches the frame at \(place)"
        case .audio: return kind == .video ? "Matches the sound at \(place)" : "Matches what's heard at \(place)"
        case .page: return "Matches the text on \(page)"
        case .pageImage: return "Matches \(page)"
        case .chunk: return "Matches its text"
        case .name: return "Matches its name"
        case .lines, .cells: return "Matches \(span ?? "the code")"
        }
    }

    /// "Screenshot · Oct 1, 2026 · 1440 × 900 · 2.1 MB", "PDF · … · 463 pages, 120 read so far · 23 MB",
    /// "Python · 63 lines · Oct 1, 2026 · 2 KB"
    var details: String {
        if kind == .code {
            var parts = [CodeExtractor.language(of: url.path)]
            if let cells = info["cells"].flatMap(Int.init) {
                parts.append(cells == 1 ? "1 cell" : "\(cells) cells")
            } else if let lines = info["lines"].flatMap(Int.init) {
                parts.append(lines == 1 ? "1 line" : "\(lines.formatted()) lines")
            }
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
            if size > 0 { parts.append(bytes(size)) }
            return parts.joined(separator: " · ")
        }
        var parts = [kind.title, modified.formatted(date: .abbreviated, time: .omitted)]
        if let width = info["width"], let height = info["height"] { parts.append("\(width) × \(height)") }
        // A long file still being read (`Indexer.finishLongFiles`): what isn't read yet can't match.
        let readTo = info["read_to"].flatMap(Int.init)
        if let pages = info["pages"].flatMap(Int.init) {
            parts.append((pages == 1 ? "1 page" : "\(pages) pages") + (readTo.map { ", \($0) read so far" } ?? ""))
        } else if readTo != nil {
            parts.append("partly read so far")
        }
        if let duration { parts.append(Self.clock(duration)) }
        if size > 0 { parts.append(bytes(size)) }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// How results are grouped in the panel, and the kind filters in the window.
enum ResultGroupKind: CaseIterable {
    case screenshots, images, documents, video, audio
    /// Code search's results (the code index; a search of it never shows anything else).
    case code

    /// The kinds of files the main index holds: the window's kind filters, ⌘2 to ⌘6.
    static let files: [ResultGroupKind] = [.screenshots, .images, .documents, .video, .audio]

    init(_ kind: FileKind) {
        switch kind {
        case .screenshot: self = .screenshots
        case .image: self = .images
        case .pdf, .doc: self = .documents
        case .video: self = .video
        case .audio: self = .audio
        case .code: self = .code
        }
    }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .images: "Images"
        case .documents: "Documents"
        case .video: "Video"
        case .audio: "Audio"
        case .code: "Code"
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: FileKind.screenshot.symbol
        case .images: FileKind.image.symbol
        case .documents: FileKind.doc.symbol
        case .video: FileKind.video.symbol
        case .audio: FileKind.audio.symbol
        case .code: FileKind.code.symbol
        }
    }

    var kinds: Set<FileKind> {
        switch self {
        case .screenshots: [.screenshot]
        case .images: [.image]
        case .documents: [.pdf, .doc]
        case .video: [.video]
        case .audio: [.audio]
        case .code: [.code]
        }
    }
}

struct ResultGroup: Identifiable, Equatable {
    let kind: ResultGroupKind
    let rows: [ResultRow]
    /// Strong results of this kind, shown or not (the panel shows a few).
    var total: Int
    var id: ResultGroupKind { kind }
}

/// Search results the way they're shown: the strong ones grouped by kind (the best hit's group first, as many rows per
/// group as there's room for), and the weaker ones (below half the top score) folded underneath.
struct ResultSet: Equatable {
    var groups: [ResultGroup] = []
    /// The strong ones in score order (the window's grid; the panel shows `groups`).
    var ranked: [ResultRow] = []
    var weaker: [ResultRow] = []

    static let empty = ResultSet()

    init() {}

    init(_ hits: [SearchHit], query: String = "", rowsPerGroup: Int = .max) {
        let strong = Searcher.strongCount(hits)
        let terms = Searcher.terms(query)
        var order: [ResultGroupKind] = []
        var byGroup: [ResultGroupKind: [ResultRow]] = [:]
        ranked = hits.prefix(strong).map { ResultRow($0, terms: terms) }
        for row in ranked {
            let group = ResultGroupKind(row.kind)
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(row)
        }
        groups = order.map {
            ResultGroup(kind: $0, rows: Array(byGroup[$0]!.prefix(rowsPerGroup)), total: byGroup[$0]!.count)
        }
        weaker = hits.dropFirst(strong).map { ResultRow($0, terms: terms) }
    }

    var strongRows: [ResultRow] { groups.flatMap(\.rows) }
    var isEmpty: Bool { groups.isEmpty && weaker.isEmpty }
    var count: Int { strongRows.count + weaker.count }
}

extension FileKind {
    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .image: "Image"
        case .pdf: "PDF"
        case .doc: "Document"
        case .audio: "Audio"
        case .video: "Video"
        case .code: "Code"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .doc: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

import AVFoundation
import AppKit
import DigUpKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// Big pictures for the preview pane: the picture itself, the video frame at the moment that matched, or the PDF page
/// that matched. Cached while the panel or a window is open, and dropped with the thumbnails when they close.
final class Previews {
    static let shared = Previews()
    private let cache = NSCache<NSString, NSImage>()
    /// The text of a document's passage or a stretch of code (`Engine.text(ofSegment:code:)`), set when the app starts.
    var passage: (Int64, Bool) async -> String? = { _, _ in nil }

    init() {
        cache.totalCostLimit = 48 << 20
    }

    func cached(_ row: ResultRow, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(row, side))
    }

    func load(_ row: ResultRow, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let image = cached(row, side: side) { return image }
        var picture: CGImage?
        if row.kind == .video, let loc = row.loc {
            picture = await Self.frame(of: row.url, at: loc, pixels: side * scale)
        } else if let page = row.page {
            picture = await Self.page(page, of: row.url, pixels: side * scale, marking: row.foundWords + row.terms)
        }
        if picture == nil { picture = await Self.thumbnail(row.url, side: side, scale: scale) }
        guard let picture else { return nil }
        let image = NSImage(cgImage: picture, size: NSSize(width: CGFloat(picture.width) / scale,
                                                           height: CGFloat(picture.height) / scale))
        cache.setObject(image, forKey: key(row, side), cost: picture.bytesPerRow * picture.height)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// What a picture depends on: the file, the page or moment, and for a page the words marked on it.
    func key(_ row: ResultRow, _ side: CGFloat) -> NSString {
        "\(Int(side)) \(row.previewKey) \(row.page == nil ? "" : (row.foundWords + row.terms).joined(separator: " "))"
            as NSString
    }

    /// The frame at `seconds` (within half a second, so it's a quick seek).
    private nonisolated static func frame(of url: URL, at seconds: Double, pixels: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Page `number` (1-based), fitted into a square of `pixels`, with `words` marked where they're on it, the way
    /// Preview marks what you searched for. With marks, it shows the band of the page around them (as wide as the page,
    /// 2:3 as high), so the words can be read in a small preview.
    private nonisolated static func page(_ number: Int, of url: URL, pixels: CGFloat, marking words: [String]) async
        -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: max(0, number - 1)) ?? document.page(at: 0) else { return nil }
            let transform = page.transform(for: .cropBox)
            let bounds = page.bounds(for: .cropBox).applying(transform)
            let marks = Self.places(of: words, on: page)
            var shown = CGRect(origin: .zero, size: bounds.size)
            if let first = marks.first?.applying(transform) {
                let height = min(bounds.height, bounds.width / 1.5)
                let top = min(max(0, first.midY - height * 0.55), bounds.height - height)
                shown = CGRect(x: 0, y: top, width: bounds.width, height: height)
            }
            let scale = pixels / max(shown.width, shown.height, 1)
            let width = max(1, Int(shown.width * scale)), height = max(1, Int(shown.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -shown.minX, y: -shown.minY)
            page.draw(with: .cropBox, to: context)
            if !marks.isEmpty {
                context.concatenate(transform)
                context.setBlendMode(.multiply)
                context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.85))
                for rect in marks { context.fill(rect.insetBy(dx: -1, dy: -1)) }
            }
            return context.makeImage()
        }.value
    }

    /// Where `words` are on `page` (as keyword search finds them: `SearchText.matches`), in page space.
    private nonisolated static func places(of words: [String], on page: PDFPage) -> [CGRect] {
        guard let text = page.string, !text.isEmpty else { return [] }
        var rects: [CGRect] = []
        for word in Set(words.filter { $0.count >= 2 }) {
            for found in SearchText.matches(of: word, in: text).prefix(200) {
                guard let selection = page.selection(for: NSRange(found, in: text)) else { continue }
                rects += selection.selectionsByLine().map { $0.bounds(for: page) }
            }
        }
        return rects
    }

    /// Quick Look's picture of the file (the system caches these across apps).
    private nonisolated static func thumbnail(_ url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}

/// The selected result, big: its picture (or the frame or page that matched), what it is, and why it's here.
struct PreviewPane: View {
    let row: ResultRow
    /// The picture's box.
    let imageSize: CGSize
    /// A double-click on the picture or passage: the file in its app, like Open.
    var open: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewPicture(row: row, size: imageSize, open: open)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([row.url])
                } label: {
                    Text(row.folder).lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                Text(row.details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 12)
            WhyItMatched(row: row)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
    }
}

/// Open and Show in Finder, under the preview (the panel and the window).
struct PreviewActions: View {
    let row: ResultRow
    let open: () -> Void
    let reveal: () -> Void
    var controlSize: ControlSize = .regular

    var body: some View {
        HStack(spacing: 8) {
            Button(row.openTitle, action: open)
                .keyboardShortcut(.defaultAction)
            Button("Show in Finder", action: reveal)
        }
        .controlSize(controlSize)
    }
}

/// The picture part of the preview. A video's moment sits on the frame as a scrub bar; audio has no picture, so it
/// gets its moment on a timeline instead.
struct PreviewPicture: View {
    let row: ResultRow
    let size: CGSize
    /// Double-click opens it, as in Finder's and Spotlight's previews (not on the player or its controls).
    var open: () -> Void = {}
    @State private var image: NSImage?
    @State private var loaded = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if row.kind == .audio {
                AudioMoment(row: row)
                    .frame(height: min(size.height, 150))
            } else if row.kind == .code {
                CodeLines(row: row)
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .onTapGesture(count: 2, perform: open)
            } else if row.segment == .chunk {
                Passage(row: row)
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .onTapGesture(count: 2, perform: open)
            } else if row.moment != nil, let player = PreviewPlayback.shared.player,
                      PreviewPlayback.shared.isCurrent(row) {
                PlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: size.width, maxHeight: size.height)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomLeading) { marks }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: open)
                    .overlay { if row.moment != nil { PlayButton(row: row) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .frame(maxWidth: size.width, maxHeight: size.height)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                            .resizable()
                            .frame(width: 64, height: 64)
                            .opacity(loaded ? 1 : 0.4)
                    }
                    .overlay(alignment: .bottomLeading) { marks }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: open)
                    .frame(maxWidth: size.width, maxHeight: size.height)
            }
        }
        .frame(height: row.kind == .audio ? min(size.height, 150) : size.height)
        .onChange(of: row.previewKey) { PreviewPlayback.shared.stop() }
        // The pane went away (the weaker-matches row selected, no results, the window's preview hidden): no sound
        // without its controls.
        .onDisappear { if PreviewPlayback.shared.isCurrent(row) { PreviewPlayback.shared.stop() } }
        .task(id: Previews.shared.key(row, max(size.width, size.height))) {
            guard row.segment != .chunk, row.kind != .code else { return }
            let side = max(size.width, size.height)
            image = Previews.shared.cached(row, side: side)
            loaded = image != nil
            if image == nil {
                image = await Previews.shared.load(row, side: side, scale: scale)
                loaded = true
            }
        }
    }

    /// The page or moment that matched, on the picture; for a video, where in it.
    @ViewBuilder private var marks: some View {
        if let place = row.place {
            VStack(alignment: .leading, spacing: 7) {
                PlaceBadge(text: place, onImage: true)
                if row.kind == .video, let loc = row.loc, let duration = row.duration, duration > 0 {
                    MomentBar(start: loc, end: row.locEnd ?? loc + 3, duration: duration, onImage: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                if row.kind == .video {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

/// An audio hit: the stretch that matched, on the file's timeline.
struct AudioMoment: View {
    let row: ResultRow
    private var playback: PreviewPlayback { .shared }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Brand.gradient)
                Button { playback.toggle(row) } label: {
                    Image(systemName: playback.isCurrent(row) && playback.isPlaying ? "pause.circle.fill"
                                                                                     : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(row.loc.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
            }
            if let loc = row.loc {
                VStack(spacing: 5) {
                    if let duration = row.duration, duration > 0 {
                        MomentBar(start: loc, end: row.locEnd ?? loc + 30, duration: duration,
                                  playhead: playback.isCurrent(row) ? playback.time : nil)
                            .frame(maxWidth: 260)
                    }
                    Text(playback.isCurrent(row) ? "\(ResultRow.clock(playback.time)) – playing from "
                         + ResultRow.clock(loc) : span(from: loc))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// "0:25 – 0:55 of 3:12"
    private func span(from start: Double) -> String {
        let end = row.locEnd ?? start + 30
        let total = row.duration.map { " of " + ResultRow.clock($0) } ?? ""
        return ResultRow.clock(start) + " – " + ResultRow.clock(end) + total
    }
}

/// "Matches the frame at 0:06" and the words it has, if any.
struct WhyItMatched: View {
    let row: ResultRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(row.reason)
            } icon: {
                Image(systemName: row.matchedMeaning ? "sparkle.magnifyingglass" : "textformat")
                    .foregroundStyle(row.matchedMeaning ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
            }
            .font(.system(size: 12, weight: .medium))
            // Code shows its lines above, the words marked there.
            if let excerpt = row.excerpt, row.kind != .code {
                Text(highlighted(excerpt, size: 12))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.leading, 22)
                    .textSelection(.enabled)
            }
        }
    }
}

/// ▶ on a video's frame: plays it in the pane from the moment that matched.
struct PlayButton: View {
    let row: ResultRow

    var body: some View {
        Button { PreviewPlayback.shared.play(row) } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(row.moment.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
        .accessibilityLabel(row.moment.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
    }
}

/// The part of a document that matched, on a page-like card, with the query's words marked.
struct Passage: View {
    let row: ResultRow
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(marked)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Color.black.opacity(0.85))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .scrollIndicators(.never)
        .environment(\.layoutDirection, Self.isRightToLeft(text ?? row.excerpt ?? "") ? .rightToLeft : .leftToRight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .overlay(alignment: .bottomTrailing) {
            if let part = partLabel { PlaceBadge(text: part, onImage: true).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12),
                                                                                    lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .task(id: row.previewKey) { text = await Previews.shared.passage(row.segmentID, false) }
    }

    /// "Part 2 of 5", when the document has more than one.
    private var partLabel: String? {
        guard let part = row.loc.map(Int.init), let parts = row.info["chunks"].flatMap(Int.init), parts > 1 else {
            return nil
        }
        return "Part \(part) of \(parts)"
    }

    /// Up to ~900 characters from just before the first marked word, the words marked like a search in Preview.
    private var marked: AttributedString {
        let source = text ?? row.excerpt?.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "") ?? ""
        let words = Set((row.foundWords + row.terms).filter { $0.count >= 2 })
        let first = words.compactMap { SearchText.matches(of: $0, in: source).first?.lowerBound }.min()
        var start = source.startIndex
        if let first, source.distance(from: source.startIndex, to: first) > 200 {
            start = source.index(first, offsetBy: -160)
            while start < first, !source[start].isWhitespace { start = source.index(after: start) }
        }
        let window = String(source[start...].prefix(900))
        let lead = start > source.startIndex ? "…" : ""
        var result = AttributedString(lead + window + (source.distance(from: start, to: source.endIndex) > 900 ? "…" : ""))
        let shown = String(result.characters)
        for word in words {
            for found in SearchText.matches(of: word, in: shown) {
                guard let range = Range(found, in: result) else { continue }
                result[range].backgroundColor = Color(red: 1, green: 0.86, blue: 0.2)
                result[range].foregroundColor = .black
            }
        }
        return result
    }

    /// Arabic or Hebrew text reads from the right.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFEFC).contains(scalar.value)
        }
        return false
    }
}

/// The lines of code that matched, numbered as in the file, in a monospaced card like an editor's: the query's words
/// are marked, the line it opens at is lit, and the card opens scrolled to it. Long lines run past the edge.
struct CodeLines: View {
    let row: ResultRow
    @State private var text: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(number(offset))
                                .foregroundStyle(.tertiary)
                                .frame(width: gutter, alignment: .trailing)
                            Text(marked(line))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.vertical, 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isFocus(offset) ? Brand.amber.opacity(0.16) : Color.clear)
                        .id(offset)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: text) {
                if let target = focusOffset ?? firstMarked, target > 3 { proxy.scrollTo(target - 2, anchor: .top) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(alignment: .bottomTrailing) {
            if let span = row.span { PlaceBadge(text: span, onImage: true).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1),
                                                                                    lineWidth: 0.5))
        .task(id: row.previewKey) { text = await Previews.shared.passage(row.segmentID, true) }
    }

    private var lines: [String] {
        (text ?? "").split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
    }

    /// A stretch's lines are the file's; a notebook's stretch has no numbers of its own, so its lines count from 1.
    private var firstNumber: Int { row.segment == .lines ? Int(row.loc ?? 1) : 1 }

    private func number(_ offset: Int) -> String { "\(firstNumber + offset)" }

    private var gutter: CGFloat { CGFloat(String(firstNumber + max(lines.count, 1)).count) * 7 + 2 }

    /// The line it opens at, in the stretch.
    private var focusOffset: Int? {
        guard row.segment == .lines, let focus = row.focus else { return nil }
        return Int(focus) - firstNumber
    }

    private func isFocus(_ offset: Int) -> Bool { offset == focusOffset }

    private var words: [String] {
        Array(Set((row.foundWords + row.terms).filter { $0.count >= 2 }))
    }

    private var firstMarked: Int? {
        lines.firstIndex { line in words.contains { !SearchText.matches(of: $0, in: line).isEmpty } }
    }

    private func marked(_ line: String) -> AttributedString {
        var result = AttributedString(line.isEmpty ? " " : line)
        for word in words {
            for found in SearchText.matches(of: word, in: line) {
                guard let range = Range(found, in: result) else { continue }
                result[range].backgroundColor = Color(red: 1, green: 0.86, blue: 0.2)
                result[range].foregroundColor = .black
            }
        }
        return result
    }
}

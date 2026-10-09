import AVFoundation
import AVKit
import AppKit
import DigUpKit
import Observation
import PDFKit
import Quartz
import SwiftUI

// The page or moment that matched, wherever a result is looked at: Quick Look (Space) opens there, the default app
// opens there when it can be told to, and the preview pane plays a recording from there.

extension ResultRow {
    /// The PDF page that matched (1-based).
    var page: Int? {
        guard kind == .pdf, segment == .page || segment == .pageImage, let loc else { return nil }
        return Int(loc)
    }

    /// Seconds into a recording where the match starts.
    var moment: Double? {
        guard kind == .video || kind == .audio, segment == .frame || segment == .audio else { return nil }
        return loc
    }

    /// Where opening or Quick Look should go when it isn't the start: a page after the first, or a moment ("p. 3",
    /// "0:06").
    var jump: String? {
        if let page, page > 1 { return place }
        if let moment, moment >= 1 { return place }
        return nil
    }

    /// Quick Look's display state for the page or moment: what its own previews report as you page through a PDF or
    /// play a movie (`QLPreviewPanel.displayState`, "the currently displayed page … or the position in a movie").
    var quickLookState: [String: Any]? {
        if let page, page > 1 { return ["CurrentPage": page - 1] }
        if let moment, moment >= 1 { return ["CurrentTime": moment] }
        return nil
    }

    /// "Open at 0:06" when the recording's app can be told the moment (QuickTime Player, IINA), else "Open". A PDF
    /// opens with your words in Preview's search, but Preview doesn't go to the page by itself. Code opens in the
    /// editor chosen for it: "Open in Zed".
    var openTitle: String {
        if kind == .code, !CodeEditor.current.id.isEmpty { return "Open in \(CodeEditor.current.name)" }
        if let moment, moment >= 1, Opener.jumpsToMoments(url) { return "Open at \(Self.clock(moment))" }
        return "Open"
    }

    /// The line a code result opens at: where the name is defined or the query's words are, else where its stretch
    /// starts (a notebook's at its top: editors can't be told a cell).
    var codeLine: Int {
        segment == .lines ? max(1, Int(focus ?? loc ?? 1)) : 1
    }
}

/// Quick Look (Space) at the page or moment. Quick Look's panel takes a display state only once its preview is up:
/// set within ~0.1 s it's ignored (and a movie plays from the start); from ~0.6 s it holds, checked on screen
/// 2026-10-08. What it reads back is just the last value set, so it can't confirm the jump: it's set at 0.6 s and once
/// more at 1.2 s for a file that loads slowly (the time is absolute, so a second set that isn't needed changes nothing).
enum QuickLookMoment {
    private static var generation = 0

    static func show(_ row: ResultRow?, in panel: QLPreviewPanel) {
        generation += 1
        let current = generation
        guard let row, let state = row.quickLookState else { return }
        for delay in [0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard current == generation, panel.isVisible,
                      (panel.currentPreviewItem?.previewItemURL)?.path == row.url.path else { return }
                panel.displayState = state
                if delay == 0.6 { log("quick look: \(row.name) at \(row.place ?? "?")") }
            }
        }
    }
}

extension Engine {
    /// Opens `row` in its app: a PDF with words from its page to search for, a recording at its moment when the app
    /// can be told it (see `Opener`).
    func open(_ row: ResultRow) {
        if row.kind == .code { return CodeEditor.current.open(row.url, line: row.codeLine) }
        guard let page = row.page else { return Opener.open(row, searching: nil) }
        let (url, words) = (row.url, row.foundWords + row.terms)
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> String? in
                // The PDF's own text, as Preview will search it (not the index's, which may come from OCR).
                guard let document = PDFDocument(url: url), document.pageCount >= page else { return nil }
                let texts = (0..<page).map { document.page(at: $0)?.string ?? "" }
                return Landmark.find(page: page, texts: texts, words: words)
            }.value
            Opener.open(row, searching: found)
        }
    }
}

/// Opens a result in its app:
/// - a PDF page: with words from that page to search for, as Spotlight opens documents (Preview fills its search with
///   them and lists the matches by page; it doesn't go to the first one by itself, checked 2026-10-08)
/// - a moment in QuickTime Player: it's asked to go there (macOS asks once whether DigUp may control it; without
///   that, the recording opens at the start)
/// - a moment in IINA: its URL scheme takes a start time
enum Opener {
    static let quickTime = "com.apple.QuickTimePlayerX"
    static let iina = "com.colliderli.iina"
    /// Debug runs (`-debugOpen dry`): say how it would open, and don't.
    static var dryRun = false

    /// The file's app can be told where in a recording to start.
    static func jumpsToMoments(_ url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return [quickTime, iina].contains(Bundle(url: app)?.bundleIdentifier)
    }

    /// `words`: what to search for in a PDF (`Landmark.find`).
    static func open(_ row: ResultRow, searching words: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: row.url) else {
            if !dryRun { NSWorkspace.shared.open(row.url) }
            return
        }
        let appID = Bundle(url: app)?.bundleIdentifier
        let appName = app.deletingPathExtension().lastPathComponent
        let moment = row.moment.flatMap { $0 >= 1 ? $0 : nil }
        if dryRun {
            let how = if let words { "searching “\(words)”" }
                else if let moment, appID == iina || appID == quickTime { "at \(ResultRow.clock(moment))" }
                else { "at the start" }
            log("open (dry run): \(row.name) in \(appName) \(how)")
            return
        }
        if let words {
            log("open: \(row.name) in \(appName), searching “\(words)”")
            // The event alone, as the app's first event: given the file as well, NSWorkspace sends its own event,
            // without the search.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.appleEvent = openEvent(row.url, searching: words)
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else if let moment, appID == iina, let link = iinaLink(row.url, at: moment) {
            log("open: \(row.name) at \(ResultRow.clock(moment)) in IINA")
            NSWorkspace.shared.open(link)
        } else if let moment, appID == quickTime {
            log("open: \(row.name) at \(ResultRow.clock(moment)) in QuickTime Player")
            openInQuickTime(row.url, at: moment)
        } else {
            log("open: \(row.name)")
            NSWorkspace.shared.open(row.url)
        }
    }

    /// The Open Documents event, with the text to search for in them (keyAESearchText).
    static func openEvent(_ url: URL, searching text: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: url), at: 0)
        event.setParam(files, forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyAESearchText))
        return event
    }

    static func iinaLink(_ url: URL, at seconds: Double) -> URL? {
        var components = URLComponents(string: "iina://open")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                  URLQueryItem(name: "mpv_start", value: String(format: "%.1f", seconds))]
        return components?.url
    }

    /// osascript rather than NSAppleScript: macOS's "control QuickTime Player?" question would otherwise block the
    /// main thread until it's answered. The time goes over as whole milliseconds (a decimal point depends on locale).
    private static func openInQuickTime(_ url: URL, at seconds: Double) {
        let script = """
            on run argv
                set theFile to POSIX file (item 1 of argv)
                set theTime to (item 2 of argv as integer) / 1000
                tell application "QuickTime Player"
                    activate
                    set theDocument to open theFile
                    set current time of theDocument to theTime
                    try
                        set miniaturized of (first window whose document is theDocument) to false
                    end try
                    play theDocument
                    return current time of theDocument
                end tell
            end run
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path, String(Int(seconds * 1000))]
        let errors = Pipe(), output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else {
                let at = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    log("open: QuickTime Player is at \(at.trimmingCharacters(in: .whitespacesAndNewlines)) s")
                }
                return
            }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                log("open: QuickTime Player didn't go to the moment (\(message.trimmingCharacters(in: .whitespacesAndNewlines)))")
                // Not allowed to control it (-1743), no answer to macOS's question (-1712), or any other failure: open
                // it the plain way (a recording that did open just comes forward).
                NSWorkspace.shared.open(url)
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Plays the selected recording in the preview pane, from the moment that matched. One at a time; it stops when the
/// selection moves, or the panel or window closes.
@Observable
final class PreviewPlayback {
    static let shared = PreviewPlayback()

    private(set) var playingKey: String?
    private(set) var isPlaying = false
    /// Seconds into the recording, while it plays.
    private(set) var time: Double = 0
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    /// Debug runs keep quiet.
    @ObservationIgnored var muted = false

    func isCurrent(_ row: ResultRow) -> Bool { playingKey == row.previewKey }

    /// Play/pause for this row; a different row starts from its moment.
    func toggle(_ row: ResultRow) {
        if isCurrent(row), let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            return
        }
        play(row)
    }

    func play(_ row: ResultRow) {
        stop()
        let player = AVPlayer(url: row.url)
        player.isMuted = muted
        let start = CMTime(seconds: row.moment ?? 0, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            guard finished else { return }
            DispatchQueue.main.async {
                // Unless it was stopped (or another one started) meanwhile.
                guard let self, let player, self.player === player, self.isPlaying else { return }
                player.play()
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
        self.player = player
        playingKey = row.previewKey
        time = row.moment ?? 0
        isPlaying = true
        log("preview: playing \(row.name) from \(ResultRow.clock(row.moment ?? 0))")
    }

    func stop() {
        guard let player else { return }
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        self.player = nil
        playingKey = nil
        isPlaying = false
    }
}

/// AVKit's player view, for a video playing in the preview pane.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

import DigUpLocalization
import AppKit
import Observation

/// State the menubar, the panel and the windows share. Engine updates arrive on the main thread.
@Observable
final class AppModel {
    var status = EngineStatus()
    var settings: AppSettings
    var hotkey: KeyCombo?
    let download: ModelDownload
    /// A newer DigUp the daily check found ("0.6.1"), until you open it (`Updates`).
    var updateAvailable: String?

    init(settings: AppSettings, download: ModelDownload) {
        self.settings = settings
        self.download = download
    }

    var hasFolders: Bool { !settings.roots.isEmpty }
    /// Code search is on (there are code folders).
    var hasCode: Bool { !settings.codeRoots.isEmpty }

    /// One line for the menu and the windows: what the index is doing.
    var statusLine: String {
        let status = self.status
        guard hasFolders else { return L10n.text("No folders chosen yet") }
        switch status.activity {
        case .starting: return L10n.text("Starting…")
        case .failed(let problem): return "⚠︎ \(problem)"
        case .syncing: return L10n.text("Checking folders…")
        case .indexing(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return L10n.format("Indexing %1$@%% · %2$@ of %3$@", String(describing: percent), String(describing: done.formatted()), String(describing: total.formatted()))
        case .finishing(let done, let total, let files):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            let which = files > 0 ? L10n.format("%1$@ long %2$@", String(describing: files.formatted()), String(describing: files == 1 ? "file" : "files")) : L10n.text("long files")
            return L10n.format("Reading the rest of %1$@ · %2$@%%", String(describing: which), String(describing: percent))
        case .idle:
            if let line = downloadLine { return line }
            if let code = status.code.indexing, code.total > 0 {
                let percent = Int((Double(code.done) / Double(code.total) * 100).rounded(.down))
                return L10n.format("Indexing code %1$@%% · %2$@ of %3$@", String(describing: percent), String(describing: code.done.formatted()), String(describing: code.total.formatted()))
            }
            let waiting = L10n.format("%1$@ %2$@ waiting", String(describing: status.pending.formatted()), String(describing: status.pending == 1 ? "file" : "files"))
            if status.pending > 0, status.paused { return L10n.format("Paused · %1$@", String(describing: waiting)) }
            if let until = status.heldUntil, !status.paused {
                // Outside the set hours: what's known to wait, and when indexing starts again.
                let when = L10n.format("indexing from %1$@", until.formatted(date: .omitted, time: .shortened))
                if status.pending > 0 { return "\(waiting) · \(when)" }
                return L10n.format("%1$@ %2$@ indexed · %3$@", status.searchable.formatted(), status.searchable == 1 ? "file" : "files", when)
            }
            if status.pending > 0, let reason = status.waitingFor { return "\(waiting) · \(reason)" }
            if status.pending > 0 { return L10n.format("%1$@ to be indexed", String(describing: waiting)) }
            if status.unfinished > 0 {
                let rest = L10n.format("%1$@ long %2$@ to finish", String(describing: status.unfinished.formatted()), String(describing: status.unfinished == 1 ? "file" : "files"))
                if status.paused { return L10n.format("Paused · %1$@", String(describing: rest)) }
                if let reason = status.waitingFor { return "\(rest) · \(reason)" }
            }
            return L10n.format("%1$@ %2$@ indexed", String(describing: status.searchable.formatted()), String(describing: status.searchable == 1 ? "file" : "files"))
                + (status.paused ? L10n.text(" · paused") : "")
        }
    }

    /// While the model isn't there, how its download goes.
    private var downloadLine: String? {
        switch download.phase {
        case .ready: nil
        case .downloading: L10n.format("Downloading the model · %1$@%%", String(describing: Int(download.fraction * 100)))
        case .verifying: L10n.text("Checking the model download…")
        case .retrying: L10n.text("Model download: waiting for the network")
        case .failed: L10n.text("⚠︎ The model download stopped")
        case .needed: status.pending > 0 ? L10n.text("The model isn't downloaded yet") : nil
        }
    }

    /// 0…1 for the menubar ring and progress bars: the model download, then an indexing pass or the rest of long files.
    var progress: Double? {
        if download.isActive { return download.fraction }
        switch status.activity {
        case .indexing(let done, let total) where total > 0: return Double(done) / Double(total)
        case .finishing(let done, let total, _) where total > 0: return Double(done) / Double(total)
        case .idle:
            guard let code = status.code.indexing, code.total > 0 else { return nil }
            return Double(code.done) / Double(code.total)
        default: return nil
        }
    }

    /// One line about the code index, for Settings → Code: "812 code files indexed", "Indexing code 42%…".
    var codeStatusLine: String {
        let code = status.code
        guard hasCode else { return L10n.text("Code search is off") }
        if !download.isReady { return L10n.text("Code is read once the model has downloaded") }
        if let indexing = code.indexing, indexing.total > 0 {
            let percent = Int((Double(indexing.done) / Double(indexing.total) * 100).rounded(.down))
            return L10n.format("Indexing code %1$@%% · %2$@ of %3$@", String(describing: percent), String(describing: indexing.done.formatted()), String(describing: indexing.total.formatted()))
        }
        let waiting = code.pending > 0 ? L10n.format(" · %1$@ waiting", String(describing: code.pending.formatted())) : ""
        if code.pending > 0, status.paused { return L10n.format("Paused · %1$@ code files waiting", String(describing: code.pending.formatted())) }
        if code.pending > 0, let reason = status.waitingFor { return L10n.format("%1$@ code files waiting · %2$@", String(describing: code.pending.formatted()), String(describing: reason)) }
        if code.pending > 0, let until = status.heldUntil {
            return L10n.format("%1$@ code files waiting · indexing from %2$@", code.pending.formatted(), until.formatted(date: .omitted, time: .shortened))
        }
        // Code is read once the other folders have nothing waiting (the helper's order).
        if code.pending > 0, status.pending > 0 {
            return L10n.format("%1$@ code %2$@ waiting · read after your other files", code.pending.formatted(), code.pending == 1 ? "file" : "files")
        }
        return L10n.format("%1$@ code %2$@ indexed", String(describing: code.searchable.formatted()), String(describing: code.searchable == 1 ? "file" : "files")) + waiting
    }

    /// A few words for the search bar while results may be incomplete: "Indexing 42%", "Downloading model · 42%".
    var activityBadge: String? {
        if download.isActive { return L10n.format("Downloading model · %1$@%%", String(describing: Int(download.fraction * 100))) }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return L10n.format("Indexing %1$@%%", String(describing: Int(Double(done) / Double(total) * 100)))
        }
        if status.paused, status.pending > 0 { return L10n.text("Indexing paused") }
        return nil
    }

    /// Why meaning search can't run yet (words still match), or nil.
    var meaningUnavailable: String? {
        guard !download.isReady else { return nil }
        if download.isActive {
            return L10n.format("Matching words only until the model has downloaded (%1$@%%)", String(describing: Int(download.fraction * 100)))
        }
        return L10n.text("Matching words only: the model isn't downloaded")
    }

    /// Why results may be incomplete right now, or nil.
    var resultsCaveat: String? {
        if let meaningUnavailable { return meaningUnavailable }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return L10n.format("Still indexing (%1$@%%): some files aren't in yet", String(describing: Int(Double(done) / Double(total) * 100)))
        }
        if status.pending > 0 {
            return L10n.format("%1$@ %2$@ indexed yet", String(describing: status.pending.formatted()), String(describing: status.pending == 1 ? "file isn't" : "files aren't"))
        }
        return nil
    }
}

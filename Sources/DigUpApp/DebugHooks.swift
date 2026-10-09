import AppKit
import Quartz
import ServiceManagement
import SwiftUI

/// Launch arguments for testing without clicks or keystrokes (the terminal has no Accessibility permission):
///
///     -debugOffscreen YES     build and draw windows and the panel but never show them or activate the app, so
///                             snapshot runs don't take the keyboard from whoever is at the Mac (no key tests then)
///     -debugMenu YES          log the menu once the index is open, then run Pause and Resume and log it again
///     -debugQuery "<text>"    open the panel and search for <text>, as if it had been typed ("": the empty panel)
///     -debugSnapshot <png>    once the final results and their pictures are showing, draw the panel into <png>
///     -debugKeys "down,space,esc,cmd+c"   then press these keys (posted through the app's own event queue, so
///                             no Accessibility permission is needed) and log what each one did. ⌘C goes to a
///                             private pasteboard. Keys: down, up, left, right, space, esc, return, cmd+c,
///                             cmd+y, cmd+o, cmd+1, cmd+2, cmd+comma and letters; `settings`, `window` and `panel`
///                             open those, `wait` waits. Each goes to the window that has the keyboard. With
///                             -debugWindow search they test the window instead.
///     -debugType "a|b c"      then type each query (|-separated) into the field, one key every
///                             `-debugTypeInterval` seconds (default 0.09), waiting for its final results; the panel
///                             logs how long after the last keystroke they arrived
///     -debugSelect "<name>"   before the snapshot, select the first result whose name contains <name>
///     -debugPlay YES          after the snapshot, play the selected recording from its moment (muted) for 1.5 s and
///                             log where playback got to
///     -debugOpen dry|YES      then open the selected result: `dry` logs where and how it would open (the page's
///                             words for Preview, QuickTime Player at the moment…) without opening; YES opens it
///                             (another app comes forward, so only with someone at the Mac)
///     -debugQuickLook YES     then show Quick Look on the selected result for 2.5 s, log its display state and draw
///                             it into <snapshot>-quicklook.png (on screen: it takes the keyboard)
///     -debugLoginItem YES     turn open-at-login on, log what macOS says, then off again (a signed build in
///                             /Applications; macOS shows a notification)
///     -debugQuit YES          quit after that
///     -debugPauseAfter S / -debugResumeAfter S   press Pause / Resume S seconds after launch
///     -debugFolders a:b -debugFoldersAfter S     choose these folders S seconds after launch (as Settings would)
///     -debugCodeFolders a:b|off -debugCodeFoldersAfter S   the same for code search's folders ("off" turns it off)
///     -debugIcon <png>        draw the menubar icon idle, at 0%, 42% and 90%, paused, and with an update waiting
///     -debugHotkeyCheck a,b   log what the shortcut recorder would say about each combination ("cmd+space"…)
///     -debugMenuView <png>    draw the top of the menu (status, detail, progress) into <png>, after
///                             -debugMenuViewAfter seconds
///     -debugReshow N          after the query's final results, hide and show the panel N times (logs show times)
///     -debugWindow PAGE       open a window instead of the panel and snapshot it: search (with -debugQuery),
///                             settings:general|folders|code|storage, settings:add (Folders with Add Folders open),
///                             settings:addcode (Code with its folders' sheet open),
///                             onboarding:welcome|folders|code|shortcut|ready
///                             (-debugCloseWindow YES closes it afterwards, to measure what closing gives back)
///     -debugChoices "open:real;click:real/videos;add:<path>"   before the snapshot, act on the folder list of
///                             onboarding's folder step or of Add Folders, then log what it would apply. Actions,
///                             `;`-separated: open:NAME (show a folder's subfolders), click:NAME (a folder's
///                             checkbox) or click:NAME/SUB (a subfolder's), add:PATH and skip:PATH (as picked in the
///                             open panel), unskip:PATH, types:heic,txt. NAME is the end of a listed folder's path.
///     -debugAdd YES           after the snapshot, press Add Folders' Add (or the code sheet's) and log what it applied
///     -debugFocus YES         with -debugWindow search: the field has the cursor (its ring shows) in the snapshot
///     -debugUpdateCheck YES   check for updates in the background a second after launch, as the daily check does
///     -debugQuitAfter S       log the menu and quit S seconds after launch (a downloaded update installs on quit)
///     -debugWaitForIndex YES  wait for the model and an idle index with nothing waiting, then search for
///                             -debugQuery in the panel (<snapshot>-5-panel.png), as -debugOnboarding auto ends
///     -debugOnboarding auto   first launch, start to finish: snapshot each onboarding step (<snapshot>-1-welcome.png
///                             …), continue through it (the download starts, the folders apply), wait for the model
///                             and the first index, then search for -debugQuery in the panel (<snapshot>-N-panel.png)
///     -debugSearchCode YES    on onboarding's code step (or -debugWindow onboarding:code), turn code search on
///     -codeLocations a:b      the folders offered for code search (dev runs offer none without it)
enum DebugHooks {
    /// A debug run that decides what to show (the window a launch by hand opens would get in its way).
    static var drivesUI: Bool {
        ["debugOnboarding", "debugWindow", "debugQuery", "debugLoginItem", "debugWaitForIndex", "debugMenu",
         "debugMenuView", "debugIcon", "debugKeys", "debugType"].contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    static func run(_ app: AppController) {
        _ = launched   // first-launch stamps count from here
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "debugOnboarding") == "auto" {
            return runOnboarding(app)
        }
        if let page = defaults.string(forKey: "debugWindow") {
            return showWindow(page, app)
        }
        if defaults.bool(forKey: "debugLoginItem") {
            return loginItem(app)
        }
        if defaults.bool(forKey: "debugWaitForIndex") {
            return waitForFirstIndex(app)
        }
        if defaults.object(forKey: "debugPauseAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugPauseAfter")) {
                log("debug: Pause")
                app.engine.setPaused(true)
            }
        }
        if defaults.object(forKey: "debugResumeAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugResumeAfter")) {
                log("debug: Resume")
                app.engine.setPaused(false)
            }
        }
        if let folders = defaults.string(forKey: "debugFolders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugFoldersAfter")) {
                log("debug: folders → \(folders)")
                app.applyFolders(folders.split(separator: ":").map { AppSettings.folderURL(String($0)) })
            }
        }
        if let folders = defaults.string(forKey: "debugCodeFolders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugCodeFoldersAfter")) {
                log("debug: code folders → \(folders)")
                app.applyCodeFolders(folders == "off" ? [] : folders.split(separator: ":").map {
                    AppSettings.folderURL(String($0))
                }, excluded: [])
            }
        }
        if defaults.bool(forKey: "debugUpdateCheck") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                log("debug: checking for updates in the background")
                app.updates.checkInBackground()
            }
        }
        if defaults.object(forKey: "debugQuitAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugQuitAfter")) {
                log("debug: menu \(app.statusMenu.describeMenu())")
                log("debug: quitting")
                NSApp.terminate(nil)
            }
        }
        if let path = defaults.string(forKey: "debugIcon") {
            drawIcons(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        if let list = defaults.string(forKey: "debugHotkeyCheck") {
            // What the shortcut recorder would say about each combination (nothing is saved or kept registered).
            for spec in list.split(separator: ",").map(String.init) {
                guard let combo = KeyCombo(spec) else {
                    log("hotkey check: \(spec): not a usable combination")
                    continue
                }
                let free = combo == app.model.hotkey || GlobalHotkey(combo, action: {}) != nil
                log("hotkey check: \(combo.display): " + (combo.systemConflict ?? (free ? "free" : "taken by another app")))
            }
        }
        if let path = defaults.string(forKey: "debugMenuView") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugMenuViewAfter")) {
                drawMenuHeader(app, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        if defaults.bool(forKey: "debugMenu") {
            let menu = app.statusMenu!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                log("menu: \(menu.describeMenu())")
                menu.performItem(titled: "Pause Indexing")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    log("menu after Pause: \(menu.describeMenu())")
                    menu.performItem(titled: "Resume Indexing")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log("menu after Resume: \(menu.describeMenu())")
                    }
                }
            }
        }
        if let text = defaults.string(forKey: "debugQuery") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchInPanel(text, app, snapshot: snapshotPath()) {
                    if AppController.offscreen { app.panel.hide() }   // as Esc would: its pictures are dropped
                    if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private static func snapshotPath(_ suffix: String? = nil) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "debugSnapshot") else { return nil }
        let full = (path as NSString).expandingTildeInPath
        guard let suffix else { return URL(fileURLWithPath: full) }
        return URL(fileURLWithPath: (full as NSString).deletingPathExtension + "-\(suffix).png")
    }

    private static func save(_ name: String, _ draw: (URL) throws -> Void, to url: URL?) {
        guard let url else { return }
        do {
            try draw(url)
            log("snapshot: \(name) → \(url.path)")
        } catch {
            log("snapshot of \(name) failed: \(error)")
        }
    }

    /// Opens the panel with `text`, waits for its final results and pictures, snapshots it, runs the key and typing
    /// tests, then `done`.
    private static func searchInPanel(_ text: String, _ app: AppController, snapshot: URL?,
                                      then done: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let panel = app.panel!
        if text.isEmpty {   // the panel as the hotkey opens it: nothing to wait for
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                save("panel", { try panel.snapshot(to: $0) }, to: snapshot)
                done()
            }
            return
        }
        let keys = defaults.string(forKey: "debugKeys")?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? []
        if !keys.isEmpty {
            panel.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.abdurrahim.DigUp.debug"))
            panel.pasteboard.clearContents()
        }
        let typed = defaults.string(forKey: "debugType")?.split(separator: "|").map(String.init) ?? []
        let interval = defaults.object(forKey: "debugTypeInterval") == nil
            ? 0.09 : defaults.double(forKey: "debugTypeInterval")
        panel.onFinalResults = {
            panel.onFinalResults = nil
            if let name = defaults.string(forKey: "debugSelect") {
                if let row = panel.rows.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    panel.select(row)
                    log("debug: selected \(row.name) (\(row.place ?? "no page or moment"), \(row.reason))")
                } else {
                    log("debug: no result named like \"\(name)\"")
                }
            }
            whenPicturesSettle {
                save("panel", { try panel.snapshot(to: $0) }, to: snapshot)
                let row = panel.selectedRow
                play(row) {
                    openSelected(row, app) {
                        quickLook(row, panel: panel, snapshot: snapshotPath("quicklook")) {
                            press(keys, app, describe: { panelState(panel) }) {
                                type(typed, in: panel, every: interval) {
                                    reshow(panel, times: defaults.integer(forKey: "debugReshow"), then: done)
                                }
                            }
                        }
                    }
                }
            }
        }
        panel.show()
        panel.query = text
    }

    /// `-debugPlay`: plays `row` from its moment, muted, and logs where playback is 1.5 s later.
    private static func play(_ row: ResultRow?, then done: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugPlay"), let row else { return done() }
        let playback = PreviewPlayback.shared
        playback.muted = true
        playback.play(row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let at = playback.player?.currentTime().seconds ?? -1
            log("debug: playback of \(row.name) from \(ResultRow.clock(row.moment ?? 0)) is at "
                + String(format: "%.2f s", at) + " after 1.5 s (\(playback.isPlaying ? "playing" : "stopped"))")
            playback.stop()
            done()
        }
    }

    /// `-debugOpen dry|YES`: opens `row` as ↩ would (dry: only logs how).
    private static func openSelected(_ row: ResultRow?, _ app: AppController, then done: @escaping () -> Void) {
        guard let mode = UserDefaults.standard.string(forKey: "debugOpen"), let row else { return done() }
        Opener.dryRun = mode == "dry"
        app.engine.open(row)
        // A real open waits for the other app to report back (QuickTime Player says where it is).
        DispatchQueue.main.asyncAfter(deadline: .now() + (Opener.dryRun ? 0.5 : 6), execute: done)
    }

    /// `-debugQuickLook`: Space on `row`, then what Quick Look shows (it's on screen, and takes the keyboard).
    private static func quickLook(_ row: ResultRow?, panel: SearchPanelController, snapshot: URL?,
                                  then done: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugQuickLook"), row != nil else { return done() }
        panel.toggleQuickLook()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let preview = QLPreviewPanel.shared()!
            log("debug: Quick Look \(preview.isVisible ? "open" : "closed") on "
                + "\(preview.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "nothing"), state "
                + "\(String(describing: preview.displayState).replacingOccurrences(of: "\n", with: " "))")
            if let snapshot { save("quick look", { try Snapshot.capture(preview, to: $0) }, to: snapshot) }
            preview.orderOut(nil)
            done()
        }
    }

    /// Thumbnails and previews load asynchronously; give them a moment (and up to 5 s) before drawing.
    private static func whenPicturesSettle(_ body: @escaping () -> Void) {
        Thumbnails.shared.whenIdle(timeout: 5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { body() }
        }
    }

    // MARK: Windows

    private static func showWindow(_ page: String, _ app: AppController) {
        let defaults = UserDefaults.standard
        let started = Date()
        let parts = page.split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let loaded: () -> Bool
            let draw: (URL) throws -> Void
            let close: () -> Void
            var choices: () -> FolderChoices? = { nil }
            switch parts[0] {
            case "settings" where parts.count > 1 && parts[1] == "addcode":
                app.showSettings(.code)
                app.settingsWindow.addCodeFolders()
                let sheet = app.settingsWindow.codeSheet
                choices = { sheet.choices }
                loaded = { app.settingsWindow.state.isLoaded && sheet.choices?.estimatesDone ?? false }
                draw = { try sheet.snapshot(to: $0) }
                close = { sheet.end() }
            case "settings" where parts.count > 1 && parts[1] == "add":
                app.showSettings(.folders)
                app.settingsWindow.addFolders()
                let sheet = app.settingsWindow.addSheet
                choices = { sheet.choices }
                loaded = { app.settingsWindow.state.isLoaded && sheet.choices?.estimatesDone ?? false }
                draw = { try sheet.snapshot(to: $0) }
                close = { sheet.end() }
            case "settings":
                let tab = SettingsTab(rawValue: parts.count > 1 ? parts[1] : "general") ?? .general
                app.showSettings(tab)
                loaded = { app.settingsWindow.state.isLoaded }
                draw = { try app.settingsWindow.snapshot(to: $0) }
                close = {}
            case "onboarding":
                app.showOnboarding()
                let onboarding = app.onboarding!
                if parts.count > 1, let step = OnboardingState.Step.allCases.first(where: { "\($0)" == parts[1] }) {
                    onboarding.state.go(to: step)
                }
                if onboarding.state.step == .code, defaults.bool(forKey: "debugSearchCode") {
                    onboarding.state.searchCode = true
                }
                choices = {
                    switch onboarding.state.step {
                    case .folders: onboarding.state.folders
                    case .code: onboarding.state.searchCode ? onboarding.state.codeFolders : nil
                    default: nil
                    }
                }
                loaded = { onboarding.state.isLoaded }
                draw = { try onboarding.snapshot(to: $0) }
                close = { onboarding.close() }
            default:
                app.showSearchWindow(query: defaults.string(forKey: "debugQuery") ?? "")
                let search = app.searchWindow.search
                // The field with the cursor, as on screen (an offscreen window doesn't take it by itself).
                if defaults.bool(forKey: "debugFocus") { DispatchQueue.main.async { search.focusField() } }
                loaded = { search.query.isEmpty || search.hasResults }
                draw = { try app.searchWindow.snapshot(to: $0) }
                close = { app.searchWindow.close() }
            }
            let keys = defaults.string(forKey: "debugKeys")?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
            waitUntil(loaded, deadline: Date().addingTimeInterval(30)) {
                log("window: \(page) loaded in \(ms(since: started)) (after a 0.5 s launch delay)")
                if let list = choices() { act(on: list) }
                waitUntil({ choices()?.estimatesDone ?? true }, deadline: Date().addingTimeInterval(30)) {
                    whenPicturesSettle {
                        save(page, draw, to: snapshotPath())
                        if let list = choices() { log("choices: \(describe(list))") }
                        if defaults.bool(forKey: "debugAdd"), app.settingsWindow.addSheet.isOpen {
                            app.settingsWindow.addSheet.add()
                            let settings = app.model.settings
                            log("debug: added; folders \(settings.roots.map { tildePath($0.path) }) · skipping "
                                + "\(settings.excludedFolders.map { tildePath($0.path) })")
                        }
                        if defaults.bool(forKey: "debugAdd"), app.settingsWindow.codeSheet.isOpen {
                            app.settingsWindow.codeSheet.add()
                            let settings = app.model.settings
                            log("debug: added; code folders \(settings.codeRoots.map { tildePath($0.path) }) · "
                                + "skipping \(settings.codeExcluded.map { tildePath($0.path) })")
                        }
                        press(keys, app, describe: { windowState(app) }) {
                            if defaults.bool(forKey: "debugCloseWindow") {
                                close()
                                log("window: closed")
                            }
                            if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Open at login

    private static func loginItem(_ app: AppController) {
        func status() -> String {
            switch SMAppService.mainApp.status {
            case .enabled: "enabled"
            case .requiresApproval: "requires approval (System Settings → Login Items)"
            case .notRegistered: "not registered"
            case .notFound: "not found"
            @unknown default: "unknown"
            }
        }
        log("login item: \(status()) at first · app at \(Bundle.main.bundlePath)")
        let on = app.setLaunchAtLogin(true)
        log("login item: turned on → \(on ?? "ok"), now \(status())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let off = app.setLaunchAtLogin(false)
            log("login item: turned off → \(off ?? "ok"), now \(status())")
            if UserDefaults.standard.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
        }
    }

    // MARK: First launch, start to finish

    private static let launched = Date()

    private static func stamp(_ what: String) {
        log("first launch: \(what) at \(String(format: "%.1f s", Date().timeIntervalSince(launched)))")
    }


    private static func runOnboarding(_ app: AppController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let onboarding = app.onboarding else {
                log("first launch: onboarding didn't open (folders or onboarded already set?)")
                return NSApp.terminate(nil)
            }
            stamp("onboarding open")
            onboardingStep(0, onboarding, app)
        }
    }

    /// How many steps the onboarding just run had (the panel's snapshot is numbered after them).
    private static var onboardingStepCount = 4

    /// Snapshots step `index` (of the steps this Mac gets), then presses its Continue (Get Started, Continue…, Done).
    /// On the folder step, `-debugChoices` acts on the list first; on the code step, `-debugSearchCode` turns it on.
    private static func onboardingStep(_ index: Int, _ onboarding: OnboardingController, _ app: AppController) {
        let state = onboarding.state
        onboardingStepCount = state.steps.count
        guard index < state.steps.count else { return waitForFirstIndex(app) }
        let name = "\(index + 1)-\(state.step)"
        if state.step == .code, UserDefaults.standard.bool(forKey: "debugSearchCode") { state.searchCode = true }
        waitUntil({ state.isLoaded }, deadline: Date().addingTimeInterval(60)) {
            if state.step == .folders { act(on: state.folders) }
            waitUntil({ state.isLoaded }, deadline: Date().addingTimeInterval(60)) {
                whenPicturesSettle {
                    save(name, { try onboarding.snapshot(to: $0) }, to: snapshotPath(name))
                    if state.step == .folders { log("choices: \(describe(state.folders))") }
                    stamp("step \(name) done")
                    state.next()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onboardingStep(index + 1, onboarding, app) }
                }
            }
        }
    }

    // MARK: Folder lists

    /// `-debugChoices`: clicks and picks in a folder list, as described at the top.
    private static func act(on choices: FolderChoices) {
        guard let script = UserDefaults.standard.string(forKey: "debugChoices") else { return }
        func row(_ name: String) -> URL? { choices.rows.first { $0.path.hasSuffix("/" + name) } }
        for action in script.split(separator: ";").map(String.init) {
            let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (verb, name) = (parts[0], parts[1])
            switch verb {
            case "open":
                if let row = row(name) { choices.expanded.insert(row.path) } else { log("choices: no folder \(name)") }
            case "click":
                if let row = row(name) {
                    choices.toggle(row)
                } else if let row = row((name as NSString).deletingLastPathComponent) {
                    choices.toggle(subfolder: row.path + "/" + (name as NSString).lastPathComponent)
                } else {
                    log("choices: no folder \(name)")
                }
            case "add": choices.add([AppSettings.folderURL(name)])
            case "skip": choices.skip([AppSettings.folderURL(name)])
            case "unskip": choices.unskip(AppSettings.folderURL(name).path)
            case "types": choices.setTypes(name)
            default: log("choices: don't know \"\(verb)\"")
            }
            log("choices: \(action) → \(describe(choices))")
        }
    }

    /// What a folder list would apply, and how it shows.
    private static func describe(_ choices: FolderChoices) -> String {
        let marks = choices.rows.map { row in
            "\(row.lastPathComponent) \(choices.mark(row))"
                + (choices.searchedPart(of: row).map { String(format: " %.1f s", $0.seconds) } ?? "")
        }
        return "folders \(choices.roots.map { tildePath($0.path) }) · skipping \(choices.skipped.map { tildePath($0.path) })"
            + " · rows [\(marks.joined(separator: ", "))] · first pass ≈ \(roughDuration(choices.totalSeconds))"
            + (choices.note.map { " · note: \($0)" } ?? "")
    }

    private static func waitForFirstIndex(_ app: AppController) {
        var lastLog = Date()
        let finished = {
            if Date().timeIntervalSince(lastLog) > 10 {
                lastLog = Date()
                log("first launch: waiting · \(app.model.statusLine) · model \(app.download.progressText)")
            }
            guard app.download.isReady, case .idle = app.model.status.activity else { return false }
            return app.model.status.pending == 0 && app.model.status.searchable > 0
        }
        waitUntil(finished, deadline: Date().addingTimeInterval(45 * 60)) {
            stamp("model ready and first index done (\(app.model.statusLine))")
            let text = UserDefaults.standard.string(forKey: "debugQuery") ?? "zebra"
            searchInPanel(text, app, snapshot: snapshotPath("\(onboardingStepCount + 1)-panel")) {
                stamp("searched \"\(text)\"")
                if UserDefaults.standard.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
            }
        }
    }

    private static func waitUntil(_ condition: @escaping () -> Bool, deadline: Date, then body: @escaping () -> Void) {
        if condition() || Date() > deadline { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitUntil(condition, deadline: deadline, then: body) }
    }

    // MARK: Panel keys

    private static func reshow(_ panel: SearchPanelController, times: Int, then done: @escaping () -> Void) {
        guard times > 0 else { return done() }
        panel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                reshow(panel, times: times - 1, then: done)
            }
        }
    }

    /// Posts each key to the window that has the keyboard (the panel, Quick Look, a window), 0.5 s apart, and logs
    /// `describe()` after it. Not keys: `settings`, `window` and `panel` open those; `wait` just waits.
    private static func press(_ keys: [String], _ app: AppController, describe: @escaping () -> String,
                              then done: @escaping () -> Void) {
        guard let key = keys.first else { return done() }
        let next = { press(Array(keys.dropFirst()), app, describe: describe, then: done) }
        switch key {
        case "settings": app.showSettings()
        case "window": app.showSearchWindow()
        case "panel": app.panel.show()
        case "wait": break
        default:
            guard let event = keyEvent(key, window: NSApp.keyWindow?.windowNumber ?? app.panel.windowNumber) else {
                log("keys: don't know \"\(key)\"")
                return next()
            }
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let keyWindow = NSApp.keyWindow.map { window in
                window is QLPreviewPanel ? "Quick Look" : window is SearchPanelWindow ? "panel"
                    : window.title.isEmpty ? "\(Swift.type(of: window))" : window.title
            } ?? "none"
            log("keys: \(key) → \(describe()) · keyboard: \(keyWindow)" + (NSApp.isHidden ? " · app hidden" : ""))
            next()
        }
    }

    /// The panel's state, for key tests.
    private static func panelState(_ panel: SearchPanelController) -> String {
        let ids = panel.rowIDs
        let index = ids.firstIndex { $0 == panel.selection }.map { "\($0 + 1)" } ?? "-"
        let copied = panel.pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
        let selected = panel.selection == SearchPanelController.weakerToggle ? "the weaker-matches fold"
            : panel.selectedRow?.name ?? "none"
        return "row \(index) of \(ids.count) (\(selected)) · weaker \(panel.showWeaker ? "shown" : "folded") · "
            + "query \"\(panel.query)\" · panel \(panel.isVisible ? "open" : "hidden") · "
            + "Quick Look \(panel.isPreviewing ? "open" : "closed")"
            + (copied.map { " · pasteboard: \($0.lastPathComponent)" } ?? "")
    }

    /// The search window's state, for key tests.
    private static func windowState(_ app: AppController) -> String {
        let search = app.searchWindow.search
        let rows = search.rows
        let index = rows.firstIndex { $0.id == search.selectedRow?.id }.map { "\($0 + 1)" } ?? "-"
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        return "cell \(index) of \(rows.count) (\(search.selectedRow?.name ?? "none")) · columns \(search.columns) · "
            + "filter \(search.filter?.title ?? "All") · query \"\(search.query)\" · "
            + "Quick Look \(previewing ? "open" : "closed")"
    }

    /// Selects the field's text (⌘A) and types `queries[0]` a key at a time, waits for its final results, then the rest.
    private static func type(_ queries: [String], in panel: SearchPanelController, every interval: Double,
                             then done: @escaping () -> Void) {
        guard let query = queries.first else { return done() }
        var events: [NSEvent] = []
        if let selectAll = characterEvent("a", modifiers: .command, window: panel.windowNumber) { events.append(selectAll) }
        events += query.compactMap { characterEvent(String($0), modifiers: [], window: panel.windowNumber) }
        panel.onFinalResults = {
            guard panel.query == query else { return }
            panel.onFinalResults = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                type(Array(queries.dropFirst()), in: panel, every: interval, then: done)
            }
        }
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func characterEvent(_ character: String, modifiers: NSEvent.ModifierFlags, window: Int) -> NSEvent? {
        let code: UInt16 = character == " " ? 49 : letterCodes[character.lowercased()] ?? 0
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                                keyCode: code)
    }

    private static func keyEvent(_ name: String, window: Int) -> NSEvent? {
        let table: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "down": (125, "\u{F701}", []), "up": (126, "\u{F700}", []), "space": (49, " ", []),
            "esc": (53, "\u{1B}", []), "return": (36, "\r", []), "cmd+c": (8, "c", .command),
            "cmd+y": (16, "y", .command), "left": (123, "\u{F702}", []), "right": (124, "\u{F703}", []),
            "cmd+1": (18, "1", .command), "cmd+2": (19, "2", .command), "cmd+o": (31, "o", .command),
            "cmd+comma": (43, ",", .command),
        ]
        var entry = table[name]
        if entry == nil, name.count == 1, let code = letterCodes[name] { entry = (code, name, []) }
        guard let (code, characters, flags) = entry else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: code)
    }

    private static let letterCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
    ]

    /// The menu's header view, as it would show if the menu opened now.
    private static func drawMenuHeader(_ app: AppController, to url: URL) {
        let view = NSHostingView(rootView: MenuStatusView(model: app.model))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        save("menu header", { try Snapshot.write(window, to: $0, cornerRadius: 6) }, to: url)
    }

    /// The menubar icon idle, at a few progress values, paused, and with an update waiting, scaled up, black on white
    /// (as a template it takes the bar's color).
    private static func drawIcons(to url: URL) {
        let states: [(Double?, Bool, Bool)] = [(nil, false, false), (0.0, false, false), (0.42, false, false),
                                               (0.9, false, false), (nil, true, false), (nil, false, true),
                                               (0.42, false, true)]
        let scale: CGFloat = 4, side: CGFloat = 18
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale) * states.count,
                                   pixelsHigh: Int(side * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        for (index, (progress, paused, update)) in states.enumerated() {
            StatusIcon.image(progress: progress, paused: paused, update: update)
                .draw(in: NSRect(x: CGFloat(index) * side * scale, y: 0, width: side * scale, height: side * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("icon: \(url.path)")
    }
}

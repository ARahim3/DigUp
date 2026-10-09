import AppKit
import DigUpKit
import Observation
import SwiftUI

/// First launch, in four steps: what DigUp does, which folders to search (with how long the first pass takes), the
/// hotkey (try it), and done; a fifth, code search, when there are folders with code on the Mac (it stays off unless
/// you turn it on there). The model downloads from Get Started on, shown at the bottom of every later step, and
/// the chosen folders start indexing as soon as you continue past them.
final class OnboardingController: NSObject, NSWindowDelegate {
    let state: OnboardingState
    private unowned let app: AppController
    private var window: NSWindow?

    init(app: AppController) {
        self.app = app
        state = OnboardingState(app: app)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        app.present(window)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width,
                                                  height: OnboardingView.size.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to DigUp"
        window.isReleasedWhenClosed = false
        window.delegate = self
        state.close = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: OnboardingView(state: state))
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        state.leaving()
        window?.contentView = nil
        window = nil
        app.onboardingClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, folders, code, shortcut, ready
    }

    private(set) var step = Step.welcome
    /// The folders to search, with their estimates and subfolders; applied on Continue.
    let folders: FolderChoices
    /// Code search's folders, offered when the Mac has folders with code (`CodeFolders`); applied on Continue when
    /// `searchCode` is on.
    let codeFolders: FolderChoices
    var searchCode = false {
        didSet { if searchCode { codeFolders.startEstimates() } }
    }
    /// You pressed the hotkey on the shortcut step.
    private(set) var hotkeyWorked = false
    var launchAtLogin: Bool
    var indexOnBattery: Bool
    /// File types to skip as typed ("heic, txt"): applied on Return, and on Continue (a click there doesn't end the
    /// field's editing).
    var skippedTypesText: String
    @ObservationIgnored let app: AppController
    @ObservationIgnored var close: () -> Void = {}

    init(app: AppController) {
        self.app = app
        let settings = app.model.settings
        let candidates = Self.candidates()
        let chosen = settings.roots
        let selection = FolderSelection(chosen: (chosen.isEmpty ? candidates : chosen).map(\.path),
                                        skipped: settings.excludedFolders.map(\.path))
        // A chosen subfolder of a folder listed shows in that folder's list, not as a folder of its own.
        let others = chosen.filter { root in
            !candidates.contains { $0.path == root.path || $0.path == FolderSelection.parent(root.path) }
        }
        folders = FolderChoices(rows: candidates + others, selection: selection, types: settings.excludedTypes)
        let codeCandidates = CodeFolders.candidates(searched: [])
        codeFolders = FolderChoices(rows: codeCandidates,
                                    selection: FolderSelection(chosen: settings.codeRoots.isEmpty
                                                                   ? codeCandidates.map(\.path)
                                                                   : settings.codeRoots.map(\.path)),
                                    types: [], code: true)
        searchCode = !settings.codeRoots.isEmpty
        launchAtLogin = app.launchesAtLogin || app.suggestsLaunchAtLogin
        indexOnBattery = settings.indexOnBattery
        skippedTypesText = settings.excludedTypes.joined(separator: ", ")
    }

    var model: AppModel { app.model }
    var download: ModelDownload { app.download }

    /// The steps this Mac gets: code search's only when there's code to offer.
    var steps: [Step] {
        Step.allCases.filter { $0 != .code || !codeFolders.rows.isEmpty }
    }

    /// The folders it offers: the usual home folders that exist, or `-onboardingLocations a:b:c` (tests point it at
    /// the testbed, never at real folders).
    static func candidates() -> [URL] {
        if let list = UserDefaults.standard.string(forKey: "onboardingLocations") {
            return list.split(separator: ":").map { AppSettings.folderURL(String($0)) }
        }
        // A dev or test run (its own defaults suite) never offers, and so never estimates, the real home folders.
        if UserDefaults.standard.string(forKey: "defaultsSuite") != nil {
            log("onboarding: no -onboardingLocations in a dev run, so no folders are offered")
            return []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { AppSettings.folderURL(home.appendingPathComponent($0).path) }
            .filter(AppSettings.isFolder)
    }

    // MARK: Steps

    func next() {
        switch step {
        case .welcome:
            download.start()   // the go-ahead for the one download
            go(to: .folders)
        case .folders:
            // Indexing starts now (file names first; meaning once the model is in), while you set up the rest.
            folders.setTypes(skippedTypesText)
            app.applyFolders(folders.roots, excluded: folders.skipped, types: folders.types)
            go(to: steps.contains(.code) ? .code : .shortcut)
        case .code:
            if searchCode, !codeFolders.roots.isEmpty {
                app.applyCodeFolders(codeFolders.roots, excluded: codeFolders.skipped)
            } else if !searchCode, model.hasCode {
                app.applyCodeFolders([], excluded: [])
            }
            go(to: .shortcut)
        case .shortcut:
            go(to: .ready)
        case .ready:
            finish()
        }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        go(to: steps[index - 1])
    }

    func go(to step: Step) {
        self.step = step
        app.hotkeyTester = step == .shortcut ? { [weak self] in self?.hotkeyWorked = true } : nil
        if step == .folders { folders.startEstimates() }
    }

    func finish() {
        if indexOnBattery != model.settings.indexOnBattery { app.setIndexOnBattery(indexOnBattery) }
        if launchAtLogin != app.launchesAtLogin { _ = app.setLaunchAtLogin(launchAtLogin) }
        log("onboarding: done (\(model.settings.roots.count) folders, login item \(launchAtLogin ? "on" : "off"))")
        close()
    }

    /// The window is closing (Done or its close button).
    func leaving() {
        app.hotkeyTester = nil
    }

    // MARK: Folders (applied on Continue, from the first pass on; Settings has the same for later)

    func addFolders(from window: NSWindow?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.add(picked)
        }
    }

    func skipFolders(from window: NSWindow?) {
        app.pickFolders(for: window, prompt: "Skip") { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.folders.skip(picked)
        }
    }

    /// The step has what it needs to be drawn (debug snapshots wait for this).
    var isLoaded: Bool {
        switch step {
        case .folders: folders.estimatesDone
        case .code: !searchCode || codeFolders.estimatesDone
        default: true
        }
    }

    func addCodeFolders(from window: NSWindow?) {
        app.pickFolders(for: window) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.codeFolders.add(picked)
        }
    }
}

// MARK: Views

struct OnboardingView: View {
    static let size = CGSize(width: 680, height: 600)
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.step {
                case .welcome: WelcomeStep()
                case .folders: FoldersStep(state: state)
                case .code: CodeStep(state: state)
                case .shortcut: ShortcutStep(state: state)
                case .ready: ReadyStep(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.step == .welcome ? .center : .top)
            .padding(.horizontal, 48)
            .padding(.top, 46)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(alignment: .top) {
            // A soft moss glow behind the top of each step, from the icon's colors.
            Brand.wash
                .frame(height: 260)
                .mask(LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            StepDots(current: state.steps.firstIndex(of: state.step) ?? 0, count: state.steps.count)
            if state.step != .welcome {
                DownloadStatus(download: state.download)
            }
            Spacer(minLength: 8)
            if state.step == .folders || state.step == .code && state.searchCode {
                Text(state.step == .code ? codeSummary : foldersSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if state.step != .welcome, state.step != .ready {
                Button("Back") { state.back() }
            }
            Button(continueTitle) { state.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.step == .folders && state.folders.roots.isEmpty)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var continueTitle: String {
        switch state.step {
        case .welcome: "Get Started"
        case .folders: "Continue"
        case .code: "Continue"
        case .shortcut: "Continue"
        case .ready: "Done"
        }
    }

    private var codeSummary: String {
        guard !state.codeFolders.roots.isEmpty else { return "Check the folders with your code" }
        guard state.codeFolders.estimatesDone else { return "Looking at your code…" }
        let seconds = state.codeFolders.totalSeconds
        return (seconds < 1 ? "Under a second" : "About \(roughDuration(seconds))")
            + ", \(roughBytes(state.codeFolders.totalBytes))"
    }

    private var foldersSummary: String {
        guard !state.folders.roots.isEmpty else { return "Choose at least one folder" }
        guard state.folders.estimatesDone else { return "Looking at your folders…" }
        return "First pass: about \(roughDuration(state.folders.totalSeconds))"
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The model download, small: "Downloading the model · 42% · about 1 min left", then "Model ready".
struct DownloadStatus: View {
    let download: ModelDownload

    var body: some View {
        HStack(spacing: 7) {
            switch download.phase {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Model ready")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1)
                Button("Try Again") { download.start() }.controlSize(.small)
            case .needed:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                Text("Model not downloaded")
                Button("Download") { download.start() }.controlSize(.small)
            default:
                ProgressView(value: download.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Downloading the model · \(download.progressText)")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Brand.moss.opacity(0.35), radius: 14, y: 6)
            Text("DigUp")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 10)
            Text("Describe it. Dig it up.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "camera.viewfinder", title: "Screenshots and photos",
                        example: "“that payment error”, “the zebra”, “whiteboard from Tuesday”")
                Feature(symbol: "doc.text", title: "PDFs and documents",
                        example: "“the clause about pets in the lease”, “flight receipt”")
                Feature(symbol: "waveform", title: "Moments inside audio and video",
                        example: "“where they talk about sleep”, “the part with the drums”")
            }
            .padding(.top, 30)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                Text("Everything is indexed and searched on this Mac. DigUp downloads its AI model (865 MB) once; "
                     + "after that it works offline, and nothing you index ever leaves your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
            .frame(maxWidth: 470, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let example: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(example).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 470, alignment: .leading)
    }
}

struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FoldersStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "What should DigUp search?",
                      subtitle: "Pick folders, or open one to pick some of its subfolders. You can change this "
                          + "anytime in Settings.")
            ScrollView {
                VStack(spacing: 6) {
                    FolderList(choices: state.folders, addTitle: "Add Folder…") {
                        state.addFolders(from: NSApp.keyWindow)
                    }
                    SkipChoices(state: state)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("macOS will ask before DigUp can read folders like Desktop, Documents and Downloads. "
                     + "DigUp only reads files: it never changes, moves or uploads them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)
        }
    }
}

/// Folders and file types to leave out, before the first pass reads anything. Folded away unless something is set.
private struct SkipChoices: View {
    @Bindable var state: OnboardingState
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.folders.selection.effectiveSkips, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(tildePath(folder)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.folders.unskip(folder)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search this folder again")
                    }
                    .font(.system(size: 12))
                }
                Button {
                    state.skipFolders(from: NSApp.keyWindow)
                } label: {
                    Label("Skip a Folder…", systemImage: "plus")
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("File types")
                    TextField("Extensions", text: $state.skippedTypesText, prompt: Text("e.g. heic, txt"))
                        .labelsHidden()
                        .controlSize(.small)
                        .onSubmit { state.folders.setTypes(state.skippedTypesText) }
                }
                .font(.system(size: 12))
                Text("Code, keys, certificates, hidden folders, app bundles and caches are always skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            Text("Skip some folders or file types")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .onAppear {
            expanded = !state.folders.selection.effectiveSkips.isEmpty || !state.folders.types.isEmpty
        }
    }
}

/// Code search, if you want it: a switch (off until you turn it on), then the folders with code, each opening to its
/// repos with how long reading them takes and the room their index needs, and the editor results open in.
private struct CodeStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Search your code too?",
                      subtitle: "DigUp can find code by what it does: type code: in the search panel, as in "
                          + "“code: retry with backoff”. It gets an index of its own and never shows up in other "
                          + "searches. You can turn it on later in Settings → Code.")
            SwitchRow(title: "Search my code", detail: "Off unless you turn it on.", isOn: $state.searchCode)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            if state.searchCode {
                ScrollView {
                    VStack(spacing: 6) {
                        FolderList(choices: state.codeFolders, addTitle: "Add Folder…") {
                            state.addCodeFolders(from: NSApp.keyWindow)
                        }
                        CodeFolderNote().padding(.top, 4)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    Text("Open code in")
                    Picker("Open code in", selection: Binding(get: { CodeEditor.current.id },
                                                              set: { state.app.setCodeEditor($0) })) {
                        ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                        Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutStep: View {
    let state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            StepTitle(title: "Open DigUp from anywhere",
                      subtitle: "Press the shortcut in any app, describe what you're looking for, and press Return.")
            ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                             listening: { state.app.hotkeyRecording($0) }, capSize: 20)
                .padding(.top, 34)
            Group {
                if state.hotkeyWorked {
                    Label("That's it. It works from any app.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let hotkey = state.model.hotkey {
                    Text("Try it now: press \(hotkey.display).")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.top, 16)
            .animation(.default, value: state.hotkeyWorked)
            VStack(alignment: .leading, spacing: 9) {
                Text("IN THE SEARCH PANEL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                KeyTip(caps: ["↩"], text: "Open the file")
                KeyTip(caps: ["⌘", "↩"], text: "Show it in Finder")
                KeyTip(caps: ["Space"], text: "Quick Look, after arrowing to a result")
                KeyTip(caps: ["⌘", "C"], text: "Copy the file, to paste anywhere")
                KeyTip(caps: ["esc"], text: "Close")
            }
            .padding(18)
            .frame(maxWidth: 340, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 34)
        }
    }
}

private struct KeyTip: View {
    let caps: [String]
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Keycaps(caps: caps, size: 11)
                .frame(width: 66, alignment: .leading)
            Text(text).font(.system(size: 12))
        }
    }
}

private struct ReadyStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(Brand.gradient)
                .padding(.top, 8)
            Text("You're all set")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text(progressNote)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 16) {
                SwitchRow(title: "Open DigUp when you log in", detail: "So the shortcut always works.",
                          isOn: $state.launchAtLogin)
                Divider()
                SwitchRow(title: AppSettings.batteryTitle, detail: AppSettings.batteryDetail,
                          isOn: $state.indexOnBattery)
            }
            .padding(20)
            .frame(maxWidth: 470, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 28)
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                Text("DigUp lives in the menu bar, which shows how indexing is going.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressNote: String {
        let seconds = state.folders.totalSeconds, later = state.folders.totalLaterSeconds
        let time = seconds > 0 ? " (about \(roughDuration(seconds)) on this Mac)" : ""
        let rest = later >= 30 ? " Long PDFs and documents get their first pages in that time, and the rest "
            + "afterwards (about \(roughDuration(later)) more)." : ""
        if state.download.isReady {
            return "DigUp is reading your folders\(time), newest files first. You can search right away; "
                + "results fill in as it goes." + rest
        }
        return "DigUp starts reading your folders\(time) once the model has downloaded "
            + "(\(state.download.progressText)). Until then, search finds files by name." + rest
    }
}

/// A setting with a title, a line about it, and a switch on the right.
struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

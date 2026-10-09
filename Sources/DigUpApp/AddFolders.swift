import AppKit
import DigUpKit
import SwiftUI

/// Settings → Folders → Add Folders…: a sheet like onboarding's folder step. It lists the usual folders that aren't
/// searched yet and any other folder you choose, each with what's in it, how long its first pass takes and its
/// subfolders; nothing changes until Add. With nothing left to suggest, it starts from the open panel.
///
/// With `code`, Settings → Code's: folders for code search, each opening to its repos, with how long reading them
/// takes and how much room their index needs.
final class AddFoldersController {
    private unowned let app: AppController
    private(set) var choices: FolderChoices?
    private var sheet: NSWindow?
    let code: Bool
    /// The folders changed (Settings refreshes its list).
    var onAdded: () -> Void = {}

    init(app: AppController, code: Bool = false) {
        self.app = app
        self.code = code
    }

    var isOpen: Bool { choices != nil }

    func begin(on window: NSWindow?) {
        guard choices == nil else { return }
        let settings = app.model.settings
        let selection = code
            ? FolderSelection(skipped: settings.codeExcluded.map(\.path), kept: settings.codeRoots.map(\.path))
            : FolderSelection(skipped: settings.excludedFolders.map(\.path), kept: settings.roots.map(\.path))
        let suggestions = (code ? CodeFolders.candidates(searched: settings.roots) : OnboardingState.candidates())
            .filter { !selection.isSearched($0.path) }
        let choices = FolderChoices(rows: suggestions, selection: selection, types: code ? [] : settings.excludedTypes,
                                    code: code)
        self.choices = choices
        // Snapshot runs never put an open panel on screen (-debugChoices picks folders instead).
        guard suggestions.isEmpty, !AppController.offscreen else { return present(choices, on: window) }
        app.pickFolders(for: window) { [weak self] picked in
            guard let self else { return }
            guard !picked.isEmpty else {
                self.choices = nil
                return
            }
            choices.add(picked)
            present(choices, on: window)
        }
    }

    private func present(_ choices: FolderChoices, on window: NSWindow?) {
        let view = AddFoldersView(choices: choices,
                                  pick: { [weak self] in self?.pick() },
                                  cancel: { [weak self] in self?.end() },
                                  add: { [weak self] in self?.add() })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet.styleMask = [.titled]
        sheet.title = code ? "Code Folders" : "Add Folders"
        self.sheet = sheet
        choices.startEstimates()
        log("add folders: \(choices.rows.count) to choose from")
        guard !AppController.offscreen else { return }   // snapshot runs draw it without showing it
        if let window, window.isVisible { window.beginSheet(sheet) } else { app.present(sheet) }
    }

    private func pick() {
        app.pickFolders(for: sheet) { [weak self] picked in
            guard !picked.isEmpty else { return }
            self?.choices?.add(picked)
        }
    }

    func add() {
        guard let choices else { return }
        log("add \(code ? "code " : "")folders: \(choices.roots.map { tildePath($0.path) })"
            + (choices.skipped.isEmpty ? "" : " minus \(choices.skipped.map { tildePath($0.path) })"))
        if code {
            app.applyCodeFolders(choices.roots, excluded: choices.skipped)
        } else {
            app.applyFolders(choices.roots, excluded: choices.skipped)
        }
        end()
        onAdded()
    }

    func end() {
        if let sheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet = nil
        choices = nil
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(sheet, to: url)
    }
}

private struct AddFoldersView: View {
    let choices: FolderChoices
    let pick: () -> Void
    let cancel: () -> Void
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if choices.code {
                    StepTitle(title: "Search your code",
                              subtitle: "Pick the folders that hold your projects; open one to pick among its repos. "
                                  + "DigUp reads each once, then what changes. Code is searched on its own: type "
                                  + "code: in the search panel.")
                } else {
                    StepTitle(title: "Add folders to search",
                              subtitle: "DigUp reads a new folder once, then keeps up with what changes in it. "
                                  + "Open a folder to pick some of its subfolders.")
                }
                ScrollView {
                    FolderList(choices: choices, addTitle: "Choose Another Folder…", add: pick)
                    if choices.code { CodeFolderNote().padding(.top, 8) }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)
            Divider()
            HStack(spacing: 12) {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!choices.changesSomething)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .frame(height: 60)
        }
        .frame(width: 600, height: 540)
    }

    private var summary: String {
        guard choices.changesSomething else { return "Check the folders to add" }
        guard choices.estimatesDone else { return "Looking at the folders…" }
        let time = choices.totalSeconds < 1 ? "under a second" : "about \(roughDuration(choices.totalSeconds))"
        if choices.code {
            return "Adds \(time) of indexing and \(roughBytes(choices.totalBytes))"
        }
        let later = choices.totalLaterSeconds
        return "Adds \(time) of indexing"
            + (later >= 30 ? ", and \(roughDuration(later)) more for long files" : "")
    }
}

/// What code search leaves out, under a list of code folders.
struct CodeFolderNote: View {
    var body: some View {
        Label {
            Text("Code search reads source files, notebooks and a repo's own docs. It skips what git ignores, vendored "
                 + "and generated code, data files, and anything that looks like a key or a password.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

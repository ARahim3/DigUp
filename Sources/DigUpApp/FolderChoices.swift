import AppKit
import DigUpKit
import Observation
import SwiftUI

/// The folder list onboarding and Settings share: folders with what's in them and how long their first pass takes,
/// each with its subfolders one level down (biggest first), and what's chosen and skipped (`FolderSelection`). A
/// folder can be searched whole, without some of its subfolders, or only for some of them. Nothing applies here:
/// onboarding's Continue and Settings' Add hand over `roots` and `skipped`, all at once.
@Observable
final class FolderChoices {
    private(set) var rows: [URL]
    private(set) var selection: FolderSelection
    /// File types to skip (onboarding sets them here; the estimates leave them out).
    private(set) var types: [String]
    private(set) var estimates: [String: FolderEstimate] = [:]
    /// Folders showing their subfolders.
    var expanded: Set<String> = []
    /// What became of the folders picked last, when it wasn't what was asked ("searched already").
    private(set) var note: String?
    /// Folders for code search: their estimates are what code search reads there, with the room its index takes.
    let code: Bool
    @ObservationIgnored private let initial: FolderSelection
    /// Each row's latest estimate run: an answer from an earlier one (before what's skipped changed) is dropped.
    @ObservationIgnored private var runs: [String: Int] = [:]
    @ObservationIgnored private var run = 0

    init(rows: [URL], selection: FolderSelection, types: [String], code: Bool = false) {
        self.rows = rows
        self.selection = selection
        self.types = types
        self.code = code
        initial = selection
        // A folder with some of its subfolders chosen or skipped starts open, so it shows which.
        expanded = Set(rows.map(\.path).filter { row in
            (selection.chosen + selection.skipped).contains { FolderSelection.parent($0) == row }
        })
    }

    /// Estimates the rows that have none yet. They read the folders, so macOS may ask for access: only from a step
    /// that says so.
    func startEstimates() {
        estimate(rows.filter { runs[$0.path] == nil })
    }

    var estimatesDone: Bool { rows.allSatisfy { estimates[$0.path] != nil } }

    // MARK: Checkboxes

    func mark(_ row: URL) -> FolderSelection.Mark { selection.mark(row.path) }

    func isSearched(_ path: String) -> Bool { selection.isSearched(path) }

    /// A folder's checkbox: a click on a mixed one takes all of it.
    func toggle(_ row: URL) {
        note = nil
        selection.setFolder(row.path, on: mark(row) != .on)
    }

    func toggle(subfolder path: String) {
        note = nil
        selection.setSubfolder(path, on: !selection.isSearched(path))
    }

    func toggleExpanded(_ row: URL) {
        if expanded.contains(row.path) { expanded.remove(row.path) } else { expanded.insert(row.path) }
    }

    // MARK: Folders picked in the open panel

    /// Add Folder…: a folder that's listed (or a subfolder of one, which opens) gets checked; any other is listed as
    /// a new folder, checked, unless it's searched already (a note says as part of what).
    func add(_ picked: [URL]) {
        note = nil
        var fresh: [URL] = []
        for folder in picked {
            let path = folder.path
            if rows.contains(where: { $0.path == path }) {
                selection.setFolder(path, on: true)
            } else if let row = rows.first(where: { $0.path == FolderSelection.parent(path) }) {
                selection.setSubfolder(path, on: true)
                expanded.insert(row.path)
            } else if selection.isSearched(path) {
                let by = selection.searchedAs(path)
                note = "“\(folder.lastPathComponent)” is searched already"
                    + (by == nil || by == path ? "." : ", as part of “\((by! as NSString).lastPathComponent)”.")
            } else {
                rows.append(folder)
                selection.setFolder(path, on: true)
                fresh.append(folder)
            }
        }
        estimate(fresh)
    }

    /// Skip a Folder…: a folder that's listed (or a subfolder of one, which opens) gets unchecked; one deeper is
    /// skipped inside the folders that search it, whose estimates run again.
    func skip(_ picked: [URL]) {
        note = nil
        var deeper: [String] = []
        for folder in picked {
            let path = folder.path
            if rows.contains(where: { $0.path == path }) {
                selection.setFolder(path, on: false)
            } else if let row = rows.first(where: { $0.path == FolderSelection.parent(path) }) {
                selection.setSubfolder(path, on: false)
                expanded.insert(row.path)
            } else if selection.isSearched(path) {
                selection.setSubfolder(path, on: false)
                deeper.append(path)
            } else {
                note = "“\(folder.lastPathComponent)” isn't searched anyway."
            }
        }
        estimate(rows.filter { row in deeper.contains { FolderSelection.isInside($0, row.path) } })
    }

    func unskip(_ path: String) {
        note = nil
        selection.unskip(path)
        if !rows.contains(where: { $0.path == FolderSelection.parent(path) }) {
            estimate(rows.filter { FolderSelection.isInside(path, $0.path) })
        }
    }

    /// File types to skip, as typed ("heic, txt"); every estimate runs again when they change.
    func setTypes(_ text: String) {
        let types = IndexOptions.extensions(text).sorted()
        guard types != self.types else { return }
        self.types = types
        estimate(rows)
    }

    // MARK: The result

    /// The folders to search, without those another one covers.
    var roots: [URL] { selection.folders.map(AppSettings.folderURL) }

    /// The folders to skip, without those that have nothing around them to be skipped from.
    var skipped: [URL] { selection.effectiveSkips.map(AppSettings.folderURL) }

    /// Something would change (Settings' Add is off until it does).
    var changesSomething: Bool {
        Set(selection.folders) != Set(initial.folders) || Set(selection.effectiveSkips) != Set(initial.effectiveSkips)
    }

    /// What a row adds to indexing: the first pass (`seconds`) and the rest of its long files after it (`later`).
    struct Part {
        var seconds = 0.0
        var later = 0.0
        var bytes = 0.0
        var files: [FileKind: Int] = [:]

        mutating func add(_ estimate: FolderEstimate, _ sign: Double = 1) {
            seconds += sign * estimate.seconds
            later += sign * estimate.laterSeconds
            bytes += sign * estimate.bytes
            for (kind, count) in estimate.files { files[kind, default: 0] += Int(sign) * count }
        }
    }

    /// What a row adds: all of it but its unchecked subfolders, or just its checked ones.
    func searchedPart(of row: URL) -> Part? {
        guard let estimate = estimates[row.path] else { return nil }
        guard selection.isSearched(row.path) else {
            var part = Part()
            for subfolder in estimate.subfolders where selection.isSearched(subfolder.folder) { part.add(subfolder) }
            return part
        }
        // Inside another listed folder that searches it: counted there.
        if rows.contains(where: { other in
            other.path != row.path && FolderSelection.isInside(row.path, other.path) && selection.isSearched(other.path)
                && FolderSelection.isSearched(row.path, folders: [other.path], skipped: selection.skipped)
        }) {
            return Part()
        }
        var part = Part()
        part.add(estimate)
        for subfolder in estimate.subfolders where !selection.isSearched(subfolder.folder) { part.add(subfolder, -1) }
        return Part(seconds: max(0, part.seconds), later: max(0, part.later), bytes: max(0, part.bytes),
                    files: part.files.filter { $0.value > 0 })
    }

    var totalSeconds: Double {
        rows.reduce(0) { $0 + (searchedPart(of: $1)?.seconds ?? 0) }
    }

    /// Code search: about how much room the code index takes for what's checked.
    var totalBytes: Double {
        rows.reduce(0) { $0 + (searchedPart(of: $1)?.bytes ?? 0) }
    }

    /// The rest of the long PDFs and documents, after the first pass.
    var totalLaterSeconds: Double {
        rows.reduce(0) { $0 + (searchedPart(of: $1)?.later ?? 0) }
    }

    // MARK: Estimates

    /// Runs the estimates of `folders` in the helper. Skipped subfolders of a listed folder still count there (the
    /// list shows them, unchecked, with their size); deeper skips and the folders searched already are left out.
    private func estimate(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        run += 1
        let run = self.run
        for folder in folders {
            runs[folder.path] = run
            estimates[folder.path] = nil
        }
        let left = selection.kept + selection.skipped.filter { skip in
            !rows.contains { $0.path == FolderSelection.parent(skip) }
        }
        Estimates.run(folders, excluded: left.map(AppSettings.folderURL), types: types, code: code) { [weak self] estimate in
            guard let self, runs[estimate.folder] == run else { return }
            estimates[estimate.folder] = estimate
        }
    }
}

// MARK: Views

/// The folders, each with a checkbox, what's in it and how long its first pass takes, opening to its subfolders; then
/// a button that adds another folder, and a note when a folder picked didn't change anything.
struct FolderList: View {
    let choices: FolderChoices
    let addTitle: String
    let add: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(choices.rows, id: \.path) { row in
                FolderRow(choices: choices, row: row)
            }
            Button(action: add) {
                Label(addTitle, systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .buttonStyle(.plain)
            if let note = choices.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct FolderRow: View {
    let choices: FolderChoices
    let row: URL
    @State private var showAll = false

    static let laterHelp = "The first pass takes this long. Long PDFs and documents get their first pages in it, "
        + "and the rest afterwards, once everything else is in."
    static let codeHelp = "How long reading this code takes, once, and about how much room its index needs. After "
        + "that, only what changes is read again."

    /// Subfolders shown before "Show N more".
    private static let shortList = 8

    var body: some View {
        let estimate = choices.estimates[row.path]
        let mark = choices.mark(row)
        let subfolders = estimate?.subfolders ?? []
        let open = choices.expanded.contains(row.path) && !subfolders.isEmpty
        VStack(spacing: 0) {
            header(estimate, mark: mark, canOpen: !subfolders.isEmpty, open: open)
            if open {
                Divider().padding(.leading, 56)
                VStack(spacing: 0) {
                    ForEach(showAll ? subfolders : Array(subfolders.prefix(Self.shortList))) { subfolder in
                        SubfolderRow(choices: choices, subfolder: subfolder)
                    }
                    if !showAll, subfolders.count > Self.shortList {
                        Button("Show \(subfolders.count - Self.shortList) more") { showAll = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 56)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(mark == .off ? 0.025 : 0.055)))
    }

    private func header(_ estimate: FolderEstimate?, mark: FolderSelection.Mark, canOpen: Bool,
                        open: Bool) -> some View {
        // Off, a folder shows all it holds (what checking it would take); else what's searched of it.
        let part = mark == .off ? estimate.map { estimate -> FolderChoices.Part in
            var part = FolderChoices.Part()
            part.add(estimate)
            return part
        } : choices.searchedPart(of: row)
        return HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { choices.toggleExpanded(row) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canOpen ? 1 : 0)
            .disabled(!canOpen)
            .help(open ? "Hide its subfolders" : "Choose among its subfolders")
            .accessibilityLabel(open ? "Hide the subfolders of \(row.lastPathComponent)"
                                : "Show the subfolders of \(row.lastPathComponent)")
            Checkbox(mark: mark, label: row.lastPathComponent) { choices.toggle(row) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.lastPathComponent).font(.system(size: 13, weight: .semibold))
                if let estimate, estimate.failed {
                    Text("Couldn't look inside it; it can still be searched.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let estimate, !estimate.readable {
                    HStack(spacing: 6) {
                        Text("macOS isn't letting DigUp read it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Button("Allow in Settings…", action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                } else if let part, !part.files.isEmpty {
                    KindCounts(counts: part.files)
                } else {
                    Text(estimate == nil ? tildePath(row.path)
                         : estimate!.files.isEmpty ? (choices.code ? "No code here" : "Nothing to search here yet")
                         : "Nothing to search in the subfolders checked")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let estimate {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(estimate.files.isEmpty ? "—" : approximately(part?.seconds ?? 0))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(mark == .off ? .tertiary : .primary)
                    if choices.code, let bytes = part?.bytes, bytes > 0 {
                        Text(roughBytes(bytes))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else if let later = part?.later, later >= 30 {
                        Text("+ \(roughDuration(later)) later")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(choices.code ? Self.codeHelp : Self.laterHelp)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { choices.toggle(row) }
        .accessibilityElement(children: .contain)
    }
}

/// A subfolder under its folder: checkbox, name, what's in it, how long it takes.
private struct SubfolderRow: View {
    let choices: FolderChoices
    let subfolder: FolderEstimate

    var body: some View {
        let on = choices.isSearched(subfolder.folder)
        let name = (subfolder.folder as NSString).lastPathComponent
        HStack(spacing: 8) {
            Checkbox(mark: on ? .on : .off, label: name) { choices.toggle(subfolder: subfolder.folder) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: subfolder.folder))
                .resizable()
                .frame(width: 18, height: 18)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            KindCounts(counts: subfolder.files)
                .opacity(on ? 1 : 0.6)
            Spacer(minLength: 8)
            Text(approximately(subfolder.seconds)
                 + (choices.code ? " · \(roughBytes(subfolder.bytes))"
                    : subfolder.laterSeconds >= 30 ? " + \(roughDuration(subfolder.laterSeconds)) later" : ""))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(on ? .secondary : .tertiary)
                .help(choices.code ? FolderRow.codeHelp : FolderRow.laterHelp)
        }
        .padding(.leading, 56)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { choices.toggle(subfolder: subfolder.folder) }
    }
}

/// A checkbox that can also show "some of it" (a folder with only some of its subfolders searched). A click asks for
/// the change; what it shows always comes from the model.
struct Checkbox: NSViewRepresentable {
    let mark: FolderSelection.Mark
    let label: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
                              action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let state: NSControl.StateValue = switch mark {
        case .on: .on
        case .mixed: .mixed
        case .off: .off
        }
        context.coordinator.action = action
        context.coordinator.state = state
        button.state = state
        button.setAccessibilityLabel(label)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        var state = NSControl.StateValue.off

        @objc func clicked(_ sender: NSButton) {
            sender.state = state   // the button steps through its states by itself; the model decides
            action()
        }
    }
}

import DigUpLocalization
import AppKit
import SwiftUI

/// The menubar icon: DigUp's logo (`Resources/AppIcon/tray.svg` and its `tray*.png`, as the Windows and Linux app's tray
/// shows it). While the model downloads or files index, the tiles are dimmed and get their color back in a sweep from
/// the top, clockwise, as far as it has come; while indexing is paused, two bars take the D's place.
enum StatusIcon {
    private static let logo = picture("tray"), dimmed = picture("tray-dim"), pausedLogo = picture("tray-paused")

    private static func picture(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    /// `update`: a newer version is waiting, a dot at the top right.
    static func image(progress: Double?, paused: Bool = false, update: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            if paused {
                pausedLogo?.draw(in: rect)
            } else if let progress {
                dimmed?.draw(in: rect)
                NSGraphicsContext.saveGraphicsState()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let reached = NSBezierPath()
                reached.move(to: center)
                reached.appendArc(withCenter: center, radius: rect.width, startAngle: 90,
                                  endAngle: 90 - 360 * min(1, max(0, progress)), clockwise: true)
                reached.close()
                reached.addClip()
                logo?.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                logo?.draw(in: rect)
            }
            if update {
                // Cut a gap around it, so it reads as a dot on the logo and not part of it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 7, height: 7)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.75, y: 12.75, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.accessibilityDescription = "DigUp"
        return image
    }
}

/// The menubar icon and its menu: what's going on (with a progress bar), Search…, the window, Pause, Settings, Quit.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    var onSearch: () -> Void = {}
    var onOpenWindow: () -> Void = {}
    var onSettings: () -> Void = {}
    var onChooseFolders: () -> Void = {}
    var onPauseChanged: (Bool) -> Void = { _ in }
    var onCheckForUpdates: () -> Void = {}
    private var shownProgress: Double?
    private var shownPaused = false
    private var shownUpdate = false

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()
        observeModel()
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.status
            _ = model.progress
            _ = model.updateAvailable
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observeModel()
            }
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let progress = model.progress.map { ($0 * 50).rounded() / 50 }   // redraw in 2% steps, not every file
        let paused = model.status.paused, update = model.updateAvailable != nil
        if progress != shownProgress || paused != shownPaused || update != shownUpdate || button.image == nil {
            button.image = StatusIcon.image(progress: progress, paused: paused, update: update)
            shownProgress = progress
            shownPaused = paused
            shownUpdate = update
        }
        button.toolTip = "DigUp — \(model.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem()
        let view = NSHostingView(rootView: MenuStatusView(model: model))
        view.frame.size = view.fittingSize
        header.view = view
        menu.addItem(header)
        menu.addItem(.separator())
        if let version = model.updateAvailable {
            menu.addItem(ActionMenuItem(L10n.format("Update to DigUp %1$@…", String(describing: version))) { [weak self] in self?.onCheckForUpdates() })
            menu.addItem(.separator())
        }

        if !model.hasFolders {
            menu.addItem(ActionMenuItem(L10n.text("Choose Folders to Search…")) { [weak self] in self?.onChooseFolders() })
        }
        let search = ActionMenuItem(L10n.text("Search…")) { [weak self] in self?.onSearch() }
        if let hotkey = model.hotkey, let (key, modifiers) = hotkey.menuEquivalent {
            search.keyEquivalent = key
            search.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(search)
        menu.addItem(ActionMenuItem(L10n.text("Open DigUp")) { [weak self] in self?.onOpenWindow() })
        if model.hasFolders {
            menu.addItem(.separator())
            let paused = model.status.paused
            menu.addItem(ActionMenuItem(paused ? L10n.text("Resume Indexing") : L10n.text("Pause Indexing")) { [weak self] in
                self?.onPauseChanged(!paused)
            })
        }
        switch model.download.phase {
        case .failed, .needed:
            menu.addItem(ActionMenuItem(L10n.text("Download the Model")) { [weak self] in self?.model.download.start() })
        default:
            break
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L10n.text("Settings…"), key: ",") { [weak self] in self?.onSettings() })
        if model.updateAvailable == nil {
            menu.addItem(ActionMenuItem(L10n.text("Check for Updates…")) { [weak self] in self?.onCheckForUpdates() })
        }
        menu.addItem(ActionMenuItem(L10n.text("Quit DigUp"), key: "q") { NSApp.terminate(nil) })
    }

    /// The menu as text, for the -debugMenu launch argument (menus can't be clicked from a script).
    func describeMenu() -> String {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.view != nil { return "[\(model.statusLine)]" }
            return item.title + (item.isEnabled ? "" : " (disabled)")
        }.joined(separator: " | ")
    }

    /// Runs a menu item by title, for -debugMenu.
    func performItem(titled title: String) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// The top of the menu: the status line, a detail (where, or how long), and progress while there is some.
struct MenuStatusView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.statusLine)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let progress = model.progress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(width: 280, alignment: .leading)
    }

    private var detail: String? {
        if model.download.isActive { return model.download.progressText }
        if case .failed(let message) = model.download.phase { return message }
        guard model.hasFolders else { return L10n.text("Pick the folders it should search.") }
        let missing = Set(model.status.missingRoots), unreadable = Set(model.status.unreadableRoots)
        let names = model.settings.roots.map { root in
            root.lastPathComponent + (missing.contains(root.path) ? L10n.text(" (not connected)")
                                      : unreadable.contains(root.path) ? L10n.text(" (no access)") : "")
        }
        return L10n.text("In ") + names.joined(separator: ", ")
    }
}

/// Makes an NSMenuItem that runs a closure.
private final class MenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

func ActionMenuItem(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
    item.target = action
    item.representedObject = action  // `target` is weak; this keeps the action alive
    return item
}

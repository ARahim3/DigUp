import AppKit
import Quartz

/// A window that can hand the shared Quick Look panel a file (both search windows conform; Quick Look addresses
/// the window itself as the panel's data source).
@MainActor
protocol QuickLookHost: AnyObject {
    var previewURL: URL? { get set }
}

/// The shared Quick Look panel, driven by whichever search surface is showing: one place for the toggle/update
/// logic and the item answers `SearchPanelWindow` and `QuickLookWindow` both duplicated. The windows keep their
/// `QLPreviewPanelDataSource` conformance (Quick Look addresses the window itself) and forward here.
@MainActor
enum QuickLookController {
    /// Whether the shared panel exists and is visible.
    static var isShowing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Space / ⌘Y: hide the panel, or show it with `row` previewed through `host`.
    static func toggle(on host: QuickLookHost?, row: ResultRow?) {
        guard let host else { return }
        if isShowing {
            QLPreviewPanel.shared().orderOut(nil)
        } else if row != nil {
            update(on: host, row: row)
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    /// Point the panel at `row` (its page or moment) and refresh it.
    static func update(on host: QuickLookHost?, row: ResultRow?) {
        host?.previewURL = row?.url
        QLPreviewPanel.shared().reloadData()
        QuickLookMoment.show(row, in: QLPreviewPanel.shared())
    }

    /// Close the panel if it's open (both surfaces do this when their window hides or closes).
    static func hide() {
        if isShowing { QLPreviewPanel.shared().orderOut(nil) }
    }

    // The data-source answers both windows shared, in one place.
    static func itemCount(for url: URL?) -> Int { url == nil ? 0 : 1 }
    static func item(for url: URL?) -> (any QLPreviewItem)? { url.map { $0 as NSURL } }
}

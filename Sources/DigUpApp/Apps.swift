import AppKit
import CoreServices
import DigUpKit

/// One app the panel can launch.
nonisolated struct InstalledApp: Sendable {
    let url: URL
    /// The name Finder shows ("Visual Studio Code"), then any other the app goes by (its bundle's: "Code").
    let names: [AppName]
    let version: String?
    /// When it was last opened, however it was (Spotlight keeps this for every app).
    let lastUsed: Date?
    let modified: Date

    var path: String { url.path }
}

extension ResultRow {
    /// The picture of the file, or the app's icon, without the arrow of a link (/Applications/Safari.app is one).
    var iconURL: URL { isApp ? url.resolvingSymlinksInPath() : url }
}

/// The apps in the Applications folders, found by name as you type (`AppSearch`): they come first in the panel, and ↩
/// launches the top one, as in Spotlight or Alfred. The apps you launch from DigUp most, and the ones you've used
/// lately, come first among matches as good.
///
/// The folders are read when the app starts and again, in the background, each time the panel opens (at most every 30
/// seconds): an app you just installed shows up the next time you look.
final class AppLauncher {
    static let shared = AppLauncher()
    /// The most the panel shows: past a few, the name you typed fits too many apps to be much help.
    static let limit = 4
    static let rescanAfter: TimeInterval = 30
    /// Off in Settings: the panel finds only files.
    static let settingKey = "searchApps"

    /// Where apps are, and how many folders down to look (Utilities, an app's own folder like "Adobe Photoshop 2026",
    /// Chrome's web apps). Never inside an app.
    nonisolated static let folders: [(URL, depth: Int)] = [
        (URL(fileURLWithPath: "/Applications"), 2),
        (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), 2),
        (URL(fileURLWithPath: "/System/Applications"), 1),
        (URL(fileURLWithPath: "/System/Library/CoreServices/Applications"), 0),
    ]
    /// Apps that live outside those folders but people launch by name.
    nonisolated static let extras = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

    private(set) var apps: [InstalledApp] = []
    private var scannedAt = Date.distantPast
    private var scanning = false
    /// Launches from the panel, by path (`appLaunches` in defaults).
    private var launches: [String: Int]
    /// The apps found changed (the first read, an app installed or removed).
    var onChange: () -> Void = {}

    init() {
        launches = AppSettings.defaults.dictionary(forKey: "appLaunches") as? [String: Int] ?? [:]
    }

    var isOn: Bool { AppSettings.defaults.object(forKey: Self.settingKey) as? Bool ?? true }

    /// Reads the folders again in the background, unless that was done moments ago.
    func refresh() {
        guard isOn, !scanning, Date().timeIntervalSince(scannedAt) > Self.rescanAfter else { return }
        scanning = true
        let started = Date()
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            let changed = found.map(\.path) != apps.map(\.path)
            apps = found
            scannedAt = Date()
            scanning = false
            if changed {
                log("apps: \(found.count) in \(ms(since: started))")
                onChange()
            }
        }
    }

    /// The apps `query` names, best first, as panel rows.
    func matches(_ query: String) -> [ResultRow] {
        guard isOn else { return [] }
        let now = Date()
        return AppSearch.rank(query, apps, names: \.names, boost: { self.boost($0, now: now) }, limit: Self.limit)
            .map(ResultRow.init(app:))
    }

    /// Opens the app (or brings it forward, if it's running), and remembers it was chosen.
    func launch(_ url: URL) {
        launches[url.path, default: 0] += 1
        AppSettings.defaults.set(launches, forKey: "appLaunches")
        let name = url.deletingPathExtension().lastPathComponent
        if Opener.dryRun { return log("launch (dry run): \(name)") }
        log("launch: \(name)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { log("launch: \(name) failed: \(error.localizedDescription)") }
        }
    }

    /// How much to favor an app among matches as good: up to 200 for the ones launched from here most (25 launches),
    /// and up to 60 for one used today, less for this week or this month.
    private func boost(_ app: InstalledApp, now: Date) -> Int {
        let launched = min(launches[app.path] ?? 0, 25) * 8
        let days = app.lastUsed.map { now.timeIntervalSince($0) / 86_400 } ?? .infinity
        let recent = days < 1 ? 60 : days < 7 ? 40 : days < 30 ? 20 : 0
        return launched + recent
    }

    // MARK: Reading the folders

    nonisolated static func scan() -> [InstalledApp] {
        var found: [InstalledApp] = []
        var seen = Set<String>()   // an app in two places (by bundle ID, else path) shows once, from the first
        func add(_ url: URL) {
            guard let app = read(url) else { return }
            let id = Bundle(url: url)?.bundleIdentifier ?? url.resolvingSymlinksInPath().path
            guard seen.insert(id).inserted else { return }
            found.append(app)
        }
        func look(in folder: URL, depth: Int) {
            let keys: [URLResourceKey] = [.isDirectoryKey]
            // Not `.skipsHiddenFiles`: /Applications/Safari.app is a link into a cryptex that's flagged hidden.
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys) else { return }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                if item.pathExtension == "app" {
                    add(item)
                } else if depth > 0, (try? item.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                    look(in: item, depth: depth - 1)
                }
            }
        }
        for (folder, depth) in folders { look(in: folder, depth: depth) }
        for url in extras { add(url) }
        return found
    }

    /// Nil for an app that can't be launched by hand (a background-only helper).
    private nonisolated static func read(_ url: URL) -> InstalledApp? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        if info["LSBackgroundOnly"] as? Bool == true { return nil }
        var shown = FileManager.default.displayName(atPath: url.path)
        if shown.hasSuffix(".app") { shown = String(shown.dropLast(4)) }
        var names = [AppName(shown)]
        let others: [Any?] = [bundle?.localizedInfoDictionary?["CFBundleDisplayName"], info["CFBundleDisplayName"],
                              bundle?.localizedInfoDictionary?["CFBundleName"], info["CFBundleName"],
                              url.deletingPathExtension().lastPathComponent]
        for other in others.compactMap({ $0 as? String }) where !other.isEmpty {
            if !names.contains(where: { $0.name.lowercased() == other.lowercased() }) { names.append(AppName(other)) }
        }
        var lastUsed: Date?
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return InstalledApp(url: url, names: names, version: info["CFBundleShortVersionString"] as? String,
                            lastUsed: lastUsed, modified: modified ?? .distantPast)
    }
}

extension ResultRow {
    /// An app, as the panel lists it: by the name Finder shows, in the folder it's in.
    init(app: InstalledApp) {
        id = app.path
        url = app.url
        name = app.names.first?.name ?? app.url.deletingPathExtension().lastPathComponent
        folder = tildePath(app.url.deletingLastPathComponent().path)
        isApp = true
        kind = .doc   // unused for an app: nothing about one is a file kind's
        segment = .name
        segmentID = 0
        loc = nil
        locEnd = nil
        focus = nil
        excerpt = nil
        matchedMeaning = false
        matchedWords = false
        modified = app.modified
        size = 0
        info = app.version.map { ["version": $0] } ?? [:]
        terms = []
    }
}

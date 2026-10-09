import DigUpKit
import Foundation

/// What to index, where the index and the model live, and the hotkey.
///
/// Saved in the app's defaults domain (com.abdurrahim.DigUp). Launch arguments override any of it without being
/// saved, which is how tests point the app at the testbed and never at real folders:
///
///     DigUp.app/Contents/MacOS/DigUp -roots ~/DigUpTestbed/real -indexDir <repo>/.dev/app-index \
///         -modelsDir <repo>/.dev/models -defaultsSuite com.abdurrahim.DigUp.dev
///
/// `-roots` takes one folder, several joined with ":", or a plist array. `-defaultsSuite` keeps what the app saves
/// (onboarding's folders, a new hotkey) out of the real settings. With no roots the app indexes nothing and opens
/// onboarding: a fresh install never starts reading someone's home folder on its own.
nonisolated struct AppSettings: Sendable {
    var roots: [URL]
    /// Folders inside the roots that are never indexed.
    var excludedFolders: [URL]
    /// File extensions that are never indexed ("heic", "txt"), on top of what DigUp never reads anyway.
    var excludedTypes: [String]
    var indexDirectory: URL
    /// Where the model files are downloaded to and loaded from (the helpers get it as DIGUP_MODELS).
    var modelsDirectory: URL
    var hotkey: String
    /// On (the default), the big first pass of a folder (the backfill) runs on battery too; off, it waits for a
    /// charger. New files always index right away, and Low Power Mode or a hot Mac make the backfill wait either way.
    var indexOnBattery: Bool
    /// The query encoder (~0.25 GB) exits after this long without a query; the next panel open starts it again.
    var encoderIdleSeconds: Double
    /// Onboarding was finished (or closed after choosing folders); it doesn't open by itself again.
    var onboarded: Bool
    /// Code search: the folders whose code goes into the code index (none: code search is off), and the folders
    /// skipped in them (`FolderSelection`'s rule, as for `roots`). Searched with "code:" only.
    var codeRoots: [URL]
    var codeExcluded: [URL]
    /// The bundle id of the editor code results open in ("" for each file's default app); nil until one is chosen
    /// (`CodeEditor.chosen`).
    var codeEditor: String?
    /// The code index catches up once the code folders have been quiet this long (`-codeQuietSeconds`, default 60).
    var codeQuietSeconds: Double

    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DigUp")
    static let defaultIndexDirectory = supportDirectory.appendingPathComponent("index.noindex")
    static let defaultHotkey = "cmd+shift+space"

    /// The battery switch, in onboarding and Settings.
    static let batteryTitle = "Index on battery power"
    static let batteryDetail = "When it's off, a folder's first pass waits for a charger. New files always go in right away."

    /// Where settings are saved. Reads see launch arguments first either way. (UserDefaults is thread-safe.)
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let suite = UserDefaults.standard.string(forKey: "defaultsSuite"), !suite.isEmpty,
              let defaults = UserDefaults(suiteName: suite) else { return .standard }
        return defaults
    }()

    static func load() -> AppSettings {
        let defaults = Self.defaults
        return AppSettings(
            roots: folders(defaults, "roots"),
            excludedFolders: folders(defaults, "excludedFolders"),
            excludedTypes: (defaults.stringArray(forKey: "excludedTypes")
                ?? defaults.string(forKey: "excludedTypes").map { [$0] } ?? [])
                .flatMap { IndexOptions.extensions($0) }.sorted(),
            indexDirectory: defaults.string(forKey: "indexDir").map(folderURL) ?? defaultIndexDirectory,
            modelsDirectory: defaults.string(forKey: "modelsDir").map(folderURL) ?? ModelFiles.installed,
            hotkey: defaults.string(forKey: "hotkey") ?? defaultHotkey,
            indexOnBattery: defaults.object(forKey: "indexOnBattery") == nil || defaults.bool(forKey: "indexOnBattery"),
            encoderIdleSeconds: defaults.object(forKey: "encoderIdleSeconds") == nil
                ? 600 : max(1, defaults.double(forKey: "encoderIdleSeconds")),
            onboarded: defaults.bool(forKey: "onboarded"),
            codeRoots: folders(defaults, "codeRoots"),
            codeExcluded: folders(defaults, "codeExcludedFolders"),
            codeEditor: defaults.string(forKey: "codeEditor"),
            codeQuietSeconds: defaults.object(forKey: "codeQuietSeconds") == nil
                ? 60 : max(1, defaults.double(forKey: "codeQuietSeconds")))
    }

    /// A list of folders: a plist array, or paths joined with ":" (the form launch arguments use).
    private static func folders(_ defaults: UserDefaults, _ key: String) -> [URL] {
        let paths: [String]
        if let list = defaults.stringArray(forKey: key) {
            paths = list
        } else if let joined = defaults.string(forKey: key) {
            paths = joined.split(separator: ":").map(String.init)
        } else {
            paths = []
        }
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty }.map(folderURL).filter { seen.insert($0.path).inserted }
    }

    static func save(roots: [URL]) {
        defaults.set(roots.map(\.path), forKey: "roots")
    }

    static func save(excludedFolders: [URL]) {
        defaults.set(excludedFolders.map(\.path), forKey: "excludedFolders")
    }

    static func save(excludedTypes: [String]) {
        defaults.set(excludedTypes, forKey: "excludedTypes")
    }

    static func save(hotkey: String) {
        defaults.set(hotkey, forKey: "hotkey")
    }

    static func save(indexOnBattery: Bool) {
        defaults.set(indexOnBattery, forKey: "indexOnBattery")
    }

    static func saveOnboarded() {
        defaults.set(true, forKey: "onboarded")
    }

    static func save(codeRoots: [URL], excluded: [URL]) {
        defaults.set(codeRoots.map(\.path), forKey: "codeRoots")
        defaults.set(excluded.map(\.path), forKey: "codeExcludedFolders")
    }

    static func save(codeEditor: String) {
        defaults.set(codeEditor, forKey: "codeEditor")
    }

    /// Expands "~" and resolves symlinks, so crawled paths match the paths FSEvents reports.
    static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }
}

/// "~/DigUpTestbed/real" instead of "/Users/…/DigUpTestbed/real".
nonisolated func tildePath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

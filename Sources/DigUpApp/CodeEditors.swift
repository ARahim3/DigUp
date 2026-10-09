import AppKit
import DigUpKit

/// The editors code search opens results in, at the line that matched: each one's own way of being told the line (a
/// URL, or a command its app bundles), found by bundle id. The one in use is a setting ("Open code in"); until it's set,
/// the first one installed, preferring one that's running now.
nonisolated struct CodeEditor: Identifiable, Hashable, Sendable {
    enum Method: Hashable, Sendable {
        /// "vscode://file/<path>:<line>:1"
        case fileURL(scheme: String)
        /// A command inside the app bundle that takes "<path>:<line>" (Zed's `cli`, Sublime Text's `subl`).
        case command(String)
        /// Xcode's `xed --line <line> <path>`.
        case xed
        /// JetBrains IDEs: their launcher takes `--line <line> <path>`.
        case jetBrains
        /// "txmt://open?url=file://<path>&line=<line>" (TextMate, BBEdit).
        case openURL(scheme: String)
        /// The app opens the file, at its start.
        case plain
    }

    let id: String       // bundle id
    let name: String
    let method: Method

    static let known: [CodeEditor] = [
        CodeEditor(id: "dev.zed.Zed", name: "Zed", method: .command("Contents/MacOS/cli")),
        CodeEditor(id: "dev.zed.Zed-Preview", name: "Zed Preview", method: .command("Contents/MacOS/cli")),
        CodeEditor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", method: .fileURL(scheme: "cursor")),
        CodeEditor(id: "com.microsoft.VSCode", name: "Visual Studio Code", method: .fileURL(scheme: "vscode")),
        CodeEditor(id: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders",
                   method: .fileURL(scheme: "vscode-insiders")),
        CodeEditor(id: "com.exafunction.windsurf", name: "Windsurf", method: .fileURL(scheme: "windsurf")),
        CodeEditor(id: "com.vscodium", name: "VSCodium", method: .fileURL(scheme: "vscodium")),
        CodeEditor(id: "com.sublimetext.4", name: "Sublime Text", method: .command("Contents/SharedSupport/bin/subl")),
        CodeEditor(id: "com.sublimetext.3", name: "Sublime Text 3", method: .command("Contents/SharedSupport/bin/subl")),
        CodeEditor(id: "com.jetbrains.pycharm", name: "PyCharm", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.pycharm.ce", name: "PyCharm CE", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.intellij", name: "IntelliJ IDEA", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.WebStorm", name: "WebStorm", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.CLion", name: "CLion", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.goland", name: "GoLand", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.rustrover", name: "RustRover", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.PhpStorm", name: "PhpStorm", method: .jetBrains),
        CodeEditor(id: "com.jetbrains.rubymine", name: "RubyMine", method: .jetBrains),
        CodeEditor(id: "com.google.android.studio", name: "Android Studio", method: .jetBrains),
        CodeEditor(id: "com.apple.dt.Xcode", name: "Xcode", method: .xed),
        CodeEditor(id: "com.barebones.bbedit", name: "BBEdit", method: .openURL(scheme: "x-bbedit")),
        CodeEditor(id: "com.macromates.TextMate", name: "TextMate", method: .openURL(scheme: "txmt")),
    ]

    /// Each file opens in the app macOS opens it with, at its start.
    static let defaultApp = CodeEditor(id: "", name: "The file's default app", method: .plain)

    /// Where code results open now (`AppController.setCodeEditor`).
    @MainActor static var current = defaultApp

    @MainActor static var installed: [CodeEditor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The editor chosen in Settings (`id`), or the first installed one, preferring one that's running.
    @MainActor static func chosen(_ id: String?) -> CodeEditor {
        let installed = Self.installed
        if let id {
            if id.isEmpty { return defaultApp }
            if let editor = installed.first(where: { $0.id == id }) { return editor }
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return installed.first { running.contains($0.id) } ?? installed.first ?? defaultApp
    }

    /// Opens `url` at `line` (from 1). Debug runs (`Opener.dryRun`) only say how.
    @MainActor func open(_ url: URL, line: Int) {
        guard !id.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            log("open: \(url.lastPathComponent) in its default app" + (Opener.dryRun ? " (dry run)" : ""))
            if !Opener.dryRun { NSWorkspace.shared.open(url) }
            return
        }
        let how: String
        var link: URL?
        var command: (URL, [String])?
        switch method {
        case .fileURL(let scheme):
            // The path as a URL path: spaces and other characters escaped, slashes kept.
            link = URL(string: "\(scheme)://file\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path):\(line):1")
            how = link?.absoluteString ?? "?"
        case .openURL(let scheme):
            var components = URLComponents(string: "\(scheme)://open")
            components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                      URLQueryItem(name: "line", value: "\(line)")]
            link = components?.url
            how = link?.absoluteString ?? "?"
        case .command(let path):
            command = (app.appendingPathComponent(path), ["\(url.path):\(line)"])
            how = "\(path) \(url.lastPathComponent):\(line)"
        case .xed:
            command = (app.appendingPathComponent("Contents/Developer/usr/bin/xed"), ["--line", "\(line)", url.path])
            how = "xed --line \(line)"
        case .jetBrains:
            let executable = Bundle(url: app)?.executableURL ?? app.appendingPathComponent("Contents/MacOS/idea")
            command = (executable, ["--line", "\(line)", url.path])
            how = "\(executable.lastPathComponent) --line \(line)"
        case .plain:
            how = "at its start"
        }
        log("open: \(url.lastPathComponent) in \(name), \(how)" + (Opener.dryRun ? " (dry run)" : ""))
        guard !Opener.dryRun else { return }
        if let link {
            NSWorkspace.shared.open(link)
        } else if let (executable, arguments) = command, FileManager.default.isExecutableFile(atPath: executable.path) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                log("open: \(name) didn't start (\(error)), opening the file plainly")
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

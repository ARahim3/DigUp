import DigUpKit
import Foundation

/// Where people keep code: the folders code search offers before you pick your own.
enum CodeFolders {
    /// The home folder's folders that hold a repo (themselves or one level down): ~/Developer, ~/Projects, ~/Codes…,
    /// or `-codeLocations a:b` (tests point it at the testbed; a dev run never offers real folders). Desktop, Documents
    /// and Downloads are only looked into when they're searched already (macOS would ask first), for the usual names
    /// people keep repos under there.
    static func candidates(searched roots: [URL]) -> [URL] {
        if let list = UserDefaults.standard.string(forKey: "codeLocations") {
            return list.split(separator: ":").map { AppSettings.folderURL(String($0)) }
        }
        if UserDefaults.standard.string(forKey: "defaultsSuite") != nil {
            log("code: no -codeLocations in a dev run, so no code folders are offered")
            return []
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let asked: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Public",
                                  "Applications", "Sites"]
        var found: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        where !name.hasPrefix(".") && !asked.contains(name) {
            let folder = AppSettings.folderURL(home.appendingPathComponent(name).path)
            if AppSettings.isFolder(folder), holdsCode(folder) { found.append(folder) }
        }
        for parent in ["Documents", "Desktop"] {
            let folder = home.appendingPathComponent(parent)
            guard roots.contains(where: { $0.path == folder.path || FolderSelection.isInside(folder.path, $0.path) })
            else { continue }
            for name in ["GitHub", "Code", "Projects", "Developer", "dev", "src", "repos", "Repositories"] {
                let inner = AppSettings.folderURL(folder.appendingPathComponent(name).path)
                if AppSettings.isFolder(inner), holdsCode(inner) { found.append(inner) }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A repo, or a folder with one in it (one level down).
    static func holdsCode(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
        let children = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return children.prefix(500).contains { name in
            !name.hasPrefix(".") && fm.fileExists(atPath: folder.appendingPathComponent(name).appendingPathComponent(".git").path)
        }
    }
}

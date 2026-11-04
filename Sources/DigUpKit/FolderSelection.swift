import Foundation

/// Which folders DigUp searches: the folders you chose, minus the folders you skipped inside them. A skip applies
/// inside the chosen folders that contain it, and a chosen folder is searched whole even inside a skipped one (skip
/// Downloads/Media, still choose Downloads/Media/Courses). The crawler, the search filter and the folder lists in
/// onboarding and Settings all follow this rule.
///
/// The folder lists show folders with one level of their subfolders, each with a checkbox. A subfolder can be searched
/// without the rest of its folder (it's chosen on its own), or left out of a folder that's searched (it's skipped).
/// A folder the walk never enters from above (hidden, `.noindex`, a developer folder) isn't searched by the folder
/// holding it, so choosing it on its own keeps it (`reaches`).
public struct FolderSelection: Equatable, Sendable {
    /// A folder's checkbox: all of it, some of its subfolders, or none.
    public enum Mark: Sendable {
        case on, mixed, off
    }

    public private(set) var chosen: [String]
    public private(set) var skipped: [String]
    /// Folders already searched (when Settings adds more): whatever is clicked, they stay.
    public let kept: [String]

    public init(chosen: [String] = [], skipped: [String] = [], kept: [String] = []) {
        self.chosen = Self.unique(chosen)
        self.skipped = Self.unique(skipped)
        self.kept = Self.unique(kept)
    }

    /// Whether `path` (a folder or a file) is searched.
    public func isSearched(_ path: String) -> Bool {
        Self.isSearched(path, folders: kept + chosen, skipped: skipped)
    }

    public static func isSearched(_ path: String, folders: [String], skipped: [String]) -> Bool {
        folders.contains { folder in
            (path == folder || reaches(path, from: folder))
                && !skipped.contains { skip in isInside(skip, folder) && (path == skip || isInside(path, skip)) }
        }
    }

    /// Whether a walk of `folder` gets to `path`: inside it, with no hidden, `.noindex` or developer folder on the way.
    /// The crawl never enters those from above (`Rules.isWalked`); chosen on their own they're read whole.
    public static func reaches(_ path: String, from folder: String) -> Bool {
        guard isInside(path, folder) else { return false }
        let rest = path.dropFirst(folder.hasSuffix("/") ? folder.count : folder.count + 1)
        return !rest.split(separator: "/").contains {
            $0.hasPrefix(".") || $0.hasSuffix(".noindex") || Rules.skippedFolderNames.contains(String($0))
        }
    }

    /// The closest chosen (or kept) folder that searches `path`.
    public func searchedAs(_ path: String) -> String? {
        (kept + chosen).filter { folder in
            (path == folder || Self.isInside(path, folder)) && Self.isSearched(path, folders: [folder], skipped: skipped)
        }.max { $0.count < $1.count }
    }

    /// What the indexer gets: kept and chosen folders, without those another one already searches whole.
    public var folders: [String] {
        let all = Self.unique(kept + chosen)
        return all.filter { folder in
            !all.contains { other in
                other != folder && Self.isInside(folder, other)
                    && Self.isSearched(folder, folders: [other], skipped: skipped)
            }
        }
    }

    /// The skips that leave something out (inside a folder that's searched).
    public var effectiveSkips: [String] {
        let folders = self.folders
        return skipped.filter { skip in folders.contains { Self.isInside(skip, $0) } }
    }

    /// A folder's checkbox: mixed when some of its subfolders are skipped (it's searched) or chosen (it isn't).
    /// Deeper choices don't show here; the folder lists name them.
    public func mark(_ folder: String) -> Mark {
        if isSearched(folder) {
            return skipped.contains { Self.parent($0) == folder && !isSearched($0) } ? .mixed : .on
        }
        return (kept + chosen).contains { Self.parent($0) == folder } ? .mixed : .off
    }

    /// Checks or unchecks a folder and its subfolders: all of it, or none of it.
    public mutating func setFolder(_ folder: String, on: Bool) {
        skipped.removeAll { Self.parent($0) == folder }
        chosen.removeAll { Self.parent($0) == folder }
        setSubfolder(folder, on: on)
    }

    /// Checks or unchecks one folder, leaving the choices inside it as they are.
    public mutating func setSubfolder(_ folder: String, on: Bool) {
        if on {
            skipped.removeAll { $0 == folder }
            if !isSearched(folder) { chosen.append(folder) }
        } else {
            chosen.removeAll { $0 == folder }
            if isSearched(folder) { skipped.append(folder) }
        }
    }

    /// Stops skipping `folder` (without choosing it).
    public mutating func unskip(_ folder: String) {
        skipped.removeAll { $0 == folder }
    }

    public static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The path as a walk of the folder reports it (/private/var where `standardizedFileURL` says /var).
    public static func realPath(_ path: String) -> String {
        #if os(Windows)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        #else
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
        #endif
    }

    /// When `path` is inside a git worktree (where `.git` is a file pointing at `<main>/.git/worktrees/<name>`),
    /// returns the corresponding path inside the main repository. The code crawler skips worktrees because they
    /// duplicate the main repository (`Rules.codeSkipReason`), so scoping a search to a worktree (`--here`) must
    /// match the main repository's indexed paths too.
    public static func worktreeMainPath(_ path: String) -> String? {
        var current = path
        while current.count > 1 {
            let dotGit = current + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                guard !isDir.boolValue,
                      let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
                let firstLine = contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                guard firstLine.hasPrefix("gitdir:") else { return nil }
                let rawGitDir = firstLine.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = gitDirPath(rawGitDir, worktree: current)
                guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
                let mainRepo = String(gitDir[..<range.lowerBound])
                let suffix = String(path.dropFirst(current.count))
                return mainRepo + suffix
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// All canonical path spellings for `paths` (folders or files), including symlink/realPath resolutions and
    /// git worktree → main repository mappings.
    public static func searchTargets(for paths: [String]) -> [String] {
        var out: [String] = []
        for raw in paths where !raw.isEmpty {
            let trimmed = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            let real = realPath(trimmed)
            out.append(trimmed)
            out.append(real)
            for candidate in [trimmed, real] {
                if let main = worktreeMainPath(candidate) {
                    out.append(main)
                    out.append(realPath(main))
                }
            }
        }
        return unique(out)
    }

    #if os(Windows)
    public static let isWindows = true
    #else
    public static let isWindows = false
    #endif

    /// Whether a path as git or a shell writes it is absolute: `/…`, and on Windows also `C:/…`, `C:\…` and
    /// `\\server\share\…` (Git for Windows writes a worktree's `gitdir:` as `C:/Users/…/.git/worktrees/<name>`).
    static func isAbsolutePath(_ path: String, windows: Bool = isWindows) -> Bool {
        if path.hasPrefix("/") { return true }
        guard windows else { return false }
        if path.hasPrefix("\\\\") { return true }
        let chars = Array(path.prefix(3))
        return chars.count == 3 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":"
            && (chars[2] == "/" || chars[2] == "\\")
    }

    /// A worktree's `gitdir:` value as a path in the same form the index stores, resolved against the worktree
    /// folder when it's relative (`git worktree add --relative-paths`).
    static func gitDirPath(_ raw: String, worktree: String) -> String {
        if isAbsolutePath(raw) {
            // Windows: through URL, so `C:\…` and `C:/…` come out the way the crawler's paths do.
            return isWindows ? URL(fileURLWithPath: raw).standardizedFileURL.path : raw
        }
        return URL(fileURLWithPath: worktree).appendingPathComponent(raw).standardizedFileURL.path
    }

    /// The path with its drive letter in capitals (`c:/x` → `C:/x`, `/c:/x` → `/C:/x`) on Windows, as the crawler's
    /// paths have it, so a scope from a shell that reports `c:\…` still finds the index's rows; unchanged elsewhere.
    public static func upperDrive(_ path: String, windows: Bool = isWindows) -> String {
        guard windows else { return path }
        let chars = Array(path.prefix(3))
        let at = chars.first == "/" ? 1 : 0
        guard chars.count > at + 1, chars[at].isASCII, chars[at].isLetter, chars[at + 1] == ":" else { return path }
        var out = path
        let index = out.index(out.startIndex, offsetBy: at)
        out.replaceSubrange(index...index, with: chars[at].uppercased())
        return out
    }

    /// Whether two paths name the same file: case-insensitively on Windows, whose file systems ignore case (a shell
    /// can report the working folder as `c:\…` while the index holds `C:/…`).
    public static func samePath(_ a: String, _ b: String, ignoringCase: Bool = isWindows) -> Bool {
        ignoringCase ? a.lowercased() == b.lowercased() : a == b
    }

    /// Whether `path` is equal to or inside any of `targets` (case-insensitively on Windows, as `samePath`).
    public static func matches(_ path: String, targets: [String], ignoringCase: Bool = isWindows) -> Bool {
        let path = ignoringCase ? path.lowercased() : path
        return targets.contains { target in
            let target = ignoringCase ? target.lowercased() : target
            return path == target || isInside(path, target)
        }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

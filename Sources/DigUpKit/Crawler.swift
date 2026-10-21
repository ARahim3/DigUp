import Foundation

/// A file the crawler decided to index.
public struct Candidate: Sendable {
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
}

public struct CrawlReport: Sendable {
    public var candidates: [Candidate] = []
    public var skipped: [String: Int] = [:]          // reason → files
    public var skippedFolders: [String: Int] = [:]   // reason → folders not walked into
    public var datasets: [String: Int] = [:]         // folder → files skipped as a dataset
    /// What each chosen folder left out, by reason (the same counts as `skipped`, split by folder), so the apps can
    /// say why a folder shows fewer files than it holds.
    public var leftOut: [String: [String: Int]] = [:]
}

/// Entries checked during a folder walk, including files that may later be skipped.
/// The count is cumulative across roots and is not an indexing total.
public struct CrawlProgress: Sendable, Equatable {
    public let checked: Int
    public let root: String?

    public init(checked: Int, root: String?) {
        self.checked = checked
        self.root = root
    }
}

/// Walks the chosen folders and applies `Rules`. Reads metadata only, never file contents (except the 600-byte
/// sniff that tells a real MPEG-TS video from a TypeScript file).
///
/// For the code index (`IndexOptions.code`) it walks the code folders instead: code files only (`Rules.classifyCode`),
/// in a git repo only those git keeps (`GitFiles`), and none in vendored or built folders.
public enum Crawler {
    /// The folder can be opened for listing, as a walk of it would (a folder macOS won't let us read, or one that's
    /// gone, says no). Opening is enough: listing a cloud folder's top level could take a while.
    public static func canList(_ url: URL) -> Bool { FileSystem.canList(url.path) }

    public static func crawl(_ roots: [URL], options: IndexOptions,
                             progress: ((CrawlProgress) -> Void)? = nil) -> CrawlReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let keys = FileSystem.crawlKeys
        var report = CrawlReport()
        var projectRoots = Set<String>()
        var repos = GitRepos()
        var found: [Candidate] = []
        var foundRoot: [String: String] = [:]   // path → the chosen folder it was found under (a folder inside
                                                // another root would be walked twice)
        func leftOut(_ reason: String, under root: String) {
            report.skipped[reason, default: 0] += 1
            report.leftOut[root, default: [:]][reason, default: 0] += 1
        }
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        var checked = 0
        let clock = ContinuousClock()
        var lastUpdate = clock.now

        for root in roots.map({ $0.standardizedFileURL }) {
            progress?(CrawlProgress(checked: checked, root: root.path))
            lastUpdate = clock.now
            if Rules.isCacheDirectory(root) {
                report.skippedFolders["cache folder", default: 0] += 1
                continue
            }
            // A folder chosen on purpose is read whole, whatever markers it holds (a home folder with its dotfiles in
            // git, a repo of notes and pictures); the code-project rule applies to project folders found inside it.
            if options.code { repos.enterRoot(root.path) }
            // A skip applies inside the chosen folders that contain it: a folder chosen inside a skipped one is
            // walked whole (`FolderSelection`). The walk reports real paths (/private/var, where the root says /var).
            let real = FolderSelection.realPath(root.path)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root.path) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            #if os(Windows)
            guard let walker = FileSystem.walk(root) else { continue }
            #else
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { continue }
            #endif
            func visit(_ url: URL) {
                #if os(Windows)
                // Foundation's resource values can trap on 2–4 GiB files, even for isDirectory alone.
                // DirectoryWalk supplies this bit from WIN32_FIND_DATAW without asking Foundation.
                let values: URLResourceValues? = nil
                let isDirectory = url.hasDirectoryPath
                #else
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory == true
                #endif
                let isPackage = FileSystem.isPackage(url, values)
                if isDirectory, !isPackage {
                    if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips)
                        ?? (options.code ? Rules.codeSkipReason(forFolder: url) : nil) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                        report.leftOut[root.path, default: [:]]["folders " + reason, default: 0] += 1
                    } else if options.code {
                        repos.enter(url.path)
                    } else if Rules.isProjectRoot(url.path) {
                        projectRoots.insert(url.path)
                    }
                    return
                }
                if isPackage {
                    walker.skipDescendants()   // macOS's enumerator never enters one; elsewhere it would
                    let library = ["photoslibrary", "photolibrary"].contains(url.pathExtension.lowercased())
                    leftOut(library ? "Photos library" : "app or bundle", under: root.path)
                    return
                }
                let classification = options.code ? Rules.classifyCode(url, options: options)
                    : Rules.classify(url, values: values, options: options)
                switch classification {
                case .ignore:
                    leftOut("other type", under: root.path)
                case .skip(let reason):
                    leftOut(reason, under: root.path)
                case .index(let kind):
                    guard let info = FileSystem.info(of: url.path), info.isRegular else {
                        leftOut("link or special file", under: root.path)
                        return
                    }
                    // Reading a dataless placeholder (iCloud "Optimize Mac Storage", File Providers) downloads it.
                    if info.dataless {
                        leftOut("in the cloud, not downloaded", under: root.path)
                        return
                    }
                    if options.code {
                        // Too big to be written by hand; a notebook's file holds its outputs too.
                        let limit = url.pathExtension.lowercased() == "ipynb" ? options.maxNotebookBytes
                            : options.maxCodeBytes
                        if info.size > limit {
                            leftOut("too big to be written by hand", under: root.path)
                            return
                        }
                        if repos.ignores(url.path) {
                            leftOut("ignored by git", under: root.path)
                            return
                        }
                    }
                    guard foundRoot[url.path] == nil else { return }
                    foundRoot[url.path] = root.path
                    found.append(Candidate(path: url.path, kind: kind, size: info.size, mtime: info.mtime,
                                           inode: info.inode, device: info.device))
                }
            }

            // URL resource values are autoreleased; draining per file keeps a big walk from piling them up (the app
            // crawls on a background queue whose pool only drains when the whole sync is done).
            while let url = autoreleasepool(invoking: { walker.nextObject() as? URL }) {
                if let progress {
                    checked += 1
                    let now = clock.now
                    if now - lastUpdate >= .milliseconds(250) {
                        progress(CrawlProgress(checked: checked, root: root.path))
                        lastUpdate = now
                    }
                }
                autoreleasepool {
                    visit(url)
                }
            }
        }

        // Inside a code project only screenshots count (assets, fixtures and datasets don't).
        var inProject: [String: Bool] = [:]
        func isInProject(_ folder: String) -> Bool {
            if let known = inProject[folder] { return known }
            let parent = (folder as NSString).deletingLastPathComponent
            let answer = projectRoots.contains(folder) || (parent != folder && parent.count > 1 && isInProject(parent))
            inProject[folder] = answer
            return answer
        }
        var kept: [Candidate] = []
        for file in found {
            if !options.code, file.kind != .screenshot, isInProject((file.path as NSString).deletingLastPathComponent) {
                leftOut("inside a code project", under: foundRoot[file.path] ?? "")
            } else {
                kept.append(file)
            }
        }

        if !options.includeDatasets, !options.code {
            let datasets = Rules.datasetFolders(kept.map {
                (($0.path as NSString).deletingLastPathComponent,
                 (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension, $0.kind)
            }, roots: rootPaths)
            if !datasets.isEmpty {
                report.datasets = datasets
                kept.removeAll { file in
                    let skip = datasets[(file.path as NSString).deletingLastPathComponent] != nil
                        && [.image, .audio, .video].contains(file.kind)
                    if skip { leftOut("dataset", under: foundRoot[file.path] ?? "") }
                    return skip
                }
            }
        }
        report.candidates = kept
        progress?(CrawlProgress(checked: checked, root: nil))
        return report
    }
}

/// The git repos a code crawl walks through, and the files each keeps (`GitFiles`): a file git ignores (a build, an
/// environment, data, a secret listed in .gitignore) isn't code search's to read. A folder that isn't in a repo, or a
/// Mac without git, has no list: everything there counts.
struct GitRepos {
    /// Repo folder → the files git keeps in it (paths relative to it), or nil when git couldn't say.
    private var files: [String: Set<String>?] = [:]
    /// Folder → the repo it's in (nil: none), as the walk found them.
    private var repoOf: [String: String?] = [:]

    /// A chosen folder: a repo itself, or inside one (a repo's subfolder chosen on its own).
    mutating func enterRoot(_ path: String) {
        var folder = path
        while true {
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                files[folder] = GitFiles.list(folder)
                repoOf[path] = folder
                return
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, parent.count > 1 else { break }
            folder = parent
        }
        repoOf[path] = .some(nil)
    }

    /// A folder the walk goes into: a repo of its own when it has a .git folder (a submodule's or a worktree's .git
    /// file keeps it out of the walk: `Rules.codeSkipReason`).
    mutating func enter(_ path: String) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), isFolder.boolValue {
            files[path] = GitFiles.list(path)
            repoOf[path] = path
        }
    }

    /// The repo `folder` is in, from the closest folder the walk has seen.
    private mutating func repo(of folder: String) -> String? {
        if let known = repoOf[folder] { return known }
        let parent = (folder as NSString).deletingLastPathComponent
        let answer = parent != folder && parent.count > 1 ? repo(of: parent) : nil
        repoOf[folder] = answer
        return answer
    }

    /// Whether git ignores the file at `path` (in a repo whose files git listed).
    mutating func ignores(_ path: String) -> Bool {
        guard let repo = repo(of: (path as NSString).deletingLastPathComponent), let kept = files[repo] ?? nil
        else { return false }
        return !kept.contains(String(path.dropFirst(repo.count + 1)))
    }
}

/// The files git keeps in a repo: tracked ones, and new ones its .gitignore doesn't leave out.
enum GitFiles {
    /// Paths relative to `repo`, or nil when git can't say (no git, not a repo, an error). The git is `FileSystem.git`.
    static func list(_ repo: String) -> Set<String>? {
        guard let git = FileSystem.git else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // A repo that arrived unzipped or copied keeps its own .git/config, which can name a program (core.fsmonitor
        // runs for ls-files; hooks could for anything else): those settings are overridden, and the system's and
        // the user's config files are left out, so no config git reads here can run anything.
        #if os(Windows)
        let nullDevice = "NUL"
        #else
        let nullDevice = "/dev/null"
        #endif
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=\(nullDevice)", "-C", repo,
                             "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        // Reading only: never wait for, or take, the repo's lock (an editor's git may be busy in it).
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": nullDevice,
                               "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }
}

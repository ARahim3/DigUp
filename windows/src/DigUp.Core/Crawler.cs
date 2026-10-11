// Walks the chosen folders and applies Rules. Ports Crawler, GitRepos and
// GitFiles (Crawler.swift). Reads metadata only, never file contents (except
// the 600-byte sniff that tells a real MPEG-TS video from TypeScript).
// Adapts the Mac specifics with no behavior change in what is kept:
//   - lstat/S_IFREG      -> reparse points are links/special files, symlinked
//                          folders are never followed (cycle risk).
//   - SF_DATALESS +      -> Offline / RecallOnDataAccess attributes and
//     ubiquitous items     .icloud placeholders ("in the cloud, not
//                          downloaded"). Reading one would download it.
//   - ~/.ssh-style hides -> Hidden attribute or leading-dot names, skipped
//     (.skipsHiddenFiles)  silently like Swift.
//   - packages/bundles    -> .app/.bundle/.framework/.photoslibrary and
//     (.skipsPackage-       friends count as "app or bundle".
//     Descendants)
//   - inode/device       -> stable Windows file IDs (volume serial + file
//                          index) via GetFileInformationByHandle, 0 on failure.
// Paths are standardized (GetFullPath) and long-path aware: BCL calls rely on
// .NET long-path support, while raw handles (sniff, file IDs) go through the
// \\?\ prefix. Enumeration is an explicit stack so one denied folder cannot
// abort the walk (Swift's errorHandler returns true), and per-file work is
// FileSystemWatcher shaped: one absolute path in, one decision out.
// The detailed counts live on CrawlResult; Crawl implements ICrawler
// (Indexer.cs) by projecting to CrawlReport.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace DigUp.Core;

/// <summary>Full walk outcome: candidates plus the skip accounting Swift reports (Crawler.swift:14).</summary>
public sealed class CrawlResult
{
    /// <summary>Files the crawler decided to index.</summary>
    public List<CrawlCandidate> Candidates { get; } = new();

    /// <summary>Reason -> files.</summary>
    public Dictionary<string, int> Skipped { get; } = new(StringComparer.Ordinal);

    /// <summary>Reason -> folders not walked into.</summary>
    public Dictionary<string, int> SkippedFolders { get; } = new(StringComparer.Ordinal);

    /// <summary>Folder -> files skipped as a dataset.</summary>
    public Dictionary<string, int> Datasets { get; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class Crawler : ICrawler
{
    public CrawlReport Crawl(IReadOnlyList<string> roots, IndexOptions options) =>
        new CrawlReport(CrawlDetailed(roots, options).Candidates);

    /// <summary>Walk with full skip accounting (Crawler.swift:27).</summary>
    public static CrawlResult CrawlDetailed(IEnumerable<string> roots, IndexOptions options)
    {
        var report = new CrawlResult();
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var projectRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var repos = new GitRepos();
        var found = new List<CrawlCandidate>();
        var foundPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rootPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rootList = new List<string>();
        foreach (string root in roots)
        {
            string standardized = CrawlPaths.Standardize(root);
            rootList.Add(standardized);
            rootPaths.Add(standardized);
        }

        foreach (string root in rootList)
        {
            if (options.Code)
            {
                repos.EnterRoot(root);
            }
            else if (Rules.IsProjectRoot(root))
            {
                projectRoots.Add(root);
            }

            // A skip applies inside the chosen folders that contain it; a
            // folder chosen inside a skipped one is walked whole
            // (FolderSelection). Both the given and the real spelling count.
            string real = FolderSelection.RealPath(root);
            var skips = new List<string>();
            foreach (string excluded in options.ExcludedFolders)
            {
                string skip = CrawlPaths.Standardize(excluded);
                if (FolderSelection.IsInside(skip, root) || FolderSelection.IsInside(skip, real))
                {
                    skips.Add(skip);
                    skips.Add(FolderSelection.RealPath(skip));
                }
            }

            var stack = new Stack<string>();
            stack.Push(root);
            while (stack.Count > 0)
            {
                string dir = stack.Pop();
                string[] entries;
                try
                {
                    entries = Directory.GetFileSystemEntries(dir);
                }
                catch
                {
                    continue;
                }

                foreach (string entry in entries)
                {
                    VisitEntry(entry, options, home, skips, repos, projectRoots, found, foundPaths, stack, report);
                }
            }
        }

        // Inside a code project only screenshots count (Crawler.swift:121).
        var inProject = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        var kept = new List<CrawlCandidate>(found.Count);
        foreach (CrawlCandidate file in found)
        {
            if (!options.Code
                && file.Kind != FileKind.Screenshot
                && IsInProject(FolderSelection.Parent(file.Path), projectRoots, inProject))
            {
                Bump(report.Skipped, "inside a code project");
            }
            else
            {
                kept.Add(file);
            }
        }

        if (!options.IncludeDatasets && !options.Code)
        {
            var stems = new List<(string Folder, string Stem, FileKind Kind)>(kept.Count);
            foreach (CrawlCandidate file in kept)
            {
                string name = Path.GetFileName(file.Path);
                int dot = name.LastIndexOf('.');
                string stem = dot > 0 ? name.Substring(0, dot) : name;
                stems.Add((FolderSelection.Parent(file.Path), stem, file.Kind));
            }

            Dictionary<string, int> datasets = Rules.DatasetFolders(stems, rootPaths);
            if (datasets.Count > 0)
            {
                foreach (var pair in datasets)
                {
                    report.Datasets[pair.Key] = pair.Value;
                }

                kept.RemoveAll(file =>
                {
                    bool skip = datasets.ContainsKey(FolderSelection.Parent(file.Path))
                        && FileKindOrder.IsMedia(file.Kind);
                    if (skip)
                    {
                        Bump(report.Skipped, "dataset");
                    }

                    return skip;
                });
            }
        }

        report.Candidates.AddRange(kept);
        return report;
    }

    private static void VisitEntry(
        string entry,
        IndexOptions options,
        string home,
        List<string> skips,
        GitRepos repos,
        HashSet<string> projectRoots,
        List<CrawlCandidate> found,
        HashSet<string> foundPaths,
        Stack<string> stack,
        CrawlResult report)
    {
        string name = Path.GetFileName(entry);
        if (name.Length == 0)
        {
            return;
        }

        FileAttributes attributes;
        try
        {
            attributes = File.GetAttributes(entry);
        }
        catch
        {
            VisitUnstatable(entry, options, report);
            return;
        }

        // The enumerator's .skipsHiddenFiles: silent, files and folders alike.
        if ((attributes & FileAttributes.Hidden) != 0 || name.StartsWith(".", StringComparison.Ordinal))
        {
            return;
        }

        string standardized = CrawlPaths.Standardize(entry);
        bool isDirectory = (attributes & FileAttributes.Directory) != 0;
        bool reparse = (attributes & FileAttributes.ReparsePoint) != 0;

        if (isDirectory)
        {
            if (reparse)
            {
                return; // Never follow symlinked folders (cycle risk). Documented deviation: the Mac walk reports them.
            }

            if (CrawlPaths.IsBundle(name))
            {
                Bump(report.Skipped, "app or bundle");
                return;
            }

            string? reason = Rules.SkipReasonForFolder(standardized, home, skips)
                ?? (options.Code ? Rules.CodeSkipReasonForFolder(standardized) : null);
            if (reason != null)
            {
                Bump(report.SkippedFolders, reason);
                return;
            }

            if (options.Code)
            {
                repos.Enter(standardized);
            }
            else if (Rules.IsProjectRoot(standardized))
            {
                projectRoots.Add(standardized);
            }

            stack.Push(standardized);
            return;
        }

        Classification classification = options.Code
            ? Rules.ClassifyCode(standardized, options)
            : Rules.Classify(standardized, options);
        if (classification is Classification.Skip skip)
        {
            Bump(report.Skipped, skip.Reason);
            return;
        }

        if (classification is Classification.Ignore)
        {
            Bump(report.Skipped, "other type");
            return;
        }

        var kind = ((Classification.Index)classification).Kind;
        if (reparse)
        {
            Bump(report.Skipped, "link or special file");
            return;
        }

        long size;
        double mtime;
        try
        {
            var info = new FileInfo(entry);
            size = info.Length;
            mtime = (info.LastWriteTimeUtc - DateTime.UnixEpoch).TotalSeconds;
        }
        catch
        {
            Bump(report.Skipped, "link or special file");
            return;
        }

        // Reading a dataless placeholder downloads it: OneDrive /
        // File Provider placeholders and iCloud (.icloud) stubs.
        if ((attributes & FileAttributes.Offline) != 0
            || ((uint)attributes & CrawlPaths.RecallOnDataAccess) != 0
            || name.EndsWith(".icloud", StringComparison.OrdinalIgnoreCase))
        {
            Bump(report.Skipped, "in the cloud, not downloaded");
            return;
        }

        if (options.Code)
        {
            // Too big to be written by hand; a notebook's file holds its outputs too.
            long limit = Rules.ExtensionOf(name) == "ipynb" ? options.MaxNotebookBytes : options.MaxCodeBytes;
            if (size > limit)
            {
                Bump(report.Skipped, "too big to be written by hand");
                return;
            }

            if (repos.Ignores(standardized))
            {
                Bump(report.Skipped, "ignored by git");
                return;
            }
        }

        if (!foundPaths.Add(standardized))
        {
            return; // A folder inside another root would be walked twice.
        }

        FileIds.TryGet(standardized, out long device, out long inode);
        found.Add(new CrawlCandidate(Path: standardized, Size: size, Mtime: mtime, Kind: kind, Device: device, Inode: inode));
    }

    /// <summary>Swift still classifies a file whose metadata cannot be read; only an indexed one then fails at lstat.</summary>
    private static void VisitUnstatable(
        string entry,
        IndexOptions options,
        CrawlResult report)
    {
        string standardized = CrawlPaths.Standardize(entry);
        Classification classification = options.Code
            ? Rules.ClassifyCode(standardized, options)
            : Rules.Classify(standardized, options);
        if (classification is Classification.Skip skip)
        {
            Bump(report.Skipped, skip.Reason);
        }
        else if (classification is Classification.Ignore)
        {
            Bump(report.Skipped, "other type");
        }
        else
        {
            Bump(report.Skipped, "link or special file");
        }
    }

    private static bool IsInProject(
        string folder,
        HashSet<string> projectRoots,
        Dictionary<string, bool> memo)
    {
        if (memo.TryGetValue(folder, out bool known))
        {
            return known;
        }

        string parent = FolderSelection.Parent(folder);
        bool answer = projectRoots.Contains(folder)
            || (!parent.Equals(folder, StringComparison.OrdinalIgnoreCase)
                && parent.Length > 1
                && IsInProject(parent, projectRoots, memo));
        memo[folder] = answer;
        return answer;
    }

    internal static void Bump(Dictionary<string, int> counts, string reason)
    {
        counts[reason] = counts.TryGetValue(reason, out int n) ? n + 1 : 1;
    }
}

/// <summary>Standardized, long-path aware path helpers for the walk.</summary>
internal static class CrawlPaths
{
    /// <summary>FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000): cloud placeholder.</summary>
    internal const uint RecallOnDataAccess = 0x00400000;

    private static readonly HashSet<string> BundleExtensions = new(
        new[] { "app", "bundle", "framework", "xcodeproj", "xcworkspace", "photoslibrary", "sparsebundle", "vmwarevm", "plugin", "kext" },
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Absolute, separator-trimmed spelling: the FileSystemWatcher-friendly identity of a path.</summary>
    internal static string Standardize(string path)
    {
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch
        {
            return path;
        }

        if (full.Length > 3 && (full.EndsWith("\\") || full.EndsWith("/")))
        {
            full = full.TrimEnd('\\', '/');
        }

        return full;
    }

    /// <summary>\\?\ spelling for raw handles; BCL enumeration already handles long paths.</summary>
    internal static string ToLongPath(string path)
    {
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
        {
            return path;
        }

        string full = Standardize(path);
        if (full.Length < 240)
        {
            return full;
        }

        if (full.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return @"\\?\UNC\" + full.TrimStart('\\');
        }

        return @"\\?\" + full;
    }

    internal static bool IsBundle(string fileName) => BundleExtensions.Contains(Rules.ExtensionOf(fileName));
}

/// <summary>Stable Windows file IDs (volume serial + file index), 0 when unknown.</summary>
internal static class FileIds
{
    private const uint ShareAll = 1 | 2 | 4; // READ | WRITE | DELETE
    private const uint OpenExisting = 3;
    private const uint FlagBackupSemantics = 0x02000000;
    private static readonly IntPtr InvalidHandle = new(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public uint CreationLow;
        public uint CreationHigh;
        public uint AccessLow;
        public uint AccessHigh;
        public uint WriteLow;
        public uint WriteHigh;
        public uint VolumeSerial;
        public uint SizeHigh;
        public uint SizeLow;
        public uint NumberOfLinks;
        public uint IndexHigh;
        public uint IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string fileName, uint desiredAccess, uint shareMode, IntPtr security,
        uint creationDisposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out FileInformation info);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    internal static bool TryGet(string path, out long device, out long inode)
    {
        device = 0;
        inode = 0;
        IntPtr handle = InvalidHandle;
        try
        {
            handle = CreateFileW(
                CrawlPaths.ToLongPath(path), 0, ShareAll, IntPtr.Zero, OpenExisting, FlagBackupSemantics, IntPtr.Zero);
            if (handle == InvalidHandle || !GetFileInformationByHandle(handle, out FileInformation info))
            {
                return false;
            }

            device = info.VolumeSerial;
            inode = ((long)info.IndexHigh << 32) | info.IndexLow;
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (handle != InvalidHandle)
            {
                CloseHandle(handle);
            }
        }
    }
}

/// <summary>
/// The git repos a code crawl walks through, and the files each keeps
/// (Crawler.swift:159): a file git ignores is not code search's to read.
/// A folder that is not in a repo, or a machine without git, has no list:
/// everything there counts.
/// </summary>
public sealed class GitRepos
{
    private readonly Dictionary<string, HashSet<string>?> _files = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string?> _repoOf = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A chosen folder: a repo itself, or inside one (Crawler.swift:169).</summary>
    public void EnterRoot(string path)
    {
        string standardized = CrawlPaths.Standardize(path);
        string folder = standardized;
        while (true)
        {
            // A worktree's .git is a file: still a repo root (the walk itself
            // never descends into .git-file folders; those are skipped).
            if (Directory.Exists(Path.Combine(folder, ".git")) || File.Exists(Path.Combine(folder, ".git")))
            {
                _files[folder] = GitFiles.List(folder);
                _repoOf[standardized] = folder;
                return;
            }

            string? parent = Path.GetDirectoryName(folder.TrimEnd('\\', '/'));
            if (string.IsNullOrEmpty(parent) || parent.Equals(folder, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            folder = parent;
        }

        _repoOf[standardized] = null;
    }

    /// <summary>
    /// A folder the walk goes into: a repo of its own when it has a .git
    /// folder (Crawler.swift:184). A submodule's or worktree's .git file keeps
    /// it out of the walk via Rules.CodeSkipReasonForFolder.
    /// </summary>
    public void Enter(string path)
    {
        if (Directory.Exists(Path.Combine(path, ".git")))
        {
            _files[path] = GitFiles.List(path);
            _repoOf[path] = path;
        }
    }

    /// <summary>The repo <paramref name="folder"/> is in, from the closest folder the walk has seen.</summary>
    public string? RepoOf(string folder)
    {
        if (_repoOf.TryGetValue(folder, out string? known))
        {
            return known;
        }

        string parent = FolderSelection.Parent(folder);
        string? answer = !parent.Equals(folder, StringComparison.OrdinalIgnoreCase) && parent.Length > 1
            ? RepoOf(parent)
            : null;
        _repoOf[folder] = answer;
        return answer;
    }

    /// <summary>Whether git ignores the file at <paramref name="path"/> (Crawler.swift:205).</summary>
    public bool Ignores(string path)
    {
        string? repo = RepoOf(FolderSelection.Parent(path));
        if (repo == null || !_files.TryGetValue(repo, out HashSet<string>? kept) || kept == null)
        {
            return false;
        }

        if (path.Length <= repo.Length + 1
            || (path[repo.Length] != '\\' && path[repo.Length] != '/')
            || !path.StartsWith(repo, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string relative = path.Substring(repo.Length + 1).Replace('\\', '/');
        return !kept.Contains(relative);
    }
}

/// <summary>
/// The files git keeps in a repo: tracked ones, and new ones its .gitignore
/// does not leave out (Crawler.swift:211). Reading only: never waits for, or
/// takes, the repo's lock.
/// </summary>
public static class GitFiles
{
    private static string? _git;
    private static bool _probed;

    /// <summary>A git that is really installed, or null.</summary>
    public static string? GitPath()
    {
        if (_probed)
        {
            return _git;
        }

        _probed = true;
        _git = FindGit();
        return _git;
    }

    private static string? FindGit()
    {
        if (RunsGit("git"))
        {
            return "git";
        }

        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates =
        {
            Path.Combine(programFiles, "Git", "cmd", "git.exe"),
            Path.Combine(programFiles, "Git", "bin", "git.exe"),
            Path.Combine(programFilesX86, "Git", "cmd", "git.exe"),
            Path.Combine(localAppData, "Programs", "Git", "cmd", "git.exe"),
        };
        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static bool RunsGit(string exe)
    {
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.ArgumentList.Add("--version");
            using var process = Process.Start(start);
            if (process == null)
            {
                return false;
            }

            process.WaitForExit(15000);
            if (!process.HasExited)
            {
                try
                {
                    process.Kill();
                }
                catch
                {
                    // Already gone.
                }

                return false;
            }

            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Paths relative to <paramref name="repo"/> (forward slashes), or null when git cannot say.</summary>
    public static HashSet<string>? List(string repo)
    {
        string? git = GitPath();
        if (git == null)
        {
            return null;
        }

        try
        {
            var start = new ProcessStartInfo
            {
                FileName = git,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            start.ArgumentList.Add("-C");
            start.ArgumentList.Add(repo);
            start.ArgumentList.Add("ls-files");
            start.ArgumentList.Add("-z");
            start.ArgumentList.Add("--cached");
            start.ArgumentList.Add("--others");
            start.ArgumentList.Add("--exclude-standard");
            start.Environment["GIT_OPTIONAL_LOCKS"] = "0";
            using var process = Process.Start(start);
            if (process == null)
            {
                return null;
            }

            string output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(30000);
            if (process.HasExited && process.ExitCode == 0)
            {
                var kept = new HashSet<string>(StringComparer.Ordinal);
                foreach (string entry in output.Split('\0'))
                {
                    if (entry.Length > 0)
                    {
                        kept.Add(entry);
                    }
                }

                return kept;
            }

            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                }
            }
            catch
            {
                // Already gone.
            }

            return null;
        }
        catch
        {
            return null;
        }
    }
}

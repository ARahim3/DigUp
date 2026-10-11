// What gets indexed. Ports Rules (Rules.swift).
// The code-search tables already ported (RulesData in CodeExtractor.cs) are
// reused, not duplicated; the secret check and MPEG-TS sniff delegate to
// CodeExtractor for the same reason. Name matching is Ordinal (like Swift's
// Set containment and the RulesData precedent); extension sets are
// OrdinalIgnoreCase, which equals Swift's lowercase-then-compare.
// UTType conformance (no Windows equivalent) is replaced by extension tables
// with the same position in the check order (Rules.swift:119-125).
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace DigUp.Core;

public static class Rules
{
    /// <summary>
    /// Folders never worth walking into (Rules.swift:14). Hidden folders and
    /// bundles are skipped by the walk itself, as in Swift.
    /// </summary>
    public static readonly HashSet<string> SkippedFolderNames = new(
        new[] { "node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage" },
        StringComparer.Ordinal);

    /// <summary>Any of these in a folder makes it a code project (Rules.swift:19). Shared with RulesData.</summary>
    public static IReadOnlyList<string> ProjectMarkers => RulesData.ProjectMarkers;

    /// <summary>Project bundles that mark a code project (Rules.swift:23).</summary>
    public static readonly HashSet<string> ProjectBundleExtensions = new(
        new[] { "xcodeproj", "xcworkspace" },
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Plain documents, always indexed (Rules.swift:25).</summary>
    public static readonly HashSet<string> DocExtensions = new(
        new[] { "txt", "text", "md", "markdown", "rtf", "docx", "doc", "odt", "html", "htm" },
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Screenshot file-name prefixes, the fallback when no screen-capture mark exists (Rules.swift:37).</summary>
    public static readonly string[] ScreenshotPrefixes = { "Screenshot", "Screen Shot", "CleanShot", "SCR-" };

    /// <summary>
    /// Image extensions standing in for UTType.image conformance
    /// (Rules.swift:123). Checked after doc/code/source extensions, as in Swift.
    /// </summary>
    public static readonly HashSet<string> ImageExtensions = new(
        new[] { "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "avif", "ico",
                "dng", "nef", "cr2", "cr3", "arw", "rw2", "orf", "raf" },
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Video extensions standing in for UTType.movie conformance (Rules.swift:124).</summary>
    public static readonly HashSet<string> VideoExtensions = new(
        new[] { "mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "mpg", "mpeg", "3gp", "3g2", "flv" },
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Audio extensions standing in for UTType.audio conformance (Rules.swift:125).</summary>
    public static readonly HashSet<string> AudioExtensions = new(
        new[] { "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "aiff", "aif", "wma" },
        StringComparer.OrdinalIgnoreCase);

    // MARK: Code (the code index, IndexOptions.Code)

    /// <summary>
    /// What code search reads in the code folders (Rules.swift:68). Same order
    /// as Swift: excluded type, keys, minified bundles, licenses, the MPEG-TS
    /// video check for .ts/.mts, sources and repo docs, then data files.
    /// </summary>
    public static Classification ClassifyCode(string path, IndexOptions options)
    {
        string name = Path.GetFileName(path);
        string ext = ExtensionOf(name);
        if (options.ExcludedExtensions.Contains(ext))
        {
            return new Classification.Skip("excluded type");
        }

        if (CodeExtractor.IsSecret(name))
        {
            return new Classification.Skip("key or password file");
        }

        string lower = name.ToLowerInvariant();
        if (lower.EndsWith(".min.js", StringComparison.Ordinal)
            || lower.EndsWith(".min.mjs", StringComparison.Ordinal)
            || lower.EndsWith(".min.css", StringComparison.Ordinal))
        {
            return new Classification.Skip("minified");
        }

        if (lower.StartsWith("license", StringComparison.Ordinal)
            || lower.StartsWith("licence", StringComparison.Ordinal)
            || lower.StartsWith("copying", StringComparison.Ordinal)
            || lower.StartsWith("notice", StringComparison.Ordinal))
        {
            return new Classification.Skip("license");
        }

        if ((ext == "ts" || ext == "mts") && CodeExtractor.IsMpegTransportStream(path))
        {
            return Classification.Ignore.Instance; // a video
        }

        if (RulesData.SourceExtensions.Contains(ext)
            || RulesData.CodeTextExtensions.Contains(ext)
            || ext == "ipynb"
            || RulesData.CodeFileNames.Contains(name)
            || name.StartsWith("Dockerfile", StringComparison.Ordinal))
        {
            return new Classification.Index(FileKind.Code);
        }

        if (RulesData.CodeExtensions.Contains(ext))
        {
            return new Classification.Skip("data file"); // json, csv, lockfiles, logs, plists
        }

        return Classification.Ignore.Instance;
    }

    /// <summary>
    /// Why code search does not go into this folder, or null. Ports
    /// codeSkipReason (Rules.swift:98): vendored/built folders, and submodules
    /// or worktrees (where .git is a file). Unlike
    /// CodeExtractor.FolderSkipReason (which walks a file's folders upward),
    /// this checks just the one folder, as the Swift walk does.
    /// </summary>
    public static string? CodeSkipReasonForFolder(string folder)
    {
        if (RulesData.CodeSkippedFolderNames.Contains(Path.GetFileName(folder.TrimEnd('\\', '/'))))
        {
            return "vendored or built code";
        }

        // A submodule or a worktree (".git" is a file there).
        if (File.Exists(Path.Combine(folder, ".git")))
        {
            return "submodule or worktree";
        }

        return null;
    }

    // MARK: Media and documents (the main index)

    /// <summary>
    /// What the main index does with a file (Rules.swift:108). The
    /// <c>type</c> parameter has no Windows counterpart, so UTType conformance
    /// becomes: source/code-text extensions (sourceCode/script), then
    /// pdf/image/movie/audio extension tables, in Swift's order.
    /// </summary>
    public static Classification Classify(string path, IndexOptions options)
    {
        string name = Path.GetFileName(path);
        string ext = ExtensionOf(name);
        if (options.ExcludedExtensions.Contains(ext))
        {
            return new Classification.Skip("excluded type");
        }

        // .ts/.mts are usually TypeScript, which the Mac types as MPEG-2
        // video. Only a real transport stream is video.
        if (ext == "ts" || ext == "mts" || ext == "m2ts")
        {
            if (CodeExtractor.IsMpegTransportStream(path))
            {
                return new Classification.Index(FileKind.Video);
            }

            return options.IncludeCode
                ? new Classification.Index(FileKind.Doc)
                : new Classification.Skip("code or data file");
        }

        if (DocExtensions.Contains(ext))
        {
            return new Classification.Index(FileKind.Doc);
        }

        if (RulesData.CodeExtensions.Contains(ext))
        {
            return options.IncludeCode
                ? new Classification.Index(FileKind.Doc)
                : new Classification.Skip("code or data file");
        }

        // UTType.sourceCode / UTType.script equivalent.
        if (RulesData.SourceExtensions.Contains(ext) || RulesData.CodeTextExtensions.Contains(ext))
        {
            return options.IncludeCode
                ? new Classification.Index(FileKind.Doc)
                : new Classification.Skip("code or data file");
        }

        if (ext == "pdf")
        {
            return new Classification.Index(FileKind.Pdf);
        }

        if (ImageExtensions.Contains(ext))
        {
            return new Classification.Index(IsScreenshot(path) ? FileKind.Screenshot : FileKind.Image);
        }

        if (VideoExtensions.Contains(ext))
        {
            return new Classification.Index(FileKind.Video);
        }

        if (AudioExtensions.Contains(ext))
        {
            return new Classification.Index(FileKind.Audio);
        }

        return Classification.Ignore.Instance;
    }

    /// <summary>
    /// Screenshot by file name (Rules.swift:141). Windows has no
    /// kMDItemIsScreenCapture xattr, so only the name prefixes apply.
    /// </summary>
    public static bool IsScreenshot(string path)
    {
        string name = Path.GetFileName(path);
        foreach (string prefix in ScreenshotPrefixes)
        {
            if (name.StartsWith(prefix, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Why the walk does not go into a folder, or null (Rules.swift:146).
    /// The ~/Library check accepts both separators; the excluded check mirrors
    /// Swift's equality-or-inside test.
    /// </summary>
    public static string? SkipReasonForFolder(string folderPath, string home, IEnumerable<string> excluded)
    {
        string name = Path.GetFileName(folderPath.TrimEnd('\\', '/'));
        if (SkippedFolderNames.Contains(name))
        {
            return "developer folder";
        }

        if (name.EndsWith(".noindex", StringComparison.Ordinal))
        {
            return ".noindex folder";
        }

        if (folderPath.Equals(home + "/Library", StringComparison.Ordinal)
            || folderPath.Equals(home + "\\Library", StringComparison.Ordinal))
        {
            return "~/Library";
        }

        foreach (string skip in excluded)
        {
            if (folderPath.Equals(skip, StringComparison.Ordinal) || FolderSelection.IsInside(folderPath, skip))
            {
                return "excluded folder";
            }
        }

        return null;
    }

    /// <summary>Whether the folder is a code project root (Rules.swift:155). Shared with the code port.</summary>
    public static bool IsProjectRoot(string folder) => CodeExtractor.IsProjectRoot(folder);

    /// <summary>
    /// Lowercase extension with NSString pathExtension semantics: a leading
    /// dot is not an extension (".env" has none), unlike Path.GetExtension.
    /// </summary>
    public static string ExtensionOf(string fileName)
    {
        int dot = fileName.LastIndexOf('.');
        if (dot <= 0 || dot == fileName.Length - 1)
        {
            return string.Empty;
        }

        return fileName.Substring(dot + 1).ToLowerInvariant();
    }

    // MARK: Datasets

    /// <summary>Camera-name prefixes: never machine-named (Rules.swift:162).</summary>
    public static readonly string[] CameraPrefixes =
        { "img", "dsc", "pxl", "mvimg", "vid", "gopr", "dji", "photo", "whatsapp", "screenshot" };

    private static readonly Regex HexName = new(
        @"^[0-9a-f]{8,}([-_][0-9a-f]{4,})*$", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex NumberedName = new(
        @"^[a-z]{0,16}[-_. ]?\d{3,}([-_.]\d+)*$", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// Machine-made names like "clip_000123", "frame-0042" or hex ids, but not
    /// camera names like "IMG_1234" (Rules.swift:166).
    /// </summary>
    public static bool LooksMachineNamed(string stem)
    {
        string name = stem.ToLowerInvariant();
        foreach (string prefix in CameraPrefixes)
        {
            if (name.StartsWith(prefix, StringComparison.Ordinal))
            {
                return false;
            }
        }

        if (HexName.IsMatch(name))
        {
            return true;
        }

        return NumberedName.IsMatch(name);
    }

    /// <summary>
    /// Folders with hundreds of same-kind, machine-named media files:
    /// training data, skipped and reported (Rules.swift:175). Roots picked by
    /// hand are never datasets. Keys match Swift's folder + NUL + kind raw value.
    /// </summary>
    public static Dictionary<string, int> DatasetFolders(
        IEnumerable<(string Folder, string Stem, FileKind Kind)> files,
        ISet<string> roots,
        int minimum = 300)
    {
        var groups = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            if (!FileKindOrder.IsMedia(file.Kind) || roots.Contains(file.Folder))
            {
                continue;
            }

            string key = file.Folder + "\0" + file.Kind.ToStorageString();
            if (!groups.TryGetValue(key, out List<string>? stems))
            {
                stems = new List<string>();
                groups[key] = stems;
            }

            stems.Add(file.Stem);
        }

        var datasets = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in groups)
        {
            if (pair.Value.Count < minimum)
            {
                continue;
            }

            int machine = 0;
            foreach (string stem in pair.Value)
            {
                if (LooksMachineNamed(stem))
                {
                    machine++;
                }
            }

            if ((double)machine / pair.Value.Count >= 0.7)
            {
                string folder = pair.Key.Substring(0, pair.Key.IndexOf('\0'));
                datasets[folder] = datasets.TryGetValue(folder, out int n) ? n + pair.Value.Count : pair.Value.Count;
            }
        }

        return datasets;
    }
}

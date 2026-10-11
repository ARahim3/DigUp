// Code extraction for the code index. Ports CodeExtractor + CodeLookup
// (CodeExtractor.swift) and the code parts of Rules (Rules.swift:40-107):
// gitignore, vendored/generated/minified/secret skips, notebook cells, and
// title-as-file-in-repo.
using System.Linq;

namespace DigUp.Core;

/// <summary>Implemented subset of .gitignore matching for code search.</summary>
public interface IGitIgnore
{
    bool IsIgnored(string absolutePath, bool isDirectory);
}

public sealed class NullGitIgnore : IGitIgnore
{
    public static readonly NullGitIgnore Instance = new();

    public bool IsIgnored(string absolutePath, bool isDirectory) => false;
}

/// <summary>
/// Loads .gitignore files from a file's folder up to its repo root and matches
/// them last-match-wins (with ! negation). Glob support: *, ?, **, trailing /
/// (directory only), leading / (anchored). Approximates git for the cases
/// code search cares about.
/// </summary>
public sealed class GitIgnore : IGitIgnore
{
    private readonly System.Collections.Generic.List<(string BaseDir, System.Collections.Generic.List<(bool Negated, bool DirOnly, System.Text.RegularExpressions.Regex Pattern)> Rules)> _files = new();

    public static IGitIgnore LoadForFile(string filePath)
    {
        var ignore = new GitIgnore();
        string? dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(filePath));
        var stack = new System.Collections.Generic.Stack<(string, string[])>();
        while (dir != null)
        {
            string gitignore = System.IO.Path.Combine(dir, ".gitignore");
            if (System.IO.File.Exists(gitignore))
            {
                try
                {
                    stack.Push((dir, System.IO.File.ReadAllLines(gitignore)));
                }
                catch
                {
                    // Unreadable ignore file: treat as absent.
                }
            }

            if (HasGitEntry(dir) || CodeExtractor.IsProjectRoot(dir))
            {
                break;
            }

            string? parent = System.IO.Path.GetDirectoryName(dir.TrimEnd(System.IO.Path.DirectorySeparatorChar));
            if (string.IsNullOrEmpty(parent) || parent == dir)
            {
                break;
            }

            dir = parent;
        }

        // Outermost first so deeper files (and later lines) win.
        while (stack.Count > 0)
        {
            var (baseDir, lines) = stack.Pop();
            ignore.AddFile(baseDir, lines);
        }

        return ignore._files.Count == 0 ? NullGitIgnore.Instance : ignore;
    }

    private static bool HasGitEntry(string dir)
    {
        return System.IO.Directory.Exists(System.IO.Path.Combine(dir, ".git"))
            || System.IO.File.Exists(System.IO.Path.Combine(dir, ".git"));
    }

    private void AddFile(string baseDir, string[] lines)
    {
        var rules = new System.Collections.Generic.List<(bool, bool, System.Text.RegularExpressions.Regex)>();
        foreach (string raw in lines)
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#") || line == "!" || line == "/")
            {
                continue;
            }

            bool negated = line.StartsWith("!");
            if (negated)
            {
                line = line.Substring(1).Trim();
            }

            bool dirOnly = line.EndsWith("/");
            line = line.TrimEnd('/');
            bool anchored = line.StartsWith("/");
            line = line.TrimStart('/');
            bool nameOnly = !anchored && !line.Contains("/");
            string regex = "^" + GlobToRegex(line) + (dirOnly ? "(/.*)?" : "(/.*)?") + "$";
            // Name-only patterns match at any depth; anchored ones match from baseDir.
            string full = nameOnly ? @"(^|.*/)" + GlobToRegex(line) + "(/.*)?$" : regex;
            try
            {
                rules.Add((negated, dirOnly, new System.Text.RegularExpressions.Regex(
                    full, System.Text.RegularExpressions.RegexOptions.IgnoreCase)));
            }
            catch
            {
                // Bad pattern: skip it.
            }
        }

        if (rules.Count > 0)
        {
            _files.Add((baseDir, rules));
        }
    }

    private static string GlobToRegex(string glob)
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < glob.Length; i++)
        {
            char c = glob[i];
            if (c == '*' && i + 1 < glob.Length && glob[i + 1] == '*')
            {
                if (i + 2 < glob.Length && glob[i + 2] == '/')
                {
                    sb.Append("(.*/)?");
                    i += 2;
                }
                else
                {
                    sb.Append(".*");
                    i++;
                }
            }
            else if (c == '*')
            {
                sb.Append("[^/]*");
            }
            else if (c == '?')
            {
                sb.Append("[^/]");
            }
            else
            {
                sb.Append(System.Text.RegularExpressions.Regex.Escape(c.ToString()));
            }
        }

        return sb.ToString();
    }

    public bool IsIgnored(string absolutePath, bool isDirectory)
    {
        bool ignored = false;
        string full = System.IO.Path.GetFullPath(absolutePath);
        foreach (var (baseDir, rules) in _files)
        {
            string rel;
            try
            {
                rel = System.IO.Path.GetRelativePath(baseDir, full).Replace('\\', '/');
            }
            catch
            {
                continue;
            }

            if (rel.StartsWith("..", System.StringComparison.Ordinal))
            {
                continue;
            }

            foreach (var (negated, dirOnly, pattern) in rules)
            {
                if (dirOnly && !isDirectory)
                {
                    // A dir-only pattern still ignores everything beneath the dir.
                    if (!pattern.IsMatch(rel))
                    {
                        continue;
                    }
                }
                else if (!pattern.IsMatch(rel))
                {
                    continue;
                }

                ignored = !negated;
            }
        }

        return ignored;
    }
}

public enum CodeDecision
{
    Index,
    Skip,
    Ignore,
}

public static class CodeExtractor
{
    /// <summary>A single line longer than this is cut here (model reads 2048 tokens max).</summary>
    public const int LongestPiece = 4000;

    public static CodeFile Read(string path, IndexOptions options, IGitIgnore? gitIgnore = null)
    {
        if (gitIgnore?.IsIgnored(path, isDirectory: false) == true)
        {
            throw ExtractError.LeftOut("ignored");
        }

        string? folderSkip = FolderSkipReason(path);
        if (folderSkip != null)
        {
            throw ExtractError.LeftOut(folderSkip);
        }

        var (repo, title) = Place(path);
        string ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        bool cappedDoc = RulesData.CodeTextExtensions.Contains(ext);

        byte[] data;
        long fileBytes;
        try
        {
            if (cappedDoc)
            {
                // Long repo doc: read the head plus slack only. Memory stays
                // bounded whatever the file size; the cap below cuts at a line.
                fileBytes = new System.IO.FileInfo(path).Length;
                int want = (int)System.Math.Min(fileBytes, (long)options.MaxDocBytes + 65536);
                data = new byte[want];
                using var stream = System.IO.File.OpenRead(path);
                int got = 0, n;
                while (got < want && (n = stream.Read(data, got, want - got)) > 0)
                    got += n;
                if (got < want)
                    System.Array.Resize(ref data, got);
            }
            else
            {
                data = System.IO.File.ReadAllBytes(path);
                fileBytes = data.Length;
            }
        }
        catch (System.Exception error) when (error is System.IO.IOException || error is System.UnauthorizedAccessException)
        {
            throw ExtractError.Unreadable(error.Message);
        }

        if (ext == "ipynb")
        {
            // NOTE: size caps live in the crawler on Swift (Crawler.swift:95);
            // enforced here since the crawler is a separate port.
            if (data.Length > options.MaxNotebookBytes)
            {
                throw ExtractError.LeftOut($"notebook over {options.MaxNotebookBytes >> 20} MB");
            }

            var cells = NotebookCells(Decode(data));
            string text = string.Join("\n", cells);
            if (System.Text.Encoding.UTF8.GetByteCount(text) > options.MaxCodeBytes)
            {
                throw ExtractError.LeftOut($"cells over {options.MaxCodeBytes >> 20} MB");
            }

            Check(text, isSource: true);
            return new CodeFile(Cells(cells, options.CodeStretch), title, repo, LineCount(text), cells.Count);
        }

        int probe = System.Math.Min(data.Length, 8000);
        for (int i = 0; i < probe; i++)
        {
            if (data[i] == 0)
            {
                throw ExtractError.LeftOut("not text");
            }
        }

        if (data.Length > options.MaxCodeBytes)
        {
            throw ExtractError.LeftOut($"file over {options.MaxCodeBytes >> 20} MB");
        }

        string decoded = Decode(data);
        string? capNote = null;
        if (cappedDoc && fileBytes > options.MaxDocBytes)
        {
            // Read with a cap (length capped): keep the head, cut at a line,
            // say what's missing. A split surrogate pair can't hurt: every
            // text entry point cleans lone surrogates (see TextSanitize).
            if (decoded.Length > options.MaxDocBytes)
            {
                int cut = decoded.LastIndexOf('\n', System.Math.Min(decoded.Length - 1, options.MaxDocBytes));
                if (cut <= 0)
                    cut = options.MaxDocBytes;
                decoded = decoded.Substring(0, cut);
            }
            long kept = System.Text.Encoding.UTF8.GetByteCount(decoded);
            capNote = kept < fileBytes ? $"first {SizeKb(kept)} of {SizeKb(fileBytes)}" : null;
        }
        Check(decoded, RulesData.SourceExtensions.Contains(ext));
        return new CodeFile(Lines(decoded, options.CodeStretch), title, repo, LineCount(decoded), null, capNote);
    }

    private static string SizeKb(long bytes) =>
        bytes >= 1 << 20 ? $"{bytes / (double)(1 << 20):0.0} MB" : $"{System.Math.Max(1, bytes >> 10)} KB";

    private static string Decode(byte[] data)
    {
        try
        {
            return System.Text.Encoding.UTF8.GetString(data);
        }
        catch
        {
            return System.Text.Encoding.GetEncoding("iso-8859-1").GetString(data);
        }
    }

    /// <summary>
    /// Code with no use to read: private keys, program-made or minified
    /// source. Ports check (CodeExtractor.swift:50).
    /// </summary>
    public static void Check(string text, bool isSource)
    {
        if (text.Contains("PRIVATE KEY-----"))
        {
            throw ExtractError.LeftOut("holds a private key");
        }

        if (!isSource)
        {
            return;
        }

        string top = text.Length > 1000 ? text.Substring(0, 1000) : text;
        foreach (string mark in new[] { "DO NOT EDIT", "@generated", "Code generated by", "Autogenerated by", "Generated by the protocol" })
        {
            if (top.Contains(mark))
            {
                throw ExtractError.LeftOut($"made by a program (“{mark}”)");
            }
        }

        int lines = System.Math.Max(1, LineCount(text));
        if (text.Length / lines > 300 && text.Split('\n').Any(static line => line.Length > 3000))
        {
            throw ExtractError.LeftOut($"minified ({text.Length / lines} characters a line)");
        }
    }

    public static int LineCount(string text)
    {
        int count = 0;
        foreach (char c in text)
        {
            if (c == '\n')
            {
                count++;
            }
        }

        return text.EndsWith("\n") || text.Length == 0 ? count : count + 1;
    }

    /// <summary>
    /// Stretches of whole lines, each at most <paramref name="size"/> chars.
    /// Ends at natural breaks (new block after a blank line, else any blank
    /// or block start) in its last 60%; a mid-block cut hands two lines on.
    /// Ports lines (CodeExtractor.swift:77).
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<CodePiece> Lines(string text, int size = 1800)
    {
        var lines = new System.Collections.Generic.List<string>(
            text.Split(new[] { "\r\n", "\n" }, System.StringSplitOptions.None));
        if (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1); // the final newline
        }

        int count = lines.Count;
        var offsets = new System.Collections.Generic.List<int>(count + 1) { 0 };
        foreach (string line in lines)
        {
            offsets.Add(offsets[^1] + line.Length + 1);
        }

        bool Blank(int i) => lines[i].Trim().Length == 0;
        bool StartsBlock(int i)
        {
            if (lines[i].Length == 0 || char.IsWhiteSpace(lines[i][0]))
            {
                return false;
            }

            string trimmed = lines[i].Trim();
            char first = lines[i][0];
            return "})]".IndexOf(first) < 0 && !RulesData.Closers.Contains(trimmed);
        }

        var pieces = new System.Collections.Generic.List<CodePiece>();
        int start = 0;
        while (start < count)
        {
            while (start < count && Blank(start))
            {
                start++;
            }

            if (start >= count)
            {
                break;
            }

            int end = start + 1;
            while (end < count && offsets[end + 1] - offsets[start] <= size)
            {
                end++;
            }

            bool natural = end >= count;
            if (!natural)
            {
                int floor = offsets[start] + size * 2 / 5;
                int? LastBreak(System.Func<int, bool> isBreak)
                {
                    int line = end;
                    while (line > start + 1 && offsets[line] >= floor)
                    {
                        if (isBreak(line))
                        {
                            return line;
                        }

                        line--;
                    }

                    return null;
                }

                int? cut = LastBreak(i => StartsBlock(i) && Blank(i - 1))
                    ?? LastBreak(i => Blank(i - 1) || StartsBlock(i));
                if (cut.HasValue)
                {
                    end = cut.Value;
                    natural = true;
                }
            }

            int last = end;
            while (last > start + 1 && Blank(last - 1))
            {
                last--;
            }

            string body = string.Join("\n", lines.GetRange(start, last - start));
            if (body.Length > LongestPiece)
            {
                body = body.Substring(0, LongestPiece);
            }

            pieces.Add(new CodePiece(body, start + 1, last));
            start = natural ? end : System.Math.Max(end - 2, start + 1);
        }

        return pieces;
    }

    /// <summary>
    /// One-line summary for result lists: the first defining line, else the
    /// first line of code, else the first line. Ports summary (CodeExtractor.swift:130).
    /// </summary>
    public static string Summary(string text)
    {
        var lines = new System.Collections.Generic.List<string>();
        foreach (string raw in text.Split(new[] { "\r\n", "\n" }, System.StringSplitOptions.None))
        {
            string trimmed = raw.Trim();
            if (trimmed.Length > 0)
            {
                lines.Add(trimmed);
            }
        }

        string? definition = null, code = null;
        string[] nonCode = { "//", "#", "/*", "*", "--", "\"\"\"", "import ", "from ", "#include", "using ", "package ", "}", ")", "@" };
        foreach (string line in lines)
        {
            if (definition == null)
            {
                var words = line.Split((char[])null, System.StringSplitOptions.RemoveEmptyEntries);
                int take = System.Math.Min(words.Length, 4);
                for (int i = 0; i < take; i++)
                {
                    if (DefinesSomething(words[i]))
                    {
                        definition = line;
                        break;
                    }
                }
            }

            if (code == null && !nonCode.Any(line.StartsWith))
            {
                code = line;
            }

            if (definition != null && code != null)
            {
                break;
            }
        }

        string picked = definition ?? code ?? (lines.Count > 0 ? lines[0] : string.Empty);
        return picked.Length > 160 ? picked.Substring(0, 160) + "…" : picked;
    }

    /// <summary>
    /// Jupyter cells, code and notes alike; outputs are never read.
    /// Ports notebookCells (CodeExtractor.swift:152): nbformat 4 top-level
    /// cells, nbformat 3 worksheets' cells with code in "input".
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<string> NotebookCells(string json)
    {
        System.Text.Json.JsonDocument doc;
        try
        {
            doc = System.Text.Json.JsonDocument.Parse(json);
        }
        catch
        {
            throw ExtractError.Unreadable("not a notebook");
        }

        using (doc)
        {
            System.Text.Json.JsonElement cells;
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Object
                || (!doc.RootElement.TryGetProperty("cells", out cells)
                    && !TryWorksheetCells(doc.RootElement, out cells)))
            {
                throw ExtractError.Unreadable("not a notebook");
            }

            var result = new System.Collections.Generic.List<string>();
            if (cells.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                foreach (var cell in cells.EnumerateArray())
                {
                    result.Add(CellSource(cell));
                }
            }

            return result;
        }
    }

    private static bool TryWorksheetCells(System.Text.Json.JsonElement root, out System.Text.Json.JsonElement cells)
    {
        cells = default;
        if (root.TryGetProperty("worksheets", out var sheets)
            && sheets.ValueKind == System.Text.Json.JsonValueKind.Array
            && sheets.GetArrayLength() > 0
            && sheets[0].TryGetProperty("cells", out cells))
        {
            return true;
        }

        return false;
    }

    private static string CellSource(System.Text.Json.JsonElement cell)
    {
        System.Text.Json.JsonElement source;
        if (!cell.TryGetProperty("source", out source) && !cell.TryGetProperty("input", out source))
        {
            return string.Empty;
        }

        if (source.ValueKind == System.Text.Json.JsonValueKind.Array)
        {
            var sb = new System.Text.StringBuilder();
            foreach (var part in source.EnumerateArray())
            {
                if (part.ValueKind == System.Text.Json.JsonValueKind.String)
                {
                    sb.Append(part.GetString());
                }
            }

            return sb.ToString();
        }

        return source.ValueKind == System.Text.Json.JsonValueKind.String ? source.GetString() ?? string.Empty : string.Empty;
    }

    /// <summary>
    /// Whole cells to a stretch, up to <paramref name="size"/> chars; a longer
    /// cell is cut into line stretches pointing at it. Ports cells (CodeExtractor.swift:167).
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<CodePiece> Cells(
        System.Collections.Generic.IReadOnlyList<string> cells, int size = 1800)
    {
        var pieces = new System.Collections.Generic.List<CodePiece>();
        string text = string.Empty;
        int first = 0, last = 0;
        void Flush()
        {
            if (text.Length > 0)
            {
                pieces.Add(new CodePiece(text, first, last));
                text = string.Empty;
            }
        }

        for (int index = 0; index < cells.Count; index++)
        {
            string body = cells[index].Trim();
            if (body.Length == 0)
            {
                continue;
            }

            int number = index + 1;
            if (body.Length > size)
            {
                Flush();
                foreach (var piece in Lines(body, size))
                {
                    pieces.Add(new CodePiece(piece.Text, number, number));
                }

                continue;
            }

            if (text.Length > 0 && text.Length + 2 + body.Length > size)
            {
                Flush();
            }

            if (text.Length == 0)
            {
                first = number;
                text = body;
            }
            else
            {
                text += "\n\n" + body;
            }

            last = number;
        }

        Flush();
        return pieces;
    }

    /// <summary>
    /// The repo (or code project) path is in, and the file's title: its path
    /// from the repo folder with the repo name first ("billing/payments/retry.py");
    /// outside any repo, its last two components. Ports place (CodeExtractor.swift:201).
    /// </summary>
    public static (string? Repo, string Title) Place(string path)
    {
        string full = System.IO.Path.GetFullPath(path);
        string home = System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile);
        string? folder = System.IO.Path.GetDirectoryName(full);
        string? repo = null;
        while (!string.IsNullOrEmpty(folder) && folder.Length > 3
            && !folder.Equals(home, System.StringComparison.OrdinalIgnoreCase))
        {
            if (System.IO.Directory.Exists(System.IO.Path.Combine(folder, ".git"))
                || System.IO.File.Exists(System.IO.Path.Combine(folder, ".git"))
                || IsProjectRoot(folder))
            {
                repo = folder;
                break;
            }

            folder = System.IO.Path.GetDirectoryName(folder);
        }

        if (repo != null)
        {
            string? parent = System.IO.Path.GetDirectoryName(repo);
            string title = parent != null
                ? System.IO.Path.GetRelativePath(parent, full).Replace('\\', '/')
                : System.IO.Path.GetFileName(full);
            return (repo, title);
        }

        string[] parts = full.Split(System.IO.Path.DirectorySeparatorChar);
        return (null, parts.Length >= 2
            ? parts[^2] + "/" + parts[^1]
            : parts[^1]);
    }

    public static bool IsProjectRoot(string folder)
    {
        string[] entries;
        try
        {
            entries = System.IO.Directory.GetFileSystemEntries(folder);
        }
        catch
        {
            return false;
        }

        var names = new System.Collections.Generic.HashSet<string>(System.StringComparer.Ordinal);
        foreach (string entry in entries)
        {
            names.Add(System.IO.Path.GetFileName(entry));
        }

        foreach (string marker in RulesData.ProjectMarkers)
        {
            if (names.Contains(marker))
            {
                return true;
            }
        }

        foreach (string entry in entries)
        {
            string ext = System.IO.Path.GetExtension(entry).TrimStart('.').ToLowerInvariant();
            if (ext == "xcodeproj" || ext == "xcworkspace")
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Why code search does not enter a folder, or null. Ports
    /// codeSkipReason (Rules.swift:99): vendored/built folders, submodules
    /// and worktrees (.git is a file there).
    /// </summary>
    public static string? FolderSkipReason(string path)
    {
        string? dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
        while (!string.IsNullOrEmpty(dir))
        {
            string name = System.IO.Path.GetFileName(dir);
            if (RulesData.CodeSkippedFolderNames.Contains(name))
            {
                return "vendored or built code";
            }

            if (System.IO.File.Exists(System.IO.Path.Combine(dir, ".git")))
            {
                return "submodule or worktree";
            }

            string? parent = System.IO.Path.GetDirectoryName(dir.TrimEnd(System.IO.Path.DirectorySeparatorChar));
            if (string.IsNullOrEmpty(parent) || parent == dir)
            {
                break;
            }

            // Only the file's own folders up to the repo root matter; stop there.
            if (System.IO.Directory.Exists(System.IO.Path.Combine(dir, ".git")))
            {
                break;
            }

            dir = parent;
        }

        return null;
    }

    public static bool IsSecret(string fileName)
    {
        string lower = fileName.ToLowerInvariant();
        string ext = System.IO.Path.GetExtension(lower).TrimStart('.');
        string[] secretTypes = { "pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "kdbx", "gpg", "asc", "crt", "cer", "der", "p8", "mobileprovision" };
        if (secretTypes.Any(ext.Equals))
        {
            return true;
        }

        string[] secretNames = { "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", "secret", "credential", ".netrc", ".npmrc", ".pypirc", "htpasswd", ".htpasswd" };
        return secretNames.Any(lower.StartsWith);
    }

    /// <summary>
    /// What code search does with a file. Ports classifyCode (Rules.swift:68).
    /// </summary>
    public static (CodeDecision Decision, string? Reason) ClassifyCode(string path, IndexOptions options)
    {
        string name = System.IO.Path.GetFileName(path);
        string ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (options.ExcludedExtensions.Contains(ext))
        {
            return (CodeDecision.Skip, "excluded type");
        }

        if (IsSecret(name))
        {
            return (CodeDecision.Skip, "key or password file");
        }

        string lower = name.ToLowerInvariant();
        if (lower.EndsWith(".min.js") || lower.EndsWith(".min.mjs") || lower.EndsWith(".min.css"))
        {
            return (CodeDecision.Skip, "minified");
        }

        if (new[] { "license", "licence", "copying", "notice" }.Any(lower.StartsWith))
        {
            return (CodeDecision.Skip, "license");
        }

        if ((ext == "ts" || ext == "mts") && IsMpegTransportStream(path))
        {
            return (CodeDecision.Ignore, null); // a video
        }

        if (RulesData.SourceExtensions.Contains(ext) || RulesData.CodeTextExtensions.Contains(ext)
            || ext == "ipynb" || RulesData.CodeFileNames.Contains(name) || name.StartsWith("Dockerfile"))
        {
            return (CodeDecision.Index, null);
        }

        if (RulesData.CodeExtensions.Contains(ext))
        {
            return (CodeDecision.Skip, "data file");
        }

        return (CodeDecision.Ignore, null);
    }

    /// <summary>
    /// MPEG-TS packets start with 0x47 every 188 bytes (or every 192 with a
    /// 4-byte timecode). Ports isMPEGTransportStream (Rules.swift:130).
    /// </summary>
    public static bool IsMpegTransportStream(string path)
    {
        byte[] data;
        try
        {
            using var stream = System.IO.File.OpenRead(path);
            data = new byte[System.Math.Min(600, (int)System.Math.Min(stream.Length, 600))];
            int read = stream.Read(data, 0, data.Length);
            if (read < 400)
            {
                return false;
            }
        }
        catch
        {
            return false;
        }

        return (data[0] == 0x47 && data[188] == 0x47 && data[376] == 0x47)
            || (data[4] == 0x47 && data[196] == 0x47 && data[388] == 0x47);
    }

    /// <summary>"Swift", "Python", "Markdown": what an extension says a file is written in.</summary>
    public static string LanguageOf(string path)
    {
        string name = System.IO.Path.GetFileName(path);
        string ext = System.IO.Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        if (RulesData.Languages.TryGetValue(ext, out string? language))
        {
            return language;
        }

        if (RulesData.CodeFileNames.Contains(name) || name.StartsWith("Dockerfile"))
        {
            return name;
        }

        return ext.Length == 0 ? "Text" : ext.ToUpperInvariant();
    }

    // MARK: CodeLookup (CodeExtractor.swift:275-297, identifier/phrase)

    private static readonly System.Collections.Generic.HashSet<string> Definers = new(
        new[]
        {
            "def", "func", "fn", "fun", "function", "class", "struct", "enum", "protocol",
            "interface", "trait", "type", "typealias", "actor", "extension", "impl", "module",
            "namespace", "object", "record", "macro", "const", "let", "var", "val", "union",
            "mod", "sub", "@interface", "@implementation", "@protocol", "#define", "function*",
        },
        System.StringComparer.Ordinal);

    public static bool DefinesSomething(string word) =>
        Definers.Contains(word) && word != "let" && word != "var" && word != "const" && word != "val";

    /// <summary>
    /// Identifier words for exact name search ("quantize_row_q8_0_ref" →
    /// quantize row q8 0 ref, as one phrase). Ports identifier (CodeExtractor.swift:257).
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<string>? IdentifierWords(string query)
    {
        string name = query.Trim();
        if (name.EndsWith("()"))
        {
            name = name.Substring(0, name.Length - 2);
        }

        if (!System.Text.RegularExpressions.Regex.IsMatch(
                name, @"^[A-Za-z_$][A-Za-z0-9_$]*(?:(?:\.|::|->|#)[A-Za-z_$][A-Za-z0-9_$]*)*$"))
        {
            return null;
        }

        bool camel = name.Skip(1).Any(char.IsUpper) && name.Any(char.IsLower);
        if (!camel && !name.Any(c => c == '_' || c == '.' || c == ':' || c == '#' || c == '$' || char.IsDigit(c)))
        {
            return null;
        }

        var words = System.Text.RegularExpressions.Regex.Split(name.ToLowerInvariant(), @"[^a-z0-9]+")
            .Where(w => w.Length > 0).ToList();
        return words;
    }

    public static string Phrase(System.Collections.Generic.IReadOnlyList<string> words) =>
        "\"" + string.Join(" ", words) + "\"";
}

/// <summary>Classification tables ported from Rules.swift.</summary>
public static class RulesData
{
    public static readonly System.Collections.Generic.HashSet<string> SourceExtensions = new(
        new[]
        {
            "py", "pyi", "pyx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm",
            "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "go", "rs", "java",
            "kt", "kts", "scala", "groovy", "rb", "php", "cs", "fs", "sh", "bash", "zsh", "fish",
            "ps1", "lua", "pl", "pm", "r", "jl", "dart", "sql", "vue", "svelte", "astro", "html",
            "htm", "css", "scss", "sass", "less", "gradle", "cmake", "mk", "proto", "graphql", "gql",
            "tf", "hcl", "nix", "zig", "hs", "ex", "exs", "erl", "clj", "cljs", "elm", "ml", "mli",
            "vim", "el", "lisp", "asm", "s", "metal", "glsl", "hlsl", "wgsl", "cu", "cuh", "ino",
            "v", "sv", "tex",
        },
        System.StringComparer.OrdinalIgnoreCase);

    public static readonly System.Collections.Generic.HashSet<string> CodeTextExtensions = new(
        new[] { "md", "markdown", "rst", "adoc", "org", "txt", "yaml", "yml", "toml" },
        System.StringComparer.OrdinalIgnoreCase);

    public static readonly System.Collections.Generic.HashSet<string> CodeExtensions = new(
        new[]
        {
            "py", "ipynb", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "swift", "tsx",
            "cts", "js", "jsx", "mjs", "cjs", "go", "rs", "java", "kt", "kts", "scala", "rb", "php",
            "cs", "fs", "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "r", "jl", "dart", "sql",
            "vue", "svelte", "css", "scss", "sass", "less", "json", "jsonl", "yaml", "yml", "toml",
            "xml", "plist", "gradle", "cmake", "mk", "lock", "log", "csv", "tsv", "ini", "cfg", "conf",
            "proto", "graphql", "tf", "nix", "zig", "hs", "ex", "exs", "erl", "clj", "elm", "ml",
            "vim", "el", "asm", "metal", "glsl", "hlsl", "wgsl", "cu", "pyi", "pyc",
        },
        System.StringComparer.OrdinalIgnoreCase);

    public static readonly System.Collections.Generic.HashSet<string> CodeFileNames = new(
        new[]
        {
            "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile",
            "justfile", "Rakefile", "Gemfile", "Podfile", "Brewfile", "Procfile", "Vagrantfile",
            "Jenkinsfile",
        },
        System.StringComparer.Ordinal);

    public static readonly System.Collections.Generic.HashSet<string> CodeSkippedFolderNames = new(
        new[]
        {
            "vendor", "Vendor", "vendored", "third_party", "third-party", "thirdparty", "3rdparty",
            "external", "extern", "deps", "build", "Build", "dist", "out", "target", "obj",
            "coverage", "htmlcov", "generated", "__generated__", "wandb", "mlruns", "lightning_logs",
        },
        System.StringComparer.Ordinal);

    public static readonly string[] ProjectMarkers =
    {
        ".git", "package.json", "Package.swift", "pyproject.toml", "setup.py", "requirements.txt",
        "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "Gemfile",
        "composer.json", "CMakeLists.txt",
    };

    public static readonly System.Collections.Generic.HashSet<string> Closers = new(
        new[] { "end", "fi", "done", "esac", "@end", "#endif", "end;", "end)" },
        System.StringComparer.Ordinal);

    public static readonly System.Collections.Generic.Dictionary<string, string> Languages =
        new(System.StringComparer.OrdinalIgnoreCase)
        {
            ["py"] = "Python", ["pyi"] = "Python", ["pyx"] = "Cython", ["ipynb"] = "Notebook",
            ["c"] = "C", ["h"] = "C header", ["cc"] = "C++", ["cpp"] = "C++", ["cxx"] = "C++",
            ["hpp"] = "C++ header", ["hh"] = "C++ header", ["hxx"] = "C++ header",
            ["m"] = "Objective-C", ["mm"] = "Objective-C++", ["swift"] = "Swift",
            ["ts"] = "TypeScript", ["tsx"] = "TypeScript", ["mts"] = "TypeScript", ["cts"] = "TypeScript",
            ["js"] = "JavaScript", ["jsx"] = "JavaScript", ["mjs"] = "JavaScript", ["cjs"] = "JavaScript",
            ["go"] = "Go", ["rs"] = "Rust", ["java"] = "Java", ["kt"] = "Kotlin", ["kts"] = "Kotlin",
            ["scala"] = "Scala", ["groovy"] = "Groovy", ["rb"] = "Ruby", ["php"] = "PHP",
            ["cs"] = "C#", ["fs"] = "F#", ["sh"] = "Shell", ["bash"] = "Shell", ["zsh"] = "Shell",
            ["fish"] = "Shell", ["ps1"] = "PowerShell", ["lua"] = "Lua", ["pl"] = "Perl",
            ["pm"] = "Perl", ["r"] = "R", ["jl"] = "Julia", ["dart"] = "Dart", ["sql"] = "SQL",
            ["vue"] = "Vue", ["svelte"] = "Svelte", ["astro"] = "Astro", ["html"] = "HTML",
            ["htm"] = "HTML", ["css"] = "CSS", ["scss"] = "SCSS", ["sass"] = "Sass", ["less"] = "Less",
            ["gradle"] = "Gradle", ["cmake"] = "CMake", ["mk"] = "Makefile", ["proto"] = "Protocol Buffers",
            ["graphql"] = "GraphQL", ["gql"] = "GraphQL", ["tf"] = "Terraform", ["hcl"] = "HCL",
            ["nix"] = "Nix", ["zig"] = "Zig", ["hs"] = "Haskell", ["ex"] = "Elixir", ["exs"] = "Elixir",
            ["erl"] = "Erlang", ["clj"] = "Clojure", ["cljs"] = "ClojureScript", ["elm"] = "Elm",
            ["ml"] = "OCaml", ["mli"] = "OCaml", ["vim"] = "Vim script", ["el"] = "Emacs Lisp",
            ["lisp"] = "Lisp", ["asm"] = "Assembly", ["s"] = "Assembly", ["metal"] = "Metal",
            ["glsl"] = "GLSL", ["hlsl"] = "HLSL", ["wgsl"] = "WGSL", ["cu"] = "CUDA", ["cuh"] = "CUDA",
            ["ino"] = "Arduino", ["v"] = "Verilog", ["sv"] = "SystemVerilog", ["tex"] = "LaTeX",
            ["md"] = "Markdown", ["markdown"] = "Markdown", ["rst"] = "reStructuredText",
            ["adoc"] = "AsciiDoc", ["org"] = "Org", ["txt"] = "Text", ["yaml"] = "YAML",
            ["yml"] = "YAML", ["toml"] = "TOML",
        };
}

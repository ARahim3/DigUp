// digup: search your files by meaning (Windows CLI).
// Every command works on an explicit index folder, so tests never touch the real one.
// Engine: DigUp.Core (crawl, SQLite index, search) + digup-embed.exe (EmbeddingGemma 2).
// Meaning search needs digup-embed.exe + model files; without them, search still
// answers from exact words and says so.

using System.Text.Json;
using DigUp.Core;

internal static class Program
{
    private const string Usage = """
        digup: search your files by meaning (DigUp Windows CLI)

          digup estimate <folder>... [--json]     what would be indexed, and how long the first pass takes
          digup index <folder>... [--limit N]     sync the index with these folders, embed what's new
          digup search <words>... [-n 10] [--json]
          digup status                            what's in the index
          digup eval <queries.json> [-n 10]       recall of known answers

        Options:
          --index DIR          index folder (default: %LocalAppData%\DigUp\index.noindex)
          --limit N            stop after N files (index only)
          --workers N          model helpers at once, 1-4 (default: 2)
          -n N                 how many hits to show (default: 10)
          --kind K,K           screenshot, image, pdf, doc, audio, video
          --json               machine-readable output

        The model: EmbeddingGemma 2 in digup-embed.exe (next to this exe), models from %DIGUP_MODELS%,
        else %LocalAppData%\DigUp\Models. Build it with windows\scripts\build-llama-windows.ps1.
        Without it, index stores words only and search says "words only".
        """;

    private static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help" or "help")
        {
            Console.WriteLine(Usage);
            return 0;
        }

        string command = args[0];
        string indexDir = DefaultIndexDir();
        var rest = new List<string>();
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--index" && i + 1 < args.Length) { indexDir = args[++i]; }
            else { rest.Add(args[i]); }
        }

        try
        {
            switch (command)
            {
                case "estimate": return Estimate(rest);
                case "index": return Index(rest, indexDir);
                case "search": return Search(rest, indexDir);
                case "status": return Status(indexDir);
                case "eval": return Eval(rest, indexDir);
                default: Console.WriteLine(Usage); return 2;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    private static string DefaultIndexDir() =>
        Environment.GetEnvironmentVariable("DIGUP_INDEX") is { Length: > 0 } chosen
            ? chosen
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DigUp", "index.noindex");

    private static string EmbedExe() =>
        Path.Combine(AppContext.BaseDirectory, "digup-embed.exe");

    private static bool JsonFlag(List<string> rest) =>
        rest.Any(a => a == "--json");

    // What would be read, from file info only (no file is opened). Same skip
    // rules as indexing, so the number matches the first pass.
    private static int Estimate(List<string> rest, bool json = false)
    {
        var folders = rest.Where(a => !a.StartsWith('-') && !IsValueOf(a, rest)).ToList();
        if (folders.Count == 0) throw new InvalidOperationException("which folders? e.g. digup estimate %USERPROFILE%\\Documents");
        foreach (var f in folders)
            if (!Directory.Exists(f) && !File.Exists(f)) throw new InvalidOperationException($"not a folder: {f}");

        var options = new IndexOptions { Code = rest.Contains("--code") };
        var result = Crawler.CrawlDetailed(folders, options);
        var estimate = Estimator.Estimate(result.Candidates, options);
        bool asJson = rest.Any(a => a == "--json");

        if (asJson)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                files = result.Candidates.Count,
                seconds = Math.Round(estimate.Seconds, 1),
                byKind = estimate.Files,
                skipped = result.Skipped,
            }));
            return 0;
        }

        Console.WriteLine($"{result.Candidates.Count} files, about {FriendlyTime(estimate.Seconds)} for the first pass.");
        foreach (var (kind, n) in estimate.Files.OrderByDescending(kv => kv.Value))
            Console.WriteLine($"  {kind,-10} {n,6}");
        if (result.Skipped.Count > 0)
        {
            Console.WriteLine("skipped:");
            foreach (var (why, n) in result.Skipped.OrderByDescending(kv => kv.Value).Take(8))
                Console.WriteLine($"  {n,6}  {why}");
        }
        return 0;
    }

    // Sync the file list, then extract + embed what's new. The model lives in
    // digup-embed.exe so its memory goes back to Windows when it quits.
    private static int Index(List<string> rest, string indexDir)
    {
        var folders = rest.Where(a => !a.StartsWith('-') && !IsValueOf(a, rest)).ToList();
        int? limit = null;
        int workers = 1; // one helper per GPU; more contend (measured 9.7 vs 5.4 files/s)
        for (int i = 0; i < rest.Count; i++)
        {
            if (rest[i] == "--limit" && i + 1 < rest.Count && int.TryParse(rest[i + 1], out int n)) limit = n;
            if (rest[i] == "--workers" && i + 1 < rest.Count && int.TryParse(rest[i + 1], out int w)) workers = Math.Clamp(w, 1, 4);
        }
        if (folders.Count == 0) throw new InvalidOperationException("which folders? e.g. digup index %USERPROFILE%\\Documents");
        foreach (var f in folders)
            if (!Directory.Exists(f) && !File.Exists(f)) throw new InvalidOperationException($"not a folder: {f}");
        Directory.CreateDirectory(indexDir);

        var options = new IndexOptions { Code = rest.Contains("--code") };
        using var store = options.Code ? new IndexStore(indexDir, IndexStore.CodeFile) : new IndexStore(indexDir);
        using var indexer = MakeIndexer(store, options, workers);
        var sync = indexer.Sync(folders);
        Console.WriteLine($"sync: +{sync.Added} ~{sync.Changed} ={sync.Unchanged} moved:{sync.Moved} -{sync.Removed}");
        // Leftover pending files (a stopped run) still need reading.
        if (sync.Queued.Count == 0 && store.PendingCount() == 0) { Console.WriteLine("nothing new to read."); return 0; }

        var states = indexer.Run(limit, onEvent: e =>
            Console.WriteLine($"[{e.Done}/{e.Total}] {e.State,-8} {e.Path}"));
        indexer.FinishLongFiles(onStep: s =>
            Console.WriteLine($"[long {s.Done}/{s.Total}] {s.State,-8} {s.Path}"));
        indexer.CloseWorker();
        foreach (var (state, n) in states.OrderByDescending(kv => kv.Value))
            Console.WriteLine($"  {state,-10} {n,6}");
        int total = states.Values.Sum();
        Console.WriteLine($"read+decode {indexer.ExtractMs / 1000.0:0.0} s CPU, " +
            $"model+store {indexer.CommitMs / 1000.0:0.0} s ({total / Math.Max(0.001, indexer.CommitMs / 1000.0):0.0} files/s).");
        return 0;
    }

    // Words first (always works), meaning added when the model answers.
    private static int Search(List<string> rest, string indexDir)
    {
        int n = 10;
        HashSet<FileKind>? kinds = null;
        for (int i = 0; i < rest.Count; i++)
        {
            if (rest[i] == "-n" && i + 1 < rest.Count && int.TryParse(rest[i + 1], out int m)) n = Math.Clamp(m, 1, 100);
            if (rest[i] == "--kind" && i + 1 < rest.Count) kinds = ParseKinds(rest[i + 1]);
        }
        string query = string.Join(' ', rest.Where(a => !a.StartsWith('-') && !IsValueOf(a, rest)));
        if (query.Length == 0) throw new InvalidOperationException("search for what?");
        if (!File.Exists(Path.Combine(indexDir, IndexStore.MainFile)))
            throw new InvalidOperationException($"no index at {indexDir} (run digup index first)");

        bool asJson = JsonFlag(rest);
        bool codeOnly = CodeQuery.TextOf(query) is not null;
        using var store = codeOnly ? new IndexStore(indexDir, IndexStore.CodeFile) : new IndexStore(indexDir);
        using var searcher = new Searcher(store, loadVectors: false);

        // Meaning: embed the query with the text-only model. Empty when the
        // helper or files are missing; search then uses words only.
        IReadOnlyList<float>? vec = TryEmbedQuery(query, codeOnly, indexDir);
        var hits = searcher.Search(query, vec, kinds, limit: n);

        if (asJson)
        {
            Console.WriteLine(JsonSerializer.Serialize(hits.Select(h => new
            {
                path = h.Path, kind = h.Kind.ToString(), score = Math.Round(h.Score, 4),
                segment = h.Segment.ToString(), loc = h.Loc, locEnd = h.LocEnd, excerpt = h.Excerpt,
            })));
            return 0;
        }

        if (vec is null) Console.WriteLine("(words only: model not ready, see digup status)");
        if (hits.Count == 0) { Console.WriteLine("no match."); return 0; }
        foreach (var h in hits)
        {
            string where = h.Loc is null ? "" : h.Segment is SegmentKind.Lines or SegmentKind.Cells
                ? $" lines {TrimNum(h.Loc)}-{TrimNum(h.LocEnd)}" : $" @{TrimNum(h.Loc)}";
            Console.WriteLine($"{h.Path}{where}");
            if (!string.IsNullOrWhiteSpace(h.Excerpt)) Console.WriteLine($"  {h.Excerpt!.Trim().Replace('\n', ' ')}");
        }
        return 0;
    }

    private static int Status(string indexDir)
    {
        Console.WriteLine($"index: {indexDir}");
        string main = Path.Combine(indexDir, IndexStore.MainFile);
        if (!File.Exists(main)) { Console.WriteLine("vectors: none yet (run digup index first)"); return 0; }
        using var store = new IndexStore(indexDir);
        var counts = store.Counts();
        Console.WriteLine($"segments: {counts.Segments}, vectors: {counts.Vectors}, unfinished: {counts.Unfinished}");
        foreach (var (kind, byState) in counts.ByKindAndState.OrderBy(kv => kv.Key))
            Console.WriteLine($"  {kind,-10} " + string.Join(" ", byState.Select(kv => $"{kv.Key}:{kv.Value}")));
        string? src = store.Meta("vector_source");
        Console.WriteLine($"vectors from: {src ?? "(none yet)"}");
        Console.WriteLine(File.Exists(EmbedExe())
            ? $"model helper: {EmbedExe()}"
            : $"model helper: missing ({EmbedExe()} not built; see windows\\scripts\\build-llama-windows.ps1)");
        return 0;
    }

    // Recall of known answers. Meaning needs the model; without it the score
    // is words-only and the report says so.
    private static int Eval(List<string> rest, string indexDir)
    {
        string? file = rest.FirstOrDefault(a => !a.StartsWith('-') && !IsValueOf(a, rest));
        if (file is null) throw new InvalidOperationException("which eval file?");
        if (!File.Exists(file)) throw new InvalidOperationException($"not a file: {file}");
        int n = 10;
        for (int i = 0; i < rest.Count; i++)
            if (rest[i] == "-n" && i + 1 < rest.Count && int.TryParse(rest[i + 1], out int m)) n = m;

        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        var queries = doc.RootElement.GetProperty("queries").EnumerateArray().ToList();
        using var main = new IndexStore(indexDir);
        using var mainSearcher = new Searcher(main, loadVectors: false);
        using var code = new IndexStore(indexDir, IndexStore.CodeFile);
        using var codeSearcher = new Searcher(code, loadVectors: false);
        int top1 = 0, top5 = 0;
        foreach (var q in queries)
        {
            string text = q.GetProperty("q").GetString() ?? "";
            var expect = q.GetProperty("expect").EnumerateArray().Select(e => e.GetString() ?? "").ToList();
            bool isCode = CodeQuery.TextOf(text) is not null;
            var searcher = isCode ? codeSearcher : mainSearcher;
            IReadOnlyList<float>? vec = TryEmbedQuery(text, isCode, indexDir, quiet: true);
            var hits = searcher.Search(text, vec, limit: n).Select(h => h.Path.Replace('\\', '/')).ToList();
            int rank = hits.FindIndex(p => expect.Any(e => p.EndsWith(e.Split('@')[0], StringComparison.OrdinalIgnoreCase)));
            if (rank == 0) top1++;
            if (rank is >= 0 and < 5) top5++;
            Console.WriteLine($"[{(rank < 0 ? "-" : (rank + 1).ToString())}] {text}");
        }
        Console.WriteLine($"top1 {top1}/{queries.Count}, top5 {top5}/{queries.Count}" +
            (AnyModelReady() ? "" : " (words only: model not ready)"));
        return 0;
    }

    // ---- helpers ----

    private static Indexer MakeIndexer(IndexStore store, IndexOptions options, int workers)
    {
        var crawler = new Crawler();
        var extractor = new DefaultExtractor(options,
            new GdiImageDecoder(), new WindowsOcrEngineStub(),
            new PdfiumEngine(FindPdfium()), FindFFmpeg(), null);
        var indexer = new Indexer(store, options, crawler, () => MakeEmbedderFor(store.Directory), extractor);
        // A words-only index adopts a words-only fingerprint; when the real
        // model arrives the index is embedded again (vectors can't be mixed).
        indexer.ResetOnModelChange = (oldPrint, newPrint) =>
            Console.WriteLine($"re-indexing with new vectors (was: {FirstLine(oldPrint)})");
        indexer.WorkerCount = workers;
        return indexer;
    }

    // Words only: no model yet. Text is stored for exact-word search; meaning
    // vectors are empty and the file keeps a note. The fingerprint is
    // words-only, so the first run with the model embeds everything again.
    private sealed class WordsOnlyEmbedder : IEmbedder
    {
        public WorkerInfo Info { get; } = new("none", "words-only", "words-only", "none", 0, true, null);
        public float[][] EmbedTexts(IReadOnlyList<string> texts)
        {
            // Zero vectors: meaning search ignores them (they score 0), words
            // still work. The words-only fingerprint makes the first model run
            // embed everything again, so these never mix with real vectors.
            var rows = new float[texts.Count][];
            for (int i = 0; i < rows.Length; i++) rows[i] = new float[Vectors.Dimension];
            return rows;
        }
        public Embedding[] EmbedImages(IReadOnlyList<string> paths, int budget)
        {
            var rows = new Embedding[paths.Count];
            for (int i = 0; i < rows.Length; i++) rows[i] = new Embedding(null, "words only (model not built)");
            return rows;
        }
        public Embedding[] EmbedAudio(IReadOnlyList<string> paths)
        {
            var rows = new Embedding[paths.Count];
            for (int i = 0; i < rows.Length; i++) rows[i] = new Embedding(null, "words only (model not built)");
            return rows;
        }
        public void Close() { }
        public void Dispose() { }
    }

    private static IEmbedder MakeEmbedderFor(string indexDir)
    {
        string exe = EmbedExe();
        if (!File.Exists(exe))
        {
            Console.WriteLine($"(words only: {exe} is not built yet; see windows\\scripts\\build-llama-windows.ps1)");
            return new WordsOnlyEmbedder();
        }
        return new WorkerClient(new WorkerConfig(exe, [], LogPath: Path.Combine(indexDir, "worker.log")));
    }

    // Null when the helper or model files are missing (caller falls back to words).
    private static IReadOnlyList<float>? TryEmbedQuery(string query, bool code, string indexDir, bool quiet = false)
    {
        try
        {
            string exe = EmbedExe();
            if (!File.Exists(exe)) return null;
            using IEmbedder w = new WorkerClient(new WorkerConfig(exe, [], TextOnly: true,
                LogPath: Path.Combine(indexDir, "worker.log")));
            string prompted = code ? Prompts.CodeQuery(query) : Prompts.Query(query);
            var rows = w.EmbedTexts([prompted]);
            if (rows.Length == 0 || rows[0].Length != Vectors.Dimension) return null;
            return rows[0];
        }
        catch (Exception ex)
        {
            if (!quiet) Console.Error.WriteLine($"(meaning off: {FirstLine(ex.Message)})");
            return null;
        }
    }

    private static bool AnyModelReady() => File.Exists(EmbedExe());

    private static FFmpegPaths FindFFmpeg()
    {
        // Test override only: DIGUP_FFMPEG points at a folder with ffmpeg.exe
        // + ffprobe.exe (your own install). The ship bundles its own copies
        // next to the exe; nothing here depends on what's on PATH.
        if (Environment.GetEnvironmentVariable("DIGUP_FFMPEG") is { Length: > 0 } dir)
            return new FFmpegPaths(Path.Combine(dir, "ffmpeg.exe"), Path.Combine(dir, "ffprobe.exe"));
        string app = AppContext.BaseDirectory;
        return new FFmpegPaths(Path.Combine(app, "ffmpeg.exe"), Path.Combine(app, "ffprobe.exe"));
    }

    private static string FindPdfium() =>
        Path.Combine(AppContext.BaseDirectory, "pdfium.dll");

    private static HashSet<FileKind>? ParseKinds(string csv)
    {
        var set = new HashSet<FileKind>();
        foreach (string k in csv.Split(',', StringSplitOptions.RemoveEmptyEntries))
            if (Enum.TryParse<FileKind>(k.Trim(), ignoreCase: true, out var v)) set.Add(v);
        return set.Count == 0 ? null : set;
    }

    private static bool IsValueOf(string a, List<string> rest)
    {
        int i = rest.IndexOf(a);
        return i > 0 && (rest[i - 1] == "-n" || rest[i - 1] == "--kind" || rest[i - 1] == "--limit" ||
            rest[i - 1] == "--index" || rest[i - 1] == "--workers");
    }

    private static string FirstLine(string s) => s.Split('\n')[0].Trim();

    private static string TrimNum(double? d) => d is null ? "" : d.Value.ToString("0.##");

    private static string FriendlyTime(double seconds)
    {
        if (seconds < 60) return $"{seconds:0} s";
        if (seconds < 3600) return $"{seconds / 60:0} min";
        return $"{seconds / 3600:0.0} h";
    }
}

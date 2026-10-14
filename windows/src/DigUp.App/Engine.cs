// Engine: owns the Core pieces (stores, searchers, indexer) on background
// threads. The UI thread never embeds and never touches SQLite: Search()
// marshals a copy back. Indexing pauses in battery saver and when asked.
// First run: EnsureModelsAsync fetches EmbeddingGemma 2 once (865 MB,
// resumable, hash-checked) while the UI shows progress.

using System.IO;
using DigUp.Core;

namespace DigUp.App;

public sealed class Engine : IDisposable
{
    private readonly Settings _settings;
    private readonly IndexOptions _options = new();
    private readonly IndexOptions _codeOptions = new() { Code = true };
    private IndexStore? _store;
    private Searcher? _searcher;
    private IndexStore? _codeStore;
    private Searcher? _codeSearcher;
    private CancellationTokenSource? _run;
    private int _wanted; // indexing requested while one is running
    private bool _paused;
    private bool _disposed;
    // Keystroke searches read the searchers while a finished indexing pass
    // swaps them: the swap waits for running searches instead of freeing
    // a searcher one is inside.
    private readonly object _searchGate = new();
    // One query worker for all keystrokes: starting a helper per keystroke
    // costs ~2 s of model load each time (measured 1859 ms spawn+load vs
    // 15 ms on a warm one). It lives until pause, model change, or quit.
    private IEmbedder? _queryWorker;
    private readonly object _queryGate = new();

    public string Status { get; private set; } = "starting…";
    public event Action? Changed;

    public Engine(Settings settings) { _settings = settings; }

    public void Start() => RequestIndex();

    public void SetPaused(bool paused)
    {
        _paused = paused;
        Status = paused ? "paused" : "running…";
        Changed?.Invoke();
        // Paused means quiet: the query helper's GPU memory goes back too.
        if (paused) DropQueryWorker();
        else RequestIndex();
    }

    /// <summary>Settings window saved: pick up folders/code without a restart.</summary>
    public void ApplySettings() => RequestIndex();

    public bool ModelsReady => ModelFiles.Missing(ModelFiles.InstalledDirectory).Count == 0;

    public void RequestIndex() => Task.Run(() => IndexPass());

    private void IndexPass()
    {
        if (_disposed || _paused) return;
        if (Interlocked.Exchange(ref _wanted, 0) == 0 && _run is not null) { _wanted = 1; return; }
        _run = new CancellationTokenSource();
        try
        {
            if (OnBatterySaver()) { Say("waiting for power…"); return; }
            if (!_settings.SetupDone) { Say("finish the one-time setup first (tray menu → Open search)."); return; }
            if (_settings.Folders.Count == 0) { Say("pick folders to search (tray menu → Settings)."); return; }
            if (!ModelsReady)
            {
                Say("getting the model… (once, 865 MB)");
                EnsureModelsAsync(null, _run.Token).GetAwaiter().GetResult();
            }
            OpenStores();
            Say("looking through your folders… (first time takes a while)");
            IndexOne(_store!, _options, "main");
            if (_settings.Code) IndexOne(_codeStore!, _codeOptions, "code");
            RefreshSearchers();
            var counts = _store!.Counts();
            if (_codeStore is not null)
            {
                // Code lives in its own index: count it too, or the status
                // line pretends thousands of indexed files don't exist.
                var code = _codeStore.Counts();
                Say($"{counts.Segments + code.Segments} pieces, " +
                    $"{counts.Vectors + code.Vectors} vectors (code {code.Vectors}). Type to search.");
            }
            else
            {
                Say($"{counts.Segments} pieces, {counts.Vectors} vectors. Type to search.");
            }
            WarmQueryWorker(); // still on the background thread: first keystroke is instant
        }
        catch (OperationCanceledException) { Say("paused"); }
        catch (Exception ex) { ErrorLog.Write("index: " + ex); Say($"indexer stopped: {FirstLine(ex.Message)}"); }
        finally { _run = null; if (Interlocked.CompareExchange(ref _wanted, 0, 0) == 1) RequestIndex(); }
    }

    private void IndexOne(IndexStore store, IndexOptions options, string _)
    {
        using var indexer = MakeIndexer(store, options);
        var sync = indexer.Sync(_settings.Folders);
        Say($"reading {sync.Queued.Count} new files…");
        indexer.Run(shouldStop: () => _paused || _run!.IsCancellationRequested,
            onEvent: e => Say($"[{e.Done}/{e.Total}] {e.State} {Short(e.Path)}"));
        indexer.FinishLongFiles(shouldStop: () => _paused || _run!.IsCancellationRequested);
        indexer.CloseWorker();
    }

    /// <summary>Fetch missing model files with progress (0..1 per file).
    /// Copies from the Hugging Face cache when it's there; downloads with
    /// resume + hash check otherwise. Throws with a plain message on failure.</summary>
    public async Task EnsureModelsAsync(IProgress<(string File, double Frac)>? progress, CancellationToken ct)
    {
        string dir = ModelFiles.InstalledDirectory;
        foreach (var file in ModelFiles.Missing(dir))
        {
            ct.ThrowIfCancellationRequested();
            Say($"getting {file.Name}…");
            string? cached = ModelFiles.CachedCopy(file);
            if (cached is not null)
            {
                File.Copy(cached, Path.Combine(dir, file.Name));
                if (ModelFiles.Sha256Of(Path.Combine(dir, file.Name)) != file.Sha256)
                {
                    File.Delete(Path.Combine(dir, file.Name));
                    throw new InvalidOperationException($"{file.Name} in the cache is broken; delete it and try again.");
                }
                progress?.Report((file.Name, 1));
                continue;
            }
            var one = new Progress<double>(f => progress?.Report((file.Name, f)));
            try { await ModelFiles.DownloadAsync(file, dir, one, ct).ConfigureAwait(false); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                throw new InvalidOperationException($"couldn't download {file.Name} ({FirstLine(ex.Message)}). Check the net and try again.");
            }
        }
    }

    public record Hit(string Path, string Kind, string Where, string? Excerpt, double Score);

    // Words always; meaning added when digup-embed.exe + model files answer.
    public List<Hit> Search(string query, int limit = 20)
    {
        query = TextSanitize.Clean(query);
        OpenStores();
        string? codeText = CodeQuery.TextOf(query);
        Searcher searcher;
        Searcher? codeSearcher;
        lock (_searchGate)
        {
            // Both searchers lazy: a search before the first indexing pass
            // still reaches code (the fallback below needs it). Loading
            // vectors waits for the first meaning search either way.
            if (_settings.Code && _codeStore is not null)
                codeSearcher = _codeSearcher ??= new Searcher(_codeStore, loadVectors: false);
            else
                codeSearcher = null;
            searcher = codeText is not null && codeSearcher is not null
                ? codeSearcher
                : (_searcher ??= new Searcher(_store!, loadVectors: false));
        }
        IReadOnlyList<float>? vec = TryEmbedQuery(query);
        var hits = searcher.Search(query, vec, limit: limit)
            .Select(h => new Hit(h.Path, h.Kind.ToString(), WhereOf(h), Clean(h.Excerpt), h.Score))
            .ToList();
        if (hits.Count == 0 && codeText is null && codeSearcher is not null)
        {
            // Nothing outside code: fall back to the code index, so a bare
            // query on a code folder doesn't come back empty without saying
            // why. (An explicit "code:" still searches code only.)
            hits = codeSearcher.Search(query, vec, limit: limit)
                .Select(h => new Hit(h.Path, h.Kind.ToString(), WhereOf(h), Clean(h.Excerpt), h.Score))
                .ToList();
        }
        return hits;
    }

    /// <summary>First-pass size for folders, off the UI thread.</summary>
    public static (int Files, double Seconds, Dictionary<FileKind, int> ByKind) Estimate(
        IEnumerable<string> folders, bool code)
    {
        var options = new IndexOptions { Code = code };
        var result = Crawler.CrawlDetailed(folders, options);
        var estimate = Estimator.Estimate(result.Candidates, options);
        return (result.Candidates.Count, estimate.Seconds, estimate.Files);
    }

    private void Say(string s) { Status = s; Changed?.Invoke(); }

    private void OpenStores()
    {
        if (_store is null)
        {
            Directory.CreateDirectory(Settings.IndexDir);
            _store = OpenIndex(Settings.IndexDir, IndexStore.MainFile);
        }
        if (_settings.Code && _codeStore is null)
            _codeStore = OpenIndex(Settings.IndexDir, IndexStore.CodeFile);
        if (!_settings.Code && _codeStore is not null)
        {
            lock (_searchGate)
            {
                _codeSearcher?.Dispose(); _codeSearcher = null;
            }
            _codeStore.Dispose(); _codeStore = null;
        }
    }

    /// <summary>Opens an index, starting over (loudly) when its file is
    /// corrupt: an index is rebuildable, a crash on launch is not.</summary>
    private IndexStore OpenIndex(string dir, string file)
    {
        try
        {
            return file == IndexStore.MainFile ? new IndexStore(dir) : new IndexStore(dir, file);
        }
        catch (Exception ex) when (IsCorrupt(ex))
        {
            string bad = Path.Combine(dir, file);
            string aside = bad + $".corrupt-{DateTime.Now:yyyyMMdd-HHmmss}";
            try { File.Move(bad, aside); } catch { }
            try { File.Delete(bad + "-wal"); } catch { }
            try { File.Delete(bad + "-shm"); } catch { }
            Say($"the index was broken, starting fresh (old one kept as {System.IO.Path.GetFileName(aside)}).");
            return file == IndexStore.MainFile ? new IndexStore(dir) : new IndexStore(dir, file);
        }
    }

    private static bool IsCorrupt(Exception ex)
    {
        string m = ex.Message.ToLowerInvariant();
        return m.Contains("not a database") || m.Contains("malformed") || m.Contains("corrupt");
    }

    private void RefreshSearchers()
    {
        lock (_searchGate)
        {
            _searcher?.Dispose();
            _searcher = new Searcher(_store!, loadVectors: false);
            if (_codeStore is not null)
            {
                _codeSearcher?.Dispose();
                _codeSearcher = new Searcher(_codeStore, loadVectors: false);
            }
        }
    }

    private Indexer MakeIndexer(IndexStore store, IndexOptions options)
    {
        var extractor = new DefaultExtractor(options,
            new GdiImageDecoder(), new WindowsOcrEngineStub(),
            new PdfiumEngine(ExeNextTo("pdfium.dll")), FindFFmpeg(), null);
        var indexer = new Indexer(store, options, new Crawler(), () => MakeEmbedder(store.Directory), extractor);
        // A new model means new vectors: the index rebuilds and the warm
        // query helper (old model) is dropped with it.
        indexer.ResetOnModelChange = (_, _) => DropQueryWorker();
        indexer.WorkerCount = 1; // measured fastest on one GPU (see Indexer)
        return indexer;
    }

    private IEmbedder MakeEmbedder(string indexDir)
    {
        string exe = ExeNextTo("digup-embed.exe");
        if (!File.Exists(exe)) return new WordsOnly();
        return new WorkerClient(new WorkerConfig(exe, [], LogPath: Path.Combine(Settings.Dir, "worker.log")));
    }

    private IReadOnlyList<float>? TryEmbedQuery(string query)
    {
        IEmbedder? worker;
        lock (_queryGate)
        {
            string exe = ExeNextTo("digup-embed.exe");
            if (!File.Exists(exe)) return null;
            if (_queryWorker is null)
            {
                // Creation loads the model (~2 s, once): failure here is
                // worth one log line; per-keystroke embed failures stay quiet
                // (the search simply goes words-only that once).
                try
                {
                    _queryWorker = new WorkerClient(new WorkerConfig(exe, [], TextOnly: true,
                        LogPath: Path.Combine(Settings.Dir, "worker.log")));
                }
                catch (Exception ex)
                {
                    ErrorLog.Write("query helper won't start: " + ex.Message);
                    _queryWorker = null;
                    return null;
                }
            }
            worker = _queryWorker;
        }
        try
        {
            string prompted = CodeQuery.TextOf(query) is not null ? Prompts.CodeQuery(query) : Prompts.Query(query);
            var rows = worker.EmbedTexts([prompted]);
            return rows.Length > 0 && rows[0].Length == Vectors.Dimension ? rows[0] : null;
        }
        catch
        {
            // A dead helper must not wedge every later keystroke: drop it,
            // this search goes words-only, the next keystroke starts fresh.
            DropQueryWorker();
            return null;
        }
    }

    /// <summary>Load the query helper now (background), so the first real
    /// keystroke embeds in milliseconds instead of seconds.</summary>
    private void WarmQueryWorker()
    {
        try
        {
            lock (_queryGate)
            {
                string exe = ExeNextTo("digup-embed.exe");
                if (!File.Exists(exe) || _queryWorker is not null) return;
                _queryWorker = new WorkerClient(new WorkerConfig(exe, [], TextOnly: true,
                    LogPath: Path.Combine(Settings.Dir, "worker.log")));
            }
            _queryWorker.EmbedTexts([Prompts.Query("warmup")]);
        }
        catch
        {
            DropQueryWorker();
        }
    }

    private void DropQueryWorker()
    {
        lock (_queryGate)
        {
            try { _queryWorker?.Close(); } catch { }
            try { _queryWorker?.Dispose(); } catch { }
            _queryWorker = null;
        }
    }

    private sealed class WordsOnly : IEmbedder
    {
        public WorkerInfo Info { get; } = new("none", "words-only", "words-only", "none", 0, true, null);
        public float[][] EmbedTexts(IReadOnlyList<string> texts)
        {
            var rows = new float[texts.Count][];
            for (int i = 0; i < rows.Length; i++) rows[i] = new float[Vectors.Dimension];
            return rows;
        }
        public Embedding[] EmbedImages(IReadOnlyList<string> paths, int budget)
            => paths.Select(_ => new Embedding(null, "words only")).ToArray();
        public Embedding[] EmbedAudio(IReadOnlyList<string> paths)
            => paths.Select(_ => new Embedding(null, "words only")).ToArray();
        public void Close() { }
        public void Dispose() { }
    }

    private static string ExeNextTo(string name) =>
        Path.Combine(AppContext.BaseDirectory, name);

    // Test override only (see CLI): the ship bundles its own FFmpeg.
    private static FFmpegPaths FindFFmpeg()
    {
        if (Environment.GetEnvironmentVariable("DIGUP_FFMPEG") is { Length: > 0 } dir)
            return new FFmpegPaths(Path.Combine(dir, "ffmpeg.exe"), Path.Combine(dir, "ffprobe.exe"));
        return new FFmpegPaths(ExeNextTo("ffmpeg.exe"), ExeNextTo("ffprobe.exe"));
    }

    private static bool OnBatterySaver()
    {
        try { return System.Windows.Forms.SystemInformation.PowerStatus.BatteryChargeStatus.HasFlag(BatteryChargeStatus.Critical); }
        catch { return false; }
    }

    private static string WhereOf(SearchHit h) =>
        h.Loc is null ? "" : h.Segment is SegmentKind.Lines or SegmentKind.Cells
            ? $"lines {Num(h.Loc)}-{Num(h.LocEnd)}" : $"@{Num(h.Loc)}";

    private static string Num(double? d) => d?.ToString("0.##") ?? "";
    private static string? Clean(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        string t = TextSanitize.Clean(s.Replace("«", "").Replace("»", "").Trim());
        return t.Length > 160 ? TextSanitize.Cut(t, 160) + "…" : t;
    }
    private static string Short(string p) => p.Length > 70 ? "…" + p[^69..] : p;
    private static string FirstLine(string s) => s.Split('\n')[0].Trim();

    public void Dispose()
    {
        _disposed = true;
        _run?.Cancel();
        DropQueryWorker();
        lock (_searchGate)
        {
            _searcher?.Dispose();
            _codeSearcher?.Dispose();
            _searcher = null;
            _codeSearcher = null;
        }
        _store?.Dispose();
        _codeStore?.Dispose();
    }
}

// Watches chosen folders. A change re-indexes after 5 quiet seconds; an
// overflow (buffer overrun) triggers a full rescan, never silent loss.
public sealed class FileSystemWatcherRunner : IDisposable
{
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly System.Timers.Timer _debounce = new(5000) { AutoReset = false };
    private readonly Action _onCalm;

    public FileSystemWatcherRunner(Settings settings, Action onCalm)
    {
        _onCalm = onCalm;
        _debounce.Elapsed += (_, _) => _onCalm();
        foreach (string folder in settings.Folders)
        {
            if (!Directory.Exists(folder)) continue;
            var w = new FileSystemWatcher(folder)
            {
                IncludeSubdirectories = true,
                InternalBufferSize = 64 * 1024,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.DirectoryName,
            };
            w.Changed += (_, _) => _debounce.Start();
            w.Created += (_, _) => _debounce.Start();
            w.Deleted += (_, _) => _debounce.Start();
            w.Renamed += (_, _) => _debounce.Start();
            w.Error += (_, _) => _onCalm(); // overflow: rescan everything
            w.EnableRaisingEvents = true;
            _watchers.Add(w);
        }
    }

    public void Dispose()
    {
        _debounce.Dispose();
        foreach (var w in _watchers) w.Dispose();
    }
}

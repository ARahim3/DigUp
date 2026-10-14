// Index orchestration: sync, first pass, and the long-file second pass.
// Ports Indexer (Indexer.swift) — the extract-ahead overlap, per-kind commit
// logic, batching, and fingerprint adoption. The crawler and SQLite store are
// separate ports; the minimal surfaces this class needs are declared here so
// they can be implemented against.
//
// Model work goes to an IEmbedder (made on first use, freed by CloseWorker).
// Extraction runs one batch ahead (see ExtractorRunner), so reading files and
// embedding them overlap.

namespace DigUp.Core;

public sealed class IndexerError : System.Exception
{
    private IndexerError(string message)
        : base(message)
    {
    }

    public static IndexerError FingerprintMismatch(string indexed, string now) =>
        new("this index was built with different settings or model:\n" +
            $"  index: {indexed}\n  now:   {now}\n" +
            "re-run with --reindex (vectors from different settings can't be compared)");
}

/// <summary>One crawl candidate. The crawler fills Device/Inode with stable
/// Windows file IDs (volume serial + file index) so moves are detected.</summary>
public sealed record CrawlCandidate(string Path, long Size, double Mtime, FileKind Kind, long Device = 0, long Inode = 0);

public sealed record CrawlReport(System.Collections.Generic.IReadOnlyList<CrawlCandidate> Candidates);

public interface ICrawler
{
    CrawlReport Crawl(System.Collections.Generic.IReadOnlyList<string> roots, IndexOptions options);
}

/// <summary>Minimal store surface the indexer needs (SQLite port implements this).</summary>
public interface IIndexerStore
{
    System.Collections.Generic.IReadOnlyList<FileRecord> FilesUnder(System.Collections.Generic.IReadOnlyList<string> roots);
    System.Collections.Generic.IReadOnlyList<FileRecord> Pending(int? limit, System.Collections.Generic.ISet<long>? only);
    System.Collections.Generic.IReadOnlyList<FileRecord> Unfinished();
    System.Collections.Generic.Dictionary<string, string?> InfoOf(long fileId);
    int? LastPlace(long fileId);
    long Insert(CrawlCandidate candidate);
    void Requeue(long id, CrawlCandidate asFile);
    void Move(long id, string toPath);
    void Delete(long id);
    void Finish(long id, string state, string? detail = null, System.Collections.Generic.Dictionary<string, string?>? info = null);
    int BumpAttempts(long id);
    void AddSegment(long fileId, SegmentKind kind, Modality modality, double? loc = null, double? locEnd = null, string? excerpt = null, string? text = null, float[]? vector = null);
    string? GetMeta(string key);
    void SetMeta(string key, string value);
    /// <summary>Removes every file that isn't under one of <paramref name="roots"/>.
    /// Returns how many went.</summary>
    int Prune(System.Collections.Generic.IReadOnlyList<string> roots);
    void ResetAll();
    int PendingCount();
    int UnfinishedFiles();
    void Transact(System.Action action);
}

/// <summary>Keeps the index in step with the chosen folders, then extracts and embeds whatever is pending.</summary>
public sealed class Indexer : System.IDisposable
{
    public sealed class SyncSummary
    {
        public int Added { get; set; }
        public int Changed { get; set; }
        public int Moved { get; set; }
        public int Removed { get; set; }
        public int Unchanged { get; set; }
        public CrawlReport Crawl { get; set; } = new CrawlReport(System.Array.Empty<CrawlCandidate>());

        /// <summary>Files this sync queued for embedding, so a watcher can index exactly those first.</summary>
        public System.Collections.Generic.List<long> Queued { get; } = new();
    }

    public sealed record Event(int Done, int Total, string Path, FileKind Kind, string State, double Seconds, string? Note);

    /// <summary>One step of the long-file pass. (Indexer.swift:156)</summary>
    public sealed record Step(int Done, int Total, int Files, string Path, FileKind Kind, string State, double Seconds, string? Note);

    private readonly IIndexerStore _store;
    private readonly IndexOptions _options;
    private readonly ICrawler _crawler;
    private readonly System.Func<IEmbedder> _makeEmbedder;
    private readonly ExtractorRunner _runner;
    private readonly string _scratch;
    private bool _disposed;

    /// <summary>
    /// When set, an index built with another model or settings is emptied and
    /// embedded again, and this hears about it. When null, indexing stops with
    /// a fingerprint mismatch. (Indexer.swift:45)
    /// </summary>
    public System.Action<string, string>? ResetOnModelChange { get; set; }

    /// <summary>
    /// The vector source of the embedders <paramref name="makeEmbedder"/>
    /// makes, when known without starting one; then CheckModel notices a new
    /// model before anything needs embedding. (Indexer.swift:50)
    /// </summary>
    public string? EmbedderSource { get; set; }

    public Indexer(
        IIndexerStore store,
        IndexOptions options,
        ICrawler crawler,
        System.Func<IEmbedder> makeEmbedder,
        IExtractor extractor)
    {
        _store = store;
        _options = options;
        _crawler = crawler;
        _makeEmbedder = makeEmbedder;
        _scratch = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            $"DigUp-{System.Diagnostics.Process.GetCurrentProcess().Id}",
            System.Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(_scratch);
        _runner = new ExtractorRunner(extractor, _scratch);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Finish();
    }

    /// <summary>Frees the embedding models until the next file needs them.</summary>
    public void CloseWorker()
    {
        lock (_workerGate)
        {
            foreach (var w in _workers) { try { w.Close(); } catch { } try { w.Dispose(); } catch { } }
            _workers.Clear();
            _nextWorker = 0;
        }
    }

    /// <summary>Stops the worker and removes the scratch folder, for a process about to exit.</summary>
    public void Finish()
    {
        CloseWorker();
        ExtractorRunner.DeleteQuiet(_scratch);
    }

    public bool WorkerIsRunning { get { lock (_workerGate) return _workers.Count > 0; } }

    /// <summary>
    /// Scratch folders (DigUp-pid) of indexing processes that are gone
    /// (killed mid-batch). The host calls this at startup.
    /// </summary>
    public static void RemoveStaleScratchFolders()
    {
        string temp = System.IO.Path.GetTempPath();
        string[] names;
        try
        {
            names = System.IO.Directory.GetDirectories(temp, "DigUp-*");
        }
        catch
        {
            return;
        }

        int self = System.Diagnostics.Process.GetCurrentProcess().Id;
        foreach (string dir in names)
        {
            string name = System.IO.Path.GetFileName(dir);
            if (!int.TryParse(name.Substring("DigUp-".Length), out int pid) || pid == self)
            {
                continue;
            }

            try
            {
                System.Diagnostics.Process.GetProcessById(pid);
            }
            catch (System.ArgumentException)
            {
                ExtractorRunner.DeleteQuiet(dir);
            }
            catch
            {
                // Cannot tell; leave it.
            }
        }
    }

    // MARK: Sync

    /// <summary>
    /// Crawls roots and reconciles the index: new files queued, changed ones
    /// re-queued, moved ones re-pathed (no re-embedding), gone or newly
    /// excluded files removed. Ports sync (Indexer.swift:86).
    /// </summary>
    public SyncSummary Sync(System.Collections.Generic.IReadOnlyList<string> roots)
    {
        var crawl = _crawler.Crawl(roots, _options);
        var existing = _store.FilesUnder(roots);
        // The store keeps forward-slash paths (IndexStore.NormalizePath) while
        // the crawler yields native backslash paths: compare normalized.
        var byPath = new System.Collections.Generic.Dictionary<string, FileRecord>(System.StringComparer.OrdinalIgnoreCase);
        var byInode = new System.Collections.Generic.Dictionary<string, FileRecord>();
        foreach (var file in existing)
        {
            byPath[IndexStore.NormalizePath(file.Path)] = file;
            byInode[$"{file.Device}:{file.Inode}"] = file;
        }

        var seen = new System.Collections.Generic.HashSet<string>(
            System.Linq.Enumerable.Select(crawl.Candidates, c => IndexStore.NormalizePath(c.Path)),
            System.StringComparer.OrdinalIgnoreCase);
        var movedFrom = new System.Collections.Generic.HashSet<string>(System.StringComparer.OrdinalIgnoreCase);
        var summary = new SyncSummary { Crawl = crawl };
        _store.Transact(() =>
        {
            foreach (var file in crawl.Candidates)
            {
                if (byPath.TryGetValue(IndexStore.NormalizePath(file.Path), out var row))
                {
                    if (row.Size != file.Size || System.Math.Abs(row.Mtime - file.Mtime) > 0.001 || row.Kind != file.Kind)
                    {
                        _store.Requeue(row.Id, file);
                        summary.Changed++;
                        summary.Queued.Add(row.Id);
                    }
                    else
                    {
                        summary.Unchanged++;
                    }
                }
                else if (byInode.TryGetValue($"{file.Device}:{file.Inode}", out var moved)
                    && !seen.Contains(IndexStore.NormalizePath(moved.Path)) && !movedFrom.Contains(IndexStore.NormalizePath(moved.Path))
                    && moved.Size == file.Size && System.Math.Abs(moved.Mtime - file.Mtime) < 0.001)
                {
                    _store.Move(moved.Id, file.Path);
                    movedFrom.Add(IndexStore.NormalizePath(moved.Path));
                    summary.Moved++;
                }
                else
                {
                    summary.Queued.Add(_store.Insert(file));
                    summary.Added++;
                }
            }

            // A root that went away mid-crawl (a drive ejected) looked emptier
            // than it is: keep its rows rather than take that for "deleted".
            var vanished = new System.Collections.Generic.List<string>();
            foreach (string root in roots)
            {
                if (!System.IO.Directory.Exists(root) && !System.IO.File.Exists(root))
                {
                    vanished.Add(IndexStore.NormalizePath(root.TrimEnd(System.IO.Path.DirectorySeparatorChar)
                        + System.IO.Path.DirectorySeparatorChar));
                }
            }

            foreach (var row in existing)
            {
                string at = IndexStore.NormalizePath(row.Path);
                if (!seen.Contains(at) && !movedFrom.Contains(at)
                    && !System.Linq.Enumerable.Any(vanished, prefix => at.StartsWith(prefix, System.StringComparison.OrdinalIgnoreCase)))
                {
                    _store.Delete(row.Id);
                    summary.Removed++;
                }
            }
        });

        // Folders the user removed in Settings are outside every root above:
        // FilesUnder never loads them, so without this they would haunt
        // search results forever. Gone hardware keeps its files (see Prune).
        summary.Removed += _store.Prune(roots);

        return summary;
    }

    // MARK: Run

    /// <summary>
    /// Processes pending files, screenshots first, newest first
    /// (<paramref name="only"/>: just these files). Long PDFs/documents get
    /// their first step and stay partial for FinishLongFiles. Ports run (Indexer.swift:139).
    /// </summary>
    public System.Collections.Generic.Dictionary<string, int> Run(
        int? limit = null,
        System.Collections.Generic.ISet<long>? only = null,
        System.Func<bool>? shouldStop = null,
        System.Action<Event>? onEvent = null)
    {
        shouldStop ??= () => false;
        onEvent ??= _ => { };
        var queue = _store.Pending(limit, only);
        var states = new System.Collections.Generic.Dictionary<string, int>();
        int done = 0;
        var jobs = System.Linq.Enumerable.Select(ExtractorRunner.Batches(queue), b => new Job(b)).ToList();
        Process(jobs, shouldStop, (index, job, results, seconds) =>
        {
            for (int o = 0; o < job.Files.Count; o++)
            {
                var (state, note) = results[o];
                states[state] = states.TryGetValue(state, out int n) ? n + 1 : 1;
                onEvent(new Event(done + o + 1, queue.Count, job.Files[o].Path, job.Files[o].Kind, state, seconds, note));
            }

            done += job.Files.Count;
        });

        return states;
    }

    /// <summary>
    /// The later pass: the rest of long PDFs/documents, a step at a time, each
    /// saved as one transaction so stopping between steps loses nothing.
    /// Ports finishLongFiles (Indexer.swift:174).
    /// </summary>
    public System.Collections.Generic.Dictionary<string, int> FinishLongFiles(
        System.Func<bool>? shouldStop = null,
        System.Action<Step>? onStep = null)
    {
        shouldStop ??= () => false;
        onStep ??= _ => { };
        var jobs = new System.Collections.Generic.List<Job>();
        foreach (var file in _store.Unfinished())
        {
            var info = _store.InfoOf(file.Id);
            int size = file.Kind == FileKind.Pdf ? _options.PdfStep : _options.DocStep;
            int start = info.TryGetValue("read_to", out string? to) && int.TryParse(to, out int rv)
                ? rv
                : _store.LastPlace(file.Id) ?? 0;
            int end = System.Math.Max(
                info.TryGetValue("read_end", out string? re) && int.TryParse(re, out int ev) ? ev : 0,
                start + 1);
            while (start < end)
            {
                int stop = System.Math.Min(start + size, end);
                jobs.Add(new Job(new[] { file }, new JobStep(start, stop)));
                start += size;
            }
        }

        var through = new System.Collections.Generic.List<int>();
        foreach (var job in jobs)
        {
            through.Add((through.Count > 0 ? through[^1] : 0) + (job.Step?.Count ?? 0));
        }

        int total = through.Count > 0 ? through[^1] : 0;
        int files = new System.Collections.Generic.HashSet<long>(System.Linq.Enumerable.Select(jobs, j => j.Files[0].Id)).Count;
        var finished = new System.Collections.Generic.HashSet<long>();
        var states = new System.Collections.Generic.Dictionary<string, int>();
        Process(jobs, shouldStop, (index, job, results, seconds) =>
        {
            var file = job.Files[0];
            var (state, note) = results[0];
            if (state != FileState.Partial && finished.Add(file.Id))
            {
                states[state] = states.TryGetValue(state, out int n) ? n + 1 : 1;
                files--;
            }

            onStep(new Step(through[index], total, files, file.Path, file.Kind, state, seconds, note));
        }, skip: job => finished.Contains(job.Files[0].Id));

        return states;
    }

    /// <summary>
    /// How much of Run went where (all threads). Read after Run returns.
    /// Extract = waiting on file reading/decoding; Commit = model + store.
    /// </summary>
    public long ExtractMs;
    public long CommitMs;

    /// <summary>Parallel file preparations (CPU decode/resize/FFmpeg).
    /// The model + store stay serial. 1 keeps the old one-ahead behavior.</summary>
    public int PrepareDegree { get; set; } = System.Math.Max(2, System.Math.Min(8, System.Environment.ProcessorCount / 2));

    /// <summary>
    /// Runs jobs in order until shouldStop, passing each one's results to
    /// committed with its place in jobs. Ports process (Indexer.swift:217).
    /// </summary>
    private void Process(
        System.Collections.Generic.IReadOnlyList<Job> jobs,
        System.Func<bool> shouldStop,
        System.Action<int, Job, System.Collections.Generic.IReadOnlyList<(string State, string? Note)>, double> committed,
        System.Func<Job, bool>? skip = null)
    {
        int index = 0;
        foreach (var (job, prepared, waited) in _runner.RunOverlapped(jobs, shouldStop, PrepareDegree))
        {
            int place = index++;
            try
            {
                if (skip?.Invoke(job) == true)
                {
                    continue;
                }

                var commitStart = System.DateTime.UtcNow;
                System.Collections.Generic.IReadOnlyList<(string State, string? Note)> results;
                try
                {
                    results = Commit(prepared);
                }
                catch (WorkerError error) when (error.Failure != WorkerError.Kind.NotFound)
                {
                    // A dead helper used to end the whole run, leaving the
                    // file that killed it first in line to kill the next run
                    // too. Now the run goes on without it; the file is tried
                    // again next time, quarantined after a few crashes.
                    results = WorkerCrashed(job, prepared, error);
                }
                double seconds = (waited + (System.DateTime.UtcNow - commitStart)).TotalSeconds
                    / System.Math.Max(1, job.Files.Count);
                System.Threading.Interlocked.Add(ref ExtractMs, (long)waited.TotalMilliseconds);
                System.Threading.Interlocked.Add(ref CommitMs,
                    (long)(System.DateTime.UtcNow - commitStart).TotalMilliseconds);
                committed(place, job, results, seconds);
            }
            finally
            {
                ExtractorRunner.DeleteQuiet(prepared.Folder);
            }
        }
    }

    /// <summary>How many times a file may crash the helper before it's
    /// quarantined (first pass) or kept as read so far (long files).</summary>
    private const int MaxWorkerAttempts = 3;

    private System.Collections.Generic.IReadOnlyList<(string State, string? Note)> WorkerCrashed(
        Job job, PreparedBatch prepared, WorkerError error)
    {
        if (error.Failure == WorkerError.Kind.Died)
        {
            CloseWorker(); // the pool holds a corpse; the next file restarts it
        }

        bool later = job.Step != null;
        var results = new System.Collections.Generic.List<(string, string?)>();
        for (int slot = 0; slot < job.Files.Count; slot++)
        {
            if (prepared.Outcomes.TryGetValue(slot, out var settled))
            {
                results.Add((settled.State, settled.Detail));
                continue;
            }

            var file = job.Files[slot];
            int tries = _store.BumpAttempts(file.Id);
            if (tries >= MaxWorkerAttempts)
            {
                if (later)
                {
                    results.Add(StopReading(file, job.Step!.Start, "the helper kept crashing here"));
                }
                else
                {
                    _store.Finish(file.Id, FileState.Failed, "the helper kept crashing on this file; skipped");
                    results.Add((FileState.Failed, "helper kept crashing; skipped"));
                }
            }
            else if (later)
            {
                results.Add((FileState.Partial, "helper crashed, kept what was read"));
            }
            else
            {
                results.Add((FileState.Pending, "helper crashed, tries again next time"));
            }
        }

        return results;
    }

    /// <summary>
    /// Compares the index with the current model and settings without starting
    /// the model; a change empties the index or throws. Ports checkModel (Indexer.swift:265).
    /// </summary>
    public void CheckModel()
    {
        if (EmbedderSource == null)
        {
            return;
        }

        Adopt($"{EmbedderSource} | {_options.Fingerprint}");
    }

    private void Adopt(string fingerprint)
    {
        string? indexed = _store.GetMeta("fingerprint");
        if (indexed == fingerprint)
        {
            return;
        }

        if (ResetOnModelChange == null)
        {
            throw IndexerError.FingerprintMismatch(indexed ?? "(none)", fingerprint);
        }

        _store.ResetAll();
        ResetOnModelChange(indexed ?? "(none)", fingerprint);
    }

    private IEmbedder FullWorker() => NextWorker();

    /// <summary>How many model helpers run at once (each ~1 GB GPU, 0.25 GB
    /// text-only). Measured 2026-10-11 on one RTX 5070 Ti: 1 helper does 9.7
    /// files/s, 2 do 5.4 (concurrent encodes contend for the same GPU).
    /// So 1 is the default; raise it only with a second GPU.</summary>
    public int WorkerCount { get; set; } = 1;

    private readonly System.Collections.Generic.List<IEmbedder> _workers = new();
    private int _nextWorker;
    private readonly object _workerGate = new();

    /// <summary>Round-robin over the pool (the GPU does the real work, so two
    /// helpers overlap encode + transfer instead of idling between files).</summary>
    private IEmbedder NextWorker()
    {
        lock (_workerGate)
        {
            if (_workers.Count == 0)
            {
                var started = _makeEmbedder();
                string fingerprint = $"{started.Info.VectorSource} | {_options.Fingerprint}";
                try
                {
                    Adopt(fingerprint);
                }
                catch
                {
                    started.Close();
                    throw;
                }

                _store.SetMeta("fingerprint", fingerprint);
                _store.SetMeta("vector_source", started.Info.VectorSource);
                _workers.Add(started);
            }
            while (_workers.Count < WorkerCount)
            {
                try { _workers.Add(_makeEmbedder()); }
                catch { break; } // one helper is enough when a second won't start
            }
            var worker = _workers[_nextWorker % _workers.Count];
            _nextWorker++;
            return worker;
        }
    }

    // MARK: Commit (the indexing thread: the model and the database)

    private System.Collections.Generic.IReadOnlyList<(string State, string? Note)> Commit(PreparedBatch prepared)
    {
        var batch = prepared.Job.Files;
        bool later = prepared.Job.Step != null;
        if (prepared.Job.Step != null && prepared.Outcomes.TryGetValue(0, out var stepOutcome))
        {
            return new[] { StopReading(batch[0], prepared.Job.Step.Start, stepOutcome.Detail ?? stepOutcome.State) };
        }

        var results = new System.Collections.Generic.List<(string, string?)>();
        for (int i = 0; i < batch.Count; i++)
        {
            results.Add((FileState.Failed, (string?)null));
        }

        foreach (var (slot, outcome) in prepared.Outcomes)
        {
            _store.Finish(batch[slot].Id, outcome.State, outcome.Detail);
            results[slot] = (outcome.State, outcome.Detail);
        }

        try
        {
            switch (prepared.Payload)
            {
                case ExtractPayload.Nothing:
                    break;
                case ExtractPayload.Images images:
                    Images(batch, images.Screenshot, images.Ready, results);
                    break;
                case ExtractPayload.Pdf pdf:
                    results[0] = PdfFile(batch[0], pdf.Pages, pdf.ReadFrom, pdf.ReadToExclusive, pdf.Total, pdf.Title, later);
                    break;
                case ExtractPayload.Doc doc:
                    results[0] = DocFile(batch[0], doc.Chunks, doc.ReadFrom, doc.ReadToExclusive, doc.Total, doc.Characters, later);
                    break;
                case ExtractPayload.Audio audio:
                    results[0] = AudioFile(batch[0], audio.Pieces, audio.DurationSeconds);
                    break;
                case ExtractPayload.Video video:
                    results[0] = VideoFile(batch[0], video.Frames, video.Sound, video.DurationSeconds);
                    break;
                case ExtractPayload.Code code:
                    results[0] = CodeFile(batch[0], code.File);
                    break;
            }
        }
        catch (WorkerError)
        {
            throw;
        }
        catch (IndexerError)
        {
            throw;
        }
        catch (System.Exception error)
        {
            if (prepared.Job.Step != null)
            {
                return new[] { StopReading(batch[0], prepared.Job.Step.Start, error.Message) };
            }

            for (int slot = 0; slot < batch.Count; slot++)
            {
                if (!prepared.Outcomes.ContainsKey(slot))
                {
                    _store.Finish(batch[slot].Id, FileState.Failed, error.Message);
                    results[slot] = (FileState.Failed, error.Message);
                }
            }
        }

        return results;
    }

    /// <summary>
    /// A long file that cannot be read further keeps what was read so far and
    /// counts as done. Ports stopReading (Indexer.swift:485).
    /// </summary>
    private (string State, string? Note) StopReading(FileRecord file, int place, string problem)
    {
        var info = _store.InfoOf(file.Id);
        info["read_to"] = null;
        info["read_end"] = null;
        string unit = file.Kind == FileKind.Pdf ? "page" : "chunk";
        _store.Finish(file.Id, FileState.Done, $"read to {unit} {place}, not after: {problem}", info);
        return (FileState.Done, $"stopped before {unit} {place + 1}: {problem}");
    }

    private void Images(
        System.Collections.Generic.IReadOnlyList<FileRecord> batch,
        bool screenshot,
        System.Collections.Generic.IReadOnlyList<ReadyImage> ready,
        System.Collections.Generic.List<(string State, string? Note)> results)
    {
        if (ready.Count == 0)
        {
            return;
        }

        var worker = FullWorker();
        var paths = System.Linq.Enumerable.Select(ready, r => r.Image.Path).ToList();
        var vectors = worker.EmbedImages(paths, screenshot ? _options.ScreenshotBudget : _options.PhotoBudget);
        _store.Transact(() =>
        {
            for (int i = 0; i < ready.Count; i++)
            {
                var item = ready[i];
                var file = batch[item.Slot];
                if (vectors[i].Vector == null)
                {
                    _store.Finish(file.Id, FileState.Failed, vectors[i].Error);
                    results[item.Slot] = (FileState.Failed, vectors[i].Error);
                    continue;
                }

                _store.AddSegment(file.Id, SegmentKind.Image, Modality.Image, vector: vectors[i].Vector);
                // Words on screen are for keyword search only; meaning comes
                // from the picture alone. (Indexer.swift:510)
                if (item.Ocr.Length > 0)
                {
                    _store.AddSegment(file.Id, SegmentKind.Ocr, Modality.Text,
                        excerpt: Excerpt.Of(item.Ocr), text: item.Ocr);
                }

                var info = new System.Collections.Generic.Dictionary<string, string?>
                {
                    ["width"] = item.Image.Width.ToString(),
                    ["height"] = item.Image.Height.ToString(),
                };
                if (item.Image.Taken != null)
                {
                    info["taken"] = item.Image.Taken;
                }

                if (screenshot)
                {
                    info["ocr_chars"] = item.Ocr.Length.ToString();
                }

                _store.Finish(file.Id, FileState.Done, info: info);
                results[item.Slot] = (FileState.Done, screenshot ? $"ocr {item.Ocr.Length} chars" : null);
            }
        });
    }

    /// <summary>Ports the pdf commit (Indexer.swift:526).</summary>
    private (string State, string? Note) PdfFile(
        FileRecord file, System.Collections.Generic.IReadOnlyList<PdfPage> pages,
        int readFrom, int readTo, int total, string? title, bool later)
    {
        int end = System.Math.Min(total, _options.MaxPages);
        bool unread = readTo < end;
        if (pages.Count == 0 && !later && !unread)
        {
            _store.Finish(file.Id, FileState.Skipped, "no pages");
            return (FileState.Skipped, "no pages");
        }

        title ??= System.IO.Path.GetFileNameWithoutExtension(file.Path);
        var textPages = System.Linq.Enumerable.Where(pages, p => p.ImagePath == null).ToList();
        // A page that is mostly digits gets keyword search only.
        var wordPages = System.Linq.Enumerable.Where(textPages, p => TextStats.HasWords(p.Text)).ToList();
        var imagePages = System.Linq.Enumerable.Where(pages, p => p.ImagePath != null).ToList();
        var garbledPages = System.Linq.Enumerable.Where(pages, p => p.Garbled != null).ToList();

        var textVectors = new System.Collections.Generic.Dictionary<int, float[]>();
        Embedding[] imageVectors = System.Array.Empty<Embedding>();
        float[][] garbledVectors = System.Array.Empty<float[]>();
        if (wordPages.Count > 0 || imagePages.Count > 0)
        {
            var worker = FullWorker();
            var vectors = worker.EmbedTexts(System.Linq.Enumerable.Select(
                wordPages, p => Prompts.Document(title, Prefix(p.Text, 4000))).ToList());
            for (int i = 0; i < wordPages.Count; i++)
            {
                textVectors[wordPages[i].Number] = vectors[i];
            }

            imageVectors = worker.EmbedImages(
                System.Linq.Enumerable.Select(imagePages, p => p.ImagePath!).ToList(), _options.PageBudget);
            garbledVectors = worker.EmbedTexts(System.Linq.Enumerable.Select(
                garbledPages, p => Prompts.Document(title, Prefix(p.Garbled!, 4000))).ToList());
        }

        _store.Transact(() =>
        {
            // Meaning only: garbled words are never shown or matched.
            for (int i = 0; i < garbledPages.Count; i++)
            {
                _store.AddSegment(file.Id, SegmentKind.Page, Modality.Text,
                    loc: garbledPages[i].Number, vector: garbledVectors[i]);
            }

            foreach (var page in textPages)
            {
                textVectors.TryGetValue(page.Number, out float[]? vector);
                _store.AddSegment(file.Id, SegmentKind.Page, Modality.Text, loc: page.Number,
                    excerpt: Excerpt.Of(page.Text), text: page.Text, vector: vector);
            }

            for (int i = 0; i < imagePages.Count; i++)
            {
                var page = imagePages[i];
                _store.AddSegment(file.Id, SegmentKind.PageImage, Modality.Image, loc: page.Number,
                    excerpt: page.Text.Length == 0 ? null : Excerpt.Of(page.Text),
                    text: page.Text, vector: imageVectors[i].Vector);
            }

            var info = later ? _store.InfoOf(file.Id) : new System.Collections.Generic.Dictionary<string, string?>();
            info["pages"] = total.ToString();
            int scanned = (info.TryGetValue("scanned_pages", out string? sp) && int.TryParse(sp, out int sv) ? sv : 0)
                + imagePages.Count;
            info["scanned_pages"] = scanned.ToString();
            info["read_to"] = unread ? readTo.ToString() : null;
            info["read_end"] = unread ? end.ToString() : null;
            string? detail = unread ? $"read to page {readTo} of {total}"
                : end < total ? $"the first {end} of {total} pages" : null;
            _store.Finish(file.Id, unread ? FileState.Partial : FileState.Done, detail, info);
        });

        int ocr = System.Linq.Enumerable.Count(pages, p => p.Ocr);
        string span = later ? $"pages {readFrom + 1}–{readTo} of {total}" : $"{pages.Count}/{total} pages";
        return (unread ? FileState.Partial : FileState.Done,
            $"{span}, {imagePages.Count} as images" + (ocr > 0 ? $", {ocr} read by OCR" : ""));
    }

    /// <summary>Ports the doc commit (Indexer.swift:583).</summary>
    private (string State, string? Note) DocFile(
        FileRecord file, System.Collections.Generic.IReadOnlyList<string> chunks,
        int readFrom, int readTo, int total, int characters, bool later)
    {
        if (total <= 0)
        {
            _store.Finish(file.Id, FileState.Skipped, "no text");
            return (FileState.Skipped, "no text");
        }

        string title = System.IO.Path.GetFileNameWithoutExtension(file.Path);
        var worded = new System.Collections.Generic.List<int>();
        for (int i = 0; i < chunks.Count; i++)
        {
            if (TextStats.HasWords(chunks[i]))
            {
                worded.Add(i);
            }
        }

        float[][] vectors = worded.Count == 0
            ? System.Array.Empty<float[]>()
            : FullWorker().EmbedTexts(System.Linq.Enumerable.Select(
                worded, i => Prompts.Document(title, chunks[i])).ToList());
        var byOffset = new System.Collections.Generic.Dictionary<int, float[]>();
        for (int i = 0; i < worded.Count; i++)
        {
            byOffset[worded[i]] = vectors[i];
        }

        int end = System.Math.Min(total, _options.MaxChunks);
        bool unread = readTo < end;
        _store.Transact(() =>
        {
            for (int offset = 0; offset < chunks.Count; offset++)
            {
                byOffset.TryGetValue(offset, out float[]? vector);
                _store.AddSegment(file.Id, SegmentKind.Chunk, Modality.Text,
                    loc: readFrom + offset + 1, excerpt: Excerpt.Of(chunks[offset]),
                    text: chunks[offset], vector: vector);
            }

            var info = new System.Collections.Generic.Dictionary<string, string?>
            {
                ["chunks"] = end.ToString(),
                ["chars"] = characters.ToString(),
                ["read_to"] = unread ? readTo.ToString() : null,
                ["read_end"] = unread ? end.ToString() : null,
            };
            string? detail = unread ? $"read to chunk {readTo} of {end}" : end < total ? $"the first {end} chunks" : null;
            _store.Finish(file.Id, unread ? FileState.Partial : FileState.Done, detail, info);
        });

        string span = later ? $"chunks {readFrom + 1}–{readTo} of {end}"
            : unread ? $"{chunks.Count} of {end} chunks" : $"{chunks.Count} chunks";
        return (unread ? FileState.Partial : FileState.Done,
            span + (worded.Count < chunks.Count ? $", {chunks.Count - worded.Count} for keywords only" : ""));
    }

    /// <summary>Ports the code commit (Indexer.swift:618).</summary>
    private (string State, string? Note) CodeFile(FileRecord file, CodeFile code)
    {
        if (code.Pieces.Count == 0)
        {
            _store.Finish(file.Id, FileState.Skipped, "no code");
            return (FileState.Skipped, "no code");
        }

        var worded = new System.Collections.Generic.List<int>();
        for (int i = 0; i < code.Pieces.Count; i++)
        {
            if (TextStats.HasWords(code.Pieces[i].Text))
            {
                worded.Add(i);
            }
        }

        float[][] vectors = worded.Count == 0
            ? System.Array.Empty<float[]>()
            : FullWorker().EmbedTexts(System.Linq.Enumerable.Select(
                worded, i => Prompts.Document(code.Title, code.Pieces[i].Text)).ToList());
        var byOffset = new System.Collections.Generic.Dictionary<int, float[]>();
        for (int i = 0; i < worded.Count; i++)
        {
            byOffset[worded[i]] = vectors[i];
        }

        _store.Transact(() =>
        {
            for (int offset = 0; offset < code.Pieces.Count; offset++)
            {
                var piece = code.Pieces[offset];
                byOffset.TryGetValue(offset, out float[]? vector);
                _store.AddSegment(file.Id, code.Cells == null ? SegmentKind.Lines : SegmentKind.Cells,
                    Modality.Text, loc: piece.First, locEnd: piece.Last,
                    excerpt: CodeExtractor.Summary(piece.Text), text: piece.Text, vector: vector);
            }

            var info = new System.Collections.Generic.Dictionary<string, string?>
            {
                ["lines"] = code.Lines.ToString(),
                ["cells"] = code.Cells?.ToString(),
                ["repo"] = code.Repo,
                ["capped"] = code.CapNote,
            };
            _store.Finish(file.Id, FileState.Done, info: info);
        });

        string extent = code.Cells.HasValue ? $"{code.Cells} cells" : $"{code.Lines} lines";
        return (FileState.Done, $"{code.Pieces.Count} stretches, {extent}"
            + (code.CapNote is null ? "" : $", {code.CapNote}")
            + (worded.Count < code.Pieces.Count ? $", {code.Pieces.Count - worded.Count} for keywords only" : ""));
    }

    private (string State, string? Note) AudioFile(
        FileRecord file, System.Collections.Generic.IReadOnlyList<MediaPiece> pieces, double duration)
    {
        if (pieces.Count == 0)
        {
            _store.Finish(file.Id, FileState.Skipped, "silent or shorter than 2 s");
            return (FileState.Skipped, "silent or too short");
        }

        var vectors = FullWorker().EmbedAudio(System.Linq.Enumerable.Select(pieces, p => p.Path).ToList());
        _store.Transact(() =>
        {
            for (int i = 0; i < pieces.Count; i++)
            {
                _store.AddSegment(file.Id, SegmentKind.Audio, Modality.Audio,
                    loc: pieces[i].StartSeconds, locEnd: pieces[i].EndSeconds, vector: vectors[i].Vector);
            }

            _store.Finish(file.Id, FileState.Done,
                info: new System.Collections.Generic.Dictionary<string, string?>
                {
                    ["duration"] = duration.ToString("F1", System.Globalization.CultureInfo.InvariantCulture),
                });
        });

        return (FileState.Done, $"{pieces.Count} windows, {(int)duration} s");
    }

    private (string State, string? Note) VideoFile(
        FileRecord file, System.Collections.Generic.IReadOnlyList<MediaPiece> frames,
        System.Collections.Generic.IReadOnlyList<MediaPiece> sound, double duration)
    {
        if (frames.Count == 0 && sound.Count == 0)
        {
            _store.Finish(file.Id, FileState.Skipped, "no frames or sound");
            return (FileState.Skipped, "no frames or sound");
        }

        var worker = FullWorker();
        var frameVectors = worker.EmbedImages(
            System.Linq.Enumerable.Select(frames, f => f.Path).ToList(), _options.FrameBudget);
        var soundVectors = worker.EmbedAudio(
            System.Linq.Enumerable.Select(sound, p => p.Path).ToList());
        _store.Transact(() =>
        {
            for (int i = 0; i < frames.Count; i++)
            {
                _store.AddSegment(file.Id, SegmentKind.Frame, Modality.Image,
                    loc: frames[i].StartSeconds, locEnd: frames[i].EndSeconds, vector: frameVectors[i].Vector);
            }

            for (int i = 0; i < sound.Count; i++)
            {
                _store.AddSegment(file.Id, SegmentKind.Audio, Modality.Audio,
                    loc: sound[i].StartSeconds, locEnd: sound[i].EndSeconds, vector: soundVectors[i].Vector);
            }

            _store.Finish(file.Id, FileState.Done,
                info: new System.Collections.Generic.Dictionary<string, string?>
                {
                    ["duration"] = duration.ToString("F1", System.Globalization.CultureInfo.InvariantCulture),
                    ["frames"] = frames.Count.ToString(),
                    ["sound_windows"] = sound.Count.ToString(),
                });
        });

        return (FileState.Done, $"{frames.Count} frames, {sound.Count} sound windows, {(int)duration} s");
    }

    private static string Prefix(string text, int max) =>
        text.Length > max ? text.Substring(0, max) : text;
}

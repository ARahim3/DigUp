// One-batch-ahead extraction overlap: while the model embeds one job, the
// next is read and decoded on another thread. Ports Indexer.process's two
// overlapping stages (Indexer.swift:217-235) and the image batching rule
// (Indexer.swift:245-260).

namespace DigUp.Core;

/// <summary>
/// Runs an <see cref="IExtractor"/> one batch ahead of the caller. The caller
/// (the indexer) commits each yielded batch to the model and store, then the
/// already-preparing next batch is waited on. Mirrors the Swift design where
/// extraction runs on a single serial preparation queue.
/// </summary>
public sealed class ExtractorRunner : System.IDisposable
{
    private readonly IExtractor _extractor;
    private readonly string _scratchRoot;
    private int _prepared;
    private bool _disposed;

    public ExtractorRunner(IExtractor extractor, string scratchRoot)
    {
        _extractor = extractor;
        _scratchRoot = scratchRoot;
        System.IO.Directory.CreateDirectory(scratchRoot);
    }

    /// <summary>
    /// Images and screenshots go to the model 8 at a time; other files one by
    /// one. Ports Indexer.batches (Indexer.swift:245).
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<System.Collections.Generic.IReadOnlyList<FileRecord>> Batches(
        System.Collections.Generic.IReadOnlyList<FileRecord> queue)
    {
        var batches = new System.Collections.Generic.List<System.Collections.Generic.IReadOnlyList<FileRecord>>();
        int index = 0;
        while (index < queue.Count)
        {
            var batch = new System.Collections.Generic.List<FileRecord> { queue[index] };
            if (batch[0].Kind == FileKind.Image || batch[0].Kind == FileKind.Screenshot)
            {
                while (index + batch.Count < queue.Count && batch.Count < 8
                    && queue[index + batch.Count].Kind == batch[0].Kind)
                {
                    batch.Add(queue[index + batch.Count]);
                }
            }

            batches.Add(batch);
            index += batch.Count;
        }

        return batches;
    }

    /// <summary>
    /// Yields each job with its prepared batch, keeping preparations in
    /// flight. <paramref name="shouldStop"/> is asked before each job; when it
    /// stops early, in-flight batches' scratch folders are deleted (jobs
    /// prepared for a run that stopped early: their files are thrown away).
    /// <paramref name="waited"/> is how long the caller blocked on the current
    /// batch's preparation, for per-file timing. Results stay in job order no
    /// matter which preparation finishes first.
    /// </summary>
    public System.Collections.Generic.IEnumerable<(Job Job, PreparedBatch Prepared, System.TimeSpan Waited)> RunOverlapped(
        System.Collections.Generic.IReadOnlyList<Job> jobs, System.Func<bool> shouldStop, int degree = 1)
    {
        degree = System.Math.Max(1, degree);
        if (degree == 1 || jobs.Count < 3)
        {
            foreach (var item in RunOverlappedSerial(jobs, shouldStop))
                yield return item;
            yield break;
        }
        var inFlight = new System.Collections.Generic.SortedDictionary<int, System.Threading.Tasks.Task<PreparedBatch>>();
        try
        {
            int next = 0, yieldAt = 0;
            while (yieldAt < jobs.Count)
            {
                if (shouldStop())
                {
                    foreach (var t in inFlight.Values) DeleteQuiet(SafeResult(t)?.Folder);
                    inFlight.Clear();
                    yield break;
                }
                while (next < jobs.Count && inFlight.Count < degree)
                {
                    int n = next++;
                    inFlight[n] = System.Threading.Tasks.Task.Run(() => Prepare(jobs[n]));
                }
                var watch = System.Diagnostics.Stopwatch.StartNew();
                PreparedBatch prepared = inFlight[yieldAt].GetAwaiter().GetResult();
                watch.Stop();
                inFlight.Remove(yieldAt);
                yield return (jobs[yieldAt], prepared, watch.Elapsed);
                yieldAt++;
            }
        }
        finally
        {
            // Abandoned enumeration (or an exception) with batches still
            // preparing: wait for them once, then throw their files away.
            foreach (var t in inFlight.Values) DeleteQuiet(SafeResult(t)?.Folder);
            inFlight.Clear();
        }
    }

    private System.Collections.Generic.IEnumerable<(Job Job, PreparedBatch Prepared, System.TimeSpan Waited)> RunOverlappedSerial(
        System.Collections.Generic.IReadOnlyList<Job> jobs, System.Func<bool> shouldStop)
    {
        System.Threading.Tasks.Task<PreparedBatch>? ahead = null;
        try
        {
            for (int i = 0; i < jobs.Count; i++)
            {
                if (shouldStop())
                {
                    if (ahead != null)
                    {
                        DeleteQuiet(SafeResult(ahead)?.Folder);
                    }

                    yield break;
                }

                PreparedBatch prepared;
                System.TimeSpan waited = System.TimeSpan.Zero;
                if (ahead != null)
                {
                    var watch = System.Diagnostics.Stopwatch.StartNew();
                    prepared = ahead.GetAwaiter().GetResult();
                    watch.Stop();
                    waited = watch.Elapsed;
                    ahead = null;
                }
                else
                {
                    prepared = Prepare(jobs[i]);
                }

                if (i + 1 < jobs.Count)
                {
                    int next = i + 1;
                    ahead = System.Threading.Tasks.Task.Run(() => Prepare(jobs[next]));
                }

                yield return (jobs[i], prepared, waited);
            }
        }
        finally
        {
            // Abandoned enumeration (or an exception) with a batch still
            // preparing: wait for it once, then throw its files away.
            if (ahead != null)
            {
                DeleteQuiet(SafeResult(ahead)?.Folder);
                ahead = null;
            }
        }
    }

    public void Dispose()
    {
        _disposed = true;
    }

    private PreparedBatch Prepare(Job job)
    {
        int number = System.Threading.Interlocked.Increment(ref _prepared);
        string folder = System.IO.Path.Combine(_scratchRoot, $"batch-{number}");
        return _extractor.Prepare(job, folder);
    }

    private static PreparedBatch? SafeResult(System.Threading.Tasks.Task<PreparedBatch> task)
    {
        try
        {
            return task.GetAwaiter().GetResult();
        }
        catch
        {
            return null;
        }
    }

    internal static void DeleteQuiet(string? folder)
    {
        if (string.IsNullOrEmpty(folder))
        {
            return;
        }

        try
        {
            if (System.IO.Directory.Exists(folder))
            {
                System.IO.Directory.Delete(folder, recursive: true);
            }
        }
        catch
        {
            // Scratch cleanup must never fail a run.
        }
    }
}

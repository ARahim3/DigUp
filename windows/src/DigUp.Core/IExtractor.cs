// Extraction abstraction: jobs, prepared batches, and the per-kind dispatcher.
// Ports Indexer.Job / Prepared / Payload / Outcome (Indexer.swift:239, 296,
// 310, 322) and the prepare stage (Indexer.swift:358-436). The embedder
// interface lives in WorkerClient.cs; this file only references it.

namespace DigUp.Core;

/// <summary>
/// Why a file could not be extracted. Ports ExtractError (Extractors.swift:8).
/// LeftOut means "not for the index after all" (generated code, private keys,
/// minified bundles): the file counts as skipped, not failed.
/// </summary>
public sealed class ExtractError : System.Exception
{
    public enum FailureKind
    {
        Unreadable,
        TooSmall,
        Locked,
        Empty,
        LeftOut,
    }

    public FailureKind Failure { get; }
    public int Width { get; }
    public int Height { get; }

    private ExtractError(FailureKind failure, string message, int width = 0, int height = 0)
        : base(message)
    {
        Failure = failure;
        Width = width;
        Height = height;
    }

    public static ExtractError Unreadable(string why) =>
        new(FailureKind.Unreadable, $"unreadable: {why}");

    public static ExtractError TooSmall(int width, int height) =>
        new(FailureKind.TooSmall, $"small image {width}×{height}", width, height);

    public static ExtractError Locked() =>
        new(FailureKind.Locked, "password-protected");

    public static ExtractError Empty(string why) => new(FailureKind.Empty, why);

    public static ExtractError LeftOut(string why) => new(FailureKind.LeftOut, why);

    public bool IsLeftOut => Failure == FailureKind.LeftOut;
    public bool IsTooSmall => Failure == FailureKind.TooSmall;
}

/// <summary>File states written to the store.</summary>
public static class FileState
{
    public const string Done = "done";
    public const string Partial = "partial";
    public const string Skipped = "skipped";
    public const string Failed = "failed";
    public const string Pending = "pending";
}

/// <summary>
/// A long file's later step: pages (PDF) or chunks (doc) from 0, half-open.
/// Null means the first step, which comes with the file.
/// </summary>
public sealed record JobStep(int Start, int EndExclusive)
{
    public int Count => EndExclusive - Start;
}

/// <summary>
/// Files read and embedded together (images 8 at a time, others one by one),
/// or one step of a long file. Ports Indexer.Job (Indexer.swift:239).
/// </summary>
public sealed record Job(System.Collections.Generic.IReadOnlyList<FileRecord> Files, JobStep? Step = null);

/// <summary>
/// A job read from disk and decoded, ready for the model. Scratch files live
/// in <see cref="PreparedBatch.Folder"/>. Ports Indexer.Prepared (Indexer.swift:296).
/// </summary>
public abstract record ExtractPayload
{
    private ExtractPayload()
    {
    }

    public sealed record Nothing : ExtractPayload
    {
        public static readonly Nothing Instance = new();
    }

    public sealed record Images(bool Screenshot, System.Collections.Generic.IReadOnlyList<ReadyImage> Ready)
        : ExtractPayload;

    /// <param name="ReadFrom">Pages read, from 0, half-open with <paramref name="ReadToExclusive"/>.</param>
    /// <param name="Total">The PDF's page count.</param>
    public sealed record Pdf(
        System.Collections.Generic.IReadOnlyList<PdfPage> Pages,
        int ReadFrom,
        int ReadToExclusive,
        int Total,
        string? Title) : ExtractPayload;

    /// <param name="ReadFrom">Chunks read, from 0, half-open with <paramref name="ReadToExclusive"/>.</param>
    /// <param name="Total">Chunk count, counted up to MaxChunks + 1.</param>
    public sealed record Doc(
        System.Collections.Generic.IReadOnlyList<string> Chunks,
        int ReadFrom,
        int ReadToExclusive,
        int Total,
        int Characters) : ExtractPayload;

    public sealed record Audio(System.Collections.Generic.IReadOnlyList<MediaPiece> Pieces, double DurationSeconds)
        : ExtractPayload;

    public sealed record Video(
        System.Collections.Generic.IReadOnlyList<MediaPiece> Frames,
        System.Collections.Generic.IReadOnlyList<MediaPiece> Sound,
        double DurationSeconds) : ExtractPayload;

    public sealed record Code(CodeFile File) : ExtractPayload;
}

/// <summary>A file already settled while reading (skipped or failed).</summary>
public sealed record ExtractOutcome(string State, string? Detail);

/// <summary>A job read from disk and decoded, ready for the model.</summary>
public sealed class PreparedBatch
{
    public PreparedBatch(Job job, string folder)
    {
        Job = job;
        Folder = folder;
    }

    public Job Job { get; }
    public string Folder { get; }
    public System.Collections.Generic.Dictionary<int, ExtractOutcome> Outcomes { get; } = new();
    public ExtractPayload Payload { get; set; } = ExtractPayload.Nothing.Instance;
}

/// <summary>
/// Reads and decodes files. Runs off the indexing thread: files only, no
/// database, no model. All external tool paths (FFmpeg, Pdfium, worker exe)
/// arrive via the concrete extractors' constructors; nothing here names one.
/// </summary>
public interface IExtractor
{
    PreparedBatch Prepare(Job job, string folder);
}

/// <summary>
/// Dispatches <see cref="IExtractor.Prepare"/> by file kind, mirroring
/// Indexer.prepare (Indexer.swift:358-436). Concrete engines are injected;
/// the WIC / Pdfium / FFmpeg / OCR implementations behind them are stubs
/// until wired (see ImageExtractor.cs, PdfExtractor.cs, AudioVideoExtractor.cs).
/// </summary>
public sealed class DefaultExtractor : IExtractor
{
    private readonly IndexOptions _options;
    private readonly IImageDecoder _images;
    private readonly IOcrEngine _ocr;
    private readonly IPdfEngine _pdf;
    private readonly FFmpegPaths _ffmpeg;
    private readonly IGitIgnore? _gitIgnore;

    public DefaultExtractor(
        IndexOptions options,
        IImageDecoder images,
        IOcrEngine ocr,
        IPdfEngine pdf,
        FFmpegPaths ffmpeg,
        IGitIgnore? gitIgnore = null)
    {
        _options = options;
        _images = images;
        _ocr = ocr;
        _pdf = pdf;
        _ffmpeg = ffmpeg;
        _gitIgnore = gitIgnore;
    }

    public PreparedBatch Prepare(Job job, string folder)
    {
        var batch = job.Files;
        var prepared = new PreparedBatch(job, folder);
        try
        {
            System.IO.Directory.CreateDirectory(folder);
            switch (batch[0].Kind)
            {
                case FileKind.Image:
                case FileKind.Screenshot:
                    prepared.Payload = PrepareImages(batch, folder, prepared);
                    break;
                case FileKind.Pdf:
                    prepared.Payload = PreparePdf(batch[0], job.Step, folder);
                    break;
                case FileKind.Doc:
                    prepared.Payload = PrepareDoc(batch[0], job.Step);
                    break;
                case FileKind.Audio:
                    prepared.Payload = PrepareAudio(batch[0], folder);
                    break;
                case FileKind.Video:
                    prepared.Payload = PrepareVideo(batch[0], folder);
                    break;
                case FileKind.Code:
                    prepared.Payload = new ExtractPayload.Code(
                        CodeExtractor.Read(batch[0].Path, _options, _gitIgnore));
                    break;
                default:
                    throw ExtractError.Unreadable("unsupported kind");
            }
        }
        catch (ExtractError error) when (error.IsLeftOut)
        {
            // Whole batch left out (single-file batches except images).
            prepared.Outcomes[0] = new ExtractOutcome(FileState.Skipped, error.Message);
            prepared.Payload = ExtractPayload.Nothing.Instance;
        }
        catch (ExtractError error)
        {
            for (int slot = 0; slot < batch.Count; slot++)
            {
                prepared.Outcomes.TryAdd(slot, new ExtractOutcome(FileState.Failed, error.Message));
            }

            prepared.Payload = ExtractPayload.Nothing.Instance;
        }
        catch (System.Exception error)
        {
            for (int slot = 0; slot < batch.Count; slot++)
            {
                prepared.Outcomes.TryAdd(slot, new ExtractOutcome(FileState.Failed, error.Message));
            }

            prepared.Payload = ExtractPayload.Nothing.Instance;
        }

        return prepared;
    }

    private ExtractPayload PrepareImages(
        System.Collections.Generic.IReadOnlyList<FileRecord> batch, string folder, PreparedBatch prepared)
    {
        bool screenshot = batch[0].Kind == FileKind.Screenshot;
        var ready = new System.Collections.Generic.List<ReadyImage>();
        for (int slot = 0; slot < batch.Count; slot++)
        {
            try
            {
                var image = ImageExtractor.Prepare(
                    batch[slot].Path,
                    maxPixel: screenshot ? ImageExtractor.ScreenshotMaxPixel : ImageExtractor.PhotoMaxPixel,
                    minSide: _options.MinImageSide,
                    folder: folder,
                    png: screenshot,
                    decoder: _images);
                string ocr = screenshot ? ImageExtractor.OcrText(image.Path, _ocr) : string.Empty;
                ready.Add(new ReadyImage(slot, image, ocr));
            }
            catch (ExtractError error) when (error.IsTooSmall)
            {
                prepared.Outcomes[slot] = new ExtractOutcome(FileState.Skipped, error.Message);
            }
            catch (ExtractError error)
            {
                prepared.Outcomes[slot] = new ExtractOutcome(FileState.Failed, error.Message);
            }
        }

        return new ExtractPayload.Images(screenshot, ready);
    }

    private ExtractPayload PreparePdf(FileRecord file, JobStep? step, string folder)
    {
        // Long PDFs (books) get their first pages now, the rest after
        // everything else. First step: PdfStep pages past BigPdfPages; cap MaxPages.
        // (Indexer.swift:385-393; Model.swift:54-59: first-30 fast path, 5000 cap.)
        JobStep wanted;
        using (var doc = _pdf.Open(file.Path))
        {
            if (doc.IsLocked)
            {
                throw ExtractError.Locked();
            }

            int total = doc.PageCount;
            int end = System.Math.Min(total, _options.MaxPages);
            JobStep first = total > _options.BigPdfPages
                ? new JobStep(0, System.Math.Min(_options.PdfStep, end))
                : new JobStep(0, end);
            wanted = Clamp(step ?? first, end);
        }

        var (pages, totalCount, title) = PdfExtractor.Pages(
            file.Path, wanted, _options.MinPageText, PdfExtractor.RenderPixels, folder, _pdf, _ocr);
        return new ExtractPayload.Pdf(pages, wanted.Start, wanted.EndExclusive, totalCount, title);
    }

    private ExtractPayload PrepareDoc(FileRecord file, JobStep? step)
    {
        // Chunks are cut the same way every time, so a later step goes on
        // where the last one stopped. (Indexer.swift:394-400)
        string text = DocExtractor.Text(file.Path);
        var chunks = DocExtractor.Chunks(text, limit: _options.MaxChunks + 1);
        var read = Clamp(step ?? new JobStep(0, _options.DocStep), System.Math.Min(chunks.Count, _options.MaxChunks));
        var slice = new System.Collections.Generic.List<string>();
        for (int i = read.Start; i < read.EndExclusive; i++)
        {
            slice.Add(chunks[i]);
        }

        return new ExtractPayload.Doc(slice, read.Start, read.EndExclusive, chunks.Count, text.Length);
    }

    private ExtractPayload PrepareAudio(FileRecord file, string folder)
    {
        var task = AudioVideoExtractor.DecodeAudioWindowsAsync(
            file.Path, _options.AudioWindow, _options.AudioHop,
            AudioVideoExtractor.TailMinimumSeconds, folder, _ffmpeg);
        var (pieces, duration) = task.GetAwaiter().GetResult();
        return new ExtractPayload.Audio(pieces, duration);
    }

    private ExtractPayload PrepareVideo(FileRecord file, string folder)
    {
        var framesTask = AudioVideoExtractor.ExtractKeyframesAsync(
            file.Path, _options.FrameInterval, AudioVideoExtractor.FrameMaxPixel,
            AudioVideoExtractor.MaxFrames, folder, _ffmpeg);
        var (frames, duration, hasAudio) = framesTask.GetAwaiter().GetResult();
        var sound = new System.Collections.Generic.List<MediaPiece>();
        if (hasAudio)
        {
            var soundTask = AudioVideoExtractor.DecodeAudioWindowsAsync(
                file.Path, _options.AudioWindow, _options.AudioHop,
                AudioVideoExtractor.TailMinimumSeconds, folder, _ffmpeg);
            sound.AddRange(soundTask.GetAwaiter().GetResult().Pieces);
        }

        return new ExtractPayload.Video(frames, sound, duration);
    }

    private static JobStep Clamp(JobStep wanted, int end)
    {
        int start = System.Math.Max(0, System.Math.Min(wanted.Start, end));
        int stop = System.Math.Max(start, System.Math.Min(wanted.EndExclusive, end));
        return new JobStep(start, stop);
    }
}

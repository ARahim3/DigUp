// First-index time from metadata alone. Ports Costs, CodeIndexSize, Estimate
// and Estimator (Estimator.swift).
// Page counts come from a PDF-trailer scan (no decoding, like Swift's
// Spotlight-first lookup); durations default to 0 until a header-level probe
// is wired in — both are injectable so callers can supply better sources
// (e.g. ffprobe via AudioVideoExtractor.MediaDuration) without changing this file.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace DigUp.Core;

/// <summary>
/// Seconds of indexing per unit (Estimator.swift:8). Same numbers as Swift.
/// </summary>
public sealed class Costs
{
    /// <summary>140 tokens, decode included.</summary>
    public double Image { get; set; } = 0.12;

    /// <summary>280 tokens; its OCR (0.24 s) runs alongside and sets the pace.</summary>
    public double Screenshot { get; set; } = 0.32;

    /// <summary>Text pages are cheap, rendered scans cost an image.</summary>
    public double PdfPage { get; set; } = 0.09;

    public double DocChunk { get; set; } = 0.095;

    /// <summary>A 30 s window every 25 s.</summary>
    public double AudioSecond { get; set; } = 0.0089;

    /// <summary>A 70-token keyframe per shot (at most one per 3 s) + the soundtrack.</summary>
    public double VideoSecond { get; set; } = 0.019;

    /// <summary>A stretch of code.</summary>
    public double CodeStretch { get; set; } = 0.037;
}

/// <summary>How big the code index gets (Estimator.swift:22).</summary>
public static class CodeIndexSize
{
    /// <summary>Keyword search keeps the text: ~2.4 bytes of index a character of code.</summary>
    public const double PerCharacter = 2.4;

    /// <summary>A vector row for each stretch.</summary>
    public const double PerStretch = 1600.0;

    /// <summary>Characters a stretch holds on average.</summary>
    public const long CharactersPerStretch = 1400;
}

public sealed class Estimate
{
    public Dictionary<FileKind, int> Files { get; } = new();

    /// <summary>Pages the first pass will read.</summary>
    public int PdfPages { get; set; }

    public int PdfPagesTotal { get; set; }

    public double AudioSeconds { get; set; }

    public double VideoSeconds { get; set; }

    /// <summary>Chunks the first pass will read.</summary>
    public int DocChunks { get; set; }

    /// <summary>Seconds for the first pass.</summary>
    public double Seconds { get; set; }

    /// <summary>
    /// Long files, which get their first step in the first pass, and how long
    /// the rest of them takes once everything else is in.
    /// </summary>
    public int LongFiles { get; set; }

    public double LaterSeconds { get; set; }

    /// <summary>The code index: its stretches of code, and about how big it gets on disk.</summary>
    public int CodeStretches { get; set; }

    public double Bytes { get; set; }

    public void Add(Estimate other)
    {
        foreach (var pair in other.Files)
        {
            Files[pair.Key] = Files.TryGetValue(pair.Key, out int n) ? n + pair.Value : pair.Value;
        }

        PdfPages += other.PdfPages;
        PdfPagesTotal += other.PdfPagesTotal;
        AudioSeconds += other.AudioSeconds;
        VideoSeconds += other.VideoSeconds;
        DocChunks += other.DocChunks;
        Seconds += other.Seconds;
        LongFiles += other.LongFiles;
        LaterSeconds += other.LaterSeconds;
        CodeStretches += other.CodeStretches;
        Bytes += other.Bytes;
    }

    public static Estimate operator +(Estimate a, Estimate b)
    {
        var sum = new Estimate();
        sum.Add(a);
        sum.Add(b);
        return sum;
    }
}

/// <summary>First-index time from metadata alone (Estimator.swift:66).</summary>
public static class Estimator
{
    private static readonly Regex PdfCount = new(
        @"/Count\s+(\d+)", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static Estimate Estimate(
        IEnumerable<CrawlCandidate> candidates,
        IndexOptions options,
        Costs? costs = null,
        Func<string, double>? durationOf = null,
        Func<string, int>? pagesOf = null)
    {
        costs ??= new Costs();
        durationOf ??= DefaultDurationOf;
        pagesOf ??= PdfPagesOf;

        var estimate = new Estimate();
        foreach (CrawlCandidate file in candidates)
        {
            estimate.Files[file.Kind] = estimate.Files.TryGetValue(file.Kind, out int n) ? n + 1 : 1;
            switch (file.Kind)
            {
                case FileKind.Image:
                    estimate.Seconds += costs.Image;
                    break;
                case FileKind.Screenshot:
                    estimate.Seconds += costs.Screenshot;
                    break;
                case FileKind.Pdf:
                {
                    int total = pagesOf(file.Path);
                    int all = Math.Min(total, options.MaxPages);
                    int first = total > options.BigPdfPages ? Math.Min(options.PdfStep, all) : all;
                    estimate.PdfPagesTotal += total;
                    estimate.PdfPages += first;
                    estimate.Seconds += first * costs.PdfPage;
                    if (all > first)
                    {
                        estimate.LongFiles++;
                        estimate.LaterSeconds += (all - first) * costs.PdfPage;
                    }

                    break;
                }

                case FileKind.Doc:
                {
                    int all = Math.Max(1, Math.Min(options.MaxChunks, (int)(file.Size / 2000)));
                    int first = Math.Min(all, options.DocStep);
                    estimate.DocChunks += first;
                    estimate.Seconds += first * costs.DocChunk;
                    if (all > first)
                    {
                        estimate.LongFiles++;
                        estimate.LaterSeconds += (all - first) * costs.DocChunk;
                    }

                    break;
                }

                case FileKind.Audio:
                {
                    double seconds = durationOf(file.Path);
                    estimate.AudioSeconds += seconds;
                    estimate.Seconds += seconds * costs.AudioSecond;
                    break;
                }

                case FileKind.Video:
                {
                    double seconds = durationOf(file.Path);
                    estimate.VideoSeconds += seconds;
                    estimate.Seconds += seconds * costs.VideoSecond;
                    break;
                }

                case FileKind.Code:
                {
                    // A notebook's file is mostly its outputs, which aren't read: a guess at its cells' share.
                    long characters = file.Path.EndsWith(".ipynb", StringComparison.OrdinalIgnoreCase)
                        ? file.Size / 8
                        : file.Size;
                    long stretches = Math.Max(
                        1,
                        (characters + CodeIndexSize.CharactersPerStretch - 1) / CodeIndexSize.CharactersPerStretch);
                    estimate.CodeStretches += (int)stretches;
                    estimate.Seconds += stretches * costs.CodeStretch;
                    estimate.Bytes += characters * CodeIndexSize.PerCharacter
                        + stretches * CodeIndexSize.PerStretch;
                    break;
                }
            }
        }

        return estimate;
    }

    /// <summary>
    /// Estimates for each subfolder one level down, and for the files right in
    /// <paramref name="folder"/> (under its own path). (Estimator.swift:119)
    /// </summary>
    public static Dictionary<string, Estimate> EstimatesBySubfolder(
        IEnumerable<CrawlCandidate> candidates,
        string folder,
        IndexOptions options,
        Costs? costs = null,
        Func<string, double>? durationOf = null,
        Func<string, int>? pagesOf = null)
    {
        string baseFolder = folder.TrimEnd('\\', '/');
        string realBase = FolderSelection.RealPath(baseFolder).TrimEnd('\\', '/');
        var groups = new Dictionary<string, List<CrawlCandidate>>(StringComparer.OrdinalIgnoreCase);
        foreach (CrawlCandidate file in candidates)
        {
            string? rest = InsideRest(file.Path, baseFolder) ?? InsideRest(file.Path, realBase);
            string key = baseFolder;
            if (rest != null)
            {
                int i = rest.IndexOfAny(new[] { '\\', '/' });
                if (i >= 0)
                {
                    key = baseFolder + "\\" + rest.Substring(0, i);
                }
            }

            if (!groups.TryGetValue(key, out List<CrawlCandidate>? group))
            {
                group = new List<CrawlCandidate>();
                groups[key] = group;
            }

            group.Add(file);
        }

        var result = new Dictionary<string, Estimate>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in groups)
        {
            result[pair.Key] = Estimate(pair.Value, options, costs, durationOf, pagesOf);
        }

        return result;
    }

    private static string? InsideRest(string path, string baseFolder)
    {
        if (path.Length <= baseFolder.Length)
        {
            return null;
        }

        char sep = path[baseFolder.Length];
        if (sep != '\\' && sep != '/')
        {
            return null;
        }

        if (!path.StartsWith(baseFolder, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return path.Substring(baseFolder.Length + 1);
    }

    /// <summary>
    /// Page count from the PDF trailer's /Count (highest wins), 1 when unknown.
    /// Stands in for Swift's Spotlight-then-CGPDF lookup (Estimator.swift:133).
    /// </summary>
    public static int PdfPagesOf(string path)
    {
        try
        {
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long take = Math.Min(stream.Length, 65536);
            stream.Seek(stream.Length - take, SeekOrigin.Begin);
            var buffer = new byte[take];
            int read = 0;
            while (read < take)
            {
                int n = stream.Read(buffer, read, (int)(take - read));
                if (n == 0)
                {
                    break;
                }

                read += n;
            }

            int best = 0;
            foreach (Match match in PdfCount.Matches(Encoding.ASCII.GetString(buffer, 0, read)))
            {
                if (int.TryParse(match.Groups[1].Value, out int count))
                {
                    best = Math.Max(best, count);
                }
            }

            return best > 0 ? best : 1;
        }
        catch
        {
            return 1;
        }
    }

    /// <summary>
    /// No metadata-only duration source is wired on Windows yet (Swift uses
    /// Spotlight, then the file header). Returns 0; pass a real
    /// <c>durationOf</c> to <see cref="Estimate"/> when available.
    /// </summary>
    public static double DefaultDurationOf(string path) => 0.0;
}

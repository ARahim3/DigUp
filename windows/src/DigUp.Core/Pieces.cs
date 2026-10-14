// Shared shapes for the Windows indexing pipeline.
// Ports Sources/DigUpKit/Model.swift (FileKind, SegmentKind, Modality,
// IndexOptions, Prompts) and the piece types from MediaExtractors.swift,
// Extractors.swift and CodeExtractor.swift.
using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace DigUp.Core;

/// <summary>What a file is, for indexing and result grouping. (Model.swift:4)</summary>
public enum FileKind
{
    Screenshot,
    Image,
    Pdf,
    Doc,
    Audio,
    Video,
    Code,
}

public static class FileKindExtensions
{
    public static string ToStorageString(this FileKind kind) => kind switch
    {
        FileKind.Screenshot => "screenshot",
        FileKind.Image => "image",
        FileKind.Pdf => "pdf",
        FileKind.Doc => "doc",
        FileKind.Audio => "audio",
        FileKind.Video => "video",
        FileKind.Code => "code",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static FileKind ParseFileKind(string value) => value switch
    {
        "screenshot" => FileKind.Screenshot,
        "image" => FileKind.Image,
        "pdf" => FileKind.Pdf,
        "doc" => FileKind.Doc,
        "audio" => FileKind.Audio,
        "video" => FileKind.Video,
        "code" => FileKind.Code,
        _ => throw new ArgumentException($"Unknown file kind: {value}", nameof(value)),
    };
}

/// <summary>One searchable piece of a file. (Model.swift:17)</summary>
public enum SegmentKind
{
    Name,
    Image,
    Ocr,
    Page,
    PageImage,
    Chunk,
    Audio,
    Frame,
    Lines,
    Cells,
}

public static class SegmentKindExtensions
{
    public static string ToStorageString(this SegmentKind kind) => kind switch
    {
        SegmentKind.Name => "name",
        SegmentKind.Image => "image",
        SegmentKind.Ocr => "ocr",
        SegmentKind.Page => "page",
        SegmentKind.PageImage => "page_image",
        SegmentKind.Chunk => "chunk",
        SegmentKind.Audio => "audio",
        SegmentKind.Frame => "frame",
        SegmentKind.Lines => "lines",
        SegmentKind.Cells => "cells",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}

/// <summary>What produced a segment's vector. (Model.swift:32)</summary>
public enum Modality
{
    None,
    Text,
    Image,
    Audio,
}

/// <summary>
/// A stretch of audio (a file's window, or a video's soundtrack window) or a
/// video frame, written to a scratch file for the model.
/// Ports MediaPiece (MediaExtractors.swift:22). Times are seconds.
/// </summary>
public sealed record MediaPiece(string Path, double StartSeconds, double EndSeconds);

/// <summary>
/// An image downscaled for the model, with its original dimensions and the
/// EXIF DateTimeOriginal as written by the camera, if any.
/// Ports ImageExtractor.Prepared (Extractors.swift:28).
/// </summary>
public sealed record PreparedImage(string Path, int Width, int Height, string? Taken);

/// <summary>An image batch slot ready to embed, with its screenshot OCR text.</summary>
public sealed record ReadyImage(int Slot, PreparedImage Image, string Ocr);

/// <summary>
/// A PDF page: its text (possibly empty for scans), the rendered PNG path when
/// the page had too little text, OCR replacement flag, and glyph-order text
/// kept for a meaning vector only. Ports PDFExtractor.Page (Extractors.swift:97).
/// Number is 1-based.
/// </summary>
public sealed record PdfPage(int Number, string Text, string? ImagePath, bool Ocr = false, string? Garbled = null);

/// <summary>
/// A stretch of a code file: its text and its first/last lines (or notebook
/// cells), from 1. Ports CodeExtractor.Piece (CodeExtractor.swift:8).
/// </summary>
public sealed record CodePiece(string Text, int First, int Last);

/// <summary>Ports CodeExtractor.File (CodeExtractor.swift:13). Cells is null for non-notebooks.
/// CapNote is set when a long repo doc was read only partly (see MaxDocBytes).</summary>
public sealed record CodeFile(
    System.Collections.Generic.IReadOnlyList<CodePiece> Pieces,
    string Title,
    string? Repo,
    int Lines,
    int? Cells,
    string? CapNote = null);

/// <summary>
/// Indexing settings. Anything that changes vectors is part of
/// <see cref="Fingerprint"/>. Ports IndexOptions (Model.swift:37).
/// </summary>
public sealed class IndexOptions
{
    public bool Code { get; set; }
    public int CodeStretch { get; set; } = 1800;
    public int MaxCodeBytes { get; set; } = 1 << 20;
    public int MaxNotebookBytes { get; set; } = 20 << 20;
    /// <summary>Repo docs (md, txt and family) are read up to here, then
    /// capped instead of skipped: a 5 MB changelog still matches on its
    /// head. Part of the code fingerprint (it changes what's stored).</summary>
    public int MaxDocBytes { get; set; } = 200 << 10;
    public bool IncludeCode { get; set; }
    public bool IncludeDatasets { get; set; }
    public int MinImageSide { get; set; } = 256;
    public int BigPdfPages { get; set; } = 50;
    public int PdfStep { get; set; } = 30;
    public int DocStep { get; set; } = 40;
    public int MaxPages { get; set; } = 5_000;
    public int MaxChunks { get; set; } = 5_000;
    public int MinPageText { get; set; } = 200;
    public int PhotoBudget { get; set; } = 140;
    public int ScreenshotBudget { get; set; } = 280;
    public int PageBudget { get; set; } = 280;
    public int FrameBudget { get; set; } = 70;
    public double FrameInterval { get; set; } = 3.0;
    public double AudioWindow { get; set; } = 30.0;
    public double AudioHop { get; set; } = 25.0;
    public System.Collections.Generic.List<string> ExcludedFolders { get; set; } = new();
    public System.Collections.Generic.HashSet<string> ExcludedExtensions { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Port-local fingerprint (Model.swift:80). NOTE: the double formatting
    /// differs from Swift ("3" vs "3.0"); it is stable within this port and
    /// must never be compared against indexes built by the Swift app.
    /// </summary>
    public string Fingerprint
    {
        get
        {
            var culture = CultureInfo.InvariantCulture;
            if (Code)
            {
                return string.Format(culture, "code1 lines{0} doc{1}", CodeStretch, MaxDocBytes);
            }

            return string.Format(
                culture,
                "photo{0} shot{1} page{2} frame{3}/{4}s audio{5}/{6}s",
                PhotoBudget, ScreenshotBudget, PageBudget, FrameBudget, FrameInterval,
                AudioWindow, AudioHop);
        }
    }

    /// <summary>File extensions as people write them ("HEIC, .txt *.md"). (Model.swift:74)</summary>
    public static System.Collections.Generic.HashSet<string> ParseExtensions(string text)
    {
        var set = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var word in text.Split(new[] { ',', ' ', '\t', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var cleaned = word.TrimStart('*', '.').ToLowerInvariant();
            if (cleaned.Length > 0)
            {
                set.Add(cleaned);
            }
        }

        return set;
    }
}

/// <summary>EmbeddingGemma task prompts (model card). Ports Prompts (Model.swift:89).</summary>
public static class Prompts
{
    public static string Query(string text) => $"task: search result | query: {text}";

    public static string CodeQuery(string text) => $"task: code retrieval | query: {text}";

    public static string Document(string? title, string text) =>
        $"title: {(string.IsNullOrEmpty(title) ? "none" : title)} | text: {text}";
}

/// <summary>
/// Whether text says something in words: at least a fifth of what isn't space
/// is letters (marks count). Ports SearchText.hasWords (SearchText.swift:37).
/// Digit-heavy pages/chunks get keyword search only.
/// </summary>
public static class TextStats
{
    public static bool HasWords(string text)
    {
        int letters = 0, others = 0;
        foreach (char c in text)
        {
            if (char.IsWhiteSpace(c))
            {
                continue;
            }

            switch (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c))
            {
                case UnicodeCategory.UppercaseLetter:
                case UnicodeCategory.LowercaseLetter:
                case UnicodeCategory.TitlecaseLetter:
                case UnicodeCategory.ModifierLetter:
                case UnicodeCategory.OtherLetter:
                case UnicodeCategory.NonSpacingMark:
                case UnicodeCategory.SpacingCombiningMark:
                case UnicodeCategory.EnclosingMark:
                    letters++;
                    break;
                default:
                    others++;
                    break;
            }
        }

        return letters > 0 && letters * 4 >= others;
    }
}

/// <summary>One line, at most <paramref name="limit"/> characters, for result lists. (Extractors.swift:249)</summary>
public static class Excerpt
{
    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.Compiled);

    public static string Of(string text, int limit = 240)
    {
        string line = Whitespace.Replace(text, " ").Trim();
        return line.Length > limit ? line.Substring(0, limit) + "…" : line;
    }
}

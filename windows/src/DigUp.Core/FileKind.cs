// FileKind helpers: first-pass order and media grouping.
// Ports the FileKind bits of Model.swift not already ported: FileKind itself
// and IndexOptions live in Pieces.cs; this file adds the indexing-pass order
// (FileKind.indexingOrderSQL, Model.swift:10) and a media-kind test used by
// the crawler's dataset filter.

namespace DigUp.Core;

/// <summary>
/// The order of the first indexing pass: what people look for most comes
/// first. Ports FileKind.indexingOrderSQL (Model.swift:10).
/// </summary>
public static class FileKindOrder
{
    /// <summary>
    /// Same CASE as Swift, for ORDER BY over the store (kind is stored with
    /// <see cref="FileKindExtensions.ToStorageString"/>).
    /// </summary>
    public const string IndexingOrderSql =
        "CASE kind WHEN 'screenshot' THEN 0 WHEN 'image' THEN 1 WHEN 'pdf' THEN 2 WHEN 'doc' THEN 3 " +
        "WHEN 'audio' THEN 4 WHEN 'video' THEN 5 ELSE 6 END";

    /// <summary>0-based place in the first pass (code sorts last, like Swift's ELSE 6).</summary>
    public static int PassOrder(FileKind kind) => kind switch
    {
        FileKind.Screenshot => 0,
        FileKind.Image => 1,
        FileKind.Pdf => 2,
        FileKind.Doc => 3,
        FileKind.Audio => 4,
        FileKind.Video => 5,
        _ => 6,
    };

    /// <summary>Image-like, audio or video: the kinds a dataset folder can hold (Rules.swift:175).</summary>
    public static bool IsMedia(FileKind kind) => kind is FileKind.Screenshot
        or FileKind.Image
        or FileKind.Audio
        or FileKind.Video;
}

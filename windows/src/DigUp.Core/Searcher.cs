using System.Text.RegularExpressions;

namespace DigUp.Core;

public sealed record SearchHit(
    string Path,
    FileKind Kind,
    double Score,
    double? Z,
    double? Cosine,
    int? KeywordRank,
    SegmentKind Segment,
    long SegmentId,
    double? Loc,
    double? LocEnd,
    string? Excerpt,
    double Modified,
    long Size,
    Dictionary<string, string> Info)
{
    /// <summary>Code: the line to open at, in the stretch (loc…loc_end). Null: the
    /// stretch's first line.</summary>
    public double? Focus { get; set; }
}

/// <summary>Hybrid search: meaning (the model's vectors) + words (FTS5).
/// Ports Searcher.swift.</summary>
public sealed class Searcher : IDisposable
{
    private readonly IndexStore _store;
    private VectorStore? _vectors;
    private bool _disposed;
    // Keystroke searches share one searcher across threads while Reload
    // rebuilds these lists and Dispose frees them: every touch is gated,
    // so an in-flight search never sees a half-built or freed state.
    private readonly object _gate = new();
    private readonly List<long> _rowFile = new();
    private readonly List<long> _rowSegment = new();
    private readonly List<Modality> _rowModality = new();
    /// <summary>False for the vectors the later pass adds: scored, but they don't set the scale.</summary>
    private readonly List<bool> _rowSetsScale = new();
    private readonly Dictionary<long, FileKind> _fileKind = new();

    public string? VectorSource { get; private set; }
    /// <summary>False after <see cref="ReleaseVectors"/>: keyword search still works,
    /// and the next search with a query vector loads them again.</summary>
    public bool VectorsLoaded { get; private set; }

    public int VectorCount { get { lock (_gate) return _rowFile.Count; } }

    /// <summary>This is the code index's searcher: names are looked up as names.</summary>
    public bool IsCode =>
        System.IO.Path.GetFileName(_store.FilePath).Equals(IndexStore.CodeFile, StringComparison.Ordinal);

    public const double WordWeight = 2.0;
    public const double CodeWordWeight = 1.0;

    /// <summary>With <paramref name="loadVectors"/> false only keyword search is ready;
    /// vectors load on the first meaning search.</summary>
    public Searcher(IndexStore store, bool loadVectors = true)
    {
        _store = store;
        if (loadVectors)
            Reload();
        else
            ReloadFiles();
    }

    /// <summary>Reads the files and all vectors again (after indexing added some).</summary>
    public void Reload()
    {
        lock (_gate)
        {
            ReloadLocked();
        }
    }

    private void ReloadLocked()
    {
        ReleaseVectors();
        ReloadFiles();
        int rows = 0;
        _store.Db.Query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL",
            r => { rows = (int)r.GetInt64(0); });
        if (rows <= 0)
        {
            VectorsLoaded = true; // nothing to load
            return;
        }
        var matrix = VectorStore.Create(rows);
        if (matrix is null)
        {
            VectorsLoaded = true;
            return;
        }
        var steps = new IndexOptions();
        try
        {
            _store.Db.Query("SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, " +
                            "CAST(json_extract(f.info, '$.pages') AS INTEGER) " +
                            "FROM segments s JOIN files f ON f.id = s.file " +
                            "WHERE s.vec IS NOT NULL ORDER BY s.id", r =>
            {
                byte[]? blob = r.NullableBlob(3);
                if (blob is null || blob.Length != Vectors.BytesPerVector || _rowFile.Count >= rows)
                    return;
                matrix.SetRow(_rowFile.Count, blob);
                _rowSegment.Add(r.GetInt64(0));
                _rowFile.Add(r.GetInt64(1));
                _rowModality.Add(ModalityStrings.Parse(r.NullableText(2)));
                // Past the first step of a long PDF (its pages) or document (its chunks).
                string kind = r.NullableText(4) ?? "";
                int place = r.IsDBNull(5) ? 0 : (int)r.GetDouble(5);
                string fileKind = r.NullableText(6) ?? "";
                int pages = r.IsDBNull(7) ? 0 : (int)r.GetInt64(7);
                bool later = fileKind == "pdf"
                    ? kind != SegmentKind.Chunk.ToStorageString() && pages > steps.BigPdfPages && place > steps.PdfStep
                    : kind == SegmentKind.Chunk.ToStorageString() && place > steps.DocStep;
                _rowSetsScale.Add(!later);
            });
        }
        catch
        {
            matrix.Dispose();
            throw;
        }
        _vectors = matrix;
        VectorsLoaded = true;
    }

    /// <summary>Frees the vectors' memory; keyword search keeps working.</summary>
    public void ReleaseVectors()
    {
        lock (_gate)
        {
            _vectors?.Dispose();
            _vectors = null;
            _rowFile.Clear();
            _rowSegment.Clear();
            _rowModality.Clear();
            _rowSetsScale.Clear();
            VectorsLoaded = false;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
                return;
            _disposed = true;
            _vectors?.Dispose();
            _vectors = null;
            _rowFile.Clear();
            _rowSegment.Clear();
            _rowModality.Clear();
            _rowSetsScale.Clear();
            VectorsLoaded = false;
        }
    }

    private void ReloadFiles()
    {
        _fileKind.Clear();
        _store.Db.Query("SELECT id, kind FROM files",
            r => { _fileKind[r.GetInt64(0)] = FileKindStrings.Parse(r.NullableText(1)); });
        VectorSource = _store.Meta("vector_source");
    }

    public List<SearchHit> Search(
        string text,
        IReadOnlyList<float>? queryVector,
        HashSet<FileKind>? kinds = null,
        int limit = 20,
        double zGate = 2.0,
        double? wordWeight = null,
        bool prefixLast = false)
    {
        // One search at a time per searcher: Reload/Dispose wait instead of
        // pulling the vectors out from under a running search.
        lock (_gate)
        {
            return SearchLocked(text, queryVector, kinds, limit, zGate, wordWeight, prefixLast);
        }
    }

    private List<SearchHit> SearchLocked(
        string text,
        IReadOnlyList<float>? queryVector,
        HashSet<FileKind>? kinds,
        int limit,
        double zGate,
        double? wordWeight,
        bool prefixLast)
    {
        text = TextSanitize.Clean(text); // typed or pasted text can hold lone surrogates
        double ww = wordWeight ?? (IsCode ? CodeWordWeight : WordWeight);
        if (queryVector is not null && !VectorsLoaded)
            Reload();
        var fileKind = _fileKind;
        bool Allowed(long file) =>
            kinds is null || (fileKind.TryGetValue(file, out var k) && kinds.Contains(k));

        // Meaning: score every vector on this query's scale, keep each file's best segment.
        var best = new Dictionary<long, (double Z, double Cosine, int Row)>();
        if (queryVector is not null && queryVector.Count == Vectors.Dimension && _rowFile.Count > 0)
        {
            float[] scores = Score(queryVector);
            double[] meaning = VectorMath.Meaning(scores, _rowModality, _rowSetsScale);
            for (int row = 0; row < scores.Length; row++)
            {
                if (!Allowed(_rowFile[row]))
                    continue;
                double z = meaning[row];
                if (!best.TryGetValue(_rowFile[row], out var prev) || z > prev.Z)
                    best[_rowFile[row]] = (z, scores[row], row);
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page
        // and document text. A name from code is matched as one phrase, as written.
        List<string> terms = Terms(text);
        List<string>? identifier = IsCode ? CodeLookup.Identifier(text) : null;
        var words = new List<(long File, long Segment, string? Snippet)>();
        var coverage = new Dictionary<long, double>();
        List<string> patterns = identifier is not null
            ? new List<string> { CodeLookup.Phrase(identifier) }
            : Patterns(terms, prefixLast);
        if (patterns.Count > 0)
        {
            var seen = new HashSet<long>();
            _store.Db.Query("SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts " +
                            "JOIN segments s ON s.id = fts.rowid " +
                            "WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000",
                new[] { SqlValue.Text(string.Join(" OR ", patterns)) }, r =>
                {
                    long file = r.GetInt64(0);
                    if (words.Count >= 100 || !Allowed(file) || !seen.Add(file))
                        return;
                    string? original = r.NullableText(3);
                    string? fallback = r.NullableText(2);
                    string? snippet = fallback;
                    if (original is not null)
                    {
                        // One poisoned row must not kill the search: fall back
                        // to SQLite's snippet when ours can't handle the text.
                        try { snippet = SearchText.Snippet(original, terms) ?? fallback; }
                        catch { snippet = fallback; }
                    }
                    words.Add((file, r.GetInt64(1), snippet));
                });
            if (words.Count > 0)
            {
                string files = string.Join(",", words.Select(w => w.File));
                foreach (string pattern in patterns)
                {
                    _store.Db.Query("SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid " +
                                    "WHERE fts MATCH ? AND s.file IN (" + files + ")",
                        new[] { SqlValue.Text(pattern) }, r =>
                        {
                            coverage[r.GetInt64(0)] =
                                coverage.GetValueOrDefault(r.GetInt64(0)) + 1.0 / patterns.Count;
                        });
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half
        // of the query's words. Score: meaning z + a bonus that grows with word
        // coverage, + 1 for the kind the query asks for.
        bool lookup = IsLookup(terms) || identifier is not null;
        double meaningWeight = lookup ? 0.5 : 1;
        double wordsWeight = lookup ? ww * 2 : ww;
        var hinted = KindHints(text);
        var candidates = new HashSet<long>();
        foreach (var kv in best)
        {
            if (kv.Value.Z >= zGate)
                candidates.Add(kv.Key);
        }
        foreach (var kv in coverage)
        {
            if (kv.Value >= 0.5)
                candidates.Add(kv.Key);
        }
        var scored = new Dictionary<long, double>();
        foreach (long file in candidates)
        {
            double s = meaningWeight * Math.Max(best.TryGetValue(file, out var b) ? b.Z : 0, 0) +
                       wordsWeight * Math.Pow(coverage.GetValueOrDefault(file), 1.5);
            if (fileKind.TryGetValue(file, out var k) && hinted.Contains(k))
                s += 1;
            scored[file] = s;
        }

        var wordRank = new Dictionary<long, (int Rank, (long Segment, string? Snippet) Match)>();
        for (int i = 0; i < words.Count; i++)
        {
            if (!wordRank.ContainsKey(words[i].File))
                wordRank[words[i].File] = (i + 1, (words[i].Segment, words[i].Snippet));
        }

        var hits = new List<SearchHit>();
        foreach (var kv in scored.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(limit))
        {
            long file = kv.Key;
            double score = kv.Value;
            int rank = hits.Count;
            bool hasSemantic = best.TryGetValue(file, out var semantic);
            bool hasKeyword = wordRank.TryGetValue(file, out var keyword);
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            bool useMeaning = hasSemantic && (semantic.Z >= zGate || !hasKeyword);
            if ((!useMeaning && !hasKeyword) || (useMeaning && !hasSemantic))
                continue;
            long segmentId = useMeaning ? _rowSegment[semantic.Row] : keyword.Match.Segment;
            double? focus = null;
            if (IsCode)
            {
                (segmentId, focus) = CodePlace(file, segmentId,
                    rank < 10 ? identifier : null, text, terms,
                    hasKeyword && keyword.Match.Segment == segmentId || identifier is not null);
            }
            string path = "";
            FileKind kind = FileKind.Doc;
            double modified = 0;
            long size = 0;
            var info = new Dictionary<string, string>();
            _store.Db.Query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?",
                new[] { SqlValue.Int(file) }, r =>
                {
                    path = r.NullableText(0) ?? "";
                    kind = FileKindStrings.Parse(r.NullableText(1));
                    modified = r.GetDouble(2);
                    size = r.GetInt64(3);
                    string? json = r.NullableText(4);
                    if (json is not null)
                    {
                        try
                        {
                            info = System.Text.Json.JsonSerializer
                                       .Deserialize<Dictionary<string, string>>(json) ??
                                   new Dictionary<string, string>();
                        }
                        catch (System.Text.Json.JsonException) { }
                    }
                });
            SegmentKind segment = SegmentKind.Name;
            double? loc = null, locEnd = null;
            string? storedExcerpt = null;
            _store.Db.Query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ?",
                new[] { SqlValue.Int(segmentId) }, r =>
                {
                    segment = SegmentKindStrings.Parse(r.NullableText(0));
                    loc = r.IsDBNull(1) ? null : r.GetDouble(1);
                    locEnd = r.IsDBNull(2) ? null : r.GetDouble(2);
                    storedExcerpt = r.NullableText(3);
                });
            // Quote the matched words only when they come from the segment we point at.
            // A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text.
            string? snippet = null;
            if (hasKeyword && keyword.Match.Segment == segmentId && keyword.Match.Snippet is not null &&
                keyword.Match.Snippet.Contains('«'))
                snippet = Excerpt(keyword.Match.Snippet, 400);
            if (snippet is null && storedExcerpt is null && loc is null && hasKeyword &&
                keyword.Match.Snippet is not null && keyword.Match.Snippet.Contains('«'))
            {
                string? matchedKind = null;
                _store.Db.Query("SELECT kind FROM segments WHERE id = ?",
                    new[] { SqlValue.Int(keyword.Match.Segment) },
                    r => { matchedKind = r.NullableText(0); });
                if (matchedKind != SegmentKind.Name.ToStorageString())
                    snippet = Excerpt(keyword.Match.Snippet, 400);
            }
            var hit = new SearchHit(path, kind, score,
                hasSemantic ? semantic.Z : null, hasSemantic ? semantic.Cosine : null,
                hasKeyword ? keyword.Rank : null, segment, segmentId, loc, locEnd,
                snippet ?? storedExcerpt, modified, size, info)
            {
                Focus = focus,
            };
            hits.Add(hit);
        }
        return hits;
    }

    /// <summary>Code: the stretch to point at, and the line in it to open at.</summary>
    private (long Segment, double? Focus) CodePlace(
        long file, long segment, List<string>? identifier, string query,
        List<string> terms, bool wordsHere)
    {
        string name = query.Trim().Replace("()", "", StringComparison.Ordinal);
        if (identifier is not null)
        {
            (long Segment, int Line, int Strength)? foundBest = null;
            _store.Db.Query("SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts " +
                            "JOIN segments s ON s.id = fts.rowid " +
                            "WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300",
                new[] { SqlValue.Text(CodeLookup.Phrase(identifier)), SqlValue.Int(file) }, r =>
                {
                    if ((foundBest?.Strength ?? 0) >= 2)
                        return;
                    string? text = r.NullableText(2);
                    if (text is null)
                        return;
                    // Name rows have no place (loc is NULL): definitions live in line stretches.
                    if (r.IsDBNull(1))
                        return;
                    var found = CodeLookup.DefinitionOf(name, text, (int)r.GetDouble(1));
                    if (found is not null && found.Value.Strength > (foundBest?.Strength ?? 0))
                        foundBest = (r.GetInt64(0), found.Value.Line, found.Value.Strength);
                });
            if (foundBest is not null)
                return (foundBest.Value.Segment, foundBest.Value.Line);
        }
        if ((!wordsHere && identifier is null) || TextOfSegment(segment) is not string text)
            return (segment, null);
        int first = 1; // name rows have no place: point at the file's first line
        _store.Db.Query("SELECT loc FROM segments WHERE id = ?",
            new[] { SqlValue.Int(segment) }, r => { if (!r.IsDBNull(0)) first = (int)r.GetDouble(0); });
        var words = identifier is null ? terms : new List<string> { name.ToLowerInvariant() };
        int? line = CodeLookup.FirstLineWith(words, text, first);
        return (segment, line is null ? null : (double?)line.Value);
    }

    /// <summary>Codes and IDs ("K7Q2LM", "TRX50") and long numbers mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words
    /// double and meaning half.</summary>
    public static bool IsLookup(List<string> terms) =>
        terms.Count > 0 && terms.All(t =>
            t.Any(char.IsDigit) && (t.Any(char.IsLetter) || t.Length >= 4));

    /// <summary>How many of <paramref name="hits"/> (best first) are strong: scoring at
    /// least <paramref name="ratio"/> × the top hit.</summary>
    public static int StrongCount(List<SearchHit> hits, double ratio = 0.5)
    {
        if (hits.Count == 0 || hits[0].Score <= 0)
            return hits.Count;
        double top = hits[0].Score;
        int n = 0;
        while (n < hits.Count && hits[n].Score >= top * ratio)
            n++;
        return n;
    }

    /// <summary>Cosine similarity of <paramref name="query"/> with every stored vector
    /// (all are L2-normalized): a matrix-vector product, done a block of rows at a time,
    /// each block turned into float32 first.</summary>
    private float[] Score(IReadOnlyList<float> query)
    {
        int rows = _rowFile.Count;
        var scores = new float[rows];
        if (_vectors is null || rows == 0)
            return scores;
        float[] q = query is float[] arr ? arr : query.ToArray();
        var block = new float[VectorStore.BlockRows * Vectors.Dimension];
        int row = 0;
        while (row < rows)
        {
            int count = Math.Min(VectorStore.BlockRows, rows - row);
            _vectors.CopyBlockAsFloat(row, count, block);
            for (int r = 0; r < count; r++)
            {
                double dot = 0;
                int off = r * Vectors.Dimension;
                for (int d = 0; d < Vectors.Dimension; d++)
                    dot += (double)block[off + d] * q[d];
                scores[row + r] = (float)dot;
            }
            row += count;
        }
        return scores;
    }

    /// <summary>The text of a page, a document's passage or a screenshot's OCR, as it's
    /// written: the preview shows the part of a document that matched.</summary>
    public string? TextOfSegment(long id)
    {
        string? text = null;
        _store.Db.Query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?",
            new[] { SqlValue.Int(id) }, r => { text = r.NullableText(0); });
        return text;
    }

    public static readonly HashSet<string> Stopwords = new(StringComparer.Ordinal)
    {
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me",
        "that", "this", "these", "those", "from", "about", "where", "what", "which", "who",
        "when", "is", "was", "are", "were", "be", "it", "its", "some", "any", "find", "show",
        "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as Terms sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে",
        "কোথায়", "কোন", "কী", "কি", "যে", "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    };

    /// <summary>The content words of a query, normalized as keyword search keeps its text.
    /// Kind words and stopwords are dropped. Words of two letters or more count.</summary>
    public static List<string> Terms(string text)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<string>();
        foreach (var token in SearchText.Normalized(text).ToLowerInvariant()
                     .Split(Array.Empty<char>()))
        {
            // Split on anything that isn't a letter or digit (mirrors Swift's
            // components(separatedBy: alphanumerics.inverted)).
            foreach (var piece in SplitWords(token))
            {
                if (piece.EnumerateRunes().Count() >= 2 &&
                    !Stopwords.Contains(piece) && seen.Add(piece))
                    output.Add(piece);
            }
        }
        return output;
    }

    private static IEnumerable<string> SplitWords(string token)
    {
        int start = -1;
        for (int i = 0; i < token.Length; i++)
        {
            if (char.IsLetterOrDigit(token[i]))
            {
                if (start < 0)
                    start = i;
            }
            else if (start >= 0)
            {
                yield return token.Substring(start, i - start);
                start = -1;
            }
        }
        if (start >= 0)
            yield return token.Substring(start);
    }

    /// <summary>FTS5 patterns for the query's words: quoted, and as prefixes for the last
    /// word while it's being typed and for words of languages that attach endings.</summary>
    public static List<string> Patterns(List<string> terms, bool prefixLast)
    {
        var output = new List<string>(terms.Count);
        for (int i = 0; i < terms.Count; i++)
        {
            bool prefix = (prefixLast && i == terms.Count - 1) || SearchText.Inflects(terms[i]);
            output.Add("\"" + terms[i] + "\"" + (prefix ? "*" : ""));
        }
        return output;
    }

    /// <summary>The query's words as an FTS5 OR-query.</summary>
    public static string? FtsQuery(string text, bool prefixLast = false)
    {
        var words = Terms(text);
        return words.Count == 0 ? null : string.Join(" OR ", Patterns(words, prefixLast));
    }

    public static readonly Dictionary<string, FileKind> KindWords = new(StringComparer.Ordinal)
    {
        ["screenshot"] = FileKind.Screenshot,
        ["screenshots"] = FileKind.Screenshot,
        ["photo"] = FileKind.Image,
        ["photos"] = FileKind.Image,
        ["picture"] = FileKind.Image,
        ["pictures"] = FileKind.Image,
        ["image"] = FileKind.Image,
        ["images"] = FileKind.Image,
        ["pdf"] = FileKind.Pdf,
        ["pdfs"] = FileKind.Pdf,
        ["paper"] = FileKind.Pdf,
        ["papers"] = FileKind.Pdf,
        ["document"] = FileKind.Doc,
        ["documents"] = FileKind.Doc,
        ["note"] = FileKind.Doc,
        ["notes"] = FileKind.Doc,
        ["video"] = FileKind.Video,
        ["videos"] = FileKind.Video,
        ["clip"] = FileKind.Video,
        ["movie"] = FileKind.Video,
        ["audio"] = FileKind.Audio,
        ["song"] = FileKind.Audio,
        ["podcast"] = FileKind.Audio,
        ["voice"] = FileKind.Audio,
        ["sound"] = FileKind.Audio,
        ["স্ক্রিনশট"] = FileKind.Screenshot,
        ["ছবি"] = FileKind.Image,
        ["পিডিএফ"] = FileKind.Pdf,
        ["নোট"] = FileKind.Doc,
        ["ভিডিও"] = FileKind.Video,
        ["অডিও"] = FileKind.Audio,
        ["গান"] = FileKind.Audio,
        ["রেকর্ডিং"] = FileKind.Audio,
        ["لقطة"] = FileKind.Screenshot,
        ["صورة"] = FileKind.Image,
        ["صور"] = FileKind.Image,
        ["مستند"] = FileKind.Doc,
        ["ملاحظات"] = FileKind.Doc,
        ["فيديو"] = FileKind.Video,
        ["مقطع"] = FileKind.Video,
        ["صوت"] = FileKind.Audio,
        ["تسجيل"] = FileKind.Audio,
        ["اغنية"] = FileKind.Audio,
    };

    /// <summary>Kinds the query asks for ("…in a video", "screenshot of…"): a soft boost,
    /// not a filter.</summary>
    public static HashSet<FileKind> KindHints(string text)
    {
        var hints = new HashSet<FileKind>();
        foreach (var word in SearchText.Normalized(text).ToLowerInvariant()
                     .Split(Array.Empty<char>()))
        {
            foreach (var piece in SplitWords(word))
            {
                if (KindWords.TryGetValue(piece, out var kind))
                {
                    hints.Add(kind);
                    continue;
                }
                foreach (var kv in KindWords)
                {
                    if (SearchText.Inflects(kv.Key) &&
                        kv.Key.EnumerateRunes().Count() >= 3 &&
                        piece.StartsWith(kv.Key, StringComparison.Ordinal))
                    {
                        hints.Add(kv.Value);
                        break;
                    }
                }
            }
        }
        return hints;
    }

    /// <summary>One line, at most <paramref name="limit"/> characters: for result lists.</summary>
    internal static string Excerpt(string text, int limit = 240)
    {
        string line = Regex.Replace(TextSanitize.Clean(text), @"\s+", " ").Trim();
        return line.EnumerateRunes().Count() > limit
            ? string.Concat(line.EnumerateRunes().Take(limit)) + "…"
            : line;
    }
}

/// <summary>Names in code: a query that's a name finds it exactly, and the place that
/// defines it rather than every place that uses it. Ports CodeLookup.</summary>
public static class CodeLookup
{
    private static readonly Regex IdentifierChars =
        new(@"^[A-Za-z_$][A-Za-z0-9_$]*(?:(?:\.|::|->|#)[A-Za-z_$][A-Za-z0-9_$]*)*$",
            RegexOptions.Compiled);

    /// <summary>The words keyword search keeps a name from code as, when the query is
    /// one: snake_case, camelCase, dotted, or with digits. Null for words anyone would
    /// say ("retry", "Renamer").</summary>
    public static List<string>? Identifier(string query)
    {
        string name = query.Trim();
        if (name.EndsWith("()", StringComparison.Ordinal))
            name = name.Substring(0, name.Length - 2);
        if (!IdentifierChars.IsMatch(name))
            return null;
        bool hasLower = name.Any(char.IsLower);
        bool camel = name.Skip(1).Any(char.IsUpper) && hasLower;
        if (!camel && !name.Any(c => "_.:#$".Contains(c) || char.IsDigit(c)))
            return null;
        return name.ToLowerInvariant().Split(Array.Empty<char>())
            .SelectMany(SplitName).Where(w => w.Length > 0).ToList();
    }

    private static IEnumerable<string> SplitName(string token)
    {
        int start = -1;
        for (int i = 0; i < token.Length; i++)
        {
            if (char.IsLetterOrDigit(token[i]))
            {
                if (start < 0)
                    start = i;
            }
            else if (start >= 0)
            {
                yield return token.Substring(start, i - start);
                start = -1;
            }
        }
        if (start >= 0)
            yield return token.Substring(start);
    }

    /// <summary>The keyword search pattern for an identifier's words: one phrase, so they
    /// match only side by side, as written.</summary>
    public static string Phrase(List<string> words) => "\"" + string.Join(" ", words) + "\"";

    /// <summary>Where <paramref name="name"/> is defined in <paramref name="text"/> (a
    /// stretch whose first line is <paramref name="first"/>): the line, and how surely.
    /// Null when the stretch only uses it.</summary>
    public static (int Line, int Strength)? DefinitionOf(string name, string text, int first)
    {
        (int Line, int Strength)? best = null;
        var lines = Lines(text);
        for (int offset = 0; offset < lines.Count; offset++)
        {
            foreach (var range in Occurrences(name, lines[offset]))
            {
                string before = lines[offset].Substring(0, range.Start).Trim();
                string after = lines[offset].Substring(range.Start + range.Length).Trim();
                int strength = DefinitionStrength(before, after, lines[offset]);
                if (strength > (best?.Strength ?? 0))
                    best = (first + offset, strength);
                if (strength == 2)
                    return best;
            }
        }
        return best;
    }

    public static bool DefinesSomething(string word) =>
        Definers.Contains(word) && word != "let" && word != "var" && word != "const" && word != "val";

    private static readonly HashSet<string> Definers = new(StringComparer.Ordinal)
    {
        "def", "func", "fn", "fun", "function", "class", "struct", "enum", "protocol",
        "interface", "trait", "type", "typealias", "actor", "extension", "impl", "module",
        "namespace", "object", "record", "macro", "const", "let", "var", "val", "union",
        "mod", "sub", "@interface", "@implementation", "@protocol", "#define", "function*",
    };

    private static readonly HashSet<string> Users = new(StringComparer.Ordinal)
    {
        "return", "await", "yield", "throw", "new", "else", "case", "print", "echo", "assert",
        "not", "and", "or", "in", "is", "do", "go", "defer", "try", "catch", "if", "while",
        "for", "typeof", "delete", "raise", "import", "from",
    };

    private static int DefinitionStrength(string before, string after, string line)
    {
        string previous = before.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
            .LastOrDefault() ?? "";
        if (Definers.Contains(previous))
            return 2;
        if (before.StartsWith("func (", StringComparison.Ordinal) && before.EndsWith(")", StringComparison.Ordinal))
            return 2; // a Go method
        if (before.StartsWith("- (", StringComparison.Ordinal) || before.StartsWith("+ (", StringComparison.Ordinal))
            return after.StartsWith(":", StringComparison.Ordinal) || after.Length == 0 ||
                   after.StartsWith("{", StringComparison.Ordinal) || after.StartsWith(";", StringComparison.Ordinal)
                ? 2 : 0; // an Objective-C method
        // C-style: "static void name(…) {", not a call or an assignment.
        if (!after.StartsWith("(", StringComparison.Ordinal) || before.Length == 0 ||
            Users.Contains(previous) || before.Any(c => "=(,.!?".Contains(c)) ||
            before.Contains("->", StringComparison.Ordinal))
            return 0;
        char last = before[^1];
        if (!(char.IsLetter(last) || char.IsDigit(last) || "*&>_]".Contains(last)))
            return 0;
        return line.Trim().EndsWith(";", StringComparison.Ordinal) ? 1 : 2;
    }

    /// <summary>The line (from <paramref name="first"/>) to open at for
    /// <paramref name="words"/>. Null when none is there.</summary>
    public static int? FirstLineWith(List<string> words, string text, int first)
    {
        var wanted = words.Where(w => w.Length >= 2).Select(w => w.ToLowerInvariant()).ToList();
        if (wanted.Count == 0)
            return null;
        int? firstCode = null, firstAny = null;
        var lines = Lines(text);
        for (int offset = 0; offset < lines.Count; offset++)
        {
            if (!wanted.Any(w => Has(w, lines[offset])))
                continue;
            string trimmed = lines[offset].Trim();
            if (trimmed.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
                    .Take(4).Any(w => DefinesSomething(w)))
                return first + offset;
            if (firstCode is null && !CommentStarts.Any(trimmed.StartsWith))
                firstCode = offset;
            firstAny ??= offset;
        }
        int? found = firstCode ?? firstAny;
        return found is null ? null : first + found.Value;
    }

    private static readonly string[] CommentStarts =
        { "//", "#", "/*", "*", "--", "\"\"\"", "'''", "<!--", ";" };

    private static bool Has(string word, string line)
    {
        string lower = line.ToLowerInvariant();
        int searchStart = 0;
        while (true)
        {
            int found = lower.IndexOf(word, searchStart, StringComparison.Ordinal);
            if (found < 0)
                return false;
            if (found == 0 ||
                (!char.IsLetter(lower[found - 1]) && !char.IsDigit(lower[found - 1])) ||
                (found < line.Length && char.IsUpper(line[found])))
                return true;
            searchStart = found + word.Length;
        }
    }

    private static List<string> Lines(string text) =>
        text.Replace("\r\n", "\n").Split('\n').ToList();

    private static List<(int Start, int Length)> Occurrences(string name, string line)
    {
        var found = new List<(int, int)>();
        int start = 0;
        while (start <= line.Length)
        {
            int at = line.IndexOf(name, start, StringComparison.OrdinalIgnoreCase);
            if (at < 0)
                break;
            bool clearBefore = at == 0 || !IsNameCharacter(line[at - 1]);
            bool clearAfter = at + name.Length >= line.Length || !IsNameCharacter(line[at + name.Length]);
            if (clearBefore && clearAfter)
                found.Add((at, name.Length));
            start = at + name.Length;
        }
        return found;
    }

    private static bool IsNameCharacter(char c) =>
        char.IsLetter(c) || char.IsDigit(c) || c == '_' || c == '$';
}

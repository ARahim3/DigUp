using System.Text.Json;

namespace DigUp.Core;

// ---------- Model helpers (enums live in Pieces.cs) ----------

/// <summary>FileKind parsing with a fallback for unknown stored values
/// (FileKindExtensions.ParseFileKind throws; the store must tolerate them).</summary>
public static class FileKindStrings
{
    public static FileKind Parse(string? raw) => raw switch
    {
        "screenshot" => FileKind.Screenshot,
        "image" => FileKind.Image,
        "pdf" => FileKind.Pdf,
        "doc" => FileKind.Doc,
        "audio" => FileKind.Audio,
        "video" => FileKind.Video,
        "code" => FileKind.Code,
        _ => FileKind.Doc,
    };
}

/// <summary>SegmentKind parsing with a fallback for unknown stored values.</summary>
public static class SegmentKindStrings
{
    public static SegmentKind Parse(string? raw) => raw switch
    {
        "name" => SegmentKind.Name,
        "image" => SegmentKind.Image,
        "ocr" => SegmentKind.Ocr,
        "page" => SegmentKind.Page,
        "page_image" => SegmentKind.PageImage,
        "chunk" => SegmentKind.Chunk,
        "audio" => SegmentKind.Audio,
        "frame" => SegmentKind.Frame,
        "lines" => SegmentKind.Lines,
        "cells" => SegmentKind.Cells,
        _ => SegmentKind.Chunk,
    };
}

/// <summary>Modality storage strings (Modality itself lives in Pieces.cs).</summary>
public static class ModalityStrings
{
    public static string Raw(Modality modality) => modality switch
    {
        Modality.None => "none",
        Modality.Text => "text",
        Modality.Image => "image",
        Modality.Audio => "audio",
        _ => "none",
    };

    public static Modality Parse(string? raw) => raw switch
    {
        "none" => Modality.None,
        "text" => Modality.Text,
        "image" => Modality.Image,
        "audio" => Modality.Audio,
        _ => Modality.None,
    };

    public static readonly Modality[] All = { Modality.None, Modality.Text, Modality.Image, Modality.Audio };
}

/// <summary>A file as the index knows it. Canonical definition (also used by the
/// extractor pipeline via IExtractor.cs); Device/Inode are Windows-stable file IDs.</summary>
public sealed record FileRecord(long Id, string Path, FileKind Kind, long Size, double Mtime,
    long Device = 0, long Inode = 0, string State = "pending");

/// <summary>One stored segment row (the <c>segments</c> table).</summary>
public sealed record Segment(long Id, long FileId, SegmentKind Kind, Modality Modality,
    double? Loc, double? LocEnd, string? Excerpt, bool HasVector);

/// <summary>One indexable piece of a file: the unit stored as a <c>segments</c> row
/// plus an FTS5 row (keyword text) and/or a vector.</summary>
public sealed record Piece(long FileId, SegmentKind Kind, Modality Modality,
    double? Loc = null, double? LocEnd = null, string? Excerpt = null,
    string? Text = null, float[]? Vector = null);

/// <summary>Which vectors an index holds. Mirrors LlamaEmbedder.vectorVersion: it changes
/// only when the vectors do, so a runtime update that leaves the vectors alone keeps the index.</summary>
public static class ModelVectors
{
    public const int VectorVersion = 1;
    public const string VectorRuntime = "llama.cpp-vectors1";

    /// <summary>The full index fingerprint: the embedding source plus the index options.</summary>
    public static string Fingerprint(string vectorSource, IndexOptions options) =>
        $"{vectorSource} | {options.Fingerprint}";
}

/// <summary>"code: retry with backoff": a search of the code index, and nothing else.</summary>
public static class CodeQuery
{
    public const string Prefix = "code:";

    /// <summary>What's typed after "code:" ("" for "code:" alone), or null for a search that isn't one of code.</summary>
    public static string? TextOf(string query)
    {
        string trimmed = query.TrimStart();
        if (trimmed.Length >= Prefix.Length &&
            trimmed.Substring(0, Prefix.Length).Equals(Prefix, StringComparison.OrdinalIgnoreCase))
            return trimmed.Substring(Prefix.Length).Trim();
        return null;
    }
}

/// <summary>Index statistics.</summary>
public sealed class Counts
{
    public Dictionary<string, Dictionary<string, int>> ByKindAndState { get; } = new();
    public int Vectors { get; set; }
    public int Segments { get; set; }
    /// <summary>Long files still being read, and their pages and chunks left.</summary>
    public int Unfinished { get; set; }
    public int Left { get; set; }
}

/// <summary>The on-disk index: one SQLite file with files, their segments (with fp16
/// vectors), and an FTS5 table. Ports IndexStore.swift with the same schema.
/// Implements IIndexerStore (declared in Indexer.cs) so the indexer can use it.</summary>
public sealed class IndexStore : IDisposable, IIndexerStore
{
    public const long SchemaVersion = 5;

    /// <summary>Keyword search's tokenizer. Marks (M*) count as letters, so Bengali vowel
    /// signs and Arabic harakat stay inside their words.</summary>
    public const string Tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'";
    /// <summary>Keyword search's table: words are matched in <c>body</c>, normalized
    /// (<see cref="SearchText"/>); <c>original</c> keeps the text as written when
    /// normalizing changed it, for showing it.</summary>
    public const string FtsColumns = "name, body, original UNINDEXED, tokenize = \"" + Tokenizer + "\"";

    /// <summary>The main index's file in the index folder.</summary>
    public const string MainFile = "index.sqlite";
    /// <summary>The code index is a file of its own beside it.</summary>
    public const string CodeFile = "code.sqlite";

    private const string FileColumns = "id, path, kind, size, mtime, inode, device, state";

    private readonly Database _db;
    private bool _disposed;

    public string Directory { get; }
    public string FilePath { get; }
    public Database Db => _db;

    private List<string>? _scope;
    private string _scopeSql = "";
    private List<SqlValue> _scopeValues = new();

    /// <summary>When set, pending/unfinished/counts see only files under these folders.</summary>
    public List<string>? Scope
    {
        get => _scope;
        set
        {
            _scope = value;
            if (value is null)
            {
                _scopeSql = "";
                _scopeValues = new();
                return;
            }
            if (value.Count == 0)
            {
                _scopeSql = " AND 0";
                _scopeValues = new();
                return;
            }
            var parts = new List<string>();
            var vals = new List<SqlValue>();
            foreach (var root in value)
            {
                string prefix = NormalizePath(root);
                if (!prefix.EndsWith('/'))
                    prefix += "/";
                parts.Add("(path >= ? AND path < ?)");
                vals.Add(SqlValue.Text(prefix));
                vals.Add(SqlValue.Text(prefix + "\U0010FFFF"));
            }
            _scopeSql = " AND (" + string.Join(" OR ", parts) + ")";
            _scopeValues = vals;
        }
    }

    public IndexStore(string directory, string fileName = MainFile)
    {
        System.IO.Directory.CreateDirectory(directory);
        Directory = directory;
        FilePath = System.IO.Path.Combine(directory, fileName);
        _db = new Database(FilePath);
        Migrate();
    }

    /// <summary>Bytes on disk: the database and its write-ahead log.</summary>
    public static long SizeOf(string file)
    {
        long total = 0;
        foreach (var path in new[] { file, file + "-wal" })
        {
            try
            {
                if (System.IO.File.Exists(path))
                    total += new System.IO.FileInfo(path).Length;
            }
            catch (System.IO.IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return total;
    }

    /// <summary>Paths are stored with '/' separators so prefix-range queries behave
    /// the same on Windows ('\') as on macOS.</summary>
    public static string NormalizePath(string path) => path.Replace('\\', '/');

    public static bool IsInside(string path, string folder)
    {
        string p = NormalizePath(path);
        string f = NormalizePath(folder);
        if (!f.EndsWith('/'))
            f += "/";
        return p.StartsWith(f, StringComparison.Ordinal);
    }

    // ---------- Schema ----------

    private void Migrate()
    {
        long version = 0;
        _db.Query("PRAGMA user_version", r => { version = r.GetInt64(0); });
        if (version > SchemaVersion)
            throw new InvalidOperationException($"this index was made by a newer DigUp (schema {version})");
        if (version == SchemaVersion)
            return;
        // One migrates while the other waits (up to a minute, not the usual 5 s).
        _db.Execute("PRAGMA busy_timeout = 60000");
        try
        {
            _db.Transaction(() =>
            {
                long v = 0;
                _db.Query("PRAGMA user_version", r => { v = r.GetInt64(0); });
                if (v == 0)
                    Create();
                if (v == 1)
                    MigrateKeywordSearch();
                if (v >= 1 && v <= 2)
                    MigrateScreenshotText();
                if (v >= 1 && v <= 3)
                    MigrateVectorNames();
                if (v >= 1 && v <= 4)
                    MigrateLongFiles();
            });
        }
        finally
        {
            _db.Execute("PRAGMA busy_timeout = 5000");
        }
    }

    private void Create()
    {
        _db.Execute(
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
            "CREATE TABLE files(" +
            "id INTEGER PRIMARY KEY," +
            "path TEXT NOT NULL UNIQUE," +
            "kind TEXT NOT NULL," +
            "size INTEGER NOT NULL," +
            "mtime REAL NOT NULL," +
            "inode INTEGER NOT NULL," +
            "device INTEGER NOT NULL," +
            "state TEXT NOT NULL DEFAULT 'pending'," +
            "detail TEXT," +
            "info TEXT," +
            "indexed_at REAL" +
            ");" +
            "CREATE INDEX files_inode ON files(device, inode);" +
            "CREATE INDEX files_state ON files(state, kind);" +
            "CREATE TABLE segments(" +
            "id INTEGER PRIMARY KEY," +
            "file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE," +
            "kind TEXT NOT NULL," +
            "modality TEXT NOT NULL," +
            "loc REAL," +
            "loc_end REAL," +
            "excerpt TEXT," +
            "vec BLOB" +
            ");" +
            "CREATE INDEX segments_file ON segments(file);" +
            "CREATE VIRTUAL TABLE fts USING fts5(" + FtsColumns + ");" +
            "PRAGMA user_version = " + SchemaVersion + ";");
    }

    /// <summary>Schema 1 → 2: keyword search with whole Bengali and Arabic words over
    /// normalized text. Rebuilt from what's stored; garbled PDFs are queued again.</summary>
    private void MigrateKeywordSearch()
    {
        var rows = new List<(long Id, string Name, string Body)>();
        _db.Query("SELECT rowid, name, body FROM fts", r =>
            rows.Add((r.GetInt64(0), r.NullableText(1) ?? "", r.NullableText(2) ?? "")));
        var garbled = new HashSet<long>();
        _db.Query("SELECT s.file, fts.body FROM fts JOIN segments s ON s.id = fts.rowid " +
                  "JOIN files f ON f.id = s.file " +
                  "WHERE f.kind = 'pdf' AND s.kind IN ('page', 'page_image')", r =>
        {
            if (PageTextProblemCheck.Check(r.NullableText(1) ?? "") != null)
                garbled.Add(r.GetInt64(0));
        });
        _db.Execute("CREATE VIRTUAL TABLE fts_new USING fts5(" + FtsColumns + ")");
        foreach (var row in rows)
        {
            var (body, original) = KeywordText(row.Body);
            _db.Run("INSERT INTO fts_new(rowid, name, body, original) VALUES(?, ?, ?, ?)",
                new[] { SqlValue.Int(row.Id), SqlValue.Text(SearchText.Normalized(row.Name)),
                        SqlValue.Text(body), SqlValue.Of(original) });
        }
        _db.Execute("DROP TABLE fts; ALTER TABLE fts_new RENAME TO fts; PRAGMA user_version = 2;");
        foreach (long id in garbled)
            Requeue(id);
    }

    /// <summary>Schema 2 → 3: a screenshot's OCR text is for keyword search only;
    /// its text vectors go, nothing is read again.</summary>
    private void MigrateScreenshotText()
    {
        _db.Execute("UPDATE segments SET vec = NULL, modality = 'none' WHERE kind = 'ocr'; " +
                    "PRAGMA user_version = 3;");
    }

    /// <summary>Schema 3 → 4: indexes name their vectors by a vector version, not by the
    /// runtime build that made them. Every index so far comes from vectors version 1.</summary>
    private void MigrateVectorNames()
    {
        _db.Execute("UPDATE meta SET value = replace(value, ' llama.cpp-b11461-metal ', ' llama.cpp-vectors1 ') " +
                    "WHERE key IN ('fingerprint', 'vector_source'); " +
                    "PRAGMA user_version = 4;");
    }

    /// <summary>Schema 4 → 5: long files finish after the first pass from where they
    /// stopped; text that's mostly digits loses its vectors. Nothing is read or embedded here.</summary>
    private void MigrateLongFiles()
    {
        var digits = new List<long>();
        _db.Query("SELECT s.id, coalesce(fts.original, fts.body) FROM segments s JOIN fts ON fts.rowid = s.id " +
                  "WHERE s.kind IN ('page', 'chunk') AND s.vec IS NOT NULL", r =>
        {
            if (!SearchText.HasWords(r.NullableText(1) ?? ""))
                digits.Add(r.GetInt64(0));
        });
        foreach (long id in digits)
            _db.Run("UPDATE segments SET vec = NULL, modality = 'none' WHERE id = ?",
                new[] { SqlValue.Int(id) });
        var limits = new IndexOptions();
        _db.Execute(
            "UPDATE files SET detail = 'read to page 30', info = json_set(info, '$.read_to', '30', '$.read_end', " +
            "CAST(MIN(CAST(json_extract(info, '$.pages') AS INTEGER), " + limits.MaxPages + ") AS TEXT)) " +
            "WHERE kind = 'pdf' AND state = 'partial' AND info IS NOT NULL;" +
            "UPDATE files SET state = 'partial', detail = 'read to chunk 40', info = json_set(info, '$.read_to', '40', " +
            "'$.read_end', CAST(MIN(MAX(41, (CAST(json_extract(info, '$.chars') AS INTEGER) + 1599) / 1600), " +
            limits.MaxChunks + ") AS TEXT)) " +
            "WHERE kind = 'doc' AND state = 'done' AND json_extract(info, '$.chunks') = '40';" +
            "PRAGMA user_version = 5;");
    }

    // ---------- Meta ----------

    public string? Meta(string key)
    {
        string? value = null;
        _db.Query("SELECT value FROM meta WHERE key = ?",
            new[] { SqlValue.Text(key) }, r => { value = r.NullableText(0); });
        return value;
    }

    public string? GetMeta(string key) => Meta(key);

    public void SetMeta(string key, string? value)
    {
        if (value is null)
            _db.Run("DELETE FROM meta WHERE key = ?", new[] { SqlValue.Text(key) });
        else
            _db.Run("INSERT INTO meta(key, value) VALUES(?, ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                new[] { SqlValue.Text(key), SqlValue.Text(value) });
    }

    public void Transact(Action action) => _db.Transaction(action);

    // ---------- Files ----------

    private static FileRecord Record(Microsoft.Data.Sqlite.SqliteDataReader r) =>
        new(r.GetInt64(0), r.NullableText(1) ?? "", FileKindStrings.Parse(r.NullableText(2)),
            r.GetInt64(3), r.GetDouble(4), r.GetInt64(5), r.GetInt64(6), r.NullableText(7) ?? "pending");

    /// <summary>Every file under one of <paramref name="roots"/>.</summary>
    public IReadOnlyList<FileRecord> FilesUnder(IReadOnlyList<string> roots)
    {
        var output = new List<FileRecord>();
        foreach (var root in roots)
        {
            bool covered = false;
            foreach (var other in roots)
            {
                if (!ReferenceEquals(root, other) && root != other && IsInside(root, other))
                { covered = true; break; }
            }
            if (covered)
                continue;
            string prefix = NormalizePath(root);
            if (!prefix.EndsWith('/'))
                prefix += "/";
            _db.Query("SELECT " + FileColumns + " FROM files WHERE path >= ? AND path < ?",
                new[] { SqlValue.Text(prefix), SqlValue.Text(prefix + "\U0010FFFF") },
                r => output.Add(Record(r)));
        }
        return output;
    }

    /// <summary>Adds a file (pending) and returns its id.</summary>
    public long Insert(CrawlCandidate file)
    {
        _db.Run("INSERT INTO files(path, kind, size, mtime, inode, device) VALUES(?, ?, ?, ?, ?, ?)",
            new[] { SqlValue.Text(NormalizePath(file.Path)), SqlValue.Text(file.Kind.ToStorageString()),
                    SqlValue.Int(file.Size), SqlValue.Real(file.Mtime),
                    SqlValue.Int(file.Inode), SqlValue.Int(file.Device) });
        long id = _db.LastInsertId;
        AddNameRow(id, file.Path);
        return id;
    }

    /// <summary>The file changed on disk: drop what was extracted from it and queue it again.</summary>
    public void Requeue(long id, CrawlCandidate file)
    {
        DeleteSegments(id, keepingName: true);
        _db.Run("UPDATE files SET kind = ?, size = ?, mtime = ?, inode = ?, device = ?, " +
                "state = 'pending', detail = NULL, info = NULL, indexed_at = NULL WHERE id = ?",
            new[] { SqlValue.Text(file.Kind.ToStorageString()), SqlValue.Int(file.Size),
                    SqlValue.Real(file.Mtime),
                    SqlValue.Int(file.Inode), SqlValue.Int(file.Device),
                    SqlValue.Int(id) });
    }

    /// <summary>Extract and embed the file again, as it is.</summary>
    public void Requeue(long id)
    {
        DeleteSegments(id, keepingName: true);
        _db.Run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL WHERE id = ?",
            new[] { SqlValue.Int(id) });
    }

    /// <summary>Same file at a new path (a move or rename): only the path changes.</summary>
    public void Move(long id, string toPath)
    {
        _db.Run("UPDATE files SET path = ? WHERE id = ?",
            new[] { SqlValue.Text(NormalizePath(toPath)), SqlValue.Int(id) });
        _db.Run("UPDATE fts SET name = ?, body = ? " +
                "WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind = 'name')",
            new[] { SqlValue.Text(SearchText.Normalized(NameText(toPath))),
                    SqlValue.Text(SearchText.Normalized(FolderText(toPath))), SqlValue.Int(id) });
    }

    public void Delete(long id)
    {
        _db.Run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ?)",
            new[] { SqlValue.Int(id) });
        _db.Run("DELETE FROM files WHERE id = ?", new[] { SqlValue.Int(id) });
    }

    /// <summary>Removes every file that isn't under one of <paramref name="roots"/>.
    /// A root that doesn't exist right now (ejected drive, offline share)
    /// keeps its files: gone hardware must not read as deleted folders.
    /// Returns how many went.</summary>
    public int Prune(IReadOnlyList<string> roots)
    {
        var prefixes = new List<string>();
        foreach (var root in roots)
        {
            if (!System.IO.Directory.Exists(root) && !System.IO.File.Exists(root))
            {
                continue;
            }

            string p = NormalizePath(root);
            prefixes.Add(p.EndsWith('/') ? p : p + "/");
        }
        var gone = new List<long>();
        _db.Query("SELECT id, path FROM files", r =>
        {
            string path = r.NullableText(1) ?? "";
            bool keep = false;
            foreach (var p in prefixes)
            {
                // Windows paths ignore case (the rest of sync compares
                // case-insensitively too): never prune over a capital.
                if (path.StartsWith(p, StringComparison.OrdinalIgnoreCase)) { keep = true; break; }
            }
            if (!keep)
                gone.Add(r.GetInt64(0));
        });
        if (gone.Count == 0)
            return 0;
        _db.Transaction(() =>
        {
            foreach (long id in gone)
                Delete(id);
        });
        return gone.Count;
    }

    /// <summary>Queues every file again and forgets the fingerprint.</summary>
    public void ResetAll()
    {
        _db.Transaction(() =>
        {
            _db.Run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE kind != 'name')");
            _db.Run("DELETE FROM segments WHERE kind != 'name'");
            _db.Run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL");
            SetMeta("fingerprint", null);
        });
    }

    /// <summary>Files waiting to be embedded, in indexing order; <paramref name="only"/>
    /// narrows it to some files (just-added ones).</summary>
    public IReadOnlyList<FileRecord> Pending(int? limit, ISet<long>? only = null)
    {
        var output = new List<FileRecord>();
        if (only is not null && only.Count == 0)
            return output;
        string filter = only is null ? "" : " AND id IN (" + string.Join(",", only) + ")";
        var values = new List<SqlValue>(_scopeValues) { SqlValue.Int(limit ?? -1) };
        _db.Query("SELECT " + FileColumns + " FROM files WHERE state = 'pending'" + filter + _scopeSql +
                  " ORDER BY " + FileKindOrder.IndexingOrderSql + ", mtime DESC LIMIT ?",
            values, r => output.Add(Record(r)));
        return output;
    }

    public int PendingCount()
    {
        int count = 0;
        _db.Query("SELECT COUNT(*) FROM files WHERE state = 'pending'" + _scopeSql, _scopeValues,
            r => { count = (int)r.GetInt64(0); });
        return count;
    }

    /// <summary>Long files with pages or chunks still to read after their first step.</summary>
    public IReadOnlyList<FileRecord> Unfinished()
    {
        var output = new List<FileRecord>();
        _db.Query("SELECT " + FileColumns + " FROM files WHERE state = 'partial'" + _scopeSql +
                  " ORDER BY " + FileKindOrder.IndexingOrderSql + ", mtime DESC",
            _scopeValues, r => output.Add(Record(r)));
        return output;
    }

    /// <summary>How many long files are unfinished, and how many of their pages and chunks are left.</summary>
    public (int Files, int Left) UnfinishedCount()
    {
        int files = 0, left = 0;
        _db.Query("SELECT COUNT(*), SUM(MAX(0, CAST(json_extract(info, '$.read_end') AS INTEGER) " +
                  "- CAST(json_extract(info, '$.read_to') AS INTEGER))) " +
                  "FROM files WHERE state = 'partial'" + _scopeSql, _scopeValues,
            r =>
            {
                files = (int)r.GetInt64(0);
                left = r.IsDBNull(1) ? 0 : (int)r.GetInt64(1);
            });
        return (files, left);
    }

    public int UnfinishedFiles() => UnfinishedCount().Files;

    /// <summary>What indexing learned about a file (<see cref="Finish"/>'s info).</summary>
    public Dictionary<string, string?> InfoOf(long fileId)
    {
        var info = new Dictionary<string, string?>();
        _db.Query("SELECT info FROM files WHERE id = ?", new[] { SqlValue.Int(fileId) }, r =>
        {
            string? json = r.NullableText(0);
            if (json is null)
                return;
            try
            {
                info = JsonSerializer.Deserialize<Dictionary<string, string?>>(json) ??
                       new Dictionary<string, string?>();
            }
            catch (JsonException) { }
        });
        return info;
    }

    /// <summary>The last page or chunk stored for a file.</summary>
    public int? LastPlace(long fileId)
    {
        int? last = null;
        _db.Query("SELECT MAX(loc) FROM segments WHERE file = ? AND kind IN ('page', 'page_image', 'chunk')",
            new[] { SqlValue.Int(fileId) },
            r => { last = r.IsDBNull(0) ? null : (int)r.GetDouble(0); });
        return last;
    }

    /// <summary>One more failed try at a file, kept in its info without
    /// touching its state. The indexer quarantines a file after a few
    /// crashes so one bad file can't wedge every run; a change on disk
    /// (Requeue) clears the count. Returns the new total.</summary>
    public int BumpAttempts(long fileId)
    {
        var info = InfoOf(fileId);
        int n = info.TryGetValue("attempts", out string? raw) && int.TryParse(raw, out int v) ? v + 1 : 1;
        info["attempts"] = n.ToString();
        var clean = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var kv in info)
        {
            if (kv.Value is not null)
                clean[kv.Key] = kv.Value;
        }
        _db.Run("UPDATE files SET info = ? WHERE id = ?",
            new[] { SqlValue.Text(JsonSerializer.Serialize(clean)), SqlValue.Int(fileId) });
        return n;
    }

    public void Finish(long id, string state, string? detail = null,
        Dictionary<string, string?>? info = null)
    {
        string? json = null;
        if (info is not null && info.Count > 0)
        {
            var clean = new SortedDictionary<string, string>(StringComparer.Ordinal);
            foreach (var kv in info)
            {
                if (kv.Value is not null)
                    clean[kv.Key] = kv.Value;
            }
            if (clean.Count > 0)
                json = JsonSerializer.Serialize(clean);
        }
        _db.Run("UPDATE files SET state = ?, detail = ?, info = ?, indexed_at = ? WHERE id = ?",
            new[] { SqlValue.Text(state), SqlValue.Of(detail), SqlValue.Of(json),
                    SqlValue.Real(DateTimeOffset.UtcNow.ToUnixTimeSeconds()), SqlValue.Int(id) });
    }

    // ---------- Segments ----------

    /// <summary>Adds a segment; <paramref name="text"/> goes into keyword search
    /// (normalized), <paramref name="vector"/> into meaning search.</summary>
    public void AddSegment(long fileId, SegmentKind kind, Modality modality,
        double? loc = null, double? locEnd = null, string? excerpt = null,
        string? text = null, float[]? vector = null)
    {
        // Clean once on the way in: no lone surrogates ever reach FTS or
        // the snippet path, whatever the extractor handed us.
        excerpt = excerpt is null ? null : TextSanitize.Clean(excerpt);
        text = text is null ? null : TextSanitize.Clean(text);
        byte[]? blob = vector is null ? null : Vectors.ToHalfBlob(vector);
        _db.Run("INSERT INTO segments(file, kind, modality, loc, loc_end, excerpt, vec) " +
                "VALUES(?, ?, ?, ?, ?, ?, ?)",
            new[] { SqlValue.Int(fileId), SqlValue.Text(kind.ToStorageString()),
                    SqlValue.Text(vector is null ? ModalityStrings.Raw(Modality.None)
                                                : ModalityStrings.Raw(modality)),
                    SqlValue.Of(loc), SqlValue.Of(locEnd), SqlValue.Of(excerpt),
                    blob is null ? SqlValue.Null : SqlValue.Blob(blob) });
        if (!string.IsNullOrEmpty(text))
        {
            var (body, original) = KeywordText(text);
            _db.Run("INSERT INTO fts(rowid, name, body, original) VALUES(?, '', ?, ?)",
                new[] { SqlValue.Int(_db.LastInsertId), SqlValue.Text(body), SqlValue.Of(original) });
        }
    }

    /// <summary>Adds a <see cref="Piece"/> as one segment row (+FTS5 row / vector).</summary>
    public void AddSegment(Piece piece) =>
        AddSegment(piece.FileId, piece.Kind, piece.Modality, piece.Loc, piece.LocEnd,
            piece.Excerpt, piece.Text, piece.Vector);

    /// <summary><c>body</c> and <c>original</c> for keyword search: the normalized text,
    /// and the text as written if that differs.</summary>
    public static (string Body, string? Original) KeywordText(string text)
    {
        string normalized = SearchText.Normalized(text);
        return (normalized, normalized == text ? null : text);
    }

    private void AddNameRow(long file, string path)
    {
        _db.Run("INSERT INTO segments(file, kind, modality) VALUES(?, 'name', 'none')",
            new[] { SqlValue.Int(file) });
        _db.Run("INSERT INTO fts(rowid, name, body) VALUES(?, ?, ?)",
            new[] { SqlValue.Int(_db.LastInsertId),
                    SqlValue.Text(SearchText.Normalized(NameText(path))),
                    SqlValue.Text(SearchText.Normalized(FolderText(path))) });
    }

    private void DeleteSegments(long file, bool keepingName)
    {
        string filter = keepingName ? "AND kind != 'name'" : "";
        _db.Run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? " + filter + ")",
            new[] { SqlValue.Int(file) });
        _db.Run("DELETE FROM segments WHERE file = ? " + filter, new[] { SqlValue.Int(file) });
    }

    /// <summary>"Screenshot 2026-10-01 at 9.41.07 PM.png" → searchable words.</summary>
    public static string NameText(string path)
    {
        string p = NormalizePath(path);
        int slash = p.LastIndexOf('/');
        return slash < 0 ? p : p.Substring(slash + 1);
    }

    /// <summary>The folders a file sits in, relative to the home folder
    /// ("Downloads Invoices"), as low-weight keywords.</summary>
    public static string FolderText(string path)
    {
        string home = NormalizePath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        string folder = NormalizePath(path);
        int slash = folder.LastIndexOf('/');
        folder = slash < 0 ? "" : folder.Substring(0, slash);
        if (folder.StartsWith(home, StringComparison.Ordinal))
            folder = folder.Substring(home.Length);
        return string.Join(" ", folder.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries));
    }

    // ---------- Stats ----------

    public Counts Counts()
    {
        var counts = new Counts();
        _db.Query("SELECT kind, state, COUNT(*) FROM files WHERE 1" + _scopeSql +
                  " GROUP BY kind, state", _scopeValues,
            r => {
                string kind = r.NullableText(0) ?? "?";
                string state = r.NullableText(1) ?? "?";
                if (!counts.ByKindAndState.TryGetValue(kind, out var inner))
                {
                    inner = new Dictionary<string, int>();
                    counts.ByKindAndState[kind] = inner;
                }
                inner[state] = (int)r.GetInt64(2);
            });
        (counts.Unfinished, counts.Left) = UnfinishedCount();
        string inScope = _scope is null ? "" : " AND file IN (SELECT id FROM files WHERE 1" + _scopeSql + ")";
        _db.Query("SELECT COUNT(*), COUNT(vec) FROM segments WHERE kind != 'name'" + inScope, _scopeValues,
            r =>
            {
                counts.Segments = (int)r.GetInt64(0);
                counts.Vectors = (int)r.GetInt64(1);
            });
        return counts;
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _db.Dispose();
    }
}

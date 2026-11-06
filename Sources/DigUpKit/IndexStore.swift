import Foundation

/// A file as the index knows it.
public struct FileRecord: Sendable {
    public let id: Int64
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
    public let state: String
    /// Why it was skipped or failed, or how far a long file has been read.
    public let detail: String?
}

/// The on-disk index: one SQLite file with files, their segments (with fp16 vectors), and an FTS5 table.
///
/// Vectors live in the same database as everything else, so a crash can never leave them out of step with the
/// rows that describe them. At this scale (~20k vectors, ~30 MB) brute-force search over an in-memory copy is a
/// few milliseconds; no vector database needed.
public final class IndexStore {
    public let directory: URL
    public let db: Database
    static let schemaVersion: Int64 = 6

    /// Keyword search's tokenizer. Marks (M*) count as letters, so Bengali vowel signs and Arabic harakat stay inside
    /// their words: by default SQLite splits on them ("কলকাতায়" became "কলক", "ত", "য").
    static let tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"
    /// Keyword search's table: words are matched in `body`, normalized (`SearchText`); `original` keeps the text as it's
    /// written when normalizing changed it (Arabic with hamza or harakat, Bengali with joiners), for showing it.
    static let ftsColumns = "name, body, original UNINDEXED, tokenize = \"\(tokenizer)\""

    /// When set, `pending`, `pendingCount` and `counts` see only files under these folders: the app's helper sets the
    /// folders that are connected right now, so files on an unplugged drive neither fail nor count as waiting.
    /// The ranges live in a temp table, merged to disjoint, and the scoped queries test a path against the one
    /// range that can contain it: `(SELECT s.hi FROM scope s WHERE s.lo <= files.path ORDER BY s.lo DESC
    /// LIMIT 1) > files.path`. When the ranges don't overlap, the greatest `lo` at or below a path is the
    /// only candidate — one PRIMARY KEY seek per row, where a correlated `EXISTS` asked every range with
    /// `lo <= path` to say yes (26× the time at 1,200 folders, measured in the #191 review's follow-up).
    /// One `(path >= ? AND path < ?)` per folder, ORed into a single expression, is what died past #166's
    /// 1,179 folders: SQLite caps expression trees at a depth of 1,000. The table grows with the list for free.
    public private(set) var scope: [String]?
    private var scopeSQL = ""

    /// Writes the merged ranges in one transaction and moves `scope`/`scopeSQL` only after it commits: a
    /// write that fails mid-flight (disk full) leaves the previous scope standing, in memory and in the
    /// table, and the scoped queries go on answering as before. Spell that order any other way and a
    /// failed write leaves the in-memory scope claiming folders the emptied table says nothing about —
    /// the indexer quietly sees zero pending files until the next `setScope` succeeds. Merging makes the
    /// range list unique on its own, so a folder listed twice folds into its twin instead of tripping
    /// the PRIMARY KEY.
    public func setScope(_ folders: [String]?) throws {
        guard let folders else { (scope, scopeSQL) = (nil, ""); return }
        let ranges = Self.mergedRanges(folders.flatMap(Self.pathRanges(under:)))
        let bucketRanges = Self.mergedRanges(folders.flatMap(Self.bucketRanges(under:)))
        try db.transaction {
            try db.run("""
                CREATE TEMP TABLE IF NOT EXISTS scope(
                    lo TEXT NOT NULL,
                    hi TEXT NOT NULL,
                    PRIMARY KEY(lo, hi)
                ) WITHOUT ROWID
                """)
            try db.run("DELETE FROM scope")
            var start = 0
            while start < ranges.count {   // multi-row INSERTs, kept under SQLite's cap on a compound select
                let chunk = ranges[start..<min(start + 200, ranges.count)]
                try db.run("INSERT INTO scope(lo, hi) VALUES"
                           + Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ","),
                           chunk.flatMap { [.text($0.from), .text($0.to)] })
                start += 200
            }
            try db.run("""
                CREATE TEMP TABLE IF NOT EXISTS scopeb(
                    lo TEXT NOT NULL,
                    hi TEXT NOT NULL,
                    PRIMARY KEY(lo, hi)
                ) WITHOUT ROWID
                """)
            try db.run("DELETE FROM scopeb")
            var bStart = 0
            while bStart < bucketRanges.count {
                let chunk = bucketRanges[bStart..<min(bStart + 200, bucketRanges.count)]
                try db.run("INSERT INTO scopeb(lo, hi) VALUES"
                           + Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ","),
                           chunk.flatMap { [.text($0.from), .text($0.to)] })
                bStart += 200
            }
        }
        (scope, scopeSQL) = (folders, ranges.isEmpty ? " AND 0"
            : " AND (SELECT s.hi FROM scope s WHERE s.lo <= files.path ORDER BY s.lo DESC LIMIT 1) > files.path")
    }

    /// The ranges of the UNIQUE path index that hold the files under `folder`. Paths are stored as a walk reports them,
    /// which isn't always how the folder is spelled here: `standardizedFileURL` says /var where the walk says
    /// /private/var, and decomposes a name with accents or Hangul that the disk keeps precomposed ("Café", Google
    /// Drive's "내 드라이브"). Swift's `==` takes those for the same folder; SQLite compares bytes. So: a range for the
    /// folder as given, and one for its real path when that's spelled differently.
    static func pathRanges(under folder: String) -> [(from: String, to: String)] {
        var spellings = [folder]
        let real = FolderSelection.realPath(folder)
        if !real.utf8.elementsEqual(folder.utf8) { spellings.append(real) }
        return spellings.map { path in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return (prefix, prefix + "\u{10FFFF}")
        }
    }

    /// The range list sorted and folded into disjoint spans: nested ranges (a chosen folder inside another),
    /// repeats, and touching ones all merge. The scope test above trusts the one range with the greatest
    /// `lo` at or below a path, and that answer is exact only when the ranges don't overlap — merging is
    /// what makes them not. Comparisons are bytewise, the order SQLite keeps TEXT in (BINARY): it is what
    /// keeps `/ab` out of `/a`'s range and a decomposed name out of its precomposed folder.
    static func mergedRanges(_ ranges: [(from: String, to: String)]) -> [(from: String, to: String)] {
        func byteLess(_ a: String, _ b: String) -> Bool {
            let x = Array(a.utf8), y = Array(b.utf8)
            for (i, byte) in x.enumerated() {
                if i >= y.count { return false }      // b ran out: a is longer, a is after b
                if byte != y[i] { return byte < y[i] }
            }
            return x.count < y.count                  // a is a strict prefix: a is before b
        }
        var out: [(from: String, to: String)] = []
        for r in ranges.filter { byteLess($0.from, $0.to) }.sorted { byteLess($0.from, $1.from) } {
            if var last = out.last, !byteLess(last.to, r.from) {   // r.from <= last.to: touching or overlapping
                if byteLess(last.to, r.to) { last.to = r.to }
                out[out.count - 1] = last
            } else { out.append(r) }
        }
        return out
    }

    /// The folder a file's name sits in: the path up to the last `/`, the slash dropped. A root-level file
    /// ("/x.png") has bucket `""`; a file directly under a Windows drive root ("C:/x") has bucket `"C:"`.
    /// Scanned bytewise, and that is the safe way to cut: a 0x2F byte is always a real separator (every
    /// UTF-8 continuation byte is ≥ 0x80, so 0x2F never hides inside a multi-byte character), the last
    /// slash byte is the last slash character, and cutting at a slash byte always yields valid UTF-8.
    /// Buckets are compared bytewise (BINARY) exactly like paths — same order, same rules — which is what
    /// makes `bucketRanges` the exact bucket analogue of `pathRanges`.
    static func bucket(of path: String) -> String {
        var bytes = [UInt8](path.utf8)
        guard let last = bytes.lastIndex(of: 0x2F) else { return "" }
        bytes.removeSubrange(last...)   // everything before the final slash
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The ranges of the counters table's bucket key that hold the files under `folder` — `pathRanges`'
    /// dual spellings (the folder as given, plus its real path) mapped into the two shapes buckets come in:
    /// * `(own, own + "\u{1}")` where `own` is the folder name without its trailing slash: the files sitting
    ///   in the folder itself, whose bucket is exactly `own`. A range spanning one code unit past `own`
    ///   contains that one bucket value and nothing else: every longer bucket extending `own` starts with
    ///   a byte ≥ 0x01, and 0x2F (`/`) is ≥ 0x01, so a sibling folder named "notes." or "notes!" — which is
    ///   NOT inside "notes" — has its files' buckets sort past this range's end. Root-level files
    ///   (bucket `""`) and drive-root files (bucket `"C:"`) land in this range for the root spellings.
    /// * `(folder + "/", folder + "/" + "\u{10FFFF}")`: the files in the folder's subfolders — their bucket
    ///   starts with `folder + "/"`, and a bucket under `folder`'s path bound is a bucket under its name
    ///   bound, because a bucket is a prefix of its files' paths.
    /// The `"\u{10FFFF}"` bound is inherited from `pathRanges` verbatim (it is that range's own `to`): on
    /// macOS a name containing it is unrepresentable — Foundation **and** raw `mkdir`/`open` refuse it
    /// (APFS, measured in the audit) — so the bound is unreachable here; Linux (ext4: any UTF-8 sans
    /// NUL/`/`) and Windows (NTFS: full UTF-16, surrogate pairs included) can represent a name starting
    /// with it, and such a file/folder escapes the range in *both* forms identically — behavior inherited
    /// from the shipped path machinery, not introduced here (audit Finding 10). The one asymmetry buckets
    /// add: a direct child named starting with U+10FFFF has bucket `own`, so the counters count it while
    /// the path query's bound excludes it (audit Finding 10's caveat, disclosed in the report).
    static func bucketRanges(under folder: String) -> [(from: String, to: String)] {
        pathRanges(under: folder).flatMap { range in
            let own = String(range.from.dropLast())   // the prefix's trailing slash IS the cut: the folder
            // name is its own bucket. `bucket(of:)` is NOT applicable to a folder path — it cuts the last
            // segment, so it maps `/t/a` to its parent `/t`, which would make the exact range one folder
            // too broad and drop the files sitting in the folder itself.
            return [(own, own + "\u{1}"), (range.from, range.to)]
        }
    }

    /// The main index's file in the index folder.
    public static let mainFile = "index.sqlite"
    /// The code index (`IndexOptions.code`) is a file of its own beside it: code search never moves the rest (its
    /// meaning scale, its keyword results, the vectors search keeps in memory), and turning it off deletes one file.
    public static let codeFile = "code.sqlite"

    public let file: URL

    public init(directory: URL, file name: String = IndexStore.mainFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        file = directory.appendingPathComponent(name)
        db = try Database(path: file.path)
        try migrate()
    }

    /// Bytes on disk: the database and its write-ahead log.
    public static func size(of file: URL) -> Int64 {
        [file.path, file.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    /// Schema changes ship as one migration each, and the layout below was designed to need as few as possible
    /// (every forced migration is paid for by every user).
    private func migrate() throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= Self.schemaVersion else {
            throw Database.Failure(message: "this index was made by a newer DigUp (schema \(version))")
        }
        guard version < Self.schemaVersion else { return }
        // The app and its helper can open the index at the same moment: one migrates while the other waits for it (up
        // to a minute, not the usual 5 s), then sees it done.
        try db.execute("PRAGMA busy_timeout = 60000")
        defer { try? db.execute("PRAGMA busy_timeout = 5000") }
        try db.transaction {
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            if version == 0 { try create() }
            if version == 1 { try migrateKeywordSearch() }
            if (1...2).contains(version) { try migrateScreenshotText() }
            if (1...3).contains(version) { try migrateVectorNames() }
            if (1...4).contains(version) { try migrateLongFiles() }
            try migrateCounters()   // 5 → 6, fresh databases included: an empty one fills trivially
        }
    }

    private func create() throws {
        try db.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                inode INTEGER NOT NULL,
                device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',   -- pending | done | partial | skipped | failed
                detail TEXT,                              -- why skipped/failed, or how far a long file has been read
                info TEXT,                                -- JSON: pixels, pages, duration, date taken; read_to/read_end
                indexed_at REAL
            );
            CREATE INDEX files_inode ON files(device, inode);
            CREATE INDEX files_state ON files(state, kind);
            CREATE TABLE segments(
                id INTEGER PRIMARY KEY,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,       -- SegmentKind
                modality TEXT NOT NULL,   -- Modality of the vector ('none' when there is no vector)
                loc REAL,                 -- PDF page number, or start second for audio/video
                loc_end REAL,
                excerpt TEXT,
                vec BLOB                  -- 768 × float16, L2-normalized
            );
            CREATE INDEX segments_file ON segments(file);
            CREATE VIRTUAL TABLE fts USING fts5(\(Self.ftsColumns));
            PRAGMA user_version = 5;   -- base layout: the counters step (6) follows in the same transaction
            """)
    }

    /// Schema 1 → 2: keyword search with whole Bengali and Arabic words (`tokenizer`) over normalized text
    /// (`SearchText`). The words are rebuilt from what's stored, without reading any file. PDFs whose text layer came
    /// out garbled (`PageTextProblem`) are queued again, to be read as pictures or by OCR.
    private func migrateKeywordSearch() throws {
        try db.execute("CREATE VIRTUAL TABLE fts_new USING fts5(\(Self.ftsColumns))")
        // Row by row: an index can hold tens of megabytes of text, and the app may be the one migrating.
        try db.query("SELECT rowid, name, body FROM fts") { row in
            let body = row.text(2) ?? ""
            try db.run("INSERT INTO fts_new(rowid, name, body, original) VALUES(?, ?, ?, ?)",
                       [.int(row.int(0)), .text(SearchText.normalized(row.text(1) ?? ""))] + Self.keywordText(body))
        }
        var garbled = Set<Int64>()
        try db.query("""
            SELECT s.file, fts.body FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file
            WHERE f.kind = 'pdf' AND s.kind IN ('page', 'page_image')
            """) { row in
            if PageTextProblem.check(row.text(1) ?? "") != nil { garbled.insert(row.int(0)) }
        }
        try db.execute("DROP TABLE fts; ALTER TABLE fts_new RENAME TO fts; PRAGMA user_version = 2;")
        for file in garbled { try requeue(file) }
    }

    /// Schema 2 → 3: a screenshot's OCR text is for keyword search only, and its meaning comes from the picture. The
    /// text vectors made screenshots outrank better matches in the evals; they go, nothing is read again.
    private func migrateScreenshotText() throws {
        try db.execute("UPDATE segments SET vec = NULL, modality = 'none' WHERE kind = 'ocr'; PRAGMA user_version = 3;")
    }

    /// Schema 3 → 4: indexes name their vectors by a vector version, not by the llama.cpp build that made them, so a
    /// llama.cpp update that leaves the vectors alone keeps the index (`LlamaEmbedder.vectorVersion`). Every index so
    /// far comes from b11461, which made version 1. Nothing is embedded again.
    private func migrateVectorNames() throws {
        try db.execute("""
            UPDATE meta SET value = replace(value, ' llama.cpp-b11461-metal ', ' llama.cpp-vectors1 ')
            WHERE key IN ('fingerprint', 'vector_source');
            PRAGMA user_version = 4;
            """)
    }

    /// Schema 4 → 5: long files are finished after the first pass (`Indexer.finishLongFiles`), from where they stopped,
    /// which until now was always page 30 of a PDF over 50 pages (already `partial`) and chunk 40 of a document (`done`,
    /// with 40 chunks). Those documents become `partial`; how many chunks they have is guessed from their length until
    /// the later pass counts them. And text that's mostly digits loses its vectors (`SearchText.hasWords`), as it
    /// would if it were indexed now. Nothing is read or embedded here.
    private func migrateLongFiles() throws {
        var digits: [Int64] = []
        try db.query("""
            SELECT s.id, coalesce(fts.original, fts.body) FROM segments s JOIN fts ON fts.rowid = s.id
            WHERE s.kind IN ('page', 'chunk') AND s.vec IS NOT NULL
            """) { row in
            if !SearchText.hasWords(row.text(1) ?? "") { digits.append(row.int(0)) }
        }
        for id in digits { try db.run("UPDATE segments SET vec = NULL, modality = 'none' WHERE id = ?", [.int(id)]) }
        let limits = IndexOptions()
        try db.execute("""
            UPDATE files SET detail = 'read to page 30', info = json_set(info, '$.read_to', '30', '$.read_end',
                CAST(MIN(CAST(json_extract(info, '$.pages') AS INTEGER), \(limits.maxPages)) AS TEXT))
            WHERE kind = 'pdf' AND state = 'partial' AND info IS NOT NULL;
            UPDATE files SET state = 'partial', detail = 'read to chunk 40', info = json_set(info, '$.read_to', '40',
                '$.read_end', CAST(MIN(MAX(41, (CAST(json_extract(info, '$.chars') AS INTEGER) + 1599) / 1600),
                                       \(limits.maxChunks)) AS TEXT))
            WHERE kind = 'doc' AND state = 'done' AND json_extract(info, '$.chunks') = '40';
            PRAGMA user_version = 5;
            """)
    }

    /// Schema 5 → 6 (issue #193): the counters. The `files.bucket` column, the counter tables, the
    /// maintenance triggers, the aggregate fill, and the content check all run inside the one transaction
    /// `migrate()` opened, with the version stamp last: a crash at any point leaves v5 exactly intact
    /// (audit Finding 12, measured: SIGKILL mid-backfill rolls the whole thing back, ~2 s WAL replay),
    /// and a re-run after such a crash is safe because every step is guarded (Finding 12's amendment —
    /// a blind `ALTER TABLE` re-run raises `duplicate column name: bucket`, measured).
    ///
    /// The order is deliberate: column and backfill come first, while no triggers exist, so the backfill's
    /// per-row UPDATEs cost one write each and fire no counter maintenance; the tables, triggers, and
    /// index come next (creating a trigger needs its tables to exist); the fill then computes every group
    /// once from full aggregation, and the check must pass before the stamp — v6 always means "checked".
    /// The fill's aggregate and the triggers' row terms share one source (`partialTerm`), so a fill can
    /// never disagree with the suite it seeds.
    private func migrateCounters() throws {
        var hasBucket = false   // the pragma_table_info guard Finding 12 measured the need for
        try db.query("SELECT 1 FROM pragma_table_info('files') WHERE name = 'bucket'") { _ in hasBucket = true }
        if !hasBucket {
            try db.execute("ALTER TABLE files ADD COLUMN bucket TEXT NOT NULL DEFAULT ''")
        }
        // Backfill by rowid in batches of 5,000. Root-level files' true bucket *is* '', so the audit's
        // resumable-scan sketch (`WHERE bucket = ''`) would rescan them forever; the rowid walk is the
        // resumable form here — a re-run after a crash walks the table again, and the `AND bucket != ?`
        // makes the re-run write nothing where the answer is already right. The statement is prepared
        // once (`keeping:`): re-parsing per row costs more than the update itself at 1.2M rows.
        // Each batch is read whole before it is written: updating a table while its own SELECT cursor is
        // open is a live-read hazard.
        var last: Int64 = -1
        var count = 5000
        while count == 5000 {
            var batch: [(id: Int64, bucket: String)] = []
            try db.query("SELECT id, path FROM files WHERE id > ? ORDER BY id LIMIT 5000", [.int(last)]) { row in
                batch.append((row.int(0), Self.bucket(of: row.text(1) ?? "")))
                last = row.int(0)
            }
            for (id, bucket) in batch {
                try db.run("UPDATE files SET bucket = ? WHERE id = ? AND bucket != ?",
                           [.text(bucket), .int(id), .text(bucket)], keeping: true)
            }
            count = batch.count
        }
        try db.execute(Self.countersTablesSQL)
        try db.execute(Self.counterTriggersSQL)
        try fillCounters()
        guard try countersAreConsistent() else {
            // The fill disagrees with files: throw, roll the transaction back, stay v5 — the stamp is the
            // commit flag, and the next open retries from the guards.
            throw Database.Failure(message: "counter fill disagrees with the files table")
        }
        try db.execute("PRAGMA user_version = 6")
    }

    /// A row's pages/chunks left, as a SQL expression over `state`/`info` expressions (Finding 8's
    /// amendment): COALESCE **outside** MAX — the exact contribution of one row to `unfinishedCount`'s
    /// SUM. A row with one key (`{"read_end":"9"}`) contributes 0, exactly as production measures it;
    /// the issue's filed nesting (COALESCE inside the subtraction) would count 9 for it. The CASE keeps
    /// `json_extract` away from non-partial rows: malformed `info` on a partial row is refused at the
    /// WRITE (the trigger dies, the statement rolls back) where today's form crashes at read time —
    /// a net improvement, measured in the audit. One source for all six trigger sites and the fill.
    private static func partialTerm(_ state: String, _ info: String) -> String {
        "CASE WHEN \(state) = 'partial' THEN COALESCE(MAX(0, CAST(json_extract(\(info), '$.read_end') AS INTEGER)"
            + " - CAST(json_extract(\(info), '$.read_to') AS INTEGER)), 0) ELSE 0 END"
    }

    /// The aggregate sibling of `partialTerm` for full-scan SELECTs (fill and check). The extra
    /// `json_valid`: a v5 row can already hold malformed `info` (the audit: today's `unfinishedCount`
    /// crashes reading one), and a migration must not be blocked by a legacy row it cannot read —
    /// the fill/check treat it as contributing 0 (and the counters' read path is json-free, so
    /// `unfinishedCount` answers where the shipped form dies). The triggers keep the ungarded term:
    /// writing a new malformed partial row is refused (Finding 8's write-time rejection, intended).
    private static func partialSum(_ prefix: String = "") -> String {
        "SUM(CASE WHEN \(prefix)state = 'partial' AND json_valid(\(prefix)info) THEN COALESCE("
            + "MAX(0, CAST(json_extract(\(prefix)info, '$.read_end') AS INTEGER)"
            + " - CAST(json_extract(\(prefix)info, '$.read_to') AS INTEGER)), 0) ELSE 0 END)"
    }

    /// The counter tables. Audit Finding 4: the filed suite is **eight** triggers
    /// (`files_ai`/`files_ad`, `files_au_state`/`files_au_path`, `files_bd`, `seg_ai`/`seg_ad`/`seg_au_vec`)
    /// — the issue prose's "nine" is a typo; an implementation following the SQL ships exactly eight.
    ///
    /// Invariants the suite rests on (audit Findings 1/5/6, each pinned by a CounterTests test):
    /// * Nothing updates `segments.kind`/`segments.file` in place — no such statement exists in
    ///   `Sources/` today. A future reparenting query would desync `segcounters`; `rebuildCounters()` is
    ///   the documented self-heal for any path that breaks an invariant.
    /// * `foreign_keys = ON` on every connection — `Database.init` is the only open site in the codebase
    ///   and sets it (the Tauri shell opens no SQLite at all). The cascade scheme needs it: for a parent
    ///   delete, `files_bd` is the ONLY effective `segcounters` decrement, and the cascade-fired `seg_ad`
    ///   firings see a NULL bucket lookup (the parent row is already gone) and stand down; in app order
    ///   (`deleteSegments` then `DELETE FROM files`) `seg_ad` decrements per row and `files_bd` then
    ///   decrements by zero. Both orders land on exactly one decrement per segment (measured firing-by-
    ///   firing in the audit; re-measured in `cascadeFiringCountsOnceInBothOrders`).
    /// * The WHEN guards split `files_au_state` (path unchanged) and `files_au_path` (path or bucket
    ///   changed — the amended guard, Finding 2) so that every file UPDATE in the codebase lands on
    ///   exactly one counter maintenance (Finding 3's five measured shapes). `bucket` is derived from
    ///   `path` and is written only by `insert`, `move`, and the migration backfill — a statement that
    ///   sets `bucket` alone is exactly the shape the amended guard now catches.
    private static let countersTablesSQL = """
        CREATE TABLE IF NOT EXISTS counters(
            bucket TEXT NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            n INTEGER NOT NULL DEFAULT 0,
            leftsum INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(bucket, kind, state)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS segcounters(
            bucket TEXT NOT NULL,
            hasvec INTEGER NOT NULL,
            n INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(bucket, hasvec)
        ) WITHOUT ROWID;
        """

    /// The eight triggers, both amendments applied (`files_au_path`'s bucket guard, Finding 2;
    /// COALESCE-outside-MAX at all six row-term sites, Finding 8), plus the state-first covering index
    /// that makes the scoped reads Θ(folders) (Finding 9: the state-filtered reads as filed cost
    /// rows × ranges, 11.1 s measured at 2.985M rows × 100 ranges; with `counters_state` and a
    /// scope-driven join the same query measured 0.4 ms, exact against live aggregation).
    /// `IF NOT EXISTS` on everything: the migration re-run after a partial state (Finding 12).
    static let counterTriggersSQL = {
        func term(_ s: String, _ i: String) -> String { IndexStore.partialTerm(s, i) }
        let moveCounters = """
            UPDATE counters SET n = counters.n - 1,
                leftsum = counters.leftsum - \(term("old.state", "old.info"))
            WHERE bucket = old.bucket AND kind = old.kind AND state = old.state;
            INSERT INTO counters(bucket, kind, state, n, leftsum)
            VALUES (new.bucket, new.kind, new.state, 1, \(term("new.state", "new.info")))
            ON CONFLICT(bucket, kind, state) DO UPDATE SET n = counters.n + 1, leftsum = counters.leftsum + excluded.leftsum;
            """
        var sql = """
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                INSERT INTO counters(bucket, kind, state, n, leftsum)
                VALUES (new.bucket, new.kind, new.state, 1, \(term("new.state", "new.info")))
                ON CONFLICT(bucket, kind, state) DO UPDATE SET n = counters.n + 1, leftsum = counters.leftsum + excluded.leftsum;
            END;
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                UPDATE counters SET n = counters.n - 1,
                    leftsum = counters.leftsum - \(term("old.state", "old.info"))
                WHERE bucket = old.bucket AND kind = old.kind AND state = old.state;
            END;
            CREATE TRIGGER IF NOT EXISTS files_au_state AFTER UPDATE OF kind, state, info ON files WHEN old.path IS new.path BEGIN
                \(moveCounters)
            END;
            CREATE TRIGGER IF NOT EXISTS files_au_path AFTER UPDATE OF path, bucket ON files
                WHEN old.path IS NOT new.path OR old.bucket IS NOT new.bucket BEGIN
            """
        sql += """
                \(moveCounters)
                UPDATE segcounters SET n = segcounters.n - (SELECT COUNT(*) FROM segments WHERE file = new.id AND kind != 'name' AND vec IS NULL)
                WHERE bucket = old.bucket AND hasvec = 0;
                UPDATE segcounters SET n = segcounters.n - (SELECT COUNT(*) FROM segments WHERE file = new.id AND kind != 'name' AND vec IS NOT NULL)
                WHERE bucket = old.bucket AND hasvec = 1;
                INSERT INTO segcounters(bucket, hasvec, n)
                SELECT new.bucket, 0, COUNT(*) FROM segments WHERE file = new.id AND kind != 'name' AND vec IS NULL HAVING COUNT(*) > 0
                ON CONFLICT(bucket, hasvec) DO UPDATE SET n = segcounters.n + excluded.n;
                INSERT INTO segcounters(bucket, hasvec, n)
                SELECT new.bucket, 1, COUNT(*) FROM segments WHERE file = new.id AND kind != 'name' AND vec IS NOT NULL HAVING COUNT(*) > 0
                ON CONFLICT(bucket, hasvec) DO UPDATE SET n = segcounters.n + excluded.n;
            END;
            CREATE TRIGGER IF NOT EXISTS files_bd BEFORE DELETE ON files BEGIN
                UPDATE segcounters SET n = segcounters.n - (SELECT COUNT(*) FROM segments WHERE file = old.id AND kind != 'name' AND vec IS NULL)
                WHERE bucket = old.bucket AND hasvec = 0;
                UPDATE segcounters SET n = segcounters.n - (SELECT COUNT(*) FROM segments WHERE file = old.id AND kind != 'name' AND vec IS NOT NULL)
                WHERE bucket = old.bucket AND hasvec = 1;
            END;
            CREATE TRIGGER IF NOT EXISTS seg_ai AFTER INSERT ON segments
                WHEN new.kind != 'name' AND EXISTS (SELECT 1 FROM files WHERE id = new.file) BEGIN
                INSERT INTO segcounters(bucket, hasvec, n)
                VALUES ((SELECT bucket FROM files WHERE id = new.file), new.vec IS NOT NULL, 1)
                ON CONFLICT(bucket, hasvec) DO UPDATE SET n = segcounters.n + 1;
            END;
            CREATE TRIGGER IF NOT EXISTS seg_ad AFTER DELETE ON segments WHEN old.kind != 'name' BEGIN
                UPDATE segcounters SET n = segcounters.n - 1
                WHERE bucket = (SELECT bucket FROM files WHERE id = old.file) AND hasvec = (old.vec IS NOT NULL);
            END;
            CREATE TRIGGER IF NOT EXISTS seg_au_vec AFTER UPDATE OF vec ON segments WHEN old.kind != 'name' AND new.kind != 'name' BEGIN
                UPDATE segcounters SET n = segcounters.n - 1
                WHERE bucket = (SELECT bucket FROM files WHERE id = new.file) AND hasvec = (old.vec IS NOT NULL);
                INSERT INTO segcounters(bucket, hasvec, n)
                VALUES ((SELECT bucket FROM files WHERE id = new.file), (new.vec IS NOT NULL), 1)
                ON CONFLICT(bucket, hasvec) DO UPDATE SET n = segcounters.n + 1;
            END;
            CREATE INDEX IF NOT EXISTS counters_state ON counters(state, bucket, kind, n, leftsum);
            """
        return sql
    }()

    /// Fill counters and segcounters from full aggregation (the migration's fill and `rebuildCounters`'
    /// repair; the aggregate uses `partialTerm`, so it agrees with the triggers by construction).
    private func fillCounters() throws {
        try db.execute("""
            DELETE FROM counters;
            DELETE FROM segcounters;
            INSERT INTO counters(bucket, kind, state, n, leftsum)
            SELECT bucket, kind, state, COUNT(*), \(Self.partialSum()) FROM files GROUP BY bucket, kind, state;
            INSERT INTO segcounters(bucket, hasvec, n)
            SELECT f.bucket, s.vec IS NOT NULL, COUNT(*) FROM segments s JOIN files f ON f.id = s.file
            WHERE s.kind != 'name' GROUP BY f.bucket, s.vec IS NOT NULL;
            """)
    }

    /// Do counters and segcounters equal full aggregation, row for row, over the whole library? A
    /// NULL-safe `IS NOT` full join against the live GROUP BY: a group missing its counter row, a
    /// non-zero row with no group, and any n/leftsum disagreement are mismatches. Zero-valued counter
    /// rows with no group stand tolerated (Finding 9's churn residue — they add 0, which is the truth,
    /// and the triggers' upserts reuse them): the join filter keeps them out of the match, and the
    /// `NOT (key IS NULL AND n = 0 …)` clause forgives the counters-only row that remains, without
    /// forgiving a zeroed row that stands over files — that group then appears on its own side of the
    /// join (its counter row was filtered away) and is flagged there. The migration's gate before the
    /// version stamp, the check `rebuildCounters` ends with, and the tests' oracle companion.
    public func countersAreConsistent() throws -> Bool {
        var mismatches: Int64 = 0
        try db.query("""
            SELECT (SELECT COUNT(*) FROM (
                        SELECT bucket, kind, state, COUNT(*) AS n, \(Self.partialSum()) AS leftsum
                        FROM files GROUP BY bucket, kind, state) f
                    FULL OUTER JOIN counters c
                        ON c.bucket = f.bucket AND c.kind = f.kind AND c.state = f.state
                        AND (c.n != 0 OR c.leftsum != 0)
                    WHERE (f.n IS NOT c.n OR f.leftsum IS NOT c.leftsum)
                        AND NOT (f.bucket IS NULL AND c.n = 0 AND c.leftsum = 0))
                  + (SELECT COUNT(*) FROM (
                        SELECT f.bucket, s.vec IS NOT NULL AS hasvec, COUNT(*) AS n
                        FROM segments s JOIN files f ON f.id = s.file
                        WHERE s.kind != 'name' GROUP BY f.bucket, s.vec IS NOT NULL) g
                    FULL OUTER JOIN segcounters q ON q.bucket = g.bucket AND q.hasvec = g.hasvec AND q.n != 0
                    WHERE g.n IS NOT q.n AND NOT (g.bucket IS NULL AND q.n = 0))
            """) { mismatches = $0.int(0) }
        return mismatches == 0
    }

    /// Recompute every counter row from full aggregation, in one transaction, and verify it: the
    /// documented self-heal (audit Findings 1/3) — the full aggregation is the truth, and any future
    /// path that breaks a trigger invariant can be repaired here without reindexing (the audit measured
    /// the full aggregation over 1.2M rows at 36 s; failure rolls back and the counters stand as they were).
    public func rebuildCounters() throws {
        try db.transaction {
            try fillCounters()
            guard try countersAreConsistent() else {
                throw Database.Failure(message: "counter rebuild disagrees with the files table")
            }
        }
    }

    /// Housekeeping (Finding 9): emptied groups keep their counter rows at zero — reads stay exact with
    /// them (they add 0, and `countersAreConsistent` allows them), and they were ~75% of rows after
    /// heavy churn in the 5M-file matrix. This clears them; the triggers' upserts re-create rows on
    /// demand, so nothing is needed to keep them. No app path calls this automatically — it is
    /// maintenance, exercised by `zeroRowsPruneAndRegrow`.
    public func pruneZeroCounterRows() throws {
        try db.execute("DELETE FROM counters WHERE n = 0 AND leftsum = 0; DELETE FROM segcounters WHERE n = 0;")
    }
    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Files

    static let fileColumns = "id, path, kind, size, mtime, inode, device, state, detail"

    static func record(_ row: Statement) -> FileRecord {
        FileRecord(id: row.int(0), path: row.text(1) ?? "", kind: FileKind(rawValue: row.text(2) ?? "") ?? .doc,
                   size: row.int(3), mtime: row.double(4), inode: UInt64(bitPattern: row.int(5)),
                   device: UInt64(bitPattern: row.int(6)), state: row.text(7) ?? "pending", detail: row.text(8))
    }

    /// Every file under one of `roots`.
    public func files(under roots: [String]) throws -> [FileRecord] {
        var out: [FileRecord] = []
        var seen = Set<Int64>()   // each file once, also where two spellings of a folder meet
        // A folder inside another one listed is already covered.
        for root in roots where !roots.contains(where: { FolderSelection.isInside(root, $0) }) {
            for range in Self.pathRanges(under: root) {
                try db.query("SELECT \(Self.fileColumns) FROM files WHERE path >= ? AND path < ?",
                             [.text(range.from), .text(range.to)]) { row in
                    let record = Self.record(row)
                    if seen.insert(record.id).inserted { out.append(record) }
                }
            }
        }
        return out
    }

    /// Adds a file (pending) and returns its id.
    @discardableResult
    public func insert(_ file: Candidate) throws -> Int64 {
        try db.transaction {   // the row and its name entry together
            try db.run("INSERT INTO files(path, kind, size, mtime, inode, device, bucket) VALUES(?, ?, ?, ?, ?, ?, ?)",
                       [.text(file.path), .text(file.kind.rawValue), .int(file.size), .double(file.mtime),
                        .int(Int64(bitPattern: file.inode)), .int(Int64(bitPattern: file.device)),
                        .text(Self.bucket(of: file.path))])
            let id = db.lastInsertID
            try addNameRow(file: id, path: file.path)
            return id
        }
    }

    /// The file changed on disk: drop what was extracted from it and queue it again.
    public func requeue(_ id: Int64, as file: Candidate) throws {
        try db.transaction {
            try deleteSegments(of: id, keepingName: true)
            try db.run("""
                UPDATE files SET kind = ?, size = ?, mtime = ?, inode = ?, device = ?, state = 'pending', detail = NULL,
                    info = NULL, indexed_at = NULL WHERE id = ?
                """, [.text(file.kind.rawValue), .int(file.size), .double(file.mtime),
                      .int(Int64(bitPattern: file.inode)), .int(Int64(bitPattern: file.device)), .int(id)])
        }
    }

    /// Extract and embed the file again, as it is (after a better way to read it arrived).
    func requeue(_ id: Int64) throws {
        try db.transaction {
            try deleteSegments(of: id, keepingName: true)
            try db.run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL WHERE id = ?",
                       [.int(id)])
        }
    }

    /// Same inode, size and date at a new path: a move or rename. Only the path changes; nothing is re-embedded.
    /// (Screenshot tools move screenshots into project folders all the time.)
    public func move(_ id: Int64, to path: String) throws {
        try db.transaction {   // the path and its name entry together
            try db.run("UPDATE files SET path = ?, bucket = ? WHERE id = ?",   // counters: path and bucket
                       [.text(path), .text(Self.bucket(of: path)), .int(id)])  // move in one statement
            try db.run("""
                UPDATE fts SET name = ?, body = ? WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind = 'name')
                """, [.text(SearchText.normalized(Self.nameText(path))), .text(SearchText.normalized(Self.folderText(path))),
                      .int(id)])
        }
    }

    public func delete(_ id: Int64) throws {
        try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ?)", [.int(id)])
        try db.run("DELETE FROM files WHERE id = ?", [.int(id)])
    }

    /// Removes every file that isn't under one of `roots` (folders taken out of the app). Returns how many went.
    @discardableResult
    public func prune(keepingUnder roots: [String]) throws -> Int {
        let prefixes = roots.flatMap { Self.pathRanges(under: $0).map(\.from) }   // a folder under /var: /private/var too
        var gone: [Int64] = []
        try db.query("SELECT id, path FROM files") { row in
            let path = row.text(1) ?? ""
            if !prefixes.contains(where: { path.hasPrefix($0) }) { gone.append(row.int(0)) }
        }
        guard !gone.isEmpty else { return 0 }
        try db.transaction {
            for id in gone { try delete(id) }
        }
        return gone.count
    }

    /// Queues every file again and forgets the fingerprint (after the model or settings changed).
    public func resetAll() throws {
        try db.transaction {
            try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE kind != 'name')")
            try db.run("DELETE FROM segments WHERE kind != 'name'")
            try db.run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL")
            try setMeta("fingerprint", nil)
        }
    }

    /// Files waiting to be embedded, in indexing order; `only` narrows it to some files (just-added ones).
    public func pending(limit: Int?, only ids: Set<Int64>? = nil) throws -> [FileRecord] {
        var out: [FileRecord] = []
        if let ids, ids.isEmpty { return out }
        let filter = ids.map { " AND id IN (\($0.map(String.init).joined(separator: ",")))" } ?? ""
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'pending'\(filter)\(scopeSQL)
            ORDER BY \(FileKind.indexingOrderSQL), mtime DESC LIMIT ?
            """, [.int(Int64(limit ?? -1))]) { out.append(Self.record($0)) }
        return out
    }

    /// Files waiting to be embedded (#193: read from the counters, not aggregated). Nil scope sums the
    /// `counters` table's pending section; a folder scope joins from `scopeb` so the cost is one index
    /// seek per connected folder, not a sweep of the counter table (audit Finding 9, measured: the
    /// state-filtered plain join costs rows × ranges — 11.1 s at 2.985M rows × 100 ranges; the CROSS
    /// JOIN form seeks `counters_state (state=? AND bucket>? AND bucket<?)` per range, 0.4 ms measured,
    /// exact against live aggregation). `CROSS JOIN` pins the join order (SCAN b, then the seek): the
    /// plain JOIN keeps the full-scan plan even with the index (measured 4 s) — tests assert the plan text.
    /// An empty scope means an empty `scopeb`, which joins to zero — the same all-zero answer the old
    /// ` AND 0` form gave.
    public func pendingCount() throws -> Int {
        var count = 0
        if scope == nil {
            try db.query("SELECT COALESCE(SUM(n), 0) FROM counters WHERE state = 'pending'") {
                count = Int($0.int(0))
            }
        } else {
            try db.query("""
                SELECT COALESCE(SUM(c.n), 0) FROM scopeb b CROSS JOIN counters c
                ON c.state = 'pending' AND c.bucket >= b.lo AND c.bucket < b.hi
                """) { count = Int($0.int(0)) }
        }
        return count
    }

    /// Long files with pages or chunks still to read after their first step, in indexing order (`pending`'s).
    public func unfinished() throws -> [FileRecord] {
        var out: [FileRecord] = []
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'partial'\(scopeSQL)
            ORDER BY \(FileKind.indexingOrderSQL), mtime DESC
            """) { out.append(Self.record($0)) }
        return out
    }

    /// How many long files are unfinished, and how many of their pages and chunks are left to read
    /// (#193: `n` and `leftsum` from the counters; `leftsum` is maintained with the exact per-row shape
    /// this query's SUM produced — Finding 8's amended term, one source with the triggers and the fill).
    /// Same join contract as `pendingCount`; a partial row with one key (`{"read_end":"9"}`) counts 0
    /// toward `left`, as production measures it.
    public func unfinishedCount() throws -> (files: Int, left: Int) {
        var count = (files: 0, left: 0)
        if scope == nil {
            try db.query("SELECT COALESCE(SUM(n), 0), COALESCE(SUM(leftsum), 0) FROM counters WHERE state = 'partial'") {
                count = (Int($0.int(0)), Int($0.int(1)))
            }
        } else {
            try db.query("""
                SELECT COALESCE(SUM(c.n), 0), COALESCE(SUM(c.leftsum), 0)
                FROM scopeb b CROSS JOIN counters c
                ON c.state = 'partial' AND c.bucket >= b.lo AND c.bucket < b.hi
                """) { count = (Int($0.int(0)), Int($0.int(1))) }
        }
        return count
    }

    /// What indexing learned about a file (`finish`'s `info`).
    public func info(of id: Int64) throws -> [String: String] {
        var info: [String: String] = [:]
        try db.query("SELECT info FROM files WHERE id = ?", [.int(id)]) { row in
            if let json = row.text(0)?.data(using: .utf8) {
                info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
            }
        }
        return info
    }

    /// The last page or chunk stored for a file (where a long file's reading got to, when its info doesn't say).
    func lastPlace(of id: Int64) throws -> Int? {
        var last: Int?
        try db.query("SELECT MAX(loc) FROM segments WHERE file = ? AND kind IN ('page', 'page_image', 'chunk')",
                     [.int(id)]) { last = $0.isNull(0) ? nil : Int($0.double(0)) }
        return last
    }

    public func finish(_ id: Int64, state: String, detail: String? = nil, info: [String: String] = [:]) throws {
        let json = info.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.run("UPDATE files SET state = ?, detail = ?, info = ?, indexed_at = ? WHERE id = ?",
                   [.text(state), .optional(detail), .optional(json), .double(Date().timeIntervalSince1970), .int(id)])
    }

    /// Files read once more because DigUp reads them better now, each kind once per index (the schema stays as it was,
    /// so an older DigUp still opens the index): PDFs with pages read as pictures, whose words come from OCR now
    /// (`meta` "scans_ocr"), and pictures that couldn't be read at all, like SVGs, which AppKit draws now
    /// ("pictures_drawn"). Only where this machine does either. Returns how many files.
    @discardableResult
    public func readAgainOnce() throws -> Int {
        var files = Set<Int64>(), flags: [String] = []
        if OCR.isAvailable, try meta("scans_ocr") == nil {
            try db.query("SELECT DISTINCT file FROM segments WHERE kind = 'page_image'") { files.insert($0.int(0)) }
            flags.append("scans_ocr")
        }
        if ImageExtractor.drawsVectorPictures, try meta("pictures_drawn") == nil {
            try db.query("SELECT id FROM files WHERE kind = 'image' AND state = 'skipped' AND detail = ?",
                         [.text(ExtractError.tooSmall(0, 0).description)]) { files.insert($0.int(0)) }
            flags.append("pictures_drawn")
        }
        guard !flags.isEmpty else { return 0 }
        try db.transaction {
            for file in files { try requeue(file) }
            for flag in flags { try setMeta(flag, "1") }
        }
        return files.count
    }

    /// A file the indexing helper had to stop on (reading it ran away): it isn't read again until it changes. A long
    /// file that was being finished keeps what was read of it. False when no file has that path.
    @discardableResult
    public func markStopped(_ path: String, why: String) throws -> Bool {
        var found: (id: Int64, state: String)?
        try db.query("SELECT id, state FROM files WHERE path = ?", [.text(path)]) { found = ($0.int(0), $0.text(1) ?? "") }
        guard let found else { return false }
        if found.state == "partial" {
            try finish(found.id, state: "done", detail: "The rest couldn't be read: it \(why)")
        } else {
            try finish(found.id, state: "failed", detail: "It \(why)")
        }
        return true
    }

    // MARK: Segments

    /// Adds a segment; `text` goes into keyword search (normalized, see `SearchText`), `vector` into meaning search.
    public func addSegment(file: Int64, kind: SegmentKind, modality: Modality, loc: Double? = nil, locEnd: Double? = nil,
                           excerpt: String? = nil, text: String? = nil, vector: [Float]? = nil) throws {
        try db.transaction {   // the segment and its keyword text together
            try db.run("INSERT INTO segments(file, kind, modality, loc, loc_end, excerpt, vec) VALUES(?, ?, ?, ?, ?, ?, ?)",
                       [.int(file), .text(kind.rawValue), .text(vector == nil ? Modality.none.rawValue : modality.rawValue),
                        .optional(loc), .optional(locEnd), .optional(excerpt),
                        vector.map { .blob(Vectors.half($0)) } ?? .null])
            if let text, !text.isEmpty {
                try db.run("INSERT INTO fts(rowid, name, body, original) VALUES(?, '', ?, ?)",
                           [.int(db.lastInsertID)] + Self.keywordText(text))
            }
        }
    }

    /// `body` and `original` for keyword search: the normalized text, and the text as written if that differs.
    static func keywordText(_ text: String) -> [SQLValue] {
        let normalized = SearchText.normalized(text)
        return [.text(normalized), normalized == text ? .null : .text(text)]
    }

    private func addNameRow(file: Int64, path: String) throws {
        try db.run("INSERT INTO segments(file, kind, modality) VALUES(?, 'name', 'none')", [.int(file)])
        try db.run("INSERT INTO fts(rowid, name, body) VALUES(?, ?, ?)",
                   [.int(db.lastInsertID), .text(SearchText.normalized(Self.nameText(path))),
                    .text(SearchText.normalized(Self.folderText(path)))])
    }

    private func deleteSegments(of file: Int64, keepingName: Bool) throws {
        let filter = keepingName ? "AND kind != 'name'" : ""
        try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? \(filter))", [.int(file)])
        try db.run("DELETE FROM segments WHERE file = ? \(filter)", [.int(file)])
    }

    /// "Screenshot 2026-10-01 at 9.41.07 PM.png" → searchable words.
    static func nameText(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The folders a file sits in, relative to the home folder ("Downloads Invoices"), as low-weight keywords.
    static func folderText(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = (path as NSString).deletingLastPathComponent
        if folder.hasPrefix(home) { folder = String(folder.dropFirst(home.count)) }
        return folder.split(separator: "/").joined(separator: " ")
    }

    // MARK: Stats

    public struct Counts: Sendable {
        public var byKindAndState: [String: [String: Int]] = [:]
        public var vectors = 0
        public var segments = 0
        /// Long files still being read (`unfinishedCount`), and their pages and chunks left.
        public var unfinished = 0
        public var left = 0
    }

    /// What indexing learned, in totals (#193: counters reads; `fullCounts` is the aggregation form kept
    /// as the tests' oracle). The `byKindAndState` dictionary lists only groups with files — zero-valued
    /// counter rows (Finding 9's churn residue) are skipped, exactly as the old GROUP BY returned no row
    /// for an absent group. Nil scope scans the two covering counter tables; a folder scope drives from
    /// `scopeb` (PK bucket seek, Θ(folders)); an empty scope joins to zero, matching the old ` AND 0`.
    public func counts() throws -> Counts {
        var counts = Counts()
        let rowSQL = scope == nil
            ? "SELECT kind, state, SUM(n) FROM counters GROUP BY kind, state"
            : "SELECT c.kind, c.state, SUM(c.n) FROM scopeb b CROSS JOIN counters c ON c.bucket >= b.lo AND c.bucket < b.hi GROUP BY c.kind, c.state"
        try db.query(rowSQL) { row in
            let n = Int(row.int(2))
            guard n != 0 else { return }
            counts.byKindAndState[row.text(0) ?? "?", default: [:]][row.text(1) ?? "?"] = n
        }
        (counts.unfinished, counts.left) = try unfinishedCount()
        let segSQL = scope == nil
            ? "SELECT hasvec, SUM(n) FROM segcounters GROUP BY hasvec"
            : "SELECT c.hasvec, SUM(c.n) FROM scopeb b CROSS JOIN segcounters c ON c.bucket >= b.lo AND c.bucket < b.hi GROUP BY c.hasvec"
        try db.query(segSQL) { row in
            counts.segments += Int(row.int(1))
            if row.int(0) == 1 { counts.vectors += Int(row.int(1)) }
        }
        return counts
    }

    // MARK: Full aggregation — the oracle (#193 keeps it)

    /// `pendingCount`'s aggregation form, verbatim as shipped before the counters. Every counters test
    /// compares the maintained answer against this; `rebuildCounters` is built from this class of query.
    public func fullPendingCount() throws -> Int {
        var count = 0
        try db.query("SELECT COUNT(*) FROM files WHERE state = 'pending'\(scopeSQL)") {
            count = Int($0.int(0))
        }
        return count
    }

    /// `unfinishedCount`'s aggregation form, verbatim as shipped before the counters.
    public func fullUnfinishedCount() throws -> (files: Int, left: Int) {
        var count = (files: 0, left: 0)
        try db.query("""
            SELECT COUNT(*), SUM(MAX(0, CAST(json_extract(info, '$.read_end') AS INTEGER)
                                      - CAST(json_extract(info, '$.read_to') AS INTEGER)))
            FROM files WHERE state = 'partial'\(scopeSQL)
            """) { count = (Int($0.int(0)), Int($0.int(1))) }
        return count
    }

    /// `counts`' aggregation form, verbatim as shipped before the counters.
    public func fullCounts() throws -> Counts {
        var counts = Counts()
        try db.query("SELECT kind, state, COUNT(*) FROM files WHERE 1\(scopeSQL) GROUP BY kind, state") {
            counts.byKindAndState[$0.text(0) ?? "?", default: [:]][$0.text(1) ?? "?"] = Int($0.int(2))
        }
        (counts.unfinished, counts.left) = try fullUnfinishedCount()
        let inScope = scope == nil ? "" : " AND file IN (SELECT id FROM files WHERE 1\(scopeSQL))"
        try db.query("SELECT COUNT(*), COUNT(vec) FROM segments WHERE kind != 'name'\(inScope)") {
            counts.segments = Int($0.int(0))
            counts.vectors = Int($0.int(1))
        }
        return counts
    }
}

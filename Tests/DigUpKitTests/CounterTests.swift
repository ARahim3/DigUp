import Foundation
import Testing
@testable import DigUpKit

/// Issue #193: the counter tables, their triggers, the scoped joins, and the schema-v6 migration.
/// Every test compares the maintained counters against full aggregation over `files`/`segments` —
/// `fullCounts`/`fullPendingCount`/`fullUnfinishedCount` are the pre-counters production forms kept
/// verbatim as the oracle, and `countersAreConsistent` is the row-for-row check the migration runs
/// before it stamps v6.
@Suite struct CounterTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpCounters-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func file(_ path: String, inode: UInt64, kind: FileKind = .image) -> Candidate {
        Candidate(path: path, kind: kind, size: 10, mtime: 1, inode: inode, device: 1)
    }

    /// The oracle pair: maintained totals equal aggregated totals, every field.
    func expectEqual(_ a: IndexStore.Counts, _ b: IndexStore.Counts, _ note: String = "") throws {
        #expect(a.byKindAndState == b.byKindAndState, "byKindAndState \(note)")
        #expect(a.segments == b.segments, "segments \(note)")
        #expect(a.vectors == b.vectors, "vectors \(note)")
        #expect(a.unfinished == b.unfinished, "unfinished \(note)")
        #expect(a.left == b.left, "left \(note)")
    }

    /// All four comparisons at once, under the scope the store currently carries.
    func expectAllMatch(_ store: IndexStore, _ note: String = "") throws {
        #expect(try store.countersAreConsistent(), "row-for-row consistency \(note)")
        try expectEqual(store.counts(), store.fullCounts(), note)
        #expect(try store.pendingCount() == store.fullPendingCount(), "pendingCount \(note)")
        #expect(try store.unfinishedCount() == store.fullUnfinishedCount(), "unfinishedCount \(note)")
    }

    func version(_ store: IndexStore) throws -> Int64 {
        var v: Int64 = -1
        try store.db.query("PRAGMA user_version") { v = $0.int(0) }
        return v
    }

    /// Back to the v5 shape: the counters layout and the bucket column go, the version stamp drops.
    /// `keepColumn` simulates a migration interrupted after the ALTER (Finding 12's partial states).
    /// (DROP TRIGGER/INDEX/TABLE take `IF EXISTS` — SQLite has no `IF NOT EXISTS` on DROP: that's the
    /// syntax the interrupted-migration re-runs must tolerate, not the test's setup.)
    func dropToV5(_ store: IndexStore, keepColumn: Bool = false, keepCounters: Bool = false) throws {
        var sql = """
            DROP TRIGGER IF EXISTS files_ai; DROP TRIGGER IF EXISTS files_ad;
            DROP TRIGGER IF EXISTS files_au_state; DROP TRIGGER IF EXISTS files_au_path;
            DROP TRIGGER IF EXISTS files_bd; DROP TRIGGER IF EXISTS seg_ai;
            DROP TRIGGER IF EXISTS seg_ad; DROP TRIGGER IF EXISTS seg_au_vec;
            DROP INDEX IF EXISTS counters_state;
            """
        if !keepCounters { sql += " DROP TABLE IF EXISTS counters; DROP TABLE IF EXISTS segcounters;" }
        if !keepColumn { sql += " ALTER TABLE files DROP COLUMN bucket;" }
        sql += " PRAGMA user_version = 5;"
        try store.db.execute(sql)
    }

    // MARK: Write paths

    @Test func countersFollowEveryWritePath() throws {
        let store = try IndexStore(directory: folder)
        try expectAllMatch(store, "empty")   // fresh database: counters exist, all zero
        // insert (+ the name segment seg_ai guards out)
        let a = try store.insert(file("/t/a/x.png", inode: 1))
        let b = try store.insert(file("/t/a/sub/y.pdf", inode: 2))
        let c = try store.insert(file("/t/b/z.doc", inode: 3))
        try expectAllMatch(store, "inserts")
        // segments with and without vectors
        let vec = [Float](repeating: 0.25, count: 768)
        try store.addSegment(file: a, kind: .image, modality: .image, vector: vec)
        try store.addSegment(file: a, kind: .ocr, modality: .text, text: "road report")
        try store.addSegment(file: b, kind: .page, modality: .text, loc: 1, text: "harbour pages")
        try store.addSegment(file: c, kind: .chunk, modality: .text, loc: 1, text: "long text", vector: vec)
        try expectAllMatch(store, "segments")
        // finish: every state shape
        try store.finish(a, state: "done", info: ["pixels": "800x600"])
        try store.finish(b, state: "partial", detail: "read to page 2",
                         info: ["read_to": "2", "read_end": "9", "pages": "9"])
        try store.finish(c, state: "skipped", detail: "too small", info: [:])
        try expectAllMatch(store, "finishes")
        // the vector-NULL migration shape (migrateLongFiles/migrateScreenshotText): seg_au_vec
        var nulled: [Int64] = []
        try store.db.query("SELECT id FROM segments WHERE vec IS NOT NULL") { nulled.append($0.int(0)) }
        for id in nulled {
            try store.db.run("UPDATE segments SET vec = NULL, modality = 'none' WHERE id = ?", [.int(id)])
        }
        try expectAllMatch(store, "vectors nulled")
        // rename: path + bucket in one statement, segcounters relocate with it
        try store.move(a, to: "/t/c/x.png")
        try expectAllMatch(store, "rename")
        // requeue: deleteSegments (app order) + the state/kind UPDATE
        try store.requeue(b, as: file("/t/a/sub/y.pdf", inode: 22, kind: .doc))
        try expectAllMatch(store, "requeue as candidate")
        try store.requeue(a)
        try expectAllMatch(store, "requeue plain")
        // markStopped: a long file being finished becomes done
        #expect(try store.markStopped("/t/b/z.doc", why: "ran away"))
        try expectAllMatch(store, "markStopped")
        // delete: cascade, files_bd + files_ad (Finding 5's cascade order)
        try store.delete(c)
        try expectAllMatch(store, "delete")
        // prune: per-id deletes of everything outside the kept roots
        #expect(try store.prune(keepingUnder: ["/t/a"]) == 1)
        try expectAllMatch(store, "prune")
        // resetAll: bulk seg_ad + one files_au_state per file
        try store.resetAll()
        try expectAllMatch(store, "resetAll")
        // the failed inner transaction: its counters undo, the outer's stand (Database.savepoint nesting)
        struct Oops: Error {}
        try store.db.transaction {
            try store.insert(file("/t/a/keep.png", inode: 40))
            #expect(throws: Oops.self) {
                try store.db.transaction {
                    try store.insert(file("/t/a/gone.png", inode: 41))
                    throw Oops()
                }
            }
        }
        try expectAllMatch(store, "failed inner transaction")
    }

    @Test func stateTransitionsInBothDirections() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(file("/t/doc.txt", inode: 1, kind: .doc))
        let pair: [String: String] = ["read_to": "10", "read_end": "40"]
        let done: [String: String] = ["chars": "60000"]
        // pending → done → pending → partial → done → partial → skipped → partial → failed → pending
        for step: (String, [String: String]) in [
            ("done", done), ("pending", [:]), ("partial", pair), ("done", done), ("partial", pair),
            ("skipped", [:]), ("partial", pair), ("failed", [:]), ("pending", [:]),
        ] {
            try store.finish(id, state: step.0, info: step.1)
            try expectAllMatch(store, "to \(step.0)")
        }
        // the same-value UPDATE (OF list names the columns, values equal): −1/+1 on one row
        try store.finish(id, state: "pending", info: [:])
        try expectAllMatch(store, "same-value requeue")
    }

    @Test func oneKeyPartialRowsCountAsProduction() throws {
        // Finding 8's amendment: COALESCE outside MAX. Production's per-row term is
        // MAX(0, read_end − read_to): a NULL key makes it NULL, and SUM skips the row → 0.
        let store = try IndexStore(directory: folder)
        let oneKey = try store.insert(file("/t/p/one.pdf", inode: 1, kind: .pdf))
        let bothKeys = try store.insert(file("/t/p/both.pdf", inode: 2, kind: .pdf))
        let reversed = try store.insert(file("/t/p/back.pdf", inode: 3, kind: .pdf))
        try store.finish(oneKey, state: "partial", info: ["read_end": "9"])
        try store.finish(bothKeys, state: "partial", info: ["read_to": "12", "read_end": "40"])
        try store.finish(reversed, state: "partial", info: ["read_to": "40", "read_end": "12"])
        try expectAllMatch(store, "one-key partials")
        let (files, left) = try store.unfinishedCount()
        #expect(files == 3 && left == 28, "3 partial rows, 28 left: production's answer")
        // a malformed info on a NON-partial row is accepted (the CASE never extracts it)
        try store.finish(oneKey, state: "skipped", detail: "not json", info: [:])
        try store.db.run("UPDATE files SET info = 'not json' WHERE id = ?", [.int(oneKey)])
        try expectAllMatch(store, "malformed on a non-partial row")
        // transitioning it to partial via finish() is ACCEPTED: finish writes valid JSON, and the
        // trigger's CASE short-circuits — json_extract sees only the NEW info (old is 'skipped', its
        // term is 0 without extracting). Refusal is for malformed NEW info: the raw INSERT below.
        try store.finish(oneKey, state: "partial", info: [:])
        try expectAllMatch(store, "malformed old info transitioned out")
        #expect(try store.unfinishedCount().left == 28, "the transitioned row contributes 0 (empty info)")
        #expect(throws: (any Error).self) {
            try store.db.run("INSERT INTO files(path, kind, size, mtime, inode, device, bucket, state, info) "
                             + "VALUES('/t/p/bad.pdf', 'pdf', 10, 1, 99, 1, '/t/p', 'partial', 'not json')")
        }
        try expectAllMatch(store, "malformed partial refused")
    }

    @Test func vectorsAddRemoveAndFlip() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(file("/t/v/img.png", inode: 1))
        try store.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768))
        try expectAllMatch(store, "vector added")
        try store.db.run("UPDATE segments SET vec = NULL, modality = 'none' WHERE file = ?", [.int(id)])
        try expectAllMatch(store, "vector removed")
        try store.db.run("UPDATE segments SET vec = ? WHERE file = ? AND kind != 'name'",
                         [.blob(Vectors.half([Float](repeating: 0.2, count: 768))), .int(id)])
        try expectAllMatch(store, "vector back")
        try store.db.run("DELETE FROM segments WHERE file = ? AND kind != 'name'", [.int(id)])
        try expectAllMatch(store, "segments gone (app-order seg_ad)")
    }

    @Test func renameMovesCountersAcrossBuckets() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(file("/t/a/x.png", inode: 1))
        try store.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768))
        try store.finish(id, state: "done")
        // out of /t/a, into /t/b: counts, segments and vectors follow
        try store.setScope(["/t/a"])
        try expectAllMatch(store, "scoped at the old folder")
        try store.move(id, to: "/t/b/x.png")
        try expectAllMatch(store, "moved, scope still the old folder")
        #expect(try store.pendingCount() == 0 && store.counts().segments == 0)
        try store.setScope(["/t/b"])
        try expectAllMatch(store, "scoped at the new folder")
        #expect(try store.counts().segments == 1 && store.counts().vectors == 1)
        // a no-op move: the guard skips, counters stand
        try store.move(id, to: "/t/b/x.png")
        try expectAllMatch(store, "no-op move")
    }

    @Test func bucketOnlyUpdateRepairKeepsCountersFollowing() throws {
        // Finding 2's amendment, the G1 shape: `UPDATE files SET bucket = …` alone — exactly the
        // migration-backfill/repair shape — must maintain the counters, not drift them.
        let store = try IndexStore(directory: folder)
        let id = try store.insert(file("/t/a/x.png", inode: 1))
        try store.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768))
        try store.db.run("UPDATE files SET bucket = '/t/drift' WHERE id = ?", [.int(id)])
        try #require(try store.countersAreConsistent(), "counters followed the bucket surgery")
        var bucket: String?
        try store.db.query("SELECT bucket FROM counters WHERE bucket = '/t/drift'") { bucket = $0.text(0) }
        #expect(bucket == "/t/drift", "the counter row moved with the file")
        // the scoped counters (bucket space) and the scoped path query agree only on canonical
        // buckets: surgery shows the two spaces are joined, not glued — the documented contract
        try store.setScope(["/t/drift"])
        #expect(try store.pendingCount() == 1, "counters count the file at its new bucket")
        #expect(try store.fullPendingCount() == 0, "the path test still sees the file at its path")
        // repair back to canonical: the counters move back and the scoped forms agree again
        try store.db.run("UPDATE files SET bucket = ? WHERE id = ?", [.text(IndexStore.bucket(of: "/t/a/x.png")), .int(id)])
        try store.setScope(["/t/a"])
        try expectAllMatch(store, "repaired bucket")
    }

    @Test func cascadeFiringCountsOnceInBothOrders() throws {
        // Findings 3/5's firing evidence (the audit's cascade.py pattern, re-run in production SQL):
        // cascade order — files_bd decrements, cascade-fired seg_ad sees a NULL bucket and stands
        // down; app order (production `delete`'s shape) — seg_ad decrements per row with the parent
        // alive, files_bd fires on an empty nest. Two stores: the cascade half deliberately uses a
        // RAW parent delete to fire the cascade — and a raw cascade leaves the nest's fts5 rows
        // behind (nothing deletes them; production never raw-cascades: `delete` removes the fts rows
        // first). Left in one connection, the leaked rows collide with the next insert's reused
        // segment rowids, so the app-order half runs on a fresh store.
        func logTriggers(_ store: IndexStore) throws {
            try store.db.execute("""
                CREATE TEMP TABLE fired(name TEXT NOT NULL, detail TEXT);
                CREATE TEMP TRIGGER log_files_bd BEFORE DELETE ON files BEGIN
                    INSERT INTO fired VALUES('files_bd', CAST(old.id AS TEXT));
                END;
                CREATE TEMP TRIGGER log_seg_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO fired VALUES('seg_ad', (SELECT bucket FROM files WHERE id = old.file) IS NULL);
                END;
                """)
        }
        func fires(_ store: IndexStore, _ name: String) throws -> [String] {
            var out: [String] = []
            try store.db.query("SELECT detail FROM fired WHERE name = ? ORDER BY rowid", [.text(name)]) {
                out.append($0.text(0) ?? "?")
            }
            return out
        }
        let vec = [Float](repeating: 0.1, count: 768)
        func nest(_ store: IndexStore, _ candidate: Candidate, _ inode: UInt64) throws -> Int64 {
            let id = try store.insert(candidate)
            for i in 0..<5 {
                try store.addSegment(file: id, kind: i < 3 ? .image : .ocr, modality: .image, vector: i < 3 ? vec : nil)
            }
            return id
        }
        // cascade order: raw DELETE FROM files with a live nest
        let cascade = try IndexStore(directory: folder)
        try logTriggers(cascade)
        let cascaded = try nest(cascade, file("/c/one.png", inode: 1), 1)
        try cascade.finish(cascaded, state: "done")
        try cascade.db.run("DELETE FROM fired")
        try cascade.db.run("DELETE FROM files WHERE id = ?", [.int(cascaded)])
        #expect(try fires(cascade, "files_bd").count == 1, "files_bd fires once")
        #expect(try fires(cascade, "seg_ad") == Array(repeating: "1", count: 6),
                "every cascade-fired seg_ad row (the 5-segment nest + the name row) sees the parent gone (NULL bucket)")
        try #require(try cascade.countersAreConsistent(), "cascade: decremented exactly once")
        try expectAllMatch(cascade, "cascade store after")
        // app order: the production delete() shape — explicit segment deletes (fts first), then the file
        let app = try IndexStore(directory: folder.appendingPathComponent("app-order"))
        try logTriggers(app)
        let moved = try nest(app, file("/c/two.png", inode: 2), 2)
        try app.db.run("DELETE FROM fired")
        try app.db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind != 'name')", [.int(moved)])
        try app.db.run("DELETE FROM segments WHERE file = ? AND kind != 'name'", [.int(moved)])
        #expect(try fires(app, "seg_ad") == Array(repeating: "0", count: 5),
                "the app-order seg_ad rows all see a live parent (real bucket)")
        try app.delete(moved)   // fts rows, then the parent: the name row goes by cascade
        #expect(try fires(app, "files_bd").count == 1, "files_bd fires once, on a nest of only the name row")
        try #require(try app.countersAreConsistent(), "app order: decremented exactly once")
        try expectAllMatch(app, "app store after")
    }

    @Test func triggerSuiteIsTheEightAmendedTriggers() throws {
        let store = try IndexStore(directory: folder)
        var names: [String] = []
        try store.db.query("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name") {
            names.append($0.text(0) ?? "?")
        }
        #expect(names == ["files_ad", "files_ai", "files_au_path", "files_au_state",
                          "files_bd", "seg_ad", "seg_ai", "seg_au_vec"],
                "eight triggers (Finding 4: the prose's 'nine' is a typo)")
        let q = "%"   // Swift 6.2 reads % in literals as interpolation — SQL's wildcard goes through a value
        var amended = 0
        try store.db.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' "
                           + "AND sql LIKE '\(q)OR old.bucket IS NOT new.bucket\(q)'") { amended = Int($0.int(0)) }
        #expect(amended == 1, "Finding 2's guard amendment is in files_au_path")
        var coalesced = 0
        try store.db.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' "
                           + "AND sql LIKE '\(q)COALESCE(MAX(0\(q)'") { coalesced = Int($0.int(0)) }
        #expect(coalesced == 4, "Finding 8's nesting: COALESCE outside MAX at every row-term trigger (4 carry terms)")
        var covering = 0
        try store.db.query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'counters_state'") {
            covering = Int($0.int(0))
        }
        #expect(covering == 1, "Finding 9's state-first covering index")
        var fk: Int64 = 0
        try store.db.query("PRAGMA foreign_keys") { fk = $0.int(0) }   // Finding 6
        #expect(fk == 1, "writable connections carry foreign_keys=ON")
        // the segments.kind/.file immutability invariant (Finding 1) is pinned by the write-path test
    }

    // MARK: Scope shapes

    @Test func scopedReadsMatchAggregationOnEveryShape() throws {
        let store = try IndexStore(directory: folder)
        var inode: UInt64 = 1
        let vec = [Float](repeating: 0.1, count: 768)
        let seeds: [(path: String, kind: FileKind, state: String?, info: [String: String])] = [
            ("/x.png", .image, "done", [:]),
            ("/t/a/x.png", .image, nil, [:]),
            ("/t/a/y.png", .image, "done", [:]),
            ("/t/a/sub/z.pdf", .pdf, "partial", ["read_to": "2", "read_end": "9"]),
            ("/t/a/sub/deep/w.doc", .doc, "partial", ["read_end": "9"]),
            ("/t/ab/q.png", .image, nil, [:]),
            ("/t/a./d.png", .image, "done", [:]),
            ("/t/a !/e.png", .image, nil, [:]),
            ("/t/a\tt/f.png", .image, nil, [:]),
            ("/t/notes\u{00E9}/g.png", .image, nil, [:]),
            ("/t/notes\u{0301}/h.png", .image, nil, [:]),
            ("/t/mix/one.pdf", .pdf, "partial", ["read_to": "40", "read_end": "12"]),
            ("/t/mix/done.doc", .doc, "skipped", [:]),
        ]
        var ids: [Int64] = []
        for s in seeds {
            ids.append(try store.insert(file(s.path, inode: inode, kind: s.kind)))
            inode += 1
            if let state = s.state { try store.finish(ids.last!, state: state, info: s.info) }
        }
        try store.addSegment(file: ids[1], kind: .image, modality: .image, vector: vec)      // /t/a/x.png
        try store.addSegment(file: ids[3], kind: .page, modality: .text, loc: 1, text: "harbour pages")
        try store.addSegment(file: ids[11], kind: .chunk, modality: .text, loc: 1, text: "long text", vector: vec)
        let shapes: [[String]?] = [
            nil, [], ["/"], ["/t"], ["/t/a"], ["/t/a/sub"], ["/t/a", "/t/a/sub"],
            ["/t/a", "/t/ab"], ["/t/a", "/t/a"], ["/t/a/sub", "/t/a/sub/deep"],
            ["/t", "/t/a"], ["/t/a."], ["/t/a "], ["/t/a\tt"], ["/nope"], ["/notes"],
            ["/t/notes\u{0301}"], ["/t/notes\u{00E9}"],
            ["/t/a"] + (0..<1_200).map { "/root-\($0)" },
            (0..<2_400).map { "/root-\($0)" } + ["/t/a"],
        ]
        for shape in shapes {
            try store.setScope(shape)
            try expectAllMatch(store, "scope of \(shape?.count ?? -1)")
        }
        // What /t/a's own counters see: its direct children plus everything in its subfolders,
        // nothing of the "ab" / "a." / "a !" / "a\tt" siblings, nothing at the filesystem root.
        try store.setScope(["/t/a"])
        let c = try store.counts()
        #expect((c.byKindAndState["image"]?["done"] ?? 0) == 1, "y.png: /t/a direct child")
        #expect((c.byKindAndState["image"]?["pending"] ?? 0) == 1, "x.png: /t/a direct child")
        #expect((c.byKindAndState["pdf"]?["partial"] ?? 0) == 1, "z.pdf: the scoped folder's one pdf, in a subfolder")
        #expect((c.byKindAndState["doc"]?["partial"] ?? 0) == 1, "deep w.doc: a doc two folders down rides in /t/a's counters")
        #expect(c.unfinished == 2 && c.left == 7, "the one-key deep file contributes 0, as production")
        #expect(c.segments == 2 && c.vectors == 1, "the /t/mix chunk belongs to its own folder")
        try store.setScope([])
        let z = try store.counts()
        #expect(z.byKindAndState.isEmpty && z.segments == 0 && z.vectors == 0
                && z.unfinished == 0 && z.left == 0, "empty scope: all zero (the old ' AND 0' answer)")
        try expectAllMatch(store, "empty scope")
    }

    @Test func bucketRuleSlashAndRootForms() throws {
        let cases: [(String, String)] = [
            ("/a/b/c.png", "/a/b"), ("/a/b", "/a"), ("/x.png", ""), ("/", ""), ("", ""),
            ("C:/x", "C:"), ("C:/x/y", "C:/x"), ("/a//x", "/a/"), ("/a/", "/a"),
            ("/notes./x", "/notes."), ("/a !/x", "/a !"), ("/a\tt/x", "/a\tt"),
            ("/a\u{E002F}tag/x", "/a\u{E002F}tag"),        // tag chars encode no 0x2F byte: the scan cuts at the real slash
            ("/\u{1F1E6}\u{1F1E6}/x", "/\u{1F1E6}\u{1F1E6}"),  // a regional-indicator pair
            ("/\u{10FFFE}/x", "/\u{10FFFE}"),
        ]
        for (path, want) in cases {
            #expect(IndexStore.bucket(of: path) == want, "bucket(of: \(path.debugDescription))")
        }
        // The reference rule: everything up to the last slash CHARACTER — the bytewise scan and
        // the character scan agree, because 0x2F bytes are always real separators in UTF-8.
        for (path, _) in cases where path.lastIndex(of: "/") != nil {
            let last = try #require(path.lastIndex(of: "/"))
            #expect(IndexStore.bucket(of: path) == String(path[..<last]))
        }
        // The range shapes for the root spellings (audit Finding 11's drive-root edge, item 9).
        let root = IndexStore.mergedRanges(IndexStore.bucketRanges(under: "/"))
        #expect(root.contains { $0.from == "" && $0.to == "\u{1}" }
                && root.contains { $0.from == "/" && $0.to == "/\u{10FFFF}" }, "root: root-level files join")
        let drive = IndexStore.mergedRanges(IndexStore.bucketRanges(under: "C:/"))
        #expect(drive.contains { $0.from == "C:" && $0.to == "C:\u{1}" }
                && drive.contains { $0.from == "C:/" && $0.to == "C:/\u{10FFFF}" }, "drive root: C: files join")
        let plain = IndexStore.mergedRanges(IndexStore.bucketRanges(under: "/t/a"))
        #expect(plain.contains { $0.from == "/t/a" && $0.to == "/t/a\u{1}" }
                && plain.contains { $0.from == "/t/a/" && $0.to == "/t/a/\u{10FFFF}" }, "own + deeper ranges")
        // Siblings whose names extend the folder name below '/' (bytes 0x01…0x2E: space ! . , -)
        // are NOT under it: their files' buckets sort past the exact range's end.
        let sibs = IndexStore.mergedRanges(IndexStore.bucketRanges(under: "/t/a"))
        for sibling in ["/t/a", "/t/a.", "/t/a !", "/t/a-", "/t/a\tz"] {
            #expect(!sibs.contains { $0.from <= sibling && sibling < $0.to }
                        || sibling == "/t/a", "\(sibling.debugDescription) outside /t/a's ranges")
        }
    }

    @Test func rootFilesCountUnderTheRootScope() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/x.png", inode: 1))          // bucket ""
        try store.insert(file("/a/y.png", inode: 2))        // bucket "/a"
        try store.insert(file("/a/sub/z.png", inode: 3))    // bucket "/a/sub"
        try store.setScope(["/"])
        try expectAllMatch(store, "root scope")
        #expect(try store.pendingCount() == 3)
        try store.setScope(["/a"])
        try expectAllMatch(store, "/a scope")
        #expect(try store.pendingCount() == 2, "the root-level file is not under /a")
    }

    @Test func scopeFolderSpellsFromDiskJoinTheSameFiles() throws {
        // NFC on disk, scope given decomposed: pathRanges' real-path machinery decides what joins,
        // and the bucket ranges mirror it verbatim — counters add no gap of their own
        // (audit Findings 10/11: behavior inherited from the shipped path form).
        let nfc = folder.appendingPathComponent("Caf\u{00E9}")
        try FileManager.default.createDirectory(at: nfc, withIntermediateDirectories: true)
        let store = try IndexStore(directory: folder.appendingPathComponent("store"))
        try store.insert(file(nfc.appendingPathComponent("x.png").path, inode: 1))
        try store.setScope([nfc.path])   // the spelling as stored
        #expect(try store.pendingCount() == 1, "the given spelling joins")
        try expectAllMatch(store, "NFC scope")
        try store.setScope([folder.appendingPathComponent("Cafe\u{0301}").path])   // decomposed
        try expectAllMatch(store, "NFD spelling")   // equality is the invariant, both worlds
    }

    /// Bytewise (BINARY) ordering, the order SQLite compares TEXT in — the order the ranges merge by.
    func byteLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        for (i, byte) in x.enumerated() {
            if i >= y.count { return false }
            if byte != y[i] { return byte < y[i] }
        }
        return x.count < y.count
    }

    func sameRanges(_ a: [(String, String)], _ b: [(String, String)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    @Test func setScopeWritesTheMergedBucketRanges() throws {
        let store = try IndexStore(directory: folder)
        let folders = ["/t/a", "/t/a/sub"]
        try store.setScope(folders)
        let expected = IndexStore.mergedRanges(folders.flatMap(IndexStore.bucketRanges(under:)))
            .map { ($0.from, $0.to) }.sorted { byteLess($0.0, $1.0) }
        var rows: [(String, String)] = []
        try store.db.query("SELECT lo, hi FROM scopeb") { rows.append(($0.text(0) ?? "", $0.text(1) ?? "")) }
        #expect(sameRanges(rows.sorted { byteLess($0.0, $1.0) }, expected))
        #expect(expected.count == 2,
                "nested scopes fold: /t/a/sub's exact and deeper ranges merge into /t/a's deeper span")
        // past the chunk size (200): the 1,200-folder case from #166's review
        let many = (0..<1_200).map { "/root-\($0)" } + ["/t/a"]
        try store.setScope(many)
        let expectedMany = IndexStore.mergedRanges(many.flatMap(IndexStore.bucketRanges(under:)))
        var manyRows = 0
        try store.db.query("SELECT COUNT(*) FROM scopeb") { manyRows = Int($0.int(0)) }
        #expect(manyRows == expectedMany.count, "every merged range is in the table (chunked inserts)")
        try store.setScope(nil)   // nil: the counters reads go covering, the table is left unused
    }

    // MARK: Migration

    @Test func migrationFromV5FillsCountersAndStampsV6() throws {
        var store: IndexStore? = try IndexStore(directory: folder)
        #expect(try version(store!) == 6, "a fresh index is created and migrated in one open")
        var inode: UInt64 = 1
        for i in 0..<120 {
            let id = try store!.insert(file("/m/f\(i % 12)/p\(i).png", inode: inode))
            inode += 1
            if i % 5 == 0 { try store!.finish(id, state: "done") }
            if i % 7 == 0 { try store!.finish(id, state: "partial", info: ["read_to": "5", "read_end": "12"]) }
            if i % 3 == 0 { try store!.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768)) }
            if i % 4 == 0 { try store!.addSegment(file: id, kind: .ocr, modality: .text, text: "words \(i)") }
        }
        try expectAllMatch(store!, "before the downgrade")
        try dropToV5(store!)
        #expect(try version(store!) == 5)
        store = nil   // close: a fresh open runs the migration
        store = try IndexStore(directory: folder)
        #expect(try version(store!) == 6, "the stamp lands last, after the check passed")
        try #require(try store!.countersAreConsistent(), "the fill agrees with files row for row")
        try expectAllMatch(store!, "migrated (nil scope)")
        try store!.setScope(["/m/f1"])
        try expectAllMatch(store!, "migrated (scoped)")
        var drift = 0
        try store!.db.query("SELECT path, bucket FROM files") {
            if $0.text(1) ?? "" != IndexStore.bucket(of: $0.text(0) ?? "") { drift += 1 }
        }
        #expect(drift == 0, "the backfill reproduces bucket(of:) on every row")
        store = nil
    }

    @Test func partialMigrationStatesReRunSafely() throws {
        var store: IndexStore? = try IndexStore(directory: folder)
        for i in 0..<40 { _ = try store!.insert(file("/p/f\(i % 5)/p\(i).png", inode: UInt64(i))) }
        try expectAllMatch(store!, "seeded")
        // shape 1: interrupted right after the ALTER — the column stands, no counters, version 5
        try dropToV5(store!, keepColumn: true)
        store = nil
        store = try IndexStore(directory: folder)
        #expect(try version(store!) == 6)
        try #require(try store!.countersAreConsistent())
        try expectAllMatch(store!, "resumed after the ALTER (no duplicate column name)")
        // shape 2: interrupted after a fill — the counter tables stand, triggers gone, version 5
        try dropToV5(store!, keepColumn: true, keepCounters: true)
        try store!.db.run("INSERT INTO counters(bucket, kind, state, n, leftsum) VALUES('/junk', 'image', 'pending', 9, 0)")
        store = nil
        store = try IndexStore(directory: folder)
        #expect(try version(store!) == 6)
        try #require(try store!.countersAreConsistent(), "the leftover fill is refilled, junk and all")
        try expectAllMatch(store!, "resumed over a leftover fill")
        // opening a finished index is a no-op
        store = nil
        store = try IndexStore(directory: folder)
        #expect(try version(store!) == 6)
        try #require(try store!.countersAreConsistent())
        store = nil
    }

    @Test func migrationToleratesALegacyMalformedPartialRow() throws {
        var store: IndexStore? = try IndexStore(directory: folder)
        _ = try store!.insert(file("/mm/p.pdf", inode: 1, kind: .pdf))
        try dropToV5(store!)
        // the v5 world writes it freely (no triggers): today's read-time hazard (Finding 8b)
        try store!.db.run("UPDATE files SET state = 'partial', info = 'not json' WHERE path = '/mm/p.pdf'")
        store = nil
        store = try IndexStore(directory: folder)   // the migration must not die on a legacy row
        #expect(try version(store!) == 6, "json_valid-guarded fill: a v5 row it cannot read counts 0")
        #expect(try store!.unfinishedCount() == (1, 0), "counted in files, 0 left")
        try #require(try store!.countersAreConsistent())
        #expect(throws: (any Error).self) { _ = try store!.fullUnfinishedCount() }  // the shipped form dies on it
        // the new world refuses such rows at the write
        #expect(throws: (any Error).self) {
            try store!.db.run("INSERT INTO files(path, kind, size, mtime, inode, device, bucket, state, info) "
                              + "VALUES('/mm/bad.pdf', 'pdf', 10, 1, 99, 1, '/mm', 'partial', 'not json')")
        }
        try #require(try store!.countersAreConsistent())
        store = nil
    }

    @Test func interruptedMigrationRollsBackToV5OnSIGKILL() throws {
        // Finding 12's measured pattern, against the Swift migration itself: kill the child mid-
        // transaction; the next open replays the WAL and finds v5 exactly intact; opening again
        // completes. The child is the built CLI (`digup status --index DIR`) so the kill lands in
        // real migration code, not a test stand-in. `swift test` runs from the package root, so the
        // debug binary sits at .build/debug/digup (DIGUP_CLI overrides, e.g. a release build).
        let candidates: [String] = [ProcessInfo.processInfo.environment["DIGUP_CLI"]].compactMap { $0 } + [
            FileManager.default.currentDirectoryPath + "/.build/debug/digup",
            FileManager.default.currentDirectoryPath + "/.build/arm64-apple-macosx/debug/digup",
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("digup").path,
        ]
        guard let cliPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Issue.record("digup CLI not found (tried: \(candidates.joined(separator: ", ")))")
            return
        }
        let cli = URL(fileURLWithPath: cliPath)
        var killedMid = false
        let delays = [0.70, 0.30, 0.12]
        for attempt in 0..<delays.count {
            let delay = delays[attempt]
            let dir = folder.appendingPathComponent("kill\(attempt)")
            var seed: IndexStore? = try IndexStore(directory: dir)
            try seed!.db.transaction {   // 100k files in 40 folders, some partial
                for batch in 0..<100 {
                    let rows = (batch * 1_000 ..< batch * 1_000 + 1_000)
                        .map { "('/k\($0 % 40)/f\($0)', 'image', 10, 1, \($0), 1)" }.joined(separator: ",")
                    try seed!.db.execute("INSERT INTO files(path, kind, size, mtime, inode, device) VALUES" + rows)
                }
                try seed!.db.execute("UPDATE files SET state = 'partial', info = json('{\"read_to\":10,\"read_end\":40}') WHERE id % 7 = 0")
            }
            try dropToV5(seed!)
            seed = nil   // close: the child opens a v5 file
            let child = Process()
            child.executableURL = cli
            child.arguments = ["status", "--index", dir.path]
            child.standardOutput = Pipe()
            child.standardError = Pipe()
            try child.run()
            Thread.sleep(forTimeInterval: delay)
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            var v: Int64 = -1
            var hasBucket = false
            var counterTables = 0
            var check = ""
            var files = 0
            let db = try Database(path: dir.appendingPathComponent(IndexStore.mainFile).path)
            try db.query("PRAGMA user_version") { v = $0.int(0) }
            try db.query("SELECT 1 FROM pragma_table_info('files') WHERE name = 'bucket'") { _ in hasBucket = true }
            try db.query("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('counters', 'segcounters')") {
                counterTables = Int($0.int(0))
            }
            try db.query("PRAGMA quick_check") { check = $0.text(0) ?? "" }
            try db.query("SELECT COUNT(*) FROM files") { files = Int($0.int(0)) }
            if v == 5, !hasBucket, counterTables == 0, check == "ok", files == 100_000 {
                killedMid = true
                let done = try IndexStore(directory: dir)   // the second open completes the migration
                #expect(try version(done) == 6)
                try #require(try done.countersAreConsistent(), "recovered index is exact")
                try expectAllMatch(done, "recovered after SIGKILL")
                break
            }
        }
        #expect(killedMid, "a SIGKILL caught mid-migration, at least once (the window is seconds wide)")
    }

    // MARK: Self-heal, zero rows, plans, connections, the random walk

    @Test func rebuildHealsCorruption() throws {
        let store = try IndexStore(directory: folder)
        for i in 0..<60 { _ = try store.insert(file("/z/f\(i % 6)/p\(i).png", inode: UInt64(i))) }
        var partials: [Int64] = []
        try store.db.query("SELECT id FROM files WHERE id % 6 = 0 LIMIT 10") { partials.append($0.int(0)) }
        for id in partials {
            try store.finish(id, state: "partial", info: ["read_to": "2", "read_end": "12"])
        }
        try expectAllMatch(store, "seeded")
        // injected drift: +7 on every counter row — the check sees it, rebuild heals it
        try store.db.execute("UPDATE counters SET n = n + 7")
        #expect(!(try store.countersAreConsistent()), "the check sees injected drift")
        var pendingRows = 0
        try store.db.query("SELECT COUNT(*) FROM counters WHERE state = 'pending'") { pendingRows = Int($0.int(0)) }
        #expect(try store.pendingCount() == store.fullPendingCount() + 7 * pendingRows,
                "drift is visible while it stands")
        try store.rebuildCounters()
        try #require(try store.countersAreConsistent(), "rebuild restored the truth")
        try expectAllMatch(store, "after rebuild")
        // a phantom non-zero row with no group: detected, healed
        try store.db.run("INSERT INTO counters(bucket, kind, state, n, leftsum) VALUES('/phantom', 'image', 'pending', 5, 0)")
        #expect(!(try store.countersAreConsistent()), "a non-zero row with no group is a mismatch")
        try store.rebuildCounters()
        try #require(try store.countersAreConsistent())
        // a zero-valued extra row is allowed (Finding 9's residue: it adds 0, the truth)
        try store.db.run("INSERT INTO counters(bucket, kind, state, n, leftsum) VALUES('/zero', 'image', 'pending', 0, 0)")
        #expect(try store.countersAreConsistent(), "zero rows are tolerated by design")
        try expectAllMatch(store, "zero row stands")   // counts() skips it (the dictionary stays clean)
        // a zeroed PK row over a group with files IS a mismatch (the (n≠0) join filter keeps it visible)
        try store.db.execute("UPDATE counters SET n = 0, leftsum = 0 WHERE state = 'pending'")
        #expect(!(try store.countersAreConsistent()), "counters saying 0 while files stand")
        try store.rebuildCounters()
        try #require(try store.countersAreConsistent())
        try expectAllMatch(store, "final")
    }

    @Test func zeroRowsPruneAndRegrow() throws {
        let store = try IndexStore(directory: folder)
        var ids: [Int64] = []
        for i in 0..<240 { ids.append(try store.insert(file("/z\(i % 6)/f\(i).png", inode: UInt64(i)))) }
        for id in ids { try store.finish(id, state: "done") }   // the pending groups empty out
        var zeros = 0
        try store.db.query("SELECT COUNT(*) FROM counters WHERE n = 0 AND leftsum = 0") { zeros = Int($0.int(0)) }
        #expect(zeros == 6, "one emptied (bucket,kind,state) group per folder (Finding 9's residue)")
        for id in ids where id % 2 == 0 { try store.finish(id, state: "pending") }   // half go back
        for id in ids where id % 3 == 0 {
            try store.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768))
        }
        // An isolated folder whose only segments go away entirely: its segcounters group empties to a
        // zero row (Finding 9's residue). Dedicated /q files, deleted app-order (fts first, like
        // production deleteSegments — a raw segment delete without fts cleanup would leak fts rowids).
        var qids: [Int64] = []
        for i in 0..<3 { qids.append(try store.insert(file("/q/f\(i).png", inode: 900 + UInt64(i)))) }
        for id in qids {
            try store.addSegment(file: id, kind: .image, modality: .image, vector: [Float](repeating: 0.1, count: 768))
        }
        for id in qids {
            try store.db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind != 'name')", [.int(id)])
            try store.db.run("DELETE FROM segments WHERE file = ? AND kind != 'name'", [.int(id)])
        }
        var segZerosBefore = 0
        try store.db.query("SELECT COUNT(*) FROM segcounters WHERE n = 0") { segZerosBefore = Int($0.int(0)) }
        #expect(segZerosBefore == 1, "the /q hasvec=1 group stands at zero (one row, the emptied group)")
        try store.pruneZeroCounterRows()
        try store.db.query("SELECT COUNT(*) FROM counters WHERE n = 0 AND leftsum = 0") { zeros = Int($0.int(0)) }
        #expect(zeros == 0, "pruned")
        var segZeros = 0
        try store.db.query("SELECT COUNT(*) FROM segcounters WHERE n = 0") { segZeros = Int($0.int(0)) }
        #expect(segZeros == 0, "segcounters pruned too")
        try #require(try store.countersAreConsistent(), "pruning changes no truth")
        try expectAllMatch(store, "after pruning (nil scope)")
        try store.setScope(["/z1"])
        try expectAllMatch(store, "after pruning (scoped)")
        // the triggers' upsert re-creates pruned groups on demand
        _ = try store.insert(file("/z1/regrown.png", inode: 999))
        try #require(try store.countersAreConsistent())
        try expectAllMatch(store, "regrown")
    }

    @Test func countersReadsUseTheIntendedPlan() throws {
        // Finding 9's amendment, asserted on the actual production query texts: the scoped reads
        // must drive from scopeb with the state-first covering seek — not sweep the counter table.
        let store = try IndexStore(directory: folder)
        for i in 0..<20 { _ = try store.insert(file("/t/f\(i % 4)/p\(i).png", inode: UInt64(i))) }
        func plan(_ sql: String) throws -> String {
            var lines: [String] = []
            try store.db.query("EXPLAIN QUERY PLAN \(sql)") { lines.append($0.text(3) ?? "") }
            return lines.joined(separator: " | ")
        }
        let nilPlan = try plan("SELECT COALESCE(SUM(n), 0) FROM counters WHERE state = 'pending'")
        #expect(nilPlan.contains("SEARCH counters") && nilPlan.contains("counters_state"),
                "nil-scope pendingCount seeks the state section: \(nilPlan)")
        try store.setScope(["/t/f0", "/t/f1", "/t/f2"])
        let scoped = try plan("SELECT COALESCE(SUM(c.n), 0) FROM scopeb b CROSS JOIN counters c "
                              + "ON c.state = 'pending' AND c.bucket >= b.lo AND c.bucket < b.hi")
        #expect(scoped.contains("SCAN b") && scoped.contains("SEARCH c USING COVERING INDEX counters_state"),
                "scope-driven seek (Finding 9): \(scoped)")
        let partial = try plan("SELECT COALESCE(SUM(c.n), 0), COALESCE(SUM(c.leftsum), 0) FROM scopeb b "
                               + "CROSS JOIN counters c ON c.state = 'partial' AND c.bucket >= b.lo AND c.bucket < b.hi")
        #expect(partial.contains("SCAN b") && partial.contains("SEARCH c USING COVERING INDEX counters_state"),
                "partial seek: \(partial)")
        let kinds = try plan("SELECT c.kind, c.state, SUM(c.n) FROM scopeb b CROSS JOIN counters c "
                             + "ON c.bucket >= b.lo AND c.bucket < b.hi GROUP BY c.kind, c.state")
        #expect(kinds.contains("SCAN b") && kinds.contains("SEARCH c USING PRIMARY KEY"),
                "kind read seeks the counters PK (a WITHOUT ROWID table's PK is its only index): \(kinds)")
        let segs = try plan("SELECT c.hasvec, SUM(c.n) FROM scopeb b CROSS JOIN segcounters c "
                            + "ON c.bucket >= b.lo AND c.bucket < b.hi GROUP BY c.hasvec")
        #expect(segs.contains("SCAN b") && segs.contains("SEARCH c USING PRIMARY KEY"), "segment read: \(segs)")
    }

    @Test func reopenKeepsCountersExact() throws {
        var store: IndexStore? = try IndexStore(directory: folder)
        for i in 0..<40 { _ = try store!.insert(file("/o/f\(i % 4)/p\(i).png", inode: UInt64(i))) }
        try store!.setScope(["/o/f1"])
        #expect(try store!.pendingCount() == 10)
        store = nil
        store = try IndexStore(directory: folder)   // a fresh connection: the counters stand as committed
        try #require(try store!.countersAreConsistent())
        try expectAllMatch(store!, "reopened (nil scope — the temp scope tables start empty)")
        try store!.setScope(["/o/f1"])
        try expectAllMatch(store!, "reopened (scoped)")
        store = nil
    }

    @Test func twoConnectionsOnOneIndexStayConsistent() throws {
        var a: IndexStore? = try IndexStore(directory: folder)
        for i in 0..<50 { _ = try a!.insert(file("/n/f\(i % 5)/p\(i).png", inode: UInt64(i))) }
        try a!.setScope(["/n"])
        let b = try IndexStore(directory: folder)   // the same file: WAL, second connection
        var fk: Int64 = 0
        try b.db.query("PRAGMA foreign_keys") { fk = $0.int(0) }
        #expect(fk == 1, "every writable connection carries foreign_keys=ON (Finding 6)")
        try #require(try b.countersAreConsistent())
        let id = try b.insert(file("/n/x.png", inode: 100))
        try b.finish(id, state: "done", info: ["read_to": "3", "read_end": "10"])
        try expectAllMatch(a!, "A sees B's commits")
        try expectAllMatch(b, "B sees itself")
        // mid-write reads are not blocked (Finding 12's reader result): B reads A's open transaction away
        try a!.db.transaction {
            _ = try a!.insert(file("/n/holding.png", inode: 101))
            try expectAllMatch(b, "reading through A's open transaction")
        }
        // writer contention: the second BEGIN IMMEDIATE hits the 5 s busy timeout, then goes through
        #expect(throws: (any Error).self) {
            try a!.db.transaction {
                _ = try a!.insert(file("/n/lock.png", inode: 102))
                _ = try b.insert(file("/n/rival.png", inode: 103))   // fails: A holds the write lock
            }
        }
        _ = try b.insert(file("/n/late.png", inode: 104))   // the lock is free
        try expectAllMatch(a!, "after contention")
        try expectAllMatch(b, "after contention")
        a = nil
    }

    @Test func randomLifecycleAgainstTheOracle() throws {
        // A fixed-seed random walk through every write path, comparing counters to full
        // aggregation after every single operation, under rotating scopes (nil, empty, nested,
        // adjacent, sibling, root, duplicates, the 200+ chunk case).
        struct Rng {
            var state: UInt64
            init(seed: UInt64) { state = seed }
            mutating func next(_ n: Int) -> Int {
                state = state &+ 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z = z ^ (z >> 31)
                return Int(z % UInt64(n))
            }
        }
        let store = try IndexStore(directory: folder)
        var rng = Rng(seed: 0x5EED_193)
        let dirs = ["/r/a", "/r/a/sub", "/r/a/sub/deep", "/r/ab", "/r/a.", "/r/a !", "/r/a\tt",
                    "/r/keep x", "/r/nó", "/r/nó"]
        let finishes: [(String, [String: String])] = [
            ("done", [:]), ("done", ["pages": "12"]),
            ("partial", ["read_to": "10", "read_end": "40"]), ("partial", ["read_to": "40", "read_end": "12"]),
            ("partial", ["read_end": "9"]), ("partial", ["read_to": "3"]), ("partial", [:]),
            ("skipped", [:]), ("failed", ["why": "x"]), ("pending", [:]),
        ]
        let kinds = Array(FileKind.allCases)
        let segKinds: [SegmentKind] = [.page, .chunk, .ocr, .pageImage, .image, .audio]
        var seq: UInt64 = 1_000
        for step in 0..<500 {
            let roll = rng.next(100)
            var ids: [Int64] = []
            try store.db.query("SELECT id FROM files") { ids.append($0.int(0)) }
            switch roll {
            case 0..<22:    // insert
                if rng.next(12) == 0 {
                    _ = try store.insert(file("/x\(seq).png", inode: seq))          // root-level file
                } else {
                    let kind = kinds[rng.next(kinds.count)]
                    _ = try store.insert(file("\(dirs[rng.next(dirs.count)])/\(seq).bin", inode: seq, kind: kind))
                }
                seq += 1
            case 22..<48:   // finish
                if !ids.isEmpty {
                    let f = finishes[rng.next(finishes.count)]
                    try store.finish(ids[rng.next(ids.count)], state: f.0, detail: "step \(step)", info: f.1)
                }
            case 48..<55:   // move
                if !ids.isEmpty {
                    try store.move(ids[rng.next(ids.count)],
                                   to: "\(dirs[rng.next(dirs.count)])/\(seq).png")
                    seq += 1
                }
            case 55..<60:   // requeue as a new candidate
                if !ids.isEmpty {
                    let id = ids[rng.next(ids.count)]
                    var path = ""
                    try store.db.query("SELECT path FROM files WHERE id = ?", [.int(id)]) { path = $0.text(0) ?? "" }
                    try store.requeue(id, as: file(path, inode: seq, kind: kinds[rng.next(kinds.count)]))
                    seq += 1
                }
            case 60..<63:   // requeue plain
                if !ids.isEmpty { try store.requeue(ids[rng.next(ids.count)]) }
            case 63..<72:   // addSegment
                if !ids.isEmpty {
                    try store.addSegment(file: ids[rng.next(ids.count)], kind: segKinds[rng.next(segKinds.count)],
                                         modality: Modality.allCases[rng.next(Modality.allCases.count)],
                                         loc: 1, text: rng.next(2) == 0 ? "a \(rng.next(50)) word walk" : nil,
                                         vector: rng.next(2) == 0 ? [Float](repeating: 0.25, count: 768) : nil)
                }
            case 72..<77:   // app-order segment delete (production deleteSegments shape: fts first)
                if !ids.isEmpty {
                    let victim = ids[rng.next(ids.count)]
                    try store.db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind != 'name')", [.int(victim)])
                    try store.db.run("DELETE FROM segments WHERE file = ? AND kind != 'name'", [.int(victim)])
                }
            case 77..<81:   // file delete (cascade order)
                if !ids.isEmpty { try store.delete(ids[rng.next(ids.count)]) }
            case 81..<89:   // setScope
                let roll2 = rng.next(100)
                if roll2 < 45 { try store.setScope(nil) }
                else if roll2 < 55 { try store.setScope([]) }
                else {
                    var picked = [dirs[rng.next(dirs.count)]]
                    for _ in 0..<rng.next(4) { picked.append(dirs[rng.next(dirs.count)]) }   // duplicates fold
                    if rng.next(12) == 0 { picked.append("/") }
                    if rng.next(20) == 0 { picked.append("/nope") }
                    try store.setScope(picked)
                }
            case 89: try store.rebuildCounters()
            case 90..<92: try store.resetAll()
            default:        // prune (cascade deletes through the roots)
                var keep = [dirs[rng.next(dirs.count)]]
                if rng.next(5) == 0 { keep.append("/") }
                _ = try store.prune(keepingUnder: keep)
            }
            try expectAllMatch(store, "step \(step) roll \(roll)")
        }
        try store.setScope((0..<2_400).map { "/root-\($0)" } + ["/r/a"])
        try expectAllMatch(store, "the 2,400-folder scope")
    }
    // MARK: Trigger invariants (Phase 7's explicit pins)
    /// Findings 1/5's invariant, pinned as behavior: NO production API reparents a segment row
    /// (`segments.file`) or renames one (`segments.kind`) in place — segment rows only ever leave by
    /// deletion (deletion recycles rowids, so a later segment with a recycled id is a NEW row, not a
    /// moved one), and every deletion path counts decrements exactly once. The counters suite has no
    /// trigger for a `file`/`kind` UPDATE (audit Finding 1), so this test is the invariant's pin:
    /// it exercises every public write path and asserts every segment row that survives a call
    /// keeps its (file, kind), with counters consistent after each call.
    @Test func segmentOwnershipAndKindAreNeverUpdated() throws {
        let store = try IndexStore(directory: folder)
        let vec = [Float](repeating: 0.1, count: 768)
        var ids: [Int64] = []
        for i in 0..<6 { ids.append(try store.insert(file("/v/f\(i).png", inode: UInt64(100 + i)))) }
        for (i, id) in ids.enumerated() {
            try store.addSegment(file: id, kind: i % 2 == 0 ? .image : .ocr, modality: .image,
                                 text: i % 2 == 1 ? "words \(i)" : nil, vector: i % 2 == 0 ? vec : nil)
        }
        try store.finish(ids[0], state: "done")
        func snapshot() throws -> [Int64: (file: Int64, kind: String)] {
            var out: [Int64: (Int64, String)] = [:]
            try store.db.query("SELECT id, file, kind FROM segments ORDER BY id") {
                out[$0.int(0)] = ($0.int(1), $0.text(2) ?? "?")
            }
            return out
        }
        // The invariant is about UPDATEs, not inserts: a segment row that SURVIVES a call (present
        // in two consecutive snapshots under the same id) must carry the same (file, kind). Rowids
        // legitimately recycle after deletions — a reused id in a later snapshot is a NEW row, not
        // a reparented one — so each step compares against the immediately preceding snapshot.
        var prev = try snapshot()
        func check(_ tag: String) throws {
            let now = try snapshot()
            for (id, row) in now {
                if let was = prev[id] {
                    #expect(was.file == row.file && was.kind == row.kind,
                            "segment \(id) keeps its (file, kind) after \(tag)")
                }
            }
            prev = now
            try #require(try store.countersAreConsistent(), "consistency after \(tag)")
            try expectAllMatch(store, "invariant \(tag)")
        }
        try check("seed")
        try store.finish(ids[1], state: "partial", info: ["read_to": "2", "read_end": "9"])
        try check("finish partial")
        try store.move(ids[2], to: "/v/moved/f2.png")
        try check("move")
        try store.addSegment(file: ids[3], kind: .chunk, modality: .text, text: "more words")
        try check("addSegment text")
        try store.addSegment(file: ids[3], kind: .image, modality: .image, vector: vec)
        try check("addSegment vector")
        try store.requeue(ids[4], as: file("/v/f4.png", inode: 104))
        try check("requeue as candidate")
        try store.requeue(ids[3])
        try check("requeue plain")
        try store.markStopped("/v/f5.png", why: "ejected")
        try check("markStopped")
        try store.resetAll()
        try check("resetAll")
        try store.delete(ids[0])
        try check("delete")
    }

    /// Finding 3's boundary, pinned as behavior: the WHEN guards give every file UPDATE in the
    /// codebase exactly one counter maintenance because no production statement sets `state` and
    /// `bucket` together without `path` (bucket is derived from path; `move` sets path+bucket,
    /// `finish`/`requeue`/`markStopped`/`resetAll` never touch bucket). This test writes exactly
    /// the forbidden shape — state + bucket, path untouched — shows both triggers fire and the
    /// counters drift, and shows `rebuildCounters` heals it: the documented self-heal is the
    /// answer to any future statement that breaks a suite invariant.
    @Test func guardsFireOnceAndTheForbiddenShapeIsHealedByRebuild() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(file("/g/a/x.png", inode: 1))
        try store.finish(id, state: "done")
        try #require(try store.countersAreConsistent(), "clean start")
        try store.db.run("UPDATE files SET state = 'pending', bucket = '/g/b' WHERE id = ?", [.int(id)])
        let consistentAfterForbidden = try store.countersAreConsistent()
        #expect(!consistentAfterForbidden,
                "the forbidden shape double-fires and drifts the counters — the invariant's boundary")
        try store.rebuildCounters()
        try #require(try store.countersAreConsistent(), "rebuildCounters heals the drift")
        try expectAllMatch(store, "after heal")
    }
}

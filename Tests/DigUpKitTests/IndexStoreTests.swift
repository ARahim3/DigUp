#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

@Suite struct IndexStoreTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func file(_ path: String, inode: UInt64) -> Candidate {
        Candidate(path: path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1)
    }

    @Test func anInnerTransactionsFailureLeavesTheOuterOne() throws {
        struct Oops: Error {}
        let store = try IndexStore(directory: folder)
        try store.db.transaction {
            try store.insert(file(folder.appendingPathComponent("a.txt").path, inode: 1))
            #expect(throws: Oops.self) {
                try store.db.transaction {
                    try store.insert(file(folder.appendingPathComponent("b.txt").path, inode: 2))
                    throw Oops()
                }
            }
            try store.insert(file(folder.appendingPathComponent("c.txt").path, inode: 3))
        }
        let names = try store.files(under: [folder.path]).map { ($0.path as NSString).lastPathComponent }.sorted()
        #expect(names == ["a.txt", "c.txt"])
    }

    @Test func pruneKeepsOnlyChosenFolders() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/a/sub/y.png", inode: 2))
        try store.insert(file("/ab/z.png", inode: 3))   // a sibling whose name starts like "/a", not inside it
        try store.insert(file("/b/w.png", inode: 4))
        #expect(try store.prune(keepingUnder: ["/a"]) == 2)
        #expect(try store.files(under: ["/a"]).count == 2)
        #expect(try store.files(under: ["/ab", "/b"]).isEmpty)
        var keywordRows = 0
        try store.db.query("SELECT COUNT(*) FROM fts") { keywordRows = Int($0.int(0)) }
        #expect(keywordRows == 2)   // the pruned files' names left keyword search too
        #expect(try store.prune(keepingUnder: []) == 2)
    }

    @Test func scopeLimitsWhatIsWaiting() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // on a drive that's unplugged
        try store.setScope(["/a"])
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        try store.setScope([])
        #expect(try store.pendingCount() == 0)
        try store.setScope(nil)
        #expect(try store.pendingCount() == 2)
    }

    @Test func aThousandFoldersFitTheScopedQueries() throws {
        // #166: 1,179 chosen folders broke every scoped query at startup — one `(path >= ? AND path < ?)`
        // range per folder, all ORed into one expression, past SQLite's expression-depth cap of 1,000.
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/b/y.png", inode: 2))
        let folders = (0..<1_200).map { "/root-\($0)" }
        try store.setScope(["/a"] + folders)
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        try store.setScope(folders)   // no chosen folder has its files in this index
        #expect(try store.pendingCount() == 0)
        try store.setScope(nil)
        #expect(try store.pendingCount() == 2)
    }

    @Test func aFailedScopeWriteKeepsTheWorkingScope() throws {
        // The #191 review's disk-full shape: the scope write touches the table in several statements,
        // so a failure needs to land *inside* the transaction, after `DELETE` has emptied it. A
        // RAISE(ABORT) trigger on the table injects that failure; the transaction must leave the
        // previous scope standing in memory and its ranges in the table, and every scoped query keep
        // answering as it did before the failed write.
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // on a drive that's unplugged
        try store.setScope(["/a"])
        var rowsBefore = -1
        try store.db.query("SELECT COUNT(*) FROM scope") { rowsBefore = Int($0.int(0)) }
        #expect(rowsBefore > 0)
        try store.db.run("""
            CREATE TEMP TRIGGER disk_full BEFORE INSERT ON scope
            BEGIN SELECT RAISE(ABORT, 'disk full'); END
            """)
        var threw = false
        do { try store.setScope(["/drive", "/b"]) } catch { threw = true }
        #expect(threw, "the injected disk full must reach the caller")
        #expect(store.scope == ["/a"])   // the in-memory scope of the last good write, untouched
        var rowsAfter = -1
        try store.db.query("SELECT COUNT(*) FROM scope") { rowsAfter = Int($0.int(0)) }
        #expect(rowsAfter == rowsBefore)   // its ranges, in the table, untouched
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        // The next write goes through: table and scope move together, in one transaction.
        try store.db.run("DROP TRIGGER disk_full")
        try store.setScope(["/a", "/drive"])
        #expect(store.scope == ["/a", "/drive"])
        #expect(try store.pendingCount() == 2)
    }

    @Test func mergedScopeKeepsNestedAdjacentAndDuplicateFoldersExact() throws {
        // The scope test asks the one range with the greatest `lo` at or below a path, and that answer
        // is exact only when the ranges don't overlap — so `setScope` merges the list first. These are
        // the merge's shapes: a chosen folder inside a chosen folder (nested), the same folder twice
        // (it must fold, not trip the PRIMARY KEY), `/a` next to `/a0` (adjacent — a `/a1` file sits in
        // the gap between their ranges), and `/ab` (a sibling in byte order whose files are its own).
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/a/b/y.png", inode: 2))
        try store.insert(file("/ab/z.png", inode: 3))
        try store.insert(file("/a0/g.png", inode: 4))
        try store.insert(file("/a1/h.png", inode: 5))
        try store.insert(file("/drive-off/d.png", inode: 6))
        try store.setScope(["/a", "/a/b"])   // nested: the subfolder's files were in /a's range all along
        #expect(Set(try store.pending(limit: nil).map(\.path)) == ["/a/x.png", "/a/b/y.png"])
        try store.setScope(["/a", "/a"])     // the same folder twice: folds, the PK never sees a repeat
        #expect(try store.pendingCount() == 2)   // a file under a chosen folder's subfolder is under it too
        try store.setScope(["/a", "/a0"])    // adjacent, gap between: the /a1 file stays out of both
        #expect(Set(try store.pending(limit: nil).map(\.path)) == ["/a/x.png", "/a/b/y.png", "/a0/g.png"])
        try store.setScope(["/ab"])          // sibling trap: byte order must not pull /a's files in
        #expect(try store.pending(limit: nil).map(\.path) == ["/ab/z.png"])
        try store.setScope(["/a", "/a/b", "/drive-off"])
        #expect(try store.pendingCount() == 3)
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 3)
        try store.setScope([])
        #expect(try store.pendingCount() == 0)
        try store.setScope(nil)
        #expect(try store.pendingCount() == 6)
    }

    @Test func countsSeeOnlyTheScopedFilesSegments() throws {
        // counts() reaches segments through the same scope string the file probes use: the predecessor
        // form must filter them exactly as the EXISTS form did (measured in the #191 review's follow-up).
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // the unplugged drive
        for (path, id) in try store.pending(limit: nil).map({ ($0.path, $0.id) }) {
            for _ in 0..<(path == "/a/x.png" ? 2 : 3) {
                try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1,
                                     vector: [Float](repeating: 0.1, count: 768))
            }
        }
        try store.setScope(["/a"])
        let scoped = try store.counts()
        #expect(scoped.segments == 2 && scoped.vectors == 2)   // the drive's 3 stay out
        try store.setScope(nil)
        let all = try store.counts()
        #expect(all.segments == 5 && all.vectors == 5)
    }

    @Test func aFileTheHelperStoppedOnIsNotReadAgain() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/stuck.pdf", inode: 1))
        let book = try store.insert(file("/a/book.pdf", inode: 2))
        try store.finish(book, state: "partial", info: ["read_to": "30", "read_end": "463"])
        #expect(try store.markStopped("/a/stuck.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.markStopped("/a/book.pdf", why: "took more than 15 minutes to read"))
        #expect(try !store.markStopped("/a/gone.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.pendingCount() == 0)
        #expect(try store.unfinishedCount().files == 0)   // the book keeps its first pages and isn't finished again
        let states = Dictionary(uniqueKeysWithValues: try store.files(under: ["/a"]).map { ($0.path, $0.state) })
        #expect(states == ["/a/stuck.pdf": "failed", "/a/book.pdf": "done"])
    }

    #if canImport(AppKit)
    @Test func picturesThatCouldntBeReadAreReadOnceMore() throws {
        // An SVG skipped by an older DigUp as "small image 0×0" (ImageIO couldn't open it): AppKit draws it now.
        let store = try IndexStore(directory: folder)
        let svg = try store.insert(file("/a/chart.svg", inode: 1))
        try store.finish(svg, state: "skipped", detail: "small image 0×0")
        let icon = try store.insert(file("/a/icon.png", inode: 2))
        try store.finish(icon, state: "skipped", detail: "small image 160×160")   // small, and rightly skipped
        #expect(try store.readAgainOnce() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/chart.svg"])
        #expect(try store.readAgainOnce() == 0)
    }
    #endif

    @Test func modelFileHashesStreamInPieces() throws {
        let small = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        #expect(try ModelFiles.sha256(of: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Bigger than one 8 MB piece.
        let bytes = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = folder.appendingPathComponent("big")
        try bytes.write(to: big)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ModelFiles.sha256(of: big) == expected)
    }

    @Test func missingModelFilesInDownloadOrder() throws {
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.text, ModelFiles.media])
        FileManager.default.createFile(atPath: folder.appendingPathComponent(ModelFiles.text.name).path, contents: nil)
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.media])
        #expect(ModelFiles.totalBytes == 864_676_480)
    }

    @Test func modelFilesComeFromTheHuggingFaceCacheWhenThere() throws {
        // As `hf download` leaves them: snapshots/<revision>/<name> → a blob. Sparse, so no disk is used.
        let hub = folder.appendingPathComponent("hub")
        let snapshot = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/snapshots/\(ModelFiles.revision)")
        let blobs = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("2188ac1d")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        try FileHandle(forWritingTo: blob).truncate(atOffset: UInt64(ModelFiles.text.bytes))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(ModelFiles.text.name),
                                                   withDestinationURL: blob)
        setEnvironment("HF_HUB_CACHE", hub.path)
        defer { setEnvironment("HF_HUB_CACHE", nil) }
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text)?.lastPathComponent == "2188ac1d")
        #expect(ModelFiles.cachedCopy(of: ModelFiles.media) == nil)   // not there
        try FileHandle(forWritingTo: blob).truncate(atOffset: 10)
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text) == nil)    // not whole
    }

    @Test func syncKeepsTheRowsOfAFolderThatWentAway() throws {
        // The real path (/private/var/…), as the crawler reports it; resolvingSymlinksInPath() would drop "/private".
        let base = URL(fileURLWithPath: FolderSelection.realPath(folder.path))
        let drive = base.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("notes from the trip".utf8).write(to: drive.appendingPathComponent("notes.txt"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([drive]).added == 1)
        try FileManager.default.moveItem(at: drive, to: base.appendingPathComponent("ejected"))
        #expect(try indexer.sync([drive]).removed == 0)   // an ejected drive is not "everything deleted"
        #expect(try store.files(under: [drive.path]).count == 1)
    }

    @Test func syncFindsTheRowsOfAFolderSpelledAnotherWay() throws {
        // The walk stores paths as the disk spells them, and on a Mac these folders are chosen spelled otherwise twice
        // over: under /var where the disk says /private/var (the temporary folder), and with a name the disk keeps
        // precomposed that `standardizedFileURL` decomposes (Google Drive's "내 드라이브", "Café"). Looking their rows up
        // by that spelling found none, so the second sync took every file for new: "UNIQUE constraint failed".
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        var chosen: [URL] = []
        for name in ["내 드라이브", "Café"] {
            let onDisk = folder.path + "/" + name.precomposedStringWithCanonicalMapping
            #if os(Windows)
            try FileManager.default.createDirectory(atPath: onDisk, withIntermediateDirectories: false)
            #else
            #expect(mkdir(onDisk, 0o755) == 0)   // FileManager would decompose the name
            #endif
            try Data("notes from the trip".utf8).write(to: URL(fileURLWithPath: onDisk + "/notes.txt"))
            chosen.append(URL(fileURLWithPath: onDisk).standardizedFileURL)
        }
        #expect(try indexer.sync(chosen).added == 2)
        let again = try indexer.sync(chosen)
        #expect(again.added == 0 && again.unchanged == 2)
        #expect(try store.files(under: chosen.map(\.path)).count == 2)
        try store.setScope(chosen.map(\.path))
        #expect(try store.pendingCount() == 2)
        #expect(try store.prune(keepingUnder: chosen.map(\.path)) == 0)
    }
}

/// Sets an environment variable of this process, or removes it (nil).
private func setEnvironment(_ name: String, _ value: String?) {
    #if os(Windows)
    _ = name.withCString(encodedAs: UTF16.self) { name in
        guard let value else { return SetEnvironmentVariableW(name, nil) }
        return value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
    }
    #else
    if let value { setenv(name, value, 1) } else { unsetenv(name) }
    #endif
}

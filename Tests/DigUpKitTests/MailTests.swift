import Foundation
import Testing
@testable import DigUpKit

/// Outlook mail in .pst files (`Mail`), with the PST Outlook made for pst/'s tests (30 mails in three folders, five
/// with an attachment). Needs the digup-pst tool: `cargo build --release` in pst/, then DIGUP_PST=pst/target/release.
@Suite(.enabled(if: Mail.isAvailable)) final class MailTests {
    /// In Caches, not the temporary folder: the walk reports /private/var/… for /var/… (see LongFilesTests).
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("files"),
                                                 withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var files: URL { folder.appendingPathComponent("files") }
    var pst: URL { files.appendingPathComponent("archive.pst") }

    /// pst/tests/data/outlook_made.pst, copied into the test's folder.
    func copyPST(to url: URL) throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("pst/tests/data/outlook_made.pst")
        try FileManager.default.copyItem(at: source, to: url)
    }

    func store() throws -> IndexStore { try IndexStore(directory: folder.appendingPathComponent("index")) }

    func indexer(_ store: IndexStore) throws -> Indexer {
        try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
    }

    /// Paths of what keyword search finds for `word`.
    func found(_ store: IndexStore, _ word: String) throws -> [String] {
        var out: [String] = []
        try store.db.query("""
            SELECT DISTINCT f.path FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file
            WHERE fts MATCH ? ORDER BY f.path
            """, [.text("\"\(word)\"")]) { out.append($0.text(0) ?? "") }
        return out
    }

    func mails(_ store: IndexStore) throws -> [(path: String, state: String, info: [String: String])] {
        try store.mails(in: pst.path).map { ($0.path, $0.state, try store.info(of: $0.id)) }.sorted { $0.path < $1.path }
    }

    @Test func pathsOfMails() {
        #expect(Mail.path(mailbox: "C:\\Mail\\archive.pst", node: 2097412) == "C:\\Mail\\archive.pst::2097412")
        #expect(Mail.split("C:\\Mail\\archive.pst::2097412")! == ("C:\\Mail\\archive.pst", 2097412))
        #expect(Mail.split("/Users/me/notes.txt") == nil)
        #expect(Mail.split("/Users/me/odd::name.txt") == nil)
        // What search checks is there on disk (and not skipped): a mail's PST.
        #expect(Mail.file(of: "C:/Mail/archive.pst::2097412") == "C:/Mail/archive.pst")
        #expect(Mail.file(of: "/Users/me/notes.txt") == "/Users/me/notes.txt")
    }

    @Test func aPSTIsAMailbox() {
        #expect(Rules.classify(pst, values: nil, options: IndexOptions()) == .index(.mailbox))
    }

    @Test func syncListsTheMailsAndRunReadsThem() throws {
        try copyPST(to: pst)
        let store = try store()
        let indexer = try indexer(store)
        let summary = try indexer.sync([files])
        #expect(summary.added == 31)   // the PST and its 30 mails
        #expect(summary.queued.count == 30)
        var listed = try mails(store)
        #expect(listed.count == 30)
        #expect(listed.allSatisfy { $0.state == "pending" && $0.info["subject"]?.hasPrefix("PST test ") == true })
        #expect(Set(listed.compactMap { $0.info["folder"] }) == ["/Boite de test", "/Clients", "/Clients/Dupont"])
        // Before it's read, a mail is found by its subject.
        #expect(try found(store, "PST test 07").count == 1)

        #expect(try indexer.run()["done"] == 30)
        listed = try mails(store)
        #expect(listed.allSatisfy { $0.state == "done" })
        let seven = try #require(listed.first { $0.info["subject"] == "PST test 07" })
        #expect(seven.info["folder"] == "/Clients")   // from the listing, kept
        #expect(seven.info["attachments"] == "piece_jointe.txt")
        #expect(try found(store, "DEV-2024-0007") == [seven.path])
        // Attachments are read for their text: mails 0, 7, 14, 21 and 28 have one.
        #expect(try found(store, "Contenu de la piece jointe").count == 5)
        #expect(try store.info(of: try #require(store.files(under: [files.path]).first { $0.kind == .mailbox }).id)
                == ["mails": "30"])

        // Nothing changed: nothing is listed or queued again.
        let again = try indexer.sync([files])
        #expect(again.added == 0 && again.changed == 0 && again.removed == 0 && again.queued.isEmpty)
    }

    @Test func aMovedPSTKeepsItsMails() throws {
        try copyPST(to: pst)
        let store = try store()
        let indexer = try indexer(store)
        _ = try indexer.sync([files])
        try indexer.run()
        let renamed = files.appendingPathComponent("archive 2024.pst")
        try FileManager.default.moveItem(at: pst, to: renamed)
        let summary = try indexer.sync([files])
        #expect(summary.moved == 1 && summary.removed == 0 && summary.queued.isEmpty)
        let moved = try store.mails(in: renamed.path)
        #expect(moved.count == 30 && moved.allSatisfy { $0.state == "done" })
        #expect(try found(store, "DEV-2024-0007").first?.hasPrefix(renamed.path + "::") == true)
    }

    @Test func mailsWaitingForOutlookAreReadOnceThePSTCanBe() throws {
        try copyPST(to: pst)
        let store = try store()
        let indexer = try indexer(store)
        _ = try indexer.sync([files])
        try indexer.run()
        // As if Outlook had held the PST when these were read.
        let waiting = Array(try store.mails(in: pst.path).prefix(3))
        for mail in waiting { try store.finish(mail.id, state: "skipped", detail: Mail.waiting, info: store.info(of: mail.id)) }
        #expect(try store.pendingCount() == 0)   // waiting isn't pending: nothing spins while Outlook has it
        let summary = try indexer.sync([files])   // the PST didn't change, but its mails wait: it's listed
        #expect(Set(summary.queued) == Set(waiting.map(\.id)))
        #expect(try indexer.run()["done"] == 3)
    }

    @Test func aMailsPreviewIsItsBeginning() throws {
        try copyPST(to: pst)
        let store = try store()
        let indexer = try indexer(store)
        _ = try indexer.sync([files])
        let seven = try #require(try store.mails(in: pst.path).first { try store.info(of: $0.id)["subject"] == "PST test 07" })
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.firstText(ofFile: seven.path) == nil)   // listed, not read yet
        try indexer.run()
        let text = try #require(try searcher.firstText(ofFile: seven.path))
        #expect(text.hasPrefix("PST test 07\n"))
        #expect(text.contains("reference DEV-2024-0007"))
    }

    @Test func aDeletedPSTTakesItsMailsAlong() throws {
        try copyPST(to: pst)
        let store = try store()
        let indexer = try indexer(store)
        _ = try indexer.sync([files])
        try FileManager.default.removeItem(at: pst)
        let summary = try indexer.sync([files])
        #expect(summary.removed == 31)
        #expect(try store.files(under: [files.path]).isEmpty)
    }
}

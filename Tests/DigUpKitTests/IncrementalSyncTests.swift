import Foundation
import Testing
@testable import DigUpKit

@Suite final class IncrementalSyncTests {
    let base: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpSyncTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path), isDirectory: true)
    }()

    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ path: String, _ text: String = "notes") throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func indexer(_ store: IndexStore, options: IndexOptions = IndexOptions()) throws -> Indexer {
        try Indexer(store: store, options: options,
                    makeEmbedder: { throw WorkerError.notFound("sync doesn't need a model") })
    }

    @Test func syncLeavesOtherChosenFoldersAlone() throws {
        let a = try write("A/a.txt")
        let b = try write("B/b.txt")
        let roots = [a.deletingLastPathComponent(), b.deletingLastPathComponent()]
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        #expect(try indexer.sync(roots).added == 2)
        try Data("changed A".utf8).write(to: a)
        try Data("changed B as well".utf8).write(to: b)
        let sync = try indexer.sync(roots, changedPaths: [a.path])
        #expect(sync.changed == 1)
        #expect(sync.crawl.candidates.map(\.path) == [a.path])
        #expect(try store.files(under: [roots[1].path]).first?.size == 5)
        #expect(try indexer.sync(roots).changed == 1)   // B was left for a later full sync
    }

    @Test func aMoveAcrossScopesKeepsItsRow() throws {
        let old = try write("root/old/note.txt")
        let new = base.appendingPathComponent("root/new/note.txt")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = base.appendingPathComponent("root")
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        #expect(try indexer.sync([root]).added == 1)
        let id = try #require(try store.files(under: [root.path]).first?.id)
        try FileManager.default.moveItem(at: old, to: new)
        let sync = try indexer.sync([root], changedPaths: [old.path, new.path])
        #expect(sync.moved == 1)
        #expect(sync.added == 0 && sync.removed == 0)
        let row = try #require(try store.files(under: [root.path]).first)
        #expect(row.id == id && row.path == new.path)
    }

    @Test func deletionRemovesRowsButAMissingRootKeepsThem() throws {
        let gone = try write("drive/sub/gone.txt")
        let kept = try write("drive/kept.txt")
        let root = base.appendingPathComponent("drive")
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        #expect(try indexer.sync([root]).added == 2)
        try FileManager.default.removeItem(at: gone)
        #expect(try indexer.sync([root], changedPaths: [gone.path]).removed == 1)
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("disconnected"))
        #expect(try indexer.sync([root], changedPaths: [kept.path]).removed == 0)
        #expect(try store.files(under: [root.path]).count == 1)
    }

    @Test func explicitlyChosenFolderOverridesAnAncestorExclusion() throws {
        let file = try write("root/Skipped/Chosen/nested/note.txt")
        let root = base.appendingPathComponent("root")
        let chosen = base.appendingPathComponent("root/Skipped/Chosen")
        var options = IndexOptions()
        options.excludedFolders = [base.appendingPathComponent("root/Skipped").path]
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store, options: options)
        #expect(try indexer.sync([root, chosen]).added == 1)
        let sync = try indexer.sync([root, chosen], changedPaths: [file.path])
        #expect(sync.unchanged == 1 && sync.removed == 0)
        let outer = try write("root/outer.txt")
        let broader = try indexer.sync([root, chosen], changedPaths: [outer.path])
        #expect(broader.added == 1 && broader.unchanged == 1 && broader.removed == 0)
    }

    @Test func chosenRootsDoNotInheritRulesFromAboveThem() throws {
        try write("project/package.json", "{}")
        let file = try write("project/node_modules/Chosen/note.txt")
        let chosen = file.deletingLastPathComponent()
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        #expect(try indexer.sync([chosen]).added == 1)
        #expect(try indexer.sync([chosen], changedPaths: [file.path]).unchanged == 1)
    }

    @Test func scopedWalkInheritsProjectAndTraversalRules() throws {
        try write("root/project/package.json", "{}")
        try write("root/project/docs/note.txt")
        try write("root/external/lib/code.swift", "let x = 1")
        try write("root/Tool.app/Contents/note.txt")
        let root = base.appendingPathComponent("root")
        let project = base.appendingPathComponent("root/project/docs")
        #expect(Crawler.crawl([project], options: IndexOptions(), chosenRoots: [root]).candidates.isEmpty)
        let bundle = base.appendingPathComponent("root/Tool.app/Contents")
        #expect(Crawler.crawl([bundle], options: IndexOptions(), chosenRoots: [root]).candidates.isEmpty)
        var code = IndexOptions()
        code.code = true
        let external = base.appendingPathComponent("root/external/lib")
        #expect(Crawler.crawl([external], options: code, chosenRoots: [root]).candidates.isEmpty)
    }

    @Test func aScopedFolderIsNotAChosenRootForDatasetRules() throws {
        for i in 0..<300 { try write(String(format: "root/photos/frame_%06d.jpg", i)) }
        let root = base.appendingPathComponent("root")
        let photo = base.appendingPathComponent("root/photos/frame_000000.jpg")
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        let sync = try indexer.sync([root], changedPaths: [photo.path])
        #expect(sync.added == 0)
        #expect(sync.crawl.datasets[photo.deletingLastPathComponent().path] == 300)
    }

    #if !os(Windows)
    @Test func aDeletedPathUsesItsSurvivingParentsRealSpelling() throws {
        let file = try write("real/sub/note.txt")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base.appendingPathComponent("real"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try indexer(store)
        #expect(try indexer.sync([alias]).added == 1)
        try FileManager.default.removeItem(at: file)
        #expect(try indexer.sync([alias], changedPaths: [alias.appendingPathComponent("sub/note.txt").path]).removed == 1)
    }
    #endif
}

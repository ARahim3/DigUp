import Foundation
import Testing
@testable import DigUpKit

@Suite struct CrawlProgressTests {
    @Test func emptyFolderReportsStartAndFinal() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var updates: [CrawlProgress] = []

        let report = Crawler.crawl([root], options: IndexOptions()) { updates.append($0) }

        #expect(report.candidates.isEmpty)
        #expect(updates == [CrawlProgress(checked: 0, root: root.standardizedFileURL.path),
                            CrawlProgress(checked: 0, root: nil)])
    }

    @Test func countsEnumeratedEntriesIncludingExcludedFoldersWithoutChangingCandidates() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try "keep".write(to: root.appendingPathComponent("keep.txt"), atomically: false, encoding: .utf8)
        try "skip".write(to: excluded.appendingPathComponent("skip.txt"), atomically: false, encoding: .utf8)
        try "skip".write(to: root.appendingPathComponent("other.xyz"), atomically: false, encoding: .utf8)
        var options = IndexOptions()
        options.excludedFolders = [excluded.path]
        var updates: [CrawlProgress] = []

        let baseline = Crawler.crawl([root], options: options)
        let observed = Crawler.crawl([root], options: options) { updates.append($0) }

        #expect(observed.candidates.map(\.path) == baseline.candidates.map(\.path))
        #expect(observed.skipped == baseline.skipped)
        #expect(observed.skippedFolders == baseline.skippedFolders)
        #expect(observed.candidates.map(\.path) == [FolderSelection.realPath(root.appendingPathComponent("keep.txt").path)])
        #expect(updates.first == CrawlProgress(checked: 0, root: root.standardizedFileURL.path))
        #expect(updates.last == CrawlProgress(checked: 3, root: nil))
        #expect(updates.map(\.checked) == updates.map(\.checked).sorted())
    }

    @Test func startsEachRootAndKeepsCumulativeCount() throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try "one".write(to: first.appendingPathComponent("one.txt"), atomically: false, encoding: .utf8)
        try "two".write(to: second.appendingPathComponent("two.txt"), atomically: false, encoding: .utf8)
        var updates: [CrawlProgress] = []

        _ = Crawler.crawl([first, second], options: IndexOptions()) { updates.append($0) }

        #expect(updates.first == CrawlProgress(checked: 0, root: first.standardizedFileURL.path))
        #expect(updates.contains(CrawlProgress(checked: 1, root: second.standardizedFileURL.path)))
        #expect(updates.last == CrawlProgress(checked: 2, root: nil))
    }

    @Test func indexerForwardsProgressBeforeWritingNewRows() throws {
        let root = try makeFolder()
        let index = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: index) }
        try "note".write(to: root.appendingPathComponent("note.txt"), atomically: false, encoding: .utf8)
        let store = try IndexStore(directory: index)
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        var updates: [CrawlProgress] = []
        var rowsDuringProgress: [Int] = []

        let summary = try indexer.sync([root]) { update in
            updates.append(update)
            rowsDuringProgress.append((try? store.files(under: [root.path]).count) ?? -1)
        }

        #expect(summary.added == 1)
        #expect(updates.first == CrawlProgress(checked: 0, root: root.standardizedFileURL.path))
        #expect(updates.last?.root == nil)
        #expect(updates.last?.checked == 1)
        #expect(rowsDuringProgress.allSatisfy { $0 == 0 })
        #expect(try store.files(under: [root.path]).count == 1)
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpCrawlProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

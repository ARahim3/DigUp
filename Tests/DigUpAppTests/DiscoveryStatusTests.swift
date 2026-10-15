import Foundation
import DigUpKit
import Testing
@testable import DigUpApp

@MainActor @Suite struct DiscoveryStatusTests {
    private func model() -> AppModel {
        var settings = AppSettings.load()
        settings.roots = [URL(fileURLWithPath: "/example")]
        settings.codeRoots = [URL(fileURLWithPath: "/code")]
        return AppModel(settings: settings, download: ModelDownload(
            folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @Test func discoveryDoesNotPresentAnEmptyCompletedIndex() {
        let model = model()
        model.status.activity = .syncing
        #expect(model.statusLine == "Checking folders…")
        #expect(model.indexDetail == "Finding files to index. The total is available after this scan.")
        #expect(model.progress == nil)
        #expect(model.activityBadge == "Checking folders")
        #expect(model.resultsCaveat == "Still checking folders: some files haven't been found yet")
    }

    @Test func aRescanKeepsExistingSearchableCounts() {
        let model = model()
        model.status.activity = .syncing
        model.status.files = 12
        model.status.searchable = 10
        model.status.pending = 2
        #expect(model.indexDetail == "10 files searchable · checking for changes")
    }

    @Test func liveCountsNeverBecomeAnIndexingPercentage() {
        let model = model()
        model.status.activity = .syncing
        model.status.scan = CrawlProgress(checked: 42, root: "/example")
        #expect(model.statusLine == "Checking folders… · 42 entries checked")
        #expect(model.progress == nil)
        model.status.scan = nil
        model.status.activity = .indexing(done: 1, total: 4)
        model.status.files = 4
        model.status.searchable = 1
        model.status.pending = 3
        #expect(model.progress == 0.25)
        #expect(model.indexDetail == "1 of 4 files searchable · 3 waiting")
        #expect(model.activityBadge == "Indexing 25%")
    }

    @Test func codeDiscoveryIsVisibleWithoutMainFolders() {
        let model = model()
        model.settings.roots = []
        model.status.activity = .idle
        model.status.code.scan = CrawlProgress(checked: 7, root: "/code")
        #expect(model.statusLine == "Checking code folders… · 7 entries checked")
        #expect(model.codeStatusLine == model.statusLine)
        #expect(model.progress == nil)
        model.status.activity = .failed("Indexing stopped")
        #expect(model.statusLine == "⚠︎ Indexing stopped")
    }
}

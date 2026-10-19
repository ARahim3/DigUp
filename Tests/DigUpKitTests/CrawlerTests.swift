import Foundation
import Testing
@testable import DigUpKit

/// The crawl's folder rules (`Crawler.crawl`).
@Suite final class CrawlerTests {
    /// In Caches, not the temporary folder: the walk reports /private/var/… for /var/… (see LongFilesTests).
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    func names(_ report: CrawlReport) -> [String] {
        report.candidates.map { String($0.path.dropFirst(folder.path.count + 1)) }.sorted()
    }

    @Test func aChosenFolderIsReadWholeAndProjectsInsideItAreNot() throws {
        try write("package.json", "{}")          // a marker in the chosen folder itself (a home folder in git)
        try write("notes.md", "notes")
        try write("Screenshot 2026-10-19 at 10.00.00.png")
        try write("app/package.json", "{}")      // a project found inside: only its screenshots count
        try write("app/readme.md", "readme")
        try write("app/Screenshot 2026-10-19 at 10.01.00.png")
        let report = Crawler.crawl([folder], options: IndexOptions())
        #expect(names(report) == ["Screenshot 2026-10-19 at 10.00.00.png", "app/Screenshot 2026-10-19 at 10.01.00.png",
                                  "notes.md"])
        #expect(report.skipped["inside a code project"] == 1)
        #expect(report.leftOut[folder.path]?["inside a code project"] == 1)
        #expect(report.leftOut[folder.path]?["code or data file"] == 2)   // the two package.json files
    }
}

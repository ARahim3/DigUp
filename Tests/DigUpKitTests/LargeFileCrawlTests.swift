import Foundation
import Testing
@testable import DigUpKit

@Suite struct LargeFileCrawlTests {
    @Test func largeFilesDoNotStopTheWalk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DigUpLargeFiles-\(UUID().uuidString)",
                                                                isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("still found".utf8).write(to: nested.appendingPathComponent("notes.txt"))
        let large = root.appendingPathComponent("large.mp4", isDirectory: false)
        #expect(fm.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        defer { try? handle.close() }
        // Exercise both sides of the signed low-DWORD boundary and the carry into the high DWORD.
        // No media contents are read: this is a metadata-only crawl.
        let sizes: [UInt64] = [(1 << 31) - 1, 1 << 31, (1 << 32) - 1, 1 << 32, 5_000_000_000]
        for size in sizes {
            try handle.truncate(atOffset: size)
            let report = Crawler.crawl([root], options: IndexOptions())
            let byName = Dictionary(uniqueKeysWithValues: report.candidates.map {
                (URL(fileURLWithPath: $0.path).lastPathComponent, $0.size)
            })
            #expect(byName == ["large.mp4": Int64(size), "notes.txt": 11])
        }
        try handle.truncate(atOffset: 1 << 31)
        try handle.close()
        // Unsupported files must not crash discovery before classification either.
        try fm.moveItem(at: large, to: root.appendingPathComponent("large.bin", isDirectory: false))
        let report = Crawler.crawl([root], options: IndexOptions())
        #expect(report.candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["notes.txt"])
        #expect(report.skipped["other type"] == 1)
    }

    @Test func skippedDirectoriesDoNotHideTheirSiblings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DigUpWalk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["excluded", "kept", ".hidden", "Example.app"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("notes".utf8).write(to: folder.appendingPathComponent("\(name).txt"))
        }
        var options = IndexOptions()
        options.excludedFolders = [root.appendingPathComponent("excluded", isDirectory: true).path]
        let report = Crawler.crawl([root], options: options)
        #expect(report.candidates.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["kept.txt"])
    }
}

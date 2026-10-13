import XCTest
@testable import DigUpKit

final class NotionExtractorTests: XCTestCase {

    func testDefaultDatabasePath() {
        let path = NotionExtractor.defaultDatabasePath
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Notion/notion.db"))
    }

    func testNotionInstalledFlagMatchesFileSystem() {
        let exists = FileManager.default.fileExists(atPath: NotionExtractor.defaultDatabasePath)
        XCTAssertEqual(NotionExtractor.isNotionInstalled, exists)
    }

    func testExtractPagesBasicShape() throws {
        guard NotionExtractor.isNotionInstalled else {
            throw XCTSkip("Notion Desktop not installed on this machine")
        }
        let pages = try NotionExtractor.extractPages()
        XCTAssertFalse(pages.isEmpty, "Should extract at least one page from notion.db")
        for p in pages.prefix(10) {
            XCTAssertFalse(p.id.isEmpty,    "Page ID must not be empty")
            XCTAssertFalse(p.title.isEmpty, "Page title must not be empty")
            XCTAssertGreaterThan(p.modified, 0, "modified timestamp must be positive")

            // URL scheme correctness
            let cleanID = p.id.replacingOccurrences(of: "-", with: "")
            XCTAssertEqual(p.notionURL?.scheme, "notion")
            XCTAssertTrue(p.notionURL?.absoluteString.hasSuffix(cleanID) ?? false)
            XCTAssertEqual(p.webURL?.scheme, "https")
            XCTAssertTrue(p.webURL?.absoluteString.hasSuffix(cleanID) ?? false)
        }
    }

    func testPersonalHomePageExcluded() throws {
        guard NotionExtractor.isNotionInstalled else {
            throw XCTSkip("Notion Desktop not installed on this machine")
        }
        let pages = try NotionExtractor.extractPages()
        // Notion's internal personal_home_page block must not appear in results.
        for p in pages {
            XCTAssertFalse(p.title.lowercased().contains("personal_home"),
                           "personal_home_page blocks must be excluded from results")
        }
    }

    func testModifiedSinceFiltersResults() throws {
        guard NotionExtractor.isNotionInstalled else {
            throw XCTSkip("Notion Desktop not installed on this machine")
        }
        let all = try NotionExtractor.extractPages(since: 0)
        // Ask for pages modified in the far future — should return nothing.
        let future = Date().timeIntervalSince1970 + 86400 * 365 * 100
        let none = try NotionExtractor.extractPages(since: future)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(none.isEmpty, "No pages should be newer than 100 years from now")
    }

    func testNestedBlockTextIsExtracted() throws {
        guard NotionExtractor.isNotionInstalled else {
            throw XCTSkip("Notion Desktop not installed on this machine")
        }
        let pages = try NotionExtractor.extractPages()
        // At least some pages should have body text from child blocks.
        let pagesWithBody = pages.filter { !$0.text.isEmpty }
        XCTAssertFalse(pagesWithBody.isEmpty,
                       "Recursive traversal should extract child block text for at least one page")
    }
}

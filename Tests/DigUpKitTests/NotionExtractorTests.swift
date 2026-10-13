import XCTest
@testable import DigUpKit

final class NotionExtractorTests: XCTestCase {
    func testDefaultDatabasePath() {
        let path = NotionExtractor.defaultDatabasePath
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Notion/notion.db"))
    }

    func testNotionExtractorReadsIfPresent() throws {
        guard NotionExtractor.isNotionInstalled else {
            throw XCTSkip("Notion Desktop not installed on this test machine")
        }
        let pages = try NotionExtractor.extractPages()
        XCTAssertFalse(pages.isEmpty, "Should extract pages from local notion.db")
        for p in pages.prefix(5) {
            XCTAssertFalse(p.id.isEmpty)
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertNotNil(p.notionURL)
        }
    }
}

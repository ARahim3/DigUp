import Foundation
import Testing
@testable import DigUpKit

@Suite struct PDFMetadataTests {
    @Test func invalidInfoKeyDoesNotCrashPageExtraction() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-PDFMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pdf = folder.appendingPathComponent("notes.pdf")
        // PDF name escapes are bytes: #FF is invalid UTF-8 and made PDFKit's documentAttributes build an NSDictionary
        // with a nil key, aborting the indexer. The title remains readable through a typed CoreGraphics lookup.
        try TextPDF.write(["Find this sentence in the extracted page."], to: pdf,
                          info: "/Title (Quarterly notes) /Bad#FF (ignored metadata)")

        let result = try PDFExtractor.pages(of: pdf, range: { total in 0..<total }, minText: 1, renderPixels: 1400,
                                            to: folder.appendingPathComponent("rendered"))

        #expect(result.total == 1)
        #expect(result.title == "Quarterly notes")
        #expect(result.pages.count == 1)
        #expect(result.pages[0].text.contains("Find this sentence"))
    }
}

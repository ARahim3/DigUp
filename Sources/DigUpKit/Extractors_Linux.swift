#if os(Linux)
import Foundation

// Linux stubs with the same API so the indexer compiles and runs.
// Text and code index normally; images, scanned PDFs and OCR'd pages report
// why they were left out until the Linux backends land (stb/VIPS, poppler,
// tesseract). See Extractors.swift (macOS implementations).

enum ImageExtractor {
    struct Prepared: Sendable {
        let path: String
        let width: Int
        let height: Int
        let taken: String?
    }

    static func prepare(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool) throws -> Prepared {
        throw ExtractError.unreadable("images need a Linux image backend (stb/VIPS) — not ported yet")
    }
}

enum PDFExtractor {
    struct Page: Sendable {
        let number: Int
        let text: String
        let imagePath: String?
        var ocr = false
        var garbled: String?
    }

    static func pages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [Page], total: Int, title: String?) {
        throw ExtractError.unreadable("PDFs need a Linux PDF backend (poppler) — not ported yet")
    }
}
#endif

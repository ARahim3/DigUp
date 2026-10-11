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

/// PDFs on Linux via poppler (`pdfinfo` for the count/title, `pdftotext -layout`
/// for text pages, `pdftoppm` for pages rendered as images), mirroring what the
/// macOS reader returns: text pages as text, the rest as pictures (with garbled
/// layers kept for meaning, never shown). No OCR yet: pages whose text layer is
/// lost keep the layer as-is instead of being re-read.
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
        let info = try pdfinfo(of: url)
        let total = info.pages
        var pages: [Page] = []
        for index in range(total).clamped(to: 0..<total) {
            let number = index + 1
            var text = ((try? pageText(of: url, page: number)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var garbled: String?
            switch PageTextProblem.check(text) {
            case .lostLetters:
                // No OCR backend yet: keep the layer when it reads as text.
                if text.count >= minText {
                    pages.append(Page(number: number, text: text, imagePath: nil))
                    continue
                }
            case .glyphOrder:
                (text, garbled) = ("", text)
            case nil:
                if text.count >= minText {
                    pages.append(Page(number: number, text: text, imagePath: nil))
                    continue
                }
            }
            guard let image = render(url, page: number, pixels: renderPixels, to: folder) else { continue }
            pages.append(Page(number: number, text: text, imagePath: image, garbled: garbled))
        }
        return (pages, total, info.title)
    }

    // MARK: poppler

    private struct Info {
        var pages = 0
        var title: String?
        var encrypted = false
    }

    private static func pdfinfo(of url: URL) throws -> Info {
        let output: String
        do {
            output = try run("pdfinfo", [url.path])
        } catch {
            throw ExtractError.unreadable("can't open PDF (\(error))")
        }
        var info = Info()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Pages:") {
                info.pages = Int(line.dropFirst("Pages:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("Title:") {
                let title = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { info.title = title }
            } else if line.hasPrefix("Encrypted:") {
                info.encrypted = line.dropFirst("Encrypted:".count).trimmingCharacters(in: .whitespaces)
                    .hasPrefix("yes")
            }
        }
        guard info.pages > 0 else {
            if info.encrypted { throw ExtractError.locked }
            throw ExtractError.unreadable("no pages")
        }
        return info
    }

    private static func pageText(of url: URL, page: Int) throws -> String {
        do {
            return try run("pdftotext", ["-layout", "-f", "\(page)", "-l", "\(page)", url.path, "-"])
        } catch {
            // A locked file fails every page the same way.
            if (try? pdfinfo(of: url))?.encrypted == true { throw ExtractError.locked }
            throw error
        }
    }

    /// The page as a PNG fitted roughly into a square of `pixels` (like the mac render).
    private static func render(_ url: URL, page: Int, pixels: Int, to folder: URL) -> String? {
        let dpi = max(100, min(300, pixels / 8))   // 1400 px -> 175 dpi (~1500x1900 for Letter)
        let prefix = folder.appendingPathComponent(UUID().uuidString).path
        guard (try? run("pdftoppm", ["-png", "-r", "\(dpi)", "-f", "\(page)", "-l", "\(page)",
                                     url.path, prefix])) != nil else { return nil }
        let out = "\(prefix)-\(page).png"
        return FileManager.default.fileExists(atPath: out) ? out : nil
    }

    /// poppler's stdout, or an error. Looks in /usr/bin, then on PATH.
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/\(tool)") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool] + arguments
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ExtractError.unreadable("can't run \(tool) (poppler-utils installed?)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw ExtractError.unreadable("\(tool) failed")
        }
        return text
    }
}
#endif

// The readers Linux and Windows use for documents (a Mac reads them through Cocoa): what a crafted file does to them.
#if !canImport(AppKit)
import CMiniz
import Foundation
import Testing
@testable import DigUpKit

@Suite struct PortableDocsTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-PortableDocs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A zip with one deflated entry, as Word and LibreOffice write theirs.
    private func zip(named file: String, entry: String, _ bytes: [UInt8]) throws -> URL {
        var archive = mz_zip_archive()
        guard mz_zip_writer_init_heap(&archive, 0, 0) != 0 else { throw ExtractError.unreadable("can't start a zip") }
        defer { mz_zip_writer_end(&archive) }
        let added = bytes.withUnsafeBytes { mz_zip_writer_add_mem(&archive, entry, $0.baseAddress, $0.count, 1) }
        guard added != 0 else { throw ExtractError.unreadable("can't add the entry") }
        var pointer: UnsafeMutableRawPointer?
        var size = 0
        guard mz_zip_writer_finalize_heap_archive(&archive, &pointer, &size) != 0, let pointer else {
            throw ExtractError.unreadable("can't finish the zip")
        }
        defer { mz_free(pointer) }
        let url = folder.appendingPathComponent(file)
        try Data(bytes: pointer, count: size).write(to: url)
        return url
    }

    /// A zip of a few KB can declare an entry of any size, and extracting allocates the declared size whole.
    @Test func zipEntriesOverTheCapAreRefusedBeforeAnythingIsAllocated() throws {
        let small = try zip(named: "notes.docx", entry: "word/document.xml",
                            Array("<w:document><w:p>hello there</w:p></w:document>".utf8))
        #expect(try Zip.entry("word/document.xml", in: small).contains("hello there"))
        let declared = Int(Zip.maxEntryBytes) + 1
        let huge = try zip(named: "bomb.docx", entry: "word/document.xml", [UInt8](repeating: 0x41, count: declared))
        #expect(try FileManager.default.attributesOfItem(atPath: huge.path)[.size] as? Int ?? 0 < 1 << 20)
        #expect(throws: ExtractError.self) { try Zip.entry("word/document.xml", in: huge) }
    }

    /// \\uN is a signed 16-bit value; anything past that used to trap the conversion and end the helper.
    @Test func rtfUnicodeValuesOutOfRangeAreDropped() {
        let text = RTF.text("{\\rtf1 a\\u99999999999?b\\u-99999?c\\u8364?d}")
        #expect(text.contains("€"))
        #expect(text.hasPrefix("a") && text.hasSuffix("d"))
        #expect(RTF.text("{\\rtf1 \\u4294967296?x}") == "x")
    }
}
#endif

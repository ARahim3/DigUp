import Foundation
import Testing
@testable import DigUpKit
#if canImport(Compression)
import Compression
#endif

/// Spreadsheets and presentations (`OfficeText`), from files made here with the parts Excel, PowerPoint and LibreOffice
/// write, and a zip writer of our own.
@Suite final class OfficeTests {
    /// In Caches, not the temporary folder: the walk reports /private/var/… for /var/… (see LongFilesTests).
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("files"),
                                                 withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent("files").appendingPathComponent(name) }

    static let workbook: [(String, String)] = [
        ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="xl/workbook.xml"/></Relationships>
            """),
        ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
            <sheet name="Budget &amp; devis" sheetId="2" r:id="rId2"/><sheet name="Notes" sheetId="1" r:id="rId1"/>\
            </sheets></workbook>
            """),
        ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="/xl/worksheets/sheet2.xml"/>\
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" \
            Target="sharedStrings.xml"/></Relationships>
            """),
        ("xl/sharedStrings.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">\
            <si><t>Toiture</t></si>\
            <si><r><t xml:space="preserve">Zinc </t></r><r><rPr><b/></rPr><t>quartz</t></r>\
            <rPh sb="0" eb="1"><t>ジンク</t></rPh></si>\
            <si><t>Menuiserie</t></si></sst>
            """),
        ("xl/worksheets/sheet2.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>12000</v></c><c r="C1" s="1"/></row>\
            <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="b"><v>1</v></c><c r="C2" t="e"><v>#N/A</v></c></row>\
            <row r="3"><c r="A3" t="inlineStr"><is><t>&#201;chafaudage</t></is></c>\
            <c r="B3" t="str"><f>IF(B1&gt;0,"OK","")</f><v>OK</v></c></row>\
            <row r="4"/></sheetData></worksheet>
            """),
        ("xl/worksheets/sheet1.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="1"><c r="A1" t="s"><v>2</v></c></row></sheetData></worksheet>
            """),
    ]

    static let deck: [(String, String)] = [
        ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="ppt/presentation.xml"/></Relationships>
            """),
        ("ppt/presentation.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst><p:sldId id="257" r:id="rId3"/><p:sldId id="256" r:id="rId2"/></p:sldIdLst></p:presentation>
            """),
        ("ppt/_rels/presentation.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" \
            Target="slideMasters/slideMaster1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" \
            Target="slides/slide1.xml"/>\
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" \
            Target="slides/slide2.xml"/></Relationships>
            """),
        ("ppt/slides/slide2.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:sp><p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="fr-FR"/><a:t>Lancement du projet</a:t></a:r></a:p></p:txBody></p:sp>\
            <p:sp><p:txBody><a:p><a:r><a:t xml:space="preserve">Planning </a:t></a:r><a:r><a:t>T3</a:t></a:r></a:p>\
            <a:p><a:r><a:t>Budget</a:t></a:r><a:br/><a:r><a:t>validé</a:t></a:r></a:p>\
            <a:p><a:fld id="{B6F15528}" type="slidenum"><a:t>1</a:t></a:fld></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld></p:sld>
            """),
        ("ppt/slides/_rels/slide2.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" \
            Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" \
            Target="../notesSlides/notesSlide1.xml"/></Relationships>
            """),
        ("ppt/notesSlides/notesSlide1.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:sp><p:txBody><a:p><a:r><a:t>Rappeler le devis du couvreur</a:t></a:r></a:p></p:txBody></p:sp>\
            <p:sp><p:txBody><a:p><a:fld id="{1}" type="slidenum"><a:t>1</a:t></a:fld></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld></p:notes>
            """),
        ("ppt/slides/slide1.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:sp><p:txBody><a:p><a:r><a:t>Annexe : contacts &lt;fournisseurs&gt;</a:t></a:r></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld></p:sld>
            """),
    ]

    static let calc: [(String, String)] = [
        ("mimetype", "application/vnd.oasis.opendocument.spreadsheet"),
        ("content.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <office:body><office:spreadsheet><table:table table:name="Inventaire">\
            <table:table-column table:number-columns-repeated="3"/>\
            <table:table-row><table:table-cell office:value-type="string"><text:p>Tuiles<text:s/>canal</text:p>\
            </table:table-cell><table:table-cell office:value-type="float" office:value="340"><text:p>340</text:p>\
            </table:table-cell><table:table-cell office:value-type="boolean" office:boolean-value="true"><text:p>VRAI</text:p>\
            </table:table-cell><table:table-cell table:number-columns-repeated="1021"/></table:table-row>\
            <table:table-row table:number-rows-repeated="1048574"><table:table-cell table:number-columns-repeated="1024"/>\
            </table:table-row>\
            <table:table-row><table:table-cell><office:annotation><dc:creator>Jean</dc:creator>\
            <dc:date>2024-01-01T00:00:00</dc:date><text:p>À recommander</text:p></office:annotation>\
            <text:p>Gouttières</text:p></table:table-cell></table:table-row>\
            </table:table></office:spreadsheet></office:body></office:document-content>
            """),
    ]

    static let impress: [(String, String)] = [
        ("mimetype", "application/vnd.oasis.opendocument.presentation"),
        ("content.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
            xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" \
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:presentation>\
            <draw:page draw:name="page1"><draw:frame><draw:text-box>\
            <text:p>Bilan<text:tab/>2024</text:p>\
            <text:p><text:span>Chantier</text:span> terminé<text:line-break/>en avance</text:p>\
            </draw:text-box></draw:frame><presentation:notes><draw:page-thumbnail/><draw:frame><draw:text-box>\
            <text:p>Remercier l'équipe <text:page-number>1</text:page-number></text:p>\
            </draw:text-box></draw:frame></presentation:notes></draw:page>\
            <draw:page draw:name="page2"><draw:frame><draw:text-box><text:h>Perspectives</text:h>\
            </draw:text-box></draw:frame></draw:page>\
            </office:presentation></office:body></office:document-content>
            """),
    ]

    @Test func spreadsheetSheetsComeInTheWorkbooksOrder() throws {
        let url = file("budget.xlsx")
        try OfficeFiles.zip(Self.workbook, to: url)
        #expect(try DocExtractor.text(of: url) == """
            Budget & devis
            Toiture\t12000
            Zinc quartz
            Échafaudage\tOK

            Notes
            Menuiserie
            """)
    }

    @Test func presentationSlidesComeInTheDecksOrderWithTheirNotes() throws {
        let url = file("lancement.pptx")
        try OfficeFiles.zip(Self.deck, to: url)
        #expect(try DocExtractor.text(of: url) == """
            Lancement du projet
            Planning T3
            Budget
            validé
            Rappeler le devis du couvreur

            Annexe : contacts <fournisseurs>
            """)
    }

    @Test func openDocumentSpreadsheet() throws {
        let url = file("inventaire.ods")
        try OfficeFiles.zip(Self.calc, to: url)
        #expect(try DocExtractor.text(of: url) == """
            Inventaire
            Tuiles canal\t340
            À recommander Gouttières
            """)
    }

    @Test func openDocumentPresentation() throws {
        let url = file("bilan.odp")
        try OfficeFiles.zip(Self.impress, to: url)
        #expect(try DocExtractor.text(of: url) == """
            Bilan 2024
            Chantier terminé
            en avance
            Remercier l'équipe

            Perspectives
            """)
    }

    #if canImport(Compression)
    /// Office deflates its parts; the readers elsewhere are miniz's, as for docx.
    @Test func deflatedPartsAreRead() throws {
        let url = file("budget.xlsx")
        try OfficeFiles.zip(Self.workbook, to: url, deflate: true)
        #expect(try DocExtractor.text(of: url).hasPrefix("Budget & devis\nToiture\t12000"))
    }
    #endif

    @Test func passwordProtectedFileIsReportedSo() throws {
        let url = file("secret.xlsx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 504)).write(to: url)
        #expect(failure(url) == "password-protected")
    }

    @Test func otherFilesAreUnreadable() throws {
        let garbage = file("not a deck.pptx")
        try Data("plain text".utf8).write(to: garbage)
        #expect(failure(garbage) == "unreadable: not a zip file")
        let partless = file("empty.ods")
        try OfficeFiles.zip([("mimetype", "application/vnd.oasis.opendocument.spreadsheet")], to: partless)
        #expect(failure(partless) == "unreadable: no content.xml inside")
    }

    @Test func relationshipTargetsBecomeEntryNames() {
        #expect(OfficeText.resolve("../notesSlides/notesSlide1.xml", from: "ppt/slides")
                == "ppt/notesSlides/notesSlide1.xml")
        #expect(OfficeText.resolve("/xl/worksheets/sheet2.xml", from: "xl") == "xl/worksheets/sheet2.xml")
        #expect(OfficeText.resolve("xl/workbook.xml", from: "") == "xl/workbook.xml")
    }

    @Test func officeFilesAreIndexedAsDocuments() throws {
        for name in ["a.xlsx", "a.pptx", "a.ods", "a.odp", "A.XLSX"] {
            #expect(Rules.classify(file(name), values: nil, options: IndexOptions()) == .index(.doc))
        }
        let url = file("budget.xlsx")
        try OfficeFiles.zip(Self.workbook, to: url)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder.appendingPathComponent("files")])
        try indexer.run()
        var found: [String] = []
        try store.db.query("""
            SELECT f.path FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file WHERE fts MATCH ?
            """, [.text("\"quartz\"")]) { found.append($0.text(0) ?? "") }
        #expect(found == [url.path])
    }

    private func failure(_ url: URL) -> String? {
        do {
            _ = try DocExtractor.text(of: url)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

/// A zip of the given parts: stored, or deflated as Office writes them where the Compression framework is there.
enum OfficeFiles {
    static func zip(_ parts: [(String, String)], to url: URL, deflate: Bool = false) throws {
        var file: [UInt8] = [], directory: [UInt8] = []
        func number(_ value: Int, _ size: Int, into bytes: inout [UInt8]) {
            for index in 0..<size { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        for (name, text) in parts {
            let data = Array(text.utf8), path = Array(name.utf8)
            var stored = data, method = 0
            #if canImport(Compression)
            if deflate, !data.isEmpty {
                var out = [UInt8](repeating: 0, count: data.count + 1024)
                let size = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
                if size > 0 { (stored, method) = (Array(out[..<size]), 8) }
            }
            #endif
            let crc = crc32(data)
            var common: [UInt8] = []
            number(20, 2, into: &common)            // version needed
            number(0x0800, 2, into: &common)        // flags: UTF-8 names
            number(method, 2, into: &common)
            number(0, 4, into: &common)             // time and date
            number(Int(crc), 4, into: &common)
            number(stored.count, 4, into: &common)
            number(data.count, 4, into: &common)
            number(path.count, 2, into: &common)
            number(0, 2, into: &common)             // extra field
            let offset = file.count
            number(0x0403_4B50, 4, into: &file)
            file += common + path + stored
            number(0x0201_4B50, 4, into: &directory)
            number(20, 2, into: &directory)         // made by
            directory += common
            number(0, 2, into: &directory)          // comment
            number(0, 4, into: &directory)          // disk, internal attributes
            number(0, 4, into: &directory)          // external attributes
            number(offset, 4, into: &directory)
            directory += path
        }
        let start = file.count
        file += directory
        number(0x0605_4B50, 4, into: &file)
        number(0, 4, into: &file)                   // disks
        number(parts.count, 2, into: &file)
        number(parts.count, 2, into: &file)
        number(directory.count, 4, into: &file)
        number(start, 4, into: &file)
        number(0, 2, into: &file)                   // comment
        try Data(file).write(to: url)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

import Foundation
import Testing
@testable import DigUpKit

/// Issue #182: the preflight that marks a picture from its header before the helper decodes it, the
/// layered-TIFF parser, the stopped-file note the helper leaves when it dies on a file, and the queue head
/// that note marks. The synthetic files are built from bytes here, so they run on CI (no fixtures, no
/// network); the tests that need a real RAW camera file take it from `DIGUP_TEST_RAW` and stay disabled
/// without it (measured on the box that ran the #182 calibration: Apple M1, 8 GB RAM, macOS 26.5.1, a
/// real 45.44 MP Nikon Z9 NEF).
@Suite(.serialized) struct PreflightTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PreflightTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: The layered-TIFF parser

    func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    func sh(_ v: Int) -> [UInt8] { u16(v) }

    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        var out = u16(tag) + u16(type) + u32(count) + value
        while out.count < 12 { out.append(0) }
        return out
    }

    func ifd(_ entries: [(tag: Int, type: Int, count: Int, value: [UInt8])]) -> [UInt8] {
        var out = u16(entries.count)
        for e in entries { out += entry(e.tag, e.type, e.count, e.value) }
        out += u32(0)   // no next IFD
        return out
    }

    var short8: [UInt8] { u16(8) }   // BitsPerSample 8 as a stored SHORT

    /// A Photoshop-style layered TIFF: a master that declares itself a preview (`SubfileType & 1`) and
    /// keeps its full-size layers in sub-IFDs. Sizes: master 800×600, layers 3000×3000, 3000×3000, 1500×1500.
    func layeredTIFF(layers: [(Int, Int)] = [(3000, 3000), (3000, 3000), (1500, 1500)],
                     master: (width: Int, height: Int) = (800, 600)) -> Data {
        let n = layers.count
        let offsetsAt = 8 + (2 + 10 * 12 + 4)
        let layersAt = offsetsAt + 4 * n
        let dataAt = layersAt + n * (2 + 3 * 12 + 4)
        var bytes = [UInt8]("II".utf8) + u16(42) + u32(8)
        bytes += ifd([
            (0x00FE, 4, 1, u32(1)),
            (0x0100, 4, 1, u32(master.width)), (0x0101, 4, 1, u32(master.height)),
            (0x0102, 3, 1, short8), (0x0103, 3, 1, sh(1)), (0x0106, 3, 1, sh(1)),
            (0x0111, 4, 1, u32(dataAt)), (0x0115, 3, 1, sh(1)), (0x0116, 3, 1, sh(600)),
            (0x0145, 4, n, u32(offsetsAt)),
        ])
        for i in 0..<n { bytes += u32(layersAt + i * (2 + 3 * 12 + 4)) }
        for (w, h) in layers {
            bytes += ifd([(0x00FE, 4, 1, u32(0)), (0x0100, 4, 1, u32(w)), (0x0101, 4, 1, u32(h))])
        }
        bytes += [0, 0, 0, 0]   // dummy strips: the parser and the preflight read sizes, not pixels
        return Data(bytes)
    }

    /// A plain TIFF: one full-size IFD, no preview declaration, no sub-IFDs — the shape ImageIO streams
    /// tiles of, measured safe at 2,125 MP.
    func plainTIFF(side: Int) -> Data {
        var bytes = [UInt8]("II".utf8) + u16(42) + u32(8)
        bytes += ifd([
            (0x00FE, 4, 1, u32(0)),
            (0x0100, 4, 1, u32(side)), (0x0101, 4, 1, u32(side)),
            (0x0102, 3, 1, short8), (0x0103, 3, 1, sh(1)), (0x0106, 3, 1, sh(1)),
            (0x0111, 4, 1, u32(8 + 2 + 9 * 12 + 4)), (0x0115, 3, 1, sh(1)), (0x0116, 3, 1, sh(side)),
        ])
        bytes += [0]
        return Data(bytes)
    }

    func write(_ data: Data, _ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    @Test func parserSumsTheLayersOfALayeredTIFF() throws {
        let file = write(layeredTIFF(), "layered.tif")
        let pixels: UInt64 = 800 * 600 + 3000 * 3000 + 3000 * 3000 + 1500 * 1500
        #expect(LayeredTIFF.layerPixels(in: file) == pixels)
    }

    @Test func parserLeavesAPlainTIFFAlone() throws {
        #expect(LayeredTIFF.layerPixels(in: write(plainTIFF(side: 3000), "plain.tif")) == nil)
    }

    @Test func parserLeavesFilesPastItsLayerLimitAlone() throws {
        // More sub-IFDs than the parser signs up for is not Photoshop: leave it unguarded (the watchdog
        // ends the helper on it) rather than guess at a shape the parser is reading wrong.
        let bytes = layeredTIFF(layers: (0..<70).map { _ in (3000, 3000) })
        #expect(LayeredTIFF.layerPixels(in: write(bytes, "many.tif")) == nil)
        #expect(LayeredTIFF.layerPixels(in: write(layeredTIFF(layers: (0..<64).map { _ in (100, 100) }), "fit.tif")) != nil)
    }

    @Test func parserRefusesGarbageDimensions() throws {
        // The sizes are 4-byte LONG tags, so a header can say 0xFFFFFFFF: garbage, and the product of two
        // such sides overflowed the parser's `Int` sum — a trap *inside* the guard built to stop traps
        // (#182, pre-push review S4). Garbage gets no estimate at all (nil: "not this file's shape"), so
        // nothing is marked from it, and a lying layer is dropped from a sum that is otherwise sound.
        let garbageMaster = write(layeredTIFF(layers: [(100, 100)], master: (width: 0xFFFFFFFF, height: 0xFFFFFFFF)),
                                 "garbage-master.tif")
        #expect(LayeredTIFF.layerPixels(in: garbageMaster) == nil)
        let garbageLayer = write(layeredTIFF(layers: [(0xFFFFFFFF, 0xFFFFFFFF), (3000, 3000)]), "garbage-layer.tif")
        let sound: UInt64 = 800 * 600 + 3000 * 3000
        #expect(LayeredTIFF.layerPixels(in: garbageLayer) == sound)
        // The sum itself is counted in `UInt64`: 64 layers of 16M×16M saturates at the ceiling, it does not trap.
        let enormous = write(layeredTIFF(layers: (0..<64).map { _ in (1 << 24, 1 << 24) }), "enormous.tif")
        #expect(LayeredTIFF.layerPixels(in: enormous) != nil)
    }

    @Test func sizesReadAsWords() {        #expect(ImageExtractor.decodeSize(192 << 20) == "192 MB")
        #expect(ImageExtractor.decodeSize(8 << 30) == "8.0 GB")
    }

    // MARK: The preflight through the production path (macOS: ImageIO side)

    #if canImport(ImageIO)
    @Test func layeredTIFFOverBudgetIsMarkedBeforeDecoding() throws {
        let file = write(layeredTIFF(), "marked.tif")
        ImageExtractor.decodeMemoryBudget = 300 << 20   // the estimate is 800×600+20.25 MP at 16 B = 323 MB
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        do {
            _ = try ImageExtractor.prepare(file, maxPixel: 1024, minSide: 256, to: folder, png: false)
            Issue.record("the preflight let a layered TIFF over the budget through")
        } catch let error as ExtractError {
            guard case .unreadable(let why) = error, why.contains("estimated") else {
                Issue.record("expected the preflight's mark, got \(error)")
                return
            }
        }
    }

    @Test func layeredTIFFUnderBudgetGoesThrough() throws {
        let file = write(layeredTIFF(), "under.tif")
        ImageExtractor.decodeMemoryBudget = 4096 << 20   // 323 MB is well under 4 GB
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        _ = try ImageExtractor.prepare(file, maxPixel: 1024, minSide: 256, to: folder, png: false)
    }

    @Test func budgetOffMeansNoPreflight() throws {
        let file = write(layeredTIFF(), "off.tif")
        ImageExtractor.decodeMemoryBudget = 0
        _ = try ImageExtractor.prepare(file, maxPixel: 1024, minSide: 256, to: folder, png: false)
    }

    // Real-RAW tests: a camera file on the box running the suite (DIGUP_TEST_RAW=… .nef). The #182
    // calibration: this Z9 NEF decodes at a 782 MB peak on this macOS (17 B/px) and the guard fires at
    // 192 B/px — marked under a 4 GB helper limit, decoded with a 16 GB one.
    static let rawFile: URL? = ProcessInfo.processInfo.environment["DIGUP_TEST_RAW"].map(URL.init(fileURLWithPath:))

    @Test(.enabled(if: rawFile != nil)) func realRAWOverTheHelperLimitIsMarked() throws {
        guard let raw = Self.rawFile else { return }
        ImageExtractor.decodeMemoryBudget = 4096 << 20
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        #expect(throws: ExtractError.self) {
            try ImageExtractor.prepare(raw, maxPixel: 1024, minSide: 256, to: folder, png: false)
        }
    }

    @Test(.enabled(if: rawFile != nil)) func realRAWWithRoomToSpareDecodes() throws {
        guard let raw = Self.rawFile else { return }
        ImageExtractor.decodeMemoryBudget = 16384 << 20
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        let prepared = try ImageExtractor.prepare(raw, maxPixel: 1024, minSide: 256, to: folder, png: false)
        #expect(prepared.width * prepared.height >= 20_000_000)   // a big camera file, decoded whole
    }
    #endif

    // MARK: The preflight on the stb side (Linux, Windows): full decode, so the header alone marks

    #if !canImport(ImageIO)
    func picture(_ side: Int, _ name: String) -> URL {
        let image = RGBImage(width: side, height: side, pixels: [UInt8](repeating: 128, count: side * side * 3))
        let url = folder.appendingPathComponent(name)
        try! image.write(to: url, png: true)
        return url
    }

    @Test func pictureOverBudgetIsMarkedBeforeDecodingHere() throws {
        let file = picture(800, "over.png")   // 800×800 at 8 B/px = 6.4 MB
        ImageExtractor.decodeMemoryBudget = 4 << 20
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        do {
            _ = try ImageExtractor.prepare(file, maxPixel: 1024, minSide: 256, to: folder, png: true)
            Issue.record("the preflight let a picture over the budget through")
        } catch let error as ExtractError {
            guard case .unreadable(let why) = error, why.contains("estimated") else {
                Issue.record("expected the preflight's mark, got \(error)")
                return
            }
        }
    }

    @Test func pictureUnderBudgetDecodesHere() throws {
        let file = picture(800, "under.png")
        ImageExtractor.decodeMemoryBudget = 64 << 20
        defer { ImageExtractor.decodeMemoryBudget = 0 }
        let prepared = try ImageExtractor.prepare(file, maxPixel: 1024, minSide: 256, to: folder, png: true)
        #expect(prepared.width == 800 && prepared.height == 800)
    }
    #endif

    // MARK: The stopped-file note, with and without a path

    @Test func notesRoundTripAndAreConsumedOnce() throws {
        let folder = self.folder.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(StoppedFile.take(from: folder) == nil)
        StoppedFile(path: "/a/b.NEF", why: "needed more than 4 GB of memory to read").write(to: StoppedFile.location(in: folder))
        let note = try #require(StoppedFile.take(from: folder))
        #expect(note.path == "/a/b.NEF")
        #expect(StoppedFile.take(from: folder) == nil)   // taken: gone
        StoppedFile(path: nil, why: "crashed on it").write(to: StoppedFile.location(in: folder))
        let head = try #require(StoppedFile.take(from: folder))
        #expect(head.path == nil && head.why.contains("crashed"))
    }

    @Test func aPathlessNoteMarksTheQueueHead() throws {
        // What `IndexService` does at startup with a note that names no file: the queue's head — the
        // file an index helper was reading when it died — is marked, and the next file becomes the head.
        let store = try IndexStore(directory: folder)
        func file(_ name: String, _ inode: UInt64) -> Candidate {
            Candidate(path: folder.appendingPathComponent(name).path, kind: .image, size: 100, mtime: 1,
                      inode: inode, device: 1)
        }
        try store.insert(file("first.NEF", 1))
        try store.insert(file("second.NEF", 2))
        let head = try #require(try store.pending(limit: 1).first)
        #expect(head.path.hasSuffix("first.NEF"))
        try store.markStopped(head.path, why: "crashed on it (a fatal signal)")
        let next = try #require(try store.pending(limit: 1).first)
        #expect(next.path.hasSuffix("second.NEF"))   // the queue moves: #182's stall broken
        let marked = try store.files(under: [folder.path]).first { $0.path.hasSuffix("first.NEF") }
        #expect(marked?.state == "failed")   // "couldn't be read": the reporter's expectation
    }

    @Test func aMarkedFileStaysMarkedUntilItChanges() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(Candidate(path: folder.appendingPathComponent("a.NEF").path, kind: .image, size: 100,
                                   mtime: 1, inode: 1, device: 1))
        #expect(try store.markStopped(folder.appendingPathComponent("a.NEF").path, why: "needed more than 4 GB"))
        let pending = try store.pending(limit: nil)
        #expect(pending.map(\.path).isEmpty)   // not queued again
    }
}

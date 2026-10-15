import Foundation
import Testing
@testable import DigUpKit

/// What indexing costs on this machine (`MeasuredCosts`), and the estimates made from it.
@Suite final class MeasuredCostsTests {
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aKindsMeasuredCostCountsOnceThereIsEnoughOfIt() {
        var measured = MeasuredCosts()
        measured.add("image", units: 10, seconds: 3)
        #expect(measured.costs.image == Costs().image)   // 10 pictures aren't enough to go by
        measured.add("image", units: 10, seconds: 3)
        #expect(measured.costs.image == 0.3)
        // Pictures went 2.5 times slower than expected: kinds not measured yet are expected at that pace.
        #expect(abs(measured.costs.docChunk - Costs().docChunk * 2.5) < 1e-9)
    }

    @Test func aSlowerMacScalesTheFixedCostsUntilItsOwnAreMeasured() {
        var measured = MeasuredCosts()
        measured.speed = MeasuredCosts.Speed(embedding: 3, ocr: 2)
        #expect(measured.costs.image == Costs().image * 3)
        #expect(measured.costs.screenshot == Costs().screenshot * 3)   // the slower of the two sets the pace
        measured.speed = MeasuredCosts.Speed(embedding: 0.001, ocr: 1)
        #expect(measured.costs.docChunk == Costs().docChunk * 0.25)   // a check that's off by far is held in
        measured.speed = MeasuredCosts.Speed(embedding: 3, ocr: 2)
        measured.add("image", units: 40, seconds: 8)
        #expect(measured.costs.image == 0.2)                         // what it measured wins
    }

    /// An RTX 4050 laptop's check, timed at a bad moment, took it for 30 times slower than the M4 Pro; its first index
    /// then went about as fast as the M4 Pro's (142 screenshots in 47 s, 189 PDF pages in 63 s, 54 minutes of video in
    /// 96 s). Its pictures, not measured yet, follow the kinds that were.
    @Test func aCheckTimedAtABadMomentIsPutRightByIndexing() throws {
        var measured = MeasuredCosts()
        let kinds = ["image", "screenshot", "pdfPage", "docChunk", "audioSecond", "videoSecond", "codeStretch"]
        measured.speed = MeasuredCosts.Speed(embedding: 1, ocr: 1, device: "gpu")
        measured.speed?.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0, 30) })
        #expect(abs(measured.costs.image - Costs().image * 30) < 1e-9)
        #expect(measured.pace == nil)
        measured.add("screenshot", units: 142, seconds: 47)
        measured.add("pdfPage", units: 189, seconds: 63)
        measured.add("videoSecond", units: 3240, seconds: 96)
        let pace = try #require(measured.pace)
        #expect(pace > 0.03 && pace < 0.1)   // the check was 10 to 30 times off
        #expect(measured.costs.image > 0.1 && measured.costs.image < 0.4)
        #expect(measured.costs.screenshot == 47.0 / 142)
    }

    @Test func recentWorkCountsMost() {
        var measured = MeasuredCosts()
        measured.add("image", units: 300, seconds: 300)   // 1 s a picture (a hot Mac, say)
        measured.add("image", units: 20, seconds: 2)      // then 0.1 s: past ten times enough, the past is halved
        #expect(measured.tallies["image"] == MeasuredCosts.Tally(seconds: 152, units: 170))
    }

    @Test func indexingKeepsWhatItCostsBesideTheIndex() throws {
        let notes = folder.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for name in ["kyoto", "budget", "garden"] {
            try "Notes about \(name): what was planned, what happened, and what to do next time.".write(
                to: notes.appendingPathComponent("\(name).txt"), atomically: false, encoding: .utf8)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        indexer.costsFolder = folder
        _ = try indexer.sync([notes])
        _ = try indexer.run()
        // Three notes of one chunk each; the first job started the model, which isn't what a chunk costs.
        #expect(MeasuredCosts.load(from: folder).tallies["docChunk"]?.units == 2)
        MeasuredCosts.setSpeed(MeasuredCosts.Speed(embedding: 1.5, ocr: 1), in: folder)
        let saved = MeasuredCosts.load(from: folder)
        #expect(saved.speed == MeasuredCosts.Speed(embedding: 1.5, ocr: 1))
        #expect(saved.tallies["docChunk"]?.units == 2)   // the speed joined what was there
        MeasuredCosts.setSpeed(MeasuredCosts.Speed(embedding: 1, ocr: 1, kinds: ["image": 2], device: "cpu"), in: folder,
                               forgetTallies: true)
        #expect(MeasuredCosts.load(from: folder).tallies.isEmpty)   // measured on the other device
    }
}

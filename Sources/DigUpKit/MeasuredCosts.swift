import Foundation

/// What indexing costs on this Mac, from the indexing itself: seconds and units (pictures, PDF pages, document chunks,
/// seconds of audio or video, stretches of code) summed kind by kind as jobs finish, in `costs.json` beside the index.
/// Estimates use a kind's measured cost once it has enough of them. Until then, `Costs`' fixed numbers, measured on an
/// M4 Pro, stand in, scaled by `speed` (how this Mac compares, from a second of work that needs no model).
public struct MeasuredCosts: Codable, Sendable, Equatable {
    public struct Tally: Codable, Sendable, Equatable {
        public var seconds = 0.0
        public var units = 0.0

        public init(seconds: Double = 0, units: Double = 0) {
            self.seconds = seconds
            self.units = units
        }
    }

    /// How this Mac compares to the M4 Pro behind `Costs`: 1 is as fast, 2 takes twice as long. `embedding` for the
    /// model's work (matrix multiplies on the GPU), `ocr` for Vision's text recognition. `kinds`, when there: each of
    /// `Costs`' fields as it compares, measured with the model itself (Linux and Windows, `digup speed --model`), in
    /// place of the other two. `device`, where there's a GPU: "gpu" or "cpu", whichever ran the model faster here (a
    /// weak integrated GPU can be slower than the processor it sits in); the helpers then run on it. `checks`: how many
    /// times the model was timed here; `doubtful`: the last time was at a bad moment (its best try wasn't seen twice),
    /// so it's timed again at the next start.
    public struct Speed: Codable, Sendable, Equatable {
        public var embedding: Double
        public var ocr: Double
        public var kinds: [String: Double]?
        public var device: String?
        public var checks: Int?
        public var doubtful: Bool?

        public init(embedding: Double, ocr: Double, kinds: [String: Double]? = nil, device: String? = nil) {
            self.embedding = embedding
            self.ocr = ocr
            self.kinds = kinds
            self.device = device
        }
    }

    /// By the name of the `Costs` field they measure ("image", "pdfPage", …).
    public var tallies: [String: Tally] = [:]
    public var speed: Speed?

    public init() {}

    /// Units a kind needs before its measured cost is trusted: a few dozen files, or minutes of media.
    static let enough: [String: Double] = [
        "image": 20, "screenshot": 20, "pdfPage": 30, "docChunk": 30, "audioSecond": 600, "videoSecond": 600,
        "codeStretch": 100,
    ]

    /// A job that took `seconds` for `units` of `name`. Recent work counts most: past ten times what's enough, what
    /// came before is halved.
    public mutating func add(_ name: String, units: Double, seconds: Double) {
        guard units > 0, seconds > 0 else { return }
        var tally = tallies[name, default: Tally()]
        if tally.units > 10 * (Self.enough[name] ?? 20) {
            tally.seconds /= 2
            tally.units /= 2
        }
        tally.seconds += seconds
        tally.units += units
        tallies[name] = tally
    }

    /// `Costs`' fields by the names tallies go by.
    static var fields: [(name: String, cost: WritableKeyPath<Costs, Double>)] {
        [("image", \.image), ("screenshot", \.screenshot), ("pdfPage", \.pdfPage), ("docChunk", \.docChunk),
         ("audioSecond", \.audioSecond), ("videoSecond", \.videoSecond), ("codeStretch", \.codeStretch)]
    }

    /// The costs to estimate with: measured ones where there are enough; else the fixed ones as fast as `speed` says, at
    /// the `pace` indexing has kept here on the kinds it has measured.
    public var costs: Costs {
        var costs = expected
        let pace = min(50, max(0.02, self.pace ?? 1))
        for field in Self.fields {
            if let tally = tallies[field.name], tally.units >= Self.enough[field.name] ?? .infinity {
                costs[keyPath: field.cost] = tally.seconds / tally.units
            } else {
                costs[keyPath: field.cost] *= pace
            }
        }
        return costs
    }

    /// How indexing here compares with what was expected of it: its measured cost over the expected one, over the kinds
    /// with enough measured (weighted by their seconds). Nil before any kind has enough. A speed check timed at a bad
    /// moment took one PC (an RTX 4050 laptop) for 30 times slower than its indexing went: this puts its other kinds
    /// right too, as indexing measures some of them.
    public var pace: Double? {
        let expected = expected
        var sum = 0.0, weights = 0.0
        for field in Self.fields {
            guard let tally = tallies[field.name], tally.units >= Self.enough[field.name] ?? .infinity,
                  tally.seconds > 0, expected[keyPath: field.cost] > 0 else { continue }
            sum += tally.seconds * log(tally.seconds / tally.units / expected[keyPath: field.cost])
            weights += tally.seconds
        }
        return weights > 0 ? exp(sum / weights) : nil
    }

    /// The fixed costs as fast as `speed` says.
    var expected: Costs {
        var costs = Costs()
        if let kinds = speed?.kinds {
            // A PC's processor can be fifty times slower than the M4 Pro's GPU.
            for field in Self.fields {
                costs[keyPath: field.cost] *= min(500, max(0.1, kinds[field.name] ?? 1))
            }
        } else if let speed {
            let embedding = min(10, max(0.25, speed.embedding)), ocr = min(10, max(0.25, speed.ocr))
            costs.image *= embedding
            costs.screenshot *= max(embedding, ocr)   // OCR runs beside the model and usually sets the pace
            costs.pdfPage *= embedding
            costs.docChunk *= embedding
            costs.audioSecond *= embedding
            costs.videoSecond *= embedding
            costs.codeStretch *= embedding
        }
        return costs
    }

    public static func file(in folder: URL) -> URL {
        folder.appendingPathComponent("costs.json")
    }

    /// What's saved in `folder`, or nothing measured yet.
    public static func load(from folder: URL) -> MeasuredCosts {
        (try? Data(contentsOf: file(in: folder))).flatMap { try? JSONDecoder().decode(MeasuredCosts.self, from: $0) }
            ?? MeasuredCosts()
    }

    public func save(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).writeReplacing(Self.file(in: folder))
    }

    private static let lock = NSLock()

    /// Saves this machine's speed (`Speed.measure`) beside what's measured in `folder`, and forgets what indexing
    /// measured if asked (the model moved from the GPU to the processor, or back).
    public static func setSpeed(_ speed: Speed, in folder: URL, forgetTallies: Bool = false) {
        lock.withLock {
            var saved = load(from: folder)
            saved.speed = speed
            if forgetTallies { saved.tallies = [:] }
            saved.save(to: folder)
        }
    }

    /// Adds `new` to what's saved in `folder` (the main index and the code index each add their own kinds).
    static func merge(_ new: MeasuredCosts, into folder: URL) {
        lock.withLock {
            var saved = load(from: folder)
            for (name, tally) in new.tallies { saved.add(name, units: tally.units, seconds: tally.seconds) }
            saved.save(to: folder)
        }
    }
}

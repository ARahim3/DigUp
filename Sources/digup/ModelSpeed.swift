import DigUpKit
import Foundation

/// `digup speed --model`: how fast this machine runs the model, timed on a made-up text, picture and sound next to the
/// M4 Pro behind the fixed costs (`Costs`). Linux and Windows have no model-free check (the Mac's is Metal's), and a
/// PC's processor can run the model fifty times slower than the M4 Pro: their estimates go by this until indexing has
/// measured enough itself (`MeasuredCosts`). Kept in costs.json beside the index, so it runs once.
enum ModelSpeed {
    /// Seconds for each input on the M4 Pro (Metal, Q8_0), 2026-10-13: the best of three after a first run, the same in
    /// two runs.
    static let baseline = Times(text: 0.026, picture: 0.123, screen: 0.265, frame: 0.067, sound: 0.220)

    /// One embedding of each input: a page of text as a document, a picture at a photo's budget (140 tokens), a
    /// screenshot's (280), a video frame's (70), and a 30 s window of sound. A check times the text, the picture and
    /// the sound; a screenshot and a frame go as the picture does (measured: within 7% of it on an i5-8350U, 20% on
    /// ARM), which spares a slow PC half the check.
    struct Times {
        var text, picture, screen, frame, sound: Double

        init(text: Double, picture: Double, screen: Double, frame: Double, sound: Double) {
            (self.text, self.picture, self.screen, self.frame, self.sound) = (text, picture, screen, frame, sound)
        }

        init(text: Double, picture: Double, sound: Double) {
            let ratio = picture / ModelSpeed.baseline.picture
            self.init(text: text, picture: picture, screen: ModelSpeed.baseline.screen * ratio,
                      frame: ModelSpeed.baseline.frame * ratio, sound: sound)
        }

        var fields: [String: Double] {
            ["text": text, "picture": picture, "screen": screen, "frame": frame, "sound": sound]
        }

        /// From `fields` (another process's measurement).
        init?(fields: [String: Double]) {
            guard let text = fields["text"], let picture = fields["picture"], let screen = fields["screen"],
                  let frame = fields["frame"], let sound = fields["sound"] else { return nil }
            self.init(text: text, picture: picture, screen: screen, frame: frame, sound: sound)
        }
    }

    /// What a check found: each input's best time, the vectors it made ("text", "picture", "sound": for comparing the
    /// GPU's with the processor's), each try's seconds, whether its best was seen twice, and the processors' worth of
    /// other programs' work while it timed (`SystemLoad`).
    struct Measurement {
        var times: Times
        var vectors: [String: [Float]]
        var tries: [Double]
        var steady: Bool
        var others: Double

        var total: Double { times.text + times.picture + times.sound }
    }

    /// Two tries within this of each other agree.
    static let agree = 1.15

    /// A first run of each input (the backend loads, a GPU compiles its kernels), then tries of all three, each
    /// input's best kept: at most `tries`, and fewer once the best try is matched by another (a busy moment makes a
    /// try slower, never faster), or once two tries came out clearly slower than `rival`'s total (the other device's,
    /// which is then kept whatever these times are).
    static func measure(_ model: any Embedder, tries: Int = 3, rival: Double? = nil) throws -> Measurement {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("picture.bmp"), sound = folder.appendingPathComponent("sound.wav")
        try bitmap(width: 960, height: 720).write(to: picture)
        try wave(seconds: 30).write(to: sound)
        let text = Prompts.document(title: "notes.txt", text: page)

        func embedded(_ result: [Embedding]) throws -> [Float]? {
            if let problem = result.first?.error { throw CLIError("the speed check's input failed: \(problem)") }
            return result.first?.vector
        }
        var vectors: [String: [Float]] = [:]
        vectors["text"] = try model.embedTexts([text]).first
        vectors["picture"] = try embedded(model.embedImages([picture.path], budget: 140))
        vectors["sound"] = try embedded(model.embedAudio([sound.path]))

        func timed(_ work: () throws -> Void) throws -> Double {
            let started = Date()
            try work()
            return Date().timeIntervalSince(started)
        }
        var best = (text: Double.infinity, picture: Double.infinity, sound: Double.infinity)
        var totals: [Double] = [], others: [Double] = []
        func matched() -> Bool {
            guard let fastest = totals.min() else { return false }
            return totals.filter { $0 <= fastest * agree }.count >= 2
        }
        for _ in 0..<max(1, tries) {
            let before = SystemLoad.sample()
            let seconds = (text: try timed { _ = try model.embedTexts([text]) },
                           picture: try timed { _ = try embedded(model.embedImages([picture.path], budget: 140)) },
                           sound: try timed { _ = try embedded(model.embedAudio([sound.path])) })
            if let before, let after = SystemLoad.sample() { others.append(SystemLoad.others(from: before, to: after)) }
            best = (min(best.text, seconds.text), min(best.picture, seconds.picture), min(best.sound, seconds.sound))
            totals.append(seconds.text + seconds.picture + seconds.sound)
            if matched() { break }
            if let rival, totals.filter({ $0 > rival * 1.3 }).count >= 2 { break }
        }
        return Measurement(times: Times(text: best.text, picture: best.picture, sound: best.sound), vectors: vectors,
                           tries: totals, steady: matched(),
                           others: others.isEmpty ? 0 : others.reduce(0, +) / Double(others.count))
    }

    /// How far two runs' vectors agree: the least cosine over the inputs both made (0 when one is missing).
    static func agreement(_ one: [String: [Float]], _ other: [String: [Float]]) -> Double {
        ["text", "picture", "sound"].map { name -> Double in
            guard let a = one[name], let b = other[name], a.count == b.count, !a.isEmpty else { return 0 }
            let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let norms = sqrt(a.reduce(0.0) { $0 + Double($1 * $1) }) * sqrt(b.reduce(0.0) { $0 + Double($1 * $1) })
            return norms > 0 ? dot / norms : 0
        }.min() ?? 0
    }

    /// Each of `Costs`' fields as this machine compares. A cost's share that is the model's work goes as this machine ran
    /// the model (pages of text, documents and code as the text did, pictures as the picture, sound as the sound); the
    /// rest (reading files, decoding) stays as on the M4 Pro, since a slow processor slows it far less. A screenshot
    /// here is a picture at the screenshot's budget with no OCR (OCR sets the M4 Pro's pace; Linux and Windows have
    /// none yet). A second of video is its keyframes' share and its soundtrack's.
    static func factors(_ times: Times) -> [String: Double] {
        let costs = Costs(), base = baseline
        func scaled(_ cost: Double, model: Double, here: Double) -> Double {
            let part = min(cost, model)
            return (cost - part + part * here / model) / cost
        }
        let window = 25.0   // seconds of sound a 30 s window stands for (a window every 25 s)
        let soundtrack = costs.audioSecond, frames = costs.videoSecond - soundtrack
        let video = frames * times.frame / base.frame
            + soundtrack * scaled(soundtrack, model: base.sound / window, here: times.sound / window)
        return [
            "image": scaled(costs.image, model: base.picture, here: times.picture),
            "screenshot": (max(0, costs.image - base.picture) + times.screen) / costs.screenshot,
            "pdfPage": scaled(costs.pdfPage, model: base.text, here: times.text),
            "docChunk": scaled(costs.docChunk, model: base.text, here: times.text),
            "codeStretch": scaled(costs.codeStretch, model: base.text, here: times.text),
            "audioSecond": scaled(costs.audioSecond, model: base.sound / window, here: times.sound / window),
            "videoSecond": video / costs.videoSecond,
        ]
    }

    /// About a page of plain prose (1,600 characters), as a document chunk is.
    static let page = String(repeating: "The meeting moved to Thursday because the room was booked. Priya will send "
        + "the notes and the budget draft; the receipts from the hardware store are in the shared folder. ", count: 9)

    /// A 24-bit BMP of soft gradients and stripes (any picture fills its budget's tokens the same).
    static func bitmap(width: Int, height: Int) -> Data {
        let row = (width * 3 + 3) / 4 * 4
        var data = Data()
        func put(_ value: UInt32, _ bytes: Int) { for index in 0..<bytes { data.append(UInt8((value >> (8 * index)) & 0xFF)) } }
        data.append(contentsOf: Array("BM".utf8))
        put(UInt32(54 + row * height), 4)
        put(0, 4)
        put(54, 4)
        put(40, 4)
        put(UInt32(width), 4)
        put(UInt32(height), 4)
        put(1, 2)
        put(24, 2)
        put(0, 4)
        put(UInt32(row * height), 4)
        put(2835, 4)
        put(2835, 4)
        put(0, 4)
        put(0, 4)
        var pixels = [UInt8](repeating: 0, count: row * height)
        for y in 0..<height {
            for x in 0..<width {
                let at = y * row + x * 3
                pixels[at] = UInt8((x * 255) / width)
                pixels[at + 1] = UInt8((y * 255) / height)
                pixels[at + 2] = ((x / 40 + y / 40) % 2 == 0) ? 200 : 60
            }
        }
        data.append(contentsOf: pixels)
        return data
    }

    /// A 16 kHz mono 16-bit WAV of rising and falling tones with a little noise.
    static func wave(seconds: Int) -> Data {
        let rate = 16000, count = rate * seconds
        var data = Data()
        func put(_ value: UInt32, _ bytes: Int) { for index in 0..<bytes { data.append(UInt8((value >> (8 * index)) & 0xFF)) } }
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + count * 2), 4)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(16, 4)
        put(1, 2)
        put(1, 2)
        put(UInt32(rate), 4)
        put(UInt32(rate * 2), 4)
        put(2, 2)
        put(16, 2)
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(count * 2), 4)
        var samples = [UInt8](repeating: 0, count: count * 2)
        var noise: UInt32 = 12345
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let pitch = 220 + 180 * sin(time * 0.7)
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let value = 0.3 * sin(2 * .pi * pitch * time) + 0.05 * (Double(noise >> 16) / 65536 - 0.5)
            let sample = UInt16(bitPattern: Int16(max(-1, min(1, value)) * 32000))
            samples[index * 2] = UInt8(sample & 0xFF)
            samples[index * 2 + 1] = UInt8(sample >> 8)
        }
        data.append(contentsOf: samples)
        return data
    }
}

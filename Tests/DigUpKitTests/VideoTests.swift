import Foundation
import Testing
@testable import DigUpKit

/// Videos/shots.ts: an MPEG-TS of three 4-second shots on black, red on the left half, green on the top half, blue on
/// the top left quarter (flat colors would all have one average hash), with a keyframe only where each starts. A
/// transport stream has no index, so a seek into one lands between keyframes. Made with
/// `ffmpeg -f lavfi -i "color=black:s=320x192:r=5:d=4,drawbox=w=160:h=192:color=0xFF0000:t=fill"
/// -f lavfi -i "color=black:s=320x192:r=5:d=4,drawbox=w=320:h=96:color=0x00FF00:t=fill"
/// -f lavfi -i "color=black:s=320x192:r=5:d=4,drawbox=w=160:h=96:color=0x0000FF:t=fill"
/// -filter_complex "[0][1][2]concat=n=3:v=1:a=0,format=yuv420p" -c:v libx264 -preset veryslow
/// -x264-params keyint=20:min-keyint=20:scenecut=0:bframes=0 -f mpegts -pat_period 4 -sdt_period 4 shots.ts`.
@Suite final class VideoTests {
    static let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Videos/shots.ts")
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A frame's time is when it's shown: each shot once, in order, each at a time inside its shot.
    @Test func framesAreTimedWhenShown() async throws {
        let frames = try await VideoExtractor.keyframes(of: Self.shots, every: 3, maxPixel: 320, to: folder).frames
        let colors = try frames.map { try ImageTests.decode($0.path).quadrants[0] }
        #expect(colors == ["R", "G", "B"])
        for (frame, color) in zip(frames, colors) {
            guard let shot = ["R", "G", "B"].firstIndex(of: color) else { continue }
            #expect(Double(shot) * 4 <= frame.start && frame.start < Double(shot + 1) * 4, "\(color) at \(frame.start) s")
        }
    }

    @Test(arguments: [(1.0, "R"), (5.0, "G"), (6.5, "G"), (9.0, "B"), (11.5, "B")])
    func previewShowsTheMoment(_ seconds: Double, _ color: String) async throws {
        let out = folder.appendingPathComponent("\(seconds).jpg")
        try await VideoExtractor.frame(at: seconds, of: Self.shots, pixels: 320, to: out)
        #expect(try ImageTests.decode(out.path).quadrants[0] == color)
    }
}

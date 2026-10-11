#if os(Linux)
import Foundation

// Linux stubs with the same API so the indexer compiles and runs.
// Audio and video report why they were left out until the ffmpeg backend
// lands. See MediaExtractors.swift (macOS implementations).

enum AudioExtractor {
    static let sampleRate = 16_000.0

    static func windows(of url: URL, window: Double, hop: Double, minimum: Double = 2, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        throw ExtractError.unreadable("audio needs a Linux audio backend (ffmpeg) — not ported yet")
    }
}

enum VideoExtractor {
    static func keyframes(of url: URL, every interval: Double, maxPixel: Int, maxFrames: Int = 1200, to folder: URL)
        async throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        throw ExtractError.unreadable("video needs a Linux video backend (ffmpeg) — not ported yet")
    }
}

enum MediaInfo {
    static func duration(of url: URL) -> Double? { nil }
}
#endif

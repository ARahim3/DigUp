import Foundation

// Portable bits of the media layer (used on every OS). The AVFoundation
// decoders live in MediaExtractors.swift (macOS); the Linux stubs that throw
// until the ffmpeg backend lands live in MediaExtractors_Linux.swift.

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs async extractor work from the synchronous indexer (one thread on purpose: simple and easy to reason about).
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

/// A stretch of audio written to a temporary WAV for the model, or a video frame written to a JPEG.
struct MediaPiece: Sendable {
    let path: String
    let start: Double
    var end: Double
}

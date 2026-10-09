import DigUpKit
import Foundation

/// How much there is to index in a folder and how long the first pass takes, from `digup estimate --json` (run as
/// the helper: it crawls, asks Spotlight, and opens PDF and media headers, none of which should weigh on the app).
nonisolated struct FolderEstimate: Identifiable, Sendable {
    let folder: String
    let seconds: Double
    let files: [FileKind: Int]
    let pdfPages: Int
    let audioSeconds: Double
    let videoSeconds: Double
    /// Long PDFs and documents get their first pages in the first pass (`seconds`), and the rest once everything else
    /// is in: this long.
    var laterSeconds = 0.0
    var longFiles = 0
    /// For code search: about how big its part of the code index gets on disk.
    var bytes = 0.0
    /// False when macOS doesn't let DigUp read the folder (it was denied in the privacy prompt).
    let readable: Bool
    /// The estimate never came (the helper stopped early).
    var failed = false
    /// One level down, the subfolders with something to index (their own seconds and files), biggest first.
    var subfolders: [FolderEstimate] = []
    var id: String { folder }
}

enum Estimates {
    /// Estimates each folder in turn, leaving out what's skipped, calling `update` (on the main actor) as each one
    /// arrives. `code`: what code search would read there (`digup estimate --code`).
    static func run(_ folders: [URL], excluded: [URL] = [], types: [String] = [], code: Bool = false,
                    update: @escaping @MainActor @Sendable (FolderEstimate) -> Void) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup")
        var arguments = ["estimate", "--json"]
        if code { arguments.append("--code") }
        for folder in excluded { arguments += ["--exclude", folder.path] }
        if !types.isEmpty { arguments += ["--exclude-ext", types.joined(separator: ",")] }
        process.arguments = arguments + folders.map(\.path)
        process.qualityOfService = .userInitiated
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = LineBuffer()
        let reported = ReportedFolders()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            for line in lines.append(data) {
                guard let estimate = decode(line) else { continue }
                reported.insert(estimate.folder)
                DispatchQueue.main.async { MainActor.assumeIsolated { update(estimate) } }
            }
        }
        // If the helper stops early, the folders it never got to mustn't spin forever.
        let paths = folders.map(\.path)
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {   // after the last lines are read
                let left = paths.filter { !reported.contains($0) }
                guard !left.isEmpty else { return }
                log("estimate: the helper stopped (\(status)) before \(left.count) folders")
                MainActor.assumeIsolated {
                    for folder in left {
                        update(FolderEstimate(folder: folder, seconds: 0, files: [:], pdfPages: 0, audioSeconds: 0,
                                              videoSeconds: 0, readable: true, failed: true))
                    }
                }
            }
        }
        do {
            try process.run()
        } catch {
            log("estimate: can't run the helper: \(error)")
        }
    }

    private nonisolated static func decode(_ line: Data) -> FolderEstimate? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return decode(object)
    }

    private nonisolated static func decode(_ object: [String: Any]) -> FolderEstimate? {
        guard let folder = object["folder"] as? String else { return nil }
        var files: [FileKind: Int] = [:]
        for (key, value) in object["files"] as? [String: Int] ?? [:] {
            if let kind = FileKind(rawValue: key) { files[kind] = value }
        }
        return FolderEstimate(folder: folder, seconds: object["seconds"] as? Double ?? 0, files: files,
                              pdfPages: object["pdf_pages"] as? Int ?? 0,
                              audioSeconds: object["audio_seconds"] as? Double ?? 0,
                              videoSeconds: object["video_seconds"] as? Double ?? 0,
                              laterSeconds: object["later_seconds"] as? Double ?? 0,
                              longFiles: object["long_files"] as? Int ?? 0,
                              bytes: object["bytes"] as? Double ?? 0,
                              readable: object["readable"] as? Bool ?? true,
                              subfolders: (object["subfolders"] as? [[String: Any]] ?? []).compactMap(decode))
    }
}

/// The folders an estimate run has reported, from the pipe's queue.
nonisolated final class ReportedFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var folders = Set<String>()

    func insert(_ folder: String) { lock.withLock { _ = folders.insert(folder) } }
    func contains(_ folder: String) -> Bool { lock.withLock { folders.contains(folder) } }
}

/// Splits a byte stream into lines (a pipe delivers whatever is ready, not whole lines).
nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}

/// "≈ 8 s", "≈ 2 min", or "< 1 s" for a few short files.
nonisolated func approximately(_ seconds: Double) -> String {
    seconds < 0.5 ? "< 1 s" : "≈ \(roughDuration(seconds))"
}

/// "8 s", "2 min", "1.5 h": the precision an estimate deserves.
nonisolated func roughDuration(_ seconds: Double) -> String {
    switch seconds {
    case ..<90: "\(Int(seconds.rounded())) s"
    case ..<5400: "\(Int((seconds / 60).rounded())) min"
    default: String(format: "%.1f h", seconds / 3600)
    }
}

/// "40 MB", "1.2 GB": the precision an estimate of an index's size deserves.
nonisolated func roughBytes(_ bytes: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : bytes < 1_000_000_000 ? [.useMB] : [.useGB]
    return formatter.string(fromByteCount: Int64(bytes < 10_000_000 ? bytes : (bytes / 1_000_000).rounded() * 1_000_000))
}

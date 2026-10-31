// Reading a file for C libraries through Foundation rather than by path (Linux, Windows): miniz and PDFium open paths
// with fopen and CreateFileA, which on Windows read the ANSI code page, so a Bengali or Arabic file name wouldn't open.
// They read through `read(at:into:count:)` instead, a block at a time.
#if !canImport(PDFKit)
import Foundation

final class FileReader {
    let size: UInt64
    private let handle: FileHandle

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Copies up to `count` bytes from `offset` into `buffer`; how many it copied.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        // A malformed archive can ask for an unsigned offset outside the file (including a wrapped negative
        // offset). Foundation on Windows traps converting offsets past Int64.max instead of throwing.
        guard count > 0, offset < size, offset <= UInt64(Int64.max) else { return 0 }
        let available = Int(min(UInt64(count), size - offset))
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: available) else { return 0 }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return data.count
    }

    /// Itself as a C callback's context (it must outlive the C library's use of it).
    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static func from(_ opaque: UnsafeMutableRawPointer?) -> FileReader {
        Unmanaged<FileReader>.fromOpaque(opaque!).takeUnretainedValue()
    }
}
#endif

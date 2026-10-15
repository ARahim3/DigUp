// Zip files on macOS, for the spreadsheets and presentations the Cocoa text system doesn't read (`OfficeText`): the
// central directory read here, deflated entries inflated by the Compression framework. Platform/Portable has the same
// name over miniz.
#if canImport(AppKit)
import Compression
import Foundation

final class ZipArchive {
    private struct Entry {
        let method: Int
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let file: Data
    private var entries: [String: Entry] = [:]

    init(_ url: URL) throws {
        file = try Data(contentsOf: url, options: .alwaysMapped)
        // The end of the central directory: the last 22 bytes, unless a comment (up to 64 KB) follows it.
        var end = file.count - 22
        while end >= max(0, file.count - 22 - 0xFFFF), (try? number(end, 4)) != 0x0605_4B50 { end -= 1 }
        guard end >= 0, end >= max(0, file.count - 22 - 0xFFFF) else { throw ExtractError.unreadable("not a zip file") }
        let count = try number(end + 10, 2)
        var offset = try number(end + 16, 4)
        guard offset != 0xFFFF_FFFF else { throw ExtractError.unreadable("zip64 files aren't read") }
        for _ in 0..<count {
            guard try number(offset, 4) == 0x0201_4B50 else { throw ExtractError.unreadable("damaged zip file") }
            let nameLength = try number(offset + 28, 2)
            let skip = try number(offset + 30, 2) + number(offset + 32, 2)   // extra field, comment
            guard offset + 46 + nameLength <= file.count else { throw ExtractError.unreadable("damaged zip file") }
            let name = String(decoding: file[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if try number(offset + 8, 2) & 1 == 0 {   // encrypted entries are left out
                entries[name] = Entry(method: try number(offset + 10, 2), compressedSize: try number(offset + 20, 4),
                                      size: try number(offset + 24, 4), headerOffset: try number(offset + 42, 4))
            }
            offset += 46 + nameLength + skip
        }
    }

    /// The entry's bytes, or nil when the zip has no such entry.
    func data(_ name: String) throws -> [UInt8]? {
        guard let entry = entries[name] else { return nil }
        guard entry.size <= Self.maxEntrySize else { throw ExtractError.unreadable("\(name) is too large") }
        let header = entry.headerOffset
        guard try number(header, 4) == 0x0403_4B50 else { throw ExtractError.unreadable("damaged zip file") }
        let start = header + 30 + (try number(header + 26, 2)) + (try number(header + 28, 2))
        guard start + entry.compressedSize <= file.count else { throw ExtractError.unreadable("damaged zip file") }
        let stored = file[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Array(stored)
        case 8:
            guard entry.size > 0 else { return [] }
            var out = [UInt8](repeating: 0, count: entry.size)
            // COMPRESSION_ZLIB is raw deflate, as zip stores it.
            let written = stored.withUnsafeBytes { source in
                out.withUnsafeMutableBytes { target in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              source.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ExtractError.unreadable("can't inflate \(name)") }
            return out
        default:
            throw ExtractError.unreadable("unknown compression in \(name)")
        }
    }

    /// A little-endian number of `size` bytes at `offset`.
    private func number(_ offset: Int, _ size: Int) throws -> Int {
        guard offset >= 0, offset + size <= file.count else { throw ExtractError.unreadable("damaged zip file") }
        var value = 0
        for index in (offset..<(offset + size)).reversed() { value = value << 8 | Int(file[file.startIndex + index]) }
        return value
    }
}
#endif

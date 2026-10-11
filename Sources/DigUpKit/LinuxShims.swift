#if os(Linux)
import Foundation

// Linux has no autorelease pool: URL resource values and file handles are
// freed by ARC alone, so this just runs the body. Same call shapes as Darwin
// (`autoreleasepool(invoking:)` and trailing-closure form).
@inline(__always)
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T {
    try body()
}
#endif

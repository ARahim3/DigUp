import Foundation

// The stdlib's `Float16` exists only on ARM64 macOS. On x86_64 the same IEEE 754 binary16 lives here instead:
// same 2-byte layout, same round-to-nearest-even conversion, so vector blobs written by this build load on
// Apple Silicon and the other way around (the index stores 768 × binary16 per segment).
#if arch(x86_64)

/// IEEE 754 binary16, matching the ARM64 stdlib's `Float16` in layout and rounding.
@frozen
public struct Float16: Hashable, Sendable {
    public var bitPattern: UInt16 = 0

    /// Rounds to nearest, ties to even, like the stdlib's `Float16(Float)` on ARM64.
    public init(_ value: Float) {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int32((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7F_FFFF

        var half: UInt16
        if exponent >= 0x1F {
            // Overflow rounds to infinity; a NaN stays a (quiet) NaN. The sign joins at the end.
            half = (bits >> 23) & 0xFF == 0xFF && mantissa != 0 ? 0x7E00 : 0x7C00
        } else if exponent <= 0 {
            // Zero, a float32 subnormal (all round to ±0), or a binary16 subnormal through rounding.
            if exponent < -10 {
                half = 0   // below half the smallest subnormal: no shift needed, and 1 << huge would trap
            } else {
                let m = mantissa | 0x80_0000                 // the implicit bit
                let shift = UInt32(14 - exponent)
                var sub = m >> shift
                let rem = m & ((1 << shift) - 1)
                let halfway = 1 << (shift - 1)
                if rem > halfway || (rem == halfway && sub & 1 == 1) { sub += 1 }
                half = UInt16(sub)
            }
        } else {
            var expMant = UInt32(exponent) << 10 | mantissa >> 13
            let rem = mantissa & 0x1FFF
            if rem > 0x1000 || (rem == 0x1000 && expMant & 1 == 1) { expMant += 1 }
            half = UInt16(expMant)
        }
        bitPattern = sign | half
    }

    /// Exact: every binary16 value is representable as a float32.
    public var value: Float {
        let bits = UInt32(bitPattern)
        let sign = (bits & 0x8000) << 16
        let exponent = (bits >> 10) & 0x1F
        let fraction = bits & 0x3FF
        var float: UInt32
        if exponent == 0 {
            if fraction == 0 {
                float = sign                                        // ±0
            } else {
                var shift = UInt32(0)
                var normalized = fraction
                while normalized & 0x400 == 0 { normalized <<= 1; shift += 1 }
                float = sign | (112 - shift + 1) << 23 | (normalized & 0x3FF) << 13
            }
        } else if exponent == 0x1F {
            float = sign | 0x7F80_0000 | (fraction != 0 ? 0x40_0000 | fraction << 13 : 0)   // ±Inf / NaN
        } else {
            float = sign | (exponent - 15 + 127) << 23 | fraction << 13
        }
        return Float(bitPattern: float)
    }
}

extension Float {
    /// The stdlib has this on ARM64 only; the shim needs it for the same call sites.
    public init(_ half: Float16) { self = half.value }
}

#endif

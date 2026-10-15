// Makes the test pictures in Tests/DigUpKitTests/Pictures: a 400×240 pattern of four colored quadrants (top left red,
// top right green, bottom left blue, bottom right yellow) stored with EXIF orientation 6 (shown turned 90° clockwise)
// and a DateTimeOriginal, in the formats stb can't read (HEIC, TIFF, WebP) and as a JPEG, plus an upright AVIF (ImageIO
// writes AVIF without orientation). macOS only (ImageIO writes them; cwebp, from Homebrew's webp, makes the WebP from
// the JPEG with its EXIF):
//   swift scripts/testbed/make_test_pictures.swift Tests/DigUpKitTests/Pictures
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 400, height = 240
var pixels = [UInt8](repeating: 255, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let left = x < width / 2, top = y < height / 2
        let rgb: (UInt8, UInt8, UInt8) = top ? (left ? (255, 0, 0) : (0, 255, 0)) : (left ? (0, 0, 255) : (255, 255, 0))
        let i = (y * width + x) * 4
        (pixels[i], pixels[i + 1], pixels[i + 2]) = rgb
    }
}
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let pattern = context.makeImage()!

func write(_ name: String, _ type: String, _ extra: [CFString: Any] = [:]) {
    let url = folder.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
    var properties: [CFString: Any] = [
        kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:17 10:30:00"],
    ]
    properties.merge(extra) { $1 }
    CGImageDestinationAddImage(destination, pattern, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "can't write \(name)")
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
write("pattern-o6.jpg", UTType.jpeg.identifier)
write("pattern-o6.heic", UTType.heic.identifier)
write("pattern.avif", "public.avif", [kCGImagePropertyOrientation: 1])
write("pattern-o6.tiff", UTType.tiff.identifier, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
let cwebp = Process()
cwebp.executableURL = URL(fileURLWithPath: "/usr/bin/env")
cwebp.arguments = ["cwebp", "-quiet", "-q", "95", "-metadata", "exif",
                   folder.appendingPathComponent("pattern-o6.jpg").path,
                   "-o", folder.appendingPathComponent("pattern-o6.webp").path]
try cwebp.run()
cwebp.waitUntilExit()
precondition(cwebp.terminationStatus == 0, "cwebp failed")

import AppKit

/// Draws a window into a PNG without the window server, so it works with the screen locked and for windows that were
/// never shown (`-debugOffscreen`). Title bar and toolbar come along. What draws no background of its own lands on the
/// window's background color; `cornerRadius` rounds that for the borderless panel, whose glass doesn't draw this way.
enum Snapshot {
    enum Failure: Error {
        case noWindow, noBitmap
    }

    static func write(_ window: NSWindow?, to url: URL, cornerRadius: CGFloat = 0) throws {
        guard let window, let content = window.contentView else { throw Failure.noWindow }
        let view = cornerRadius > 0 ? content : (content.superview ?? content)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure.noBitmap }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                            pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure.noBitmap }
        output.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: cornerRadius,
                         yRadius: cornerRadius).fill()
        }
        image.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = output.representation(using: .png, properties: [:]) else { throw Failure.noBitmap }
        try png.write(to: url)
    }

    /// A window that's on screen, as the window server shows it, content drawn by other processes included (Quick
    /// Look's previews are). An app may always capture its own windows. CGWindowListCreateImage is gone from the
    /// SDK's Swift interface, hence the lookup.
    static func capture(_ window: NSWindow, to url: URL) throws {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw Failure.noBitmap }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure.noBitmap }
        try png.write(to: url)
    }
}

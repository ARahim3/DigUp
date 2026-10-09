// Renders fake but realistic-looking UI "screenshots" (no real user data) for the embedding spike.
// usage: swift make_screenshots.swift <outdir>
import AppKit

let out = CommandLine.arguments[1]
let W: CGFloat = 1440, H: CGFloat = 900

func render(_ name: String, bg: NSColor, chrome: NSColor, title: String, _ draw: (CGRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // desktop + window
    NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.62, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let win = NSRect(x: 80, y: 60, width: W - 160, height: H - 120)
    bg.setFill(); NSBezierPath(roundedRect: win, xRadius: 12, yRadius: 12).fill()
    chrome.setFill(); NSRect(x: win.minX, y: win.maxY - 44, width: win.width, height: 44).fill()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 18 + CGFloat(i) * 22, y: win.maxY - 29, width: 13, height: 13)).fill()
    }
    text(title, at: CGPoint(x: win.midX - 180, y: win.maxY - 32), size: 15, color: .secondaryLabelColor, weight: .semibold)
    draw(NSRect(x: win.minX + 40, y: win.minY + 30, width: win.width - 80, height: win.height - 110))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor = .black, weight: NSFont.Weight = .regular, mono: Bool = false) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

func box(_ r: NSRect, _ c: NSColor, radius: CGFloat = 8) { c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }

let white = NSColor.white, light = NSColor(white: 0.93, alpha: 1)

render("shot_payment_error", bg: white, chrome: light, title: "dashboard.payments.example.com — Invoices") { r in
    text("Invoices", at: CGPoint(x: r.minX, y: r.maxY - 40), size: 30, weight: .bold)
    box(NSRect(x: r.minX, y: r.maxY - 140, width: r.width, height: 80), NSColor(red: 1, green: 0.9, blue: 0.9, alpha: 1))
    text("⚠︎  Payment failed: Your card was declined (card_declined)", at: CGPoint(x: r.minX + 24, y: r.maxY - 95), size: 22, color: .systemRed, weight: .semibold)
    text("Invoice INV-2041   ·   Acme Design Studio   ·   $249.00 USD   ·   Visa •••• 4242", at: CGPoint(x: r.minX, y: r.maxY - 200), size: 18)
    text("Attempted Oct 3, 2026 9:41 AM — The customer's bank declined the charge. Ask for another payment method.", at: CGPoint(x: r.minX, y: r.maxY - 240), size: 16, color: .darkGray)
    box(NSRect(x: r.minX, y: r.maxY - 320, width: 200, height: 44), .systemBlue)
    text("Retry payment", at: CGPoint(x: r.minX + 40, y: r.maxY - 308), size: 17, color: .white, weight: .semibold)
}

render("shot_python_traceback", bg: NSColor(white: 0.1, alpha: 1), chrome: NSColor(white: 0.22, alpha: 1), title: "zsh — 120×40") { r in
    let lines = ["$ python train.py --epochs 10",
                 "Traceback (most recent call last):",
                 "  File \"/Users/me/project/train.py\", line 3, in <module>",
                 "    import torch",
                 "ModuleNotFoundError: No module named 'torch'",
                 "$ pip install torch",
                 "error: externally-managed-environment"]
    for (i, l) in lines.enumerated() {
        text(l, at: CGPoint(x: r.minX, y: r.maxY - 30 - CGFloat(i) * 34), size: 22, color: l.contains("Error") || l.contains("error") ? .systemRed : NSColor(white: 0.9, alpha: 1), mono: true)
    }
}

render("shot_flight_booking", bg: white, chrome: light, title: "Mail — Your booking is confirmed") { r in
    text("Booking confirmed ✈︎", at: CGPoint(x: r.minX, y: r.maxY - 40), size: 30, weight: .bold)
    box(NSRect(x: r.minX, y: r.maxY - 300, width: r.width * 0.7, height: 220), NSColor(red: 0.93, green: 0.96, blue: 1, alpha: 1), radius: 14)
    text("San Francisco (SFO)  →  Tokyo Haneda (HND)", at: CGPoint(x: r.minX + 30, y: r.maxY - 120), size: 26, weight: .semibold)
    text("Flight NH 7   ·   Departs Fri, Nov 14 at 14:30   ·   Arrives Sat 18:55", at: CGPoint(x: r.minX + 30, y: r.maxY - 170), size: 19)
    text("Passenger: Alex Doe   ·   Seat 32A   ·   Gate 112   ·   Confirmation code: K7Q2LM", at: CGPoint(x: r.minX + 30, y: r.maxY - 210), size: 19)
    text("Check-in opens 24 hours before departure.", at: CGPoint(x: r.minX + 30, y: r.maxY - 260), size: 16, color: .darkGray)
}

render("shot_chat_meeting", bg: white, chrome: light, title: "#design-team") { r in
    let msgs = [("Sam", "Can we move the design review to Thursday? I'm out sick tomorrow."),
                ("Priya", "Sure, Thursday 3pm works for me. I'll update the calendar invite."),
                ("Sam", "Thanks! I'll also share the new onboarding mockups before the meeting.")]
    for (i, m) in msgs.enumerated() {
        let y = r.maxY - 60 - CGFloat(i) * 110
        box(NSRect(x: r.minX, y: y - 6, width: 44, height: 44), [NSColor.systemOrange, .systemPurple, .systemOrange][i], radius: 22)
        text(m.0, at: CGPoint(x: r.minX + 60, y: y + 18), size: 18, weight: .bold)
        text(m.1, at: CGPoint(x: r.minX + 60, y: y - 12), size: 19)
    }
}

render("shot_weather", bg: NSColor(red: 0.85, green: 0.9, blue: 0.96, alpha: 1), chrome: light, title: "Weather") { r in
    text("London", at: CGPoint(x: r.minX, y: r.maxY - 50), size: 40, weight: .bold)
    text("18° · Heavy rain ☂︎ · 90% chance of rain", at: CGPoint(x: r.minX, y: r.maxY - 110), size: 28)
    for (i, d) in ["Mon 🌧 15°", "Tue 🌧 14°", "Wed ⛈ 13°", "Thu 🌦 16°", "Fri ☁︎ 17°"].enumerated() {
        box(NSRect(x: r.minX + CGFloat(i) * 220, y: r.maxY - 300, width: 200, height: 140), NSColor(white: 1, alpha: 0.7), radius: 16)
        text(d, at: CGPoint(x: r.minX + 30 + CGFloat(i) * 220, y: r.maxY - 240), size: 24)
    }
}

render("shot_swift_code", bg: NSColor(white: 0.12, alpha: 1), chrome: NSColor(white: 0.2, alpha: 1), title: "SearchIndex.swift — Editor") { r in
    let code = ["import Accelerate", "",
                "struct SearchIndex {",
                "    var vectors: [Float]",
                "    let dimension = 768",
                "",
                "    func search(query: [Float], topK: Int) -> [Int] {",
                "        // cosine similarity via matrix-vector product",
                "        var scores = [Float](repeating: 0, count: vectors.count / dimension)",
                "        cblas_sgemv(CblasRowMajor, CblasNoTrans, ...)",
                "        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(topK).map { $0 }",
                "    }", "}"]
    for (i, l) in code.enumerated() {
        text(l, at: CGPoint(x: r.minX, y: r.maxY - 30 - CGFloat(i) * 30), size: 19,
             color: l.contains("//") ? .systemGreen : (l.contains("struct") || l.contains("func") || l.contains("import") ? .systemPink : NSColor(white: 0.9, alpha: 1)), mono: true)
    }
}
print("ok")

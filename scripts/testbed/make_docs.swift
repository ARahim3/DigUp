// Writes synthetic documents with known content (ground truth for evals):
// a 3-page text PDF (one topic per page), an image-only "scanned" PDF, and txt/md/rtf/docx notes.
//   swift make_docs.swift <out_dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func pdf(_ name: String, pages: [(CGContext, CGRect) -> Void]) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(out.appendingPathComponent(name) as CFURL, mediaBox: &box, nil)!
    for draw in pages {
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx, box)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func text(_ s: String, in r: CGRect, size: CGFloat = 13, bold: Bool = false) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4
    (s as NSString).draw(in: r, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                                 .paragraphStyle: style])
}

let body = CGRect(x: 60, y: 60, width: 492, height: 620)
pdf("Annual notes 2026.pdf", pages: [
    { _, _ in text("Quarterly business review", in: CGRect(x: 60, y: 700, width: 492, height: 40), size: 22, bold: true)
              text("Revenue grew 20% compared to last year, driven by strong sales in Europe and a new enterprise plan. Operating costs stayed flat, and the team hired four engineers. Next quarter we will focus on retention and on expanding the partner program in Japan.", in: body) },
    { _, _ in text("Hiking trip to Mount Fuji", in: CGRect(x: 60, y: 700, width: 492, height: 40), size: 22, bold: true)
              text("We started the climb from the Yoshida trail at the fifth station before sunrise. The path was rocky and cold near the summit, but the view of the clouds below the crater was unforgettable. Pack warm gloves, a headlamp and enough water; the mountain huts sell instant noodles.", in: body) },
    { _, _ in text("Sourdough bread recipe", in: CGRect(x: 60, y: 700, width: 492, height: 40), size: 22, bold: true)
              text("Feed the starter the night before. Mix 500 g flour, 350 g water and 100 g active starter, rest for an hour, then add 10 g salt. Stretch and fold four times, shape a boule, proof overnight in the fridge and bake in a Dutch oven at 250 °C.", in: body) },
])

// "Scanned" receipt: text rendered into an image, so the PDF has no text layer.
let receipt = NSImage(size: NSSize(width: 900, height: 1200))
receipt.lockFocus()
NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 1200).fill()
let lines = ["BLUE BOTTLE COFFEE", "Hayes Valley, San Francisco", "", "Oat latte            5.50", "Almond croissant     4.75",
             "Cold brew            4.25", "", "TOTAL               14.50", "VISA **** 4242", "Thank you for visiting!"]
for (i, l) in lines.enumerated() {
    (l as NSString).draw(at: NSPoint(x: 120, y: 1050 - i * 60), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 34, weight: i == 0 ? .bold : .regular)])
}
receipt.unlockFocus()
let receiptCG = receipt.cgImage(forProposedRect: nil, context: nil, hints: nil)!
pdf("Scan 2026-09-14.pdf", pages: [{ ctx, box in ctx.draw(receiptCG, in: box.insetBy(dx: 40, dy: 40)) }])

let notes: [(String, String)] = [
    ("Groceries.txt", "Grocery list for the weekend: milk, eggs, bread, apples, coffee beans and dish soap."),
    ("Tokyo itinerary.md", "# Tokyo trip\n\nFlight to Tokyo Haneda on November 14. Hotel in Shinjuku for five nights. Day trip to Kamakura on Sunday to see the Great Buddha."),
    ("Meeting notes.rtf", "Design review moved to Thursday at 3pm because Sam was sick. Priya will update the calendar invite and Sam will share the onboarding mockups."),
    ("Vector search notes.docx", "Notes on implementing cosine similarity search over embedding vectors with Accelerate in Swift: normalize vectors, use cblas_sgemv, keep the top-k with a heap."),
]
for (name, content) in notes {
    let url = out.appendingPathComponent(name)
    switch url.pathExtension {
    case "rtf", "docx":
        let attr = NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let type: NSAttributedString.DocumentType = url.pathExtension == "rtf" ? .rtf : .officeOpenXML
        let data = try! attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: type])
        try! data.write(to: url)
    default:
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }
}
print("ok")

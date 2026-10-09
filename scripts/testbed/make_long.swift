// Writes long files with known content deep inside, past the first step that the first pass reads (ground truth
// for evals: those pages are found only once the rest of a long file is read):
//   Sailing log 2025.pdf   120 pages of a logbook; a few days stand out (pages 41, 66, 88, 100)
//   Team notes 2026.md     ~150,000 characters of weekly notes; one week stands out (past the 40th chunk)
//   sensor readings.txt    a dump of numbers (keyword search only), with one number near its end
//   swift make_long.swift <out_dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The same "random" choices every run.
var seed: UInt64 = 20251009
func pick<T>(_ items: [T]) -> T {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return items[Int((seed >> 33) % UInt64(items.count))]
}

// MARK: The logbook

let ports = ["Falmouth", "Fowey", "Plymouth", "Salcombe", "Dartmouth", "Weymouth", "Poole", "Yarmouth", "Cherbourg",
             "St Peter Port", "Alderney", "Brixham", "Penzance", "Newlyn", "St Mary's"]
let winds = ["northwest 3", "west 4", "southwest 4 to 5", "south 3", "variable 2", "northeast 4", "west 5, gusting 6",
             "southwest 3"]
let seas = ["slight", "moderate", "smooth", "slight to moderate", "a long swell from the west"]
let weather = ["Sunny spells and good visibility.", "Overcast, with drizzle in the afternoon.",
               "Clear skies, cold in the evening.", "Showers passing through, rainbow at noon.",
               "Grey and still all morning, brighter later.", "High cloud and a halo around the sun."]
let days = ["Two reefs in the main until the wind eased, then full sail and a long beat to windward.",
            "Practised man-overboard drills with the fender twice; both recoveries under two minutes.",
            "Checked the rigging at the mast foot and tightened a loose shackle on the kicker.",
            "Long reach along the coast, logged a steady six knots most of the way.",
            "Motor-sailed the last hour to make the tide at the harbour entrance.",
            "Cleaned the bilge, topped up the water tanks and bought bread and fruit ashore.",
            "Took bearings on the lighthouse and the church spire to fix our position on the chart.",
            "Changed the genoa sheets and whipped the frayed ends with waxed twine.",
            "Quiet day at anchor: read, swam off the stern and cooked a curry for dinner."]

func logPage(_ number: Int) -> String {
    let from = pick(ports), to = pick(ports.filter { $0 != from })
    return "Day \(number). Left \(from) at \(pick(["06:10", "07:45", "08:30", "09:15", "10:40"])), bound for \(to). "
        + "Wind \(pick(winds)), sea \(pick(seas)). \(pick(weather)) \(pick(days)) \(pick(days.reversed())) "
        + "Moored in \(to) after \(pick(["18", "23", "27", "31", "36", "42"])) miles. Barometer \(pick(["1012", "1016", "1019", "1021", "1008"])) "
        + "and steady. Crew well; the night watch went to the skipper and the mate in two-hour turns."
}

let standouts = [
    41: "Day 41. The engine overheated off Start Point and stopped. The raw-water impeller had lost all its vanes, so "
        + "we sailed the last eight miles into Brixham under genoa alone and fitted the spare impeller on the pontoon. "
        + "Ordered two more from the chandlery; never leave harbour without a spare again.",
    66: "Day 66. At sunset a pod of a dozen common dolphins came racing in from the south and rode our bow wave for "
        + "twenty minutes, leaping clear of the water and rolling to look up at us. Nobody wanted to go below for "
        + "dinner. The skipper said it was the best evening of the whole season.",
    88: "Day 88. Picked up visitors' mooring ball M-417 in the Helford river, paid the harbour master eighteen pounds "
        + "and rowed ashore for supplies. Quiet creek, oak woods down to the water, an egret fishing on the mud.",
    100: "Day 100. Fog came down so thick off the Lizard that we could not see the bow from the cockpit. We slowed to "
        + "three knots, sounded the horn every two minutes and steered by radar and the plotter while a tanker's "
        + "foghorn boomed somewhere to starboard. It lifted only as we reached the harbour wall.",
]

var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdf = CGContext(out.appendingPathComponent("Sailing log 2025.pdf") as CFURL, mediaBox: &box, nil)!
for number in 1...120 {
    pdf.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    ("Sailing log 2025 · page \(number)" as NSString).draw(
        in: CGRect(x: 60, y: 720, width: 492, height: 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    ((standouts[number] ?? logPage(number)) as NSString).draw(
        in: CGRect(x: 60, y: 60, width: 492, height: 640),
        withAttributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: style])
    NSGraphicsContext.restoreGraphicsState()
    pdf.endPDFPage()
}
pdf.closePDF()

// MARK: The notes

let topics = ["the release checklist", "on-call handover", "the design review backlog", "hiring for the data team",
              "the customer survey results", "budget for the next quarter", "the support queue", "flaky tests in CI",
              "the onboarding guide", "the API deprecation plan", "laptop refresh", "the team offsite"]
let actions = ["Priya will draft a proposal by Friday.", "Sam takes the follow-up with finance.",
               "We agreed to revisit this in two weeks.", "Ana will write it up in the wiki.",
               "No decision yet; collect more data first.", "Ben volunteered to own it this sprint.",
               "Moved to the next planning meeting.", "Done, closing the ticket."]

var notes = "# Team notes 2026\n\n"
var week = 1, told = false
while notes.count < 150_000 {
    notes += "## Week \(week)\n\n"
    if !told, notes.count > 120_000 {   // well past the 40 chunks (~64,000 characters) of the first step
        told = true
        notes += "The big news: we agreed to move the whole team to a new office in Lisbon next March. The rent is lower, "
            + "half of the team already lives in Portugal, and the building has room to grow. Marta will look at schools "
            + "for the families who relocate, and the company covers the moving costs.\n\n"
    }
    for _ in 0..<6 {
        notes += "- On \(pick(topics)): \(pick(["discussed", "reviewed", "went through", "looked again at"])) where it stands. "
            + "\(pick(actions)) \(pick(actions))\n"
    }
    notes += "\n"
    week += 1
}
try! notes.write(to: out.appendingPathComponent("Team notes 2026.md"), atomically: true, encoding: .utf8)

// MARK: The numbers

var readings = "timestamp,sensor,value\n"
for row in 0..<12_000 {
    readings += "\(1_760_000_000 + row * 60) \(row % 17) \(row * 7919 % 100_003)\n"
    if row == 11_500 { readings += "4815162342 0 0\n" }
}
try! readings.write(to: out.appendingPathComponent("sensor readings.txt"), atomically: true, encoding: .utf8)
print("ok")

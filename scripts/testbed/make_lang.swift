// Writes Bengali and Arabic files with known content (ground truth for evals/multilingual.json): notes in
// txt/md/rtf/docx, two-page PDFs (one topic per page) and screenshots of app UIs.
//   swift make_lang.swift <out_dir>        (→ <out_dir>/bn, <out_dir>/ar)
//
// The PDFs are made by WebKit, as Safari's Export as PDF makes them: their text layer is what real files have (PDFKit
// reads Arabic from it fine, and Bengali in glyph order, garbled). PDFs drawn with CoreText directly read worse.
import AppKit
import PDFKit
import WebKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func folder(_ name: String) -> URL {
    let url = out.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func font(_ language: String, _ size: CGFloat, bold: Bool = false) -> NSFont {
    let name = language == "bn" ? (bold ? "KohinoorBangla-Semibold" : "KohinoorBangla-Regular")
                                : (bold ? "GeezaPro-Bold" : "GeezaPro")
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
}

/// Text in a box, right-aligned and right-to-left for Arabic.
func draw(_ string: String, in rect: CGRect, language: String, size: CGFloat, bold: Bool = false,
          color: NSColor = .black) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 6
    if language == "ar" {
        style.alignment = .right
        style.baseWritingDirection = .rightToLeft
    }
    (string as NSString).draw(in: rect, withAttributes: [.font: font(language, size, bold: bold),
                                                         .foregroundColor: color, .paragraphStyle: style])
}

/// PDFs to make once the run loop runs (WebKit is asynchronous): one page per (title, body).
var pdfJobs: [(url: URL, language: String, pages: [(title: String, body: String)])] = []

func pdf(_ url: URL, language: String, pages: [(title: String, body: String)]) {
    pdfJobs.append((url, language, pages))
}

/// Renders each page's HTML to a one-page PDF with WebKit, then joins the pages.
final class PDFMaker: NSObject, WKNavigationDelegate {
    private let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    private var pending: [(html: String, done: (Data) -> Void)] = []
    private var current: ((Data) -> Void)?

    override init() {
        super.init()
        view.navigationDelegate = self
    }

    func make(_ html: String, done: @escaping (Data) -> Void) {
        pending.append((html, done))
        if current == nil { next() }
    }

    private func next() {
        guard !pending.isEmpty else { current = nil; return }
        let job = pending.removeFirst()
        current = job.done
        view.loadHTMLString(job.html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        webView.createPDF(configuration: configuration) { result in
            self.current?(try! result.get())
            self.next()
        }
    }
}

func html(_ page: (title: String, body: String), language: String) -> String {
    let fontName = language == "bn" ? "Kohinoor Bangla" : "Geeza Pro"
    return """
        <!doctype html><html lang="\(language)" dir="\(language == "ar" ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <style>body { font: 15px/1.6 "\(fontName)", sans-serif; margin: 60px; } h1 { font-size: 24px; }</style></head>
        <body><h1>\(page.title)</h1><p>\(page.body)</p></body></html>
        """
}

let maker = PDFMaker()   // kept alive: the web view's delegate is weak

func makePDFs(then done: @escaping () -> Void) {
    var remaining = pdfJobs.count
    guard remaining > 0 else { return done() }
    for job in pdfJobs {
        var pages = [Data?](repeating: nil, count: job.pages.count)
        for (index, page) in job.pages.enumerated() {
            maker.make(html(page, language: job.language)) { data in
                pages[index] = data
                guard pages.allSatisfy({ $0 != nil }) else { return }
                let document = PDFDocument()
                for data in pages.compactMap({ $0 }) {
                    if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
                }
                document.write(to: job.url)
                remaining -= 1
                if remaining == 0 { done() }
            }
        }
    }
}

func note(_ url: URL, _ content: String, language: String) {
    switch url.pathExtension {
    case "rtf", "docx":
        let style = NSMutableParagraphStyle()
        if language == "ar" { style.baseWritingDirection = .rightToLeft; style.alignment = .right }
        let text = NSAttributedString(string: content, attributes: [.font: font(language, 14), .paragraphStyle: style])
        let type: NSAttributedString.DocumentType = url.pathExtension == "rtf" ? .rtf : .officeOpenXML
        try! text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            .write(to: url)
    default:
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A 1440×900 "screenshot" of an app window.
func screenshot(_ url: URL, title: String, language: String, _ body: (CGRect) -> Void) {
    let width = 1440, height = 900
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.62, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let window = NSRect(x: 80, y: 60, width: 1280, height: 780)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: window, xRadius: 12, yRadius: 12).fill()
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: window.minX, y: window.maxY - 44, width: window.width, height: 44).fill()
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: window.minX + 18 + CGFloat(index) * 22, y: window.maxY - 29, width: 13,
                                    height: 13)).fill()
    }
    draw(title, in: CGRect(x: window.minX + 200, y: window.maxY - 38, width: window.width - 400, height: 30),
         language: language, size: 15, color: .secondaryLabelColor)
    body(NSRect(x: window.minX + 60, y: window.minY + 40, width: window.width - 120, height: window.height - 130))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 10) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

// MARK: Bengali

let bn = folder("bn")
note(bn.appendingPathComponent("পরীক্ষার ফলাফল.txt"), """
    এসএসসি পরীক্ষার ফলাফল প্রকাশিত হয়েছে। এ বছর পাসের হার ৮৩ শতাংশ, যা গত বছরের চেয়ে বেশি। ঢাকা বোর্ডে মেয়েরা \
    ছেলেদের চেয়ে ভালো ফল করেছে। ফলাফল শিক্ষা বোর্ডের ওয়েবসাইটে এবং মোবাইলে এসএমএসের মাধ্যমে জানা যাবে।
    """, language: "bn")
note(bn.appendingPathComponent("ইলিশ মাছের রেসিপি.md"), """
    # সরিষা ইলিশ

    সরিষা ইলিশ রান্নার জন্য প্রথমে সরিষা বাটা, কাঁচা মরিচ, হলুদ আর লবণ দিয়ে ইলিশ মাছের টুকরোগুলো মাখিয়ে নিন। \
    কড়াইয়ে সরিষার তেল গরম করে মাছগুলো দিন, ঢেকে দিয়ে কম আঁচে দশ মিনিট রান্না করুন। গরম ভাতের সঙ্গে পরিবেশন করুন।
    """, language: "bn")
note(bn.appendingPathComponent("Sundarbans trip.docx"), """
    সুন্দরবন ভ্রমণ

    খুলনা থেকে লঞ্চে করে আমরা তিন দিনের জন্য সুন্দরবনে গিয়েছিলাম। ম্যানগ্রোভ বনের খালে নৌকায় ঘুরে আমরা রয়েল বেঙ্গল \
    টাইগারের পায়ের ছাপ দেখেছি। চিত্রা হরিণ, বানর আর একটি বড় কুমিরও চোখে পড়েছে। রাতে লঞ্চের ছাদে বসে তারা দেখা ছিল \
    সবচেয়ে সুন্দর অভিজ্ঞতা।
    """, language: "bn")
pdf(bn.appendingPathComponent("বাড়ি ভাড়ার চুক্তি.pdf"), language: "bn", pages: [
    ("বাড়ি ভাড়ার চুক্তিপত্র", """
        ধানমন্ডি ৭ নম্বর রোডের তিন বেডরুমের ফ্ল্যাটটি মাসিক ২৫,০০০ টাকা ভাড়ায় দেওয়া হলো। ভাড়াটিয়া দুই মাসের ভাড়া অগ্রিম \
        জমা দেবেন। প্রতি মাসের পাঁচ তারিখের মধ্যে ভাড়া পরিশোধ করতে হবে। বিদ্যুৎ, পানি ও গ্যাস বিল ভাড়াটিয়া আলাদাভাবে \
        দেবেন। চুক্তির মেয়াদ এক বছর, এবং বাড়ি ছাড়ার আগে অন্তত দুই মাস আগে বাড়িওয়ালাকে লিখিতভাবে জানাতে হবে। ফ্ল্যাটে \
        কোনো স্থায়ী পরিবর্তন করতে হলে বাড়িওয়ালার অনুমতি লাগবে।
        """),
    ("প্রোগ্রামিং ক্লাসের নোট", """
        আজকের ক্লাসে আমরা পাইথনে লুপ আর ফাংশন শিখেছি। for লুপ দিয়ে একটি তালিকার প্রতিটি উপাদানের উপর কাজ করা যায়, আর \
        while লুপ চলতে থাকে যতক্ষণ শর্তটি সত্য থাকে। ফাংশন তৈরি করতে def শব্দটি ব্যবহার করা হয়, এবং return দিয়ে ফলাফল \
        ফেরত পাঠানো হয়। বাড়ির কাজ: একটি ফাংশন লিখুন যা একটি সংখ্যার ফ্যাক্টোরিয়াল বের করে, তারপর লুপ দিয়ে এক থেকে \
        দশ পর্যন্ত সব সংখ্যার ফ্যাক্টোরিয়াল ছাপুন।
        """),
])
screenshot(bn.appendingPathComponent("wallet_failed_bn.png"), title: "মোবাইল ওয়ালেট — টাকা পাঠান", language: "bn") { r in
    draw("টাকা পাঠান", in: CGRect(x: r.minX, y: r.maxY - 60, width: 600, height: 60), language: "bn", size: 34,
         bold: true)
    fill(NSRect(x: r.minX, y: r.maxY - 200, width: r.width, height: 110), NSColor(red: 1, green: 0.9, blue: 0.9, alpha: 1))
    draw("⚠︎  লেনদেন ব্যর্থ হয়েছে: অপর্যাপ্ত ব্যালেন্স", in: CGRect(x: r.minX + 30, y: r.maxY - 175, width: r.width - 60,
         height: 60), language: "bn", size: 30, bold: true, color: .systemRed)
    draw("পরিমাণ: ৳ ৫,০০০   ·   প্রাপক: ০১৭০০-০০০০০০   ·   সময়: সকাল ১০:১২", in: CGRect(x: r.minX, y: r.maxY - 290,
         width: r.width, height: 50), language: "bn", size: 24)
    draw("আপনার অ্যাকাউন্টে যথেষ্ট টাকা নেই। টাকা যোগ করে আবার চেষ্টা করুন।", in: CGRect(x: r.minX, y: r.maxY - 350,
         width: r.width, height: 50), language: "bn", size: 22, color: .darkGray)
    fill(NSRect(x: r.minX, y: r.maxY - 450, width: 300, height: 60), .systemPink)
    draw("আবার চেষ্টা করুন", in: CGRect(x: r.minX + 50, y: r.maxY - 440, width: 260, height: 44), language: "bn",
         size: 24, bold: true, color: .white)
}

// MARK: Arabic

let ar = folder("ar")
note(ar.appendingPathComponent("وصفة الكبسة.txt"), """
    الكبسة السعودية: اغسل الأرز البسمتي وانقعه في الماء لمدة نصف ساعة. في قدر كبير، اقلِ البصل حتى يذبل ثم أضف قطع \
    الدجاج والطماطم والثوم وبهارات الكبسة. أضف الماء واترك الدجاج ينضج، ثم أضف الأرز واطبخه على نار هادئة. قدّمها مع \
    اللوز المحمص والزبيب.
    """, language: "ar")
note(ar.appendingPathComponent("Meeting minutes.rtf"), """
    محضر اجتماع فريق التطوير

    تقرر تأجيل إطلاق التطبيق إلى شهر ديسمبر بسبب مشاكل في نظام الدفع الإلكتروني. سيقوم فريق الخوادم بإصلاح الأخطاء قبل \
    نهاية الشهر، وسيتم اختبار النسخة الجديدة مع مجموعة صغيرة من المستخدمين.
    """, language: "ar")
note(ar.appendingPathComponent("ملاحظة.md"), """
    # مُلاحَظَة

    قَالَ مُحَمَّدٌ إِنَّ الْمَكْتَبَةَ الْعَامَّةَ تُغْلَقُ فِي السَّاعَةِ الثَّامِنَةِ مَسَاءً يَوْمَ الْخَمِيسِ، فَلَا تَتَأَخَّرْ فِي إِعَادَةِ الْكُتُبِ.
    """, language: "ar")
pdf(ar.appendingPathComponent("تقرير.pdf"), language: "ar", pages: [
    ("التقرير الربعي", """
        ارتفعت المبيعات بنسبة خمسة عشر بالمئة في الربع الثالث مقارنة بالعام الماضي، بفضل نمو قوي في أسواق الخليج وإطلاق \
        خدمة الاشتراك الجديدة. بقيت التكاليف التشغيلية مستقرة، وانضم ثلاثة مهندسين جدد إلى الفريق. في الربع القادم سنركز \
        على رضا العملاء وتوسيع شبكة الشركاء.
        """),
    ("رحلة إلى البتراء", """
        زرنا مدينة البتراء الأثرية في جنوب الأردن. مشينا عبر السيق الضيق حتى ظهرت الخزنة المنحوتة في الصخر الوردي. صعدنا \
        إلى الدير في الصباح الباكر لتجنب الحر، وتناولنا الغداء في قرية وادي موسى. أنصح بارتداء حذاء مريح وحمل الكثير من \
        الماء.
        """),
])
screenshot(ar.appendingPathComponent("payment_error_ar.png"), title: "متجر إلكتروني — الدفع", language: "ar") { r in
    draw("إتمام الطلب", in: CGRect(x: r.minX, y: r.maxY - 60, width: r.width, height: 60), language: "ar", size: 34,
         bold: true)
    fill(NSRect(x: r.minX, y: r.maxY - 200, width: r.width, height: 110), NSColor(red: 1, green: 0.9, blue: 0.9, alpha: 1))
    draw("فشلت عملية الدفع: البطاقة مرفوضة من البنك  ⚠︎", in: CGRect(x: r.minX + 30, y: r.maxY - 175,
         width: r.width - 60, height: 60), language: "ar", size: 30, bold: true, color: .systemRed)
    draw("المبلغ: ٣٥٠ ريال   ·   رقم الطلب: ٤٨٢١٧   ·   بطاقة فيزا تنتهي بـ ٤٢٤٢", in: CGRect(x: r.minX, y: r.maxY - 290,
         width: r.width, height: 50), language: "ar", size: 24)
    draw("يرجى استخدام بطاقة أخرى أو المحاولة مرة أخرى لاحقاً.", in: CGRect(x: r.minX, y: r.maxY - 350, width: r.width,
         height: 50), language: "ar", size: 22, color: .darkGray)
    fill(NSRect(x: r.maxX - 300, y: r.maxY - 450, width: 300, height: 60), .systemBlue)
    draw("إعادة المحاولة", in: CGRect(x: r.maxX - 280, y: r.maxY - 440, width: 260, height: 44), language: "ar",
         size: 24, bold: true, color: .white)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
makePDFs {
    print("ok")
    exit(0)
}
app.run()

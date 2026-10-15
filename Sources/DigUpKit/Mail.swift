import Foundation

/// Outlook mail stored in .pst files. The digup-pst tool (pst/, beside the helper) reads a PST without Outlook; each
/// mail becomes an entry of its own in the index, at a path inside its PST ("…/archive.pst::2097412": the mail's node
/// id in the PST), so search, results and the index's bookkeeping treat it as they treat a file. The PST itself is a
/// `mailbox`: syncing it lists its mails (fast, no bodies) and queues the new and changed ones (`Indexer.sync`).
///
/// A PST that Outlook has open is locked: nothing can read it until Outlook lets go. Its mails wait (`waiting`) and
/// are taken up again by the first sync that can read it, so a locked PST never keeps indexing busy.
///
/// Mails are indexed where the tool is: shipped with the Windows helper, where opening a mail in Outlook works
/// (`digup-pst open`). Elsewhere `$DIGUP_PST` names its folder (development, tests).
public enum Mail {
    /// The tool: beside the helper, in $DIGUP_PST, then on PATH.
    static let tool: String? = {
        #if os(Windows)
        let (name, separator): (String, Character) = ("digup-pst.exe", ";")
        let path = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
        #else
        let (name, separator): (String, Character) = ("digup-pst", ":")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #endif
        var folders: [String] = []
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_PST"], !chosen.isEmpty { folders.append(chosen) }
        if let executable = Bundle.main.executableURL { folders.append(executable.deletingLastPathComponent().path) }
        folders += path.split(separator: separator).map(String.init)
        return folders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    public static var isAvailable: Bool { tool != nil }

    /// Between a PST's path and a mail's node id in the path of the mail.
    static let separator = "::"

    static func path(mailbox: String, node: UInt32) -> String { mailbox + separator + String(node) }

    /// The PST and the node id of a mail's path; nil for a file's.
    public static func split(_ path: String) -> (mailbox: String, node: UInt32)? {
        guard let range = path.range(of: separator, options: .backwards), let node = UInt32(path[range.upperBound...])
        else { return nil }
        return (String(path[..<range.lowerBound]), node)
    }

    /// Why a mail waits: its PST is open in Outlook. A sync that can read the PST queues it again.
    static let waiting = "waiting: the PST is open in Outlook"

    enum Failure: Error, CustomStringConvertible {
        case locked
        var description: String { Mail.waiting }
    }

    /// A mail as `list` gives it: enough to show it in results and to tell when it changed.
    struct Listed: Sendable {
        let node: UInt32
        let folder: String
        let subject: String
        let from: String
        let date: String?
        let modified: Double
    }

    /// A mail with its text, as `read` gives it.
    struct Content: Sendable {
        let subject: String
        let from: String
        let recipients: [(kind: String, name: String)]
        let date: String?
        let body: String
        let attachments: [(name: String, path: String?, embedded: String?)]
    }

    /// The PST's mails, without their bodies. Seconds for a big PST.
    static func list(_ mailbox: String) throws -> [Listed] {
        try lines(["list", mailbox]).compactMap { line in
            guard line["type"] as? String == "mail", let node = (line["node"] as? NSNumber)?.uint32Value else { return nil }
            let date = line["received"] as? String ?? line["sent"] as? String
            return Listed(node: node, folder: line["folder"] as? String ?? "", subject: line["subject"] as? String ?? "",
                          from: sender(line), date: date,
                          modified: (line["modified"] as? String ?? date).flatMap(seconds) ?? 0)
        }
    }

    /// The mails with these node ids, by node id, their attachments written into `folder`. A node that's gone from the
    /// PST isn't in the result.
    static func read(_ mailbox: String, nodes: [UInt32], attachmentsTo folder: URL) throws -> [UInt32: Content] {
        var out: [UInt32: Content] = [:]
        for line in try lines(["read", mailbox] + nodes.map(String.init) + ["--attachments", folder.path]) {
            guard line["type"] as? String == "mail", let node = (line["node"] as? NSNumber)?.uint32Value else { continue }
            let recipients = (line["recipients"] as? [[String: Any]] ?? []).map { recipient in
                (kind: recipient["kind"] as? String ?? "to", name: person(recipient["name"], recipient["email"]))
            }
            let attachments = (line["attachments"] as? [[String: Any]] ?? []).map { item in
                let embedded = item["embedded"] as? [String: Any]
                return (name: item["name"] as? String ?? "", path: item["path"] as? String,
                        embedded: embedded.map { [$0["subject"] as? String, $0["body"] as? String]
                            .compactMap { $0 }.joined(separator: "\n") })
            }
            out[node] = Content(subject: line["subject"] as? String ?? "", from: sender(line), recipients: recipients,
                                date: line["received"] as? String ?? line["sent"] as? String,
                                body: line["body"] as? String ?? "", attachments: attachments)
        }
        return out
    }

    /// What's indexed of a mail: its subject, who sent it to whom and when, its body, then the text of its attachments
    /// that DigUp reads (documents, spreadsheets, presentations, PDFs, attached mails).
    static func text(of mail: Content) -> String {
        var parts = [mail.subject]
        if !mail.from.isEmpty { parts.append("From: \(mail.from)") }
        for kind in ["to", "cc"] {
            let names = mail.recipients.filter { $0.kind == kind }.map(\.name).filter { !$0.isEmpty }
            if !names.isEmpty { parts.append("\(kind == "to" ? "To" : "Cc"): \(names.joined(separator: ", "))") }
        }
        if let date = mail.date { parts.append("Date: \(date)") }
        var text = parts.joined(separator: "\n") + "\n\n" + mail.body
        for attachment in mail.attachments {
            guard let content = attachment.embedded ?? attachment.path.flatMap(attachmentText), !content.isEmpty
            else { continue }
            text += "\n\nAttachment: \(attachment.name)\n" + content
        }
        return text
    }

    /// An attachment's text, when it's a kind DigUp reads for words. Pictures, audio and video are left out.
    private static func attachmentText(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if Rules.docExtensions.contains(ext) { return try? DocExtractor.text(of: url) }
        if ext == "pdf", let pdf = try? PDFExtractor.pages(of: url, range: { 0..<min($0, 50) }, minText: 0,
                                                           renderPixels: 0, to: url.deletingLastPathComponent()) {
            return pdf.pages.map(\.text).joined(separator: "\n\n")
        }
        return nil
    }

    private static func sender(_ line: [String: Any]) -> String {
        person(line["sender_name"], line["sender_email"])
    }

    private static func person(_ name: Any?, _ email: Any?) -> String {
        let (name, email) = (name as? String ?? "", email as? String ?? "")
        if name.isEmpty { return email }
        return email.isEmpty || name == email ? name : "\(name) <\(email)>"
    }

    private static func seconds(_ iso: String) -> Double? {
        ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970
    }

    /// Runs the tool and parses its JSON lines. Exit 3: the PST is locked.
    private static func lines(_ arguments: [String]) throws -> [[String: Any]] {
        guard let tool else { throw ExtractError.unreadable("digup-pst isn't installed (Outlook mail needs it)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 3 { throw Failure.locked }
        guard process.terminationStatus == 0 else {
            throw ExtractError.unreadable("digup-pst failed (\(process.terminationStatus))")
        }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }
}

#if os(Linux)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct LegacyWordTests {
    @Test func libreOfficeReadsLegacyWordFile() throws {
        // LibreOffice is an optional runtime dependency; Linux CI installs it.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/soffice") else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-doc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rtf = folder.appendingPathComponent("sample.rtf")
        try #"{\rtf1\ansi\uc1\pard Atlas nebula orchid. Caf\u233? and \u26085?\u26412?.\par}"#
            .write(to: rtf, atomically: true, encoding: .utf8)
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/soffice")
        let profile = folder.appendingPathComponent("profile", isDirectory: true)
        converter.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless",
                               "--convert-to", "doc", "--outdir", folder.path, rtf.path]
        converter.standardInput = FileHandle.nullDevice
        converter.standardOutput = FileHandle.nullDevice
        converter.standardError = FileHandle.nullDevice
        try converter.run()
        converter.waitUntilExit()
        #expect(converter.terminationStatus == 0)

        let document = folder.appendingPathComponent("sample.doc")
        let text = try DocExtractor.text(of: document)
        #expect(text.contains("Atlas nebula orchid. Café and 日本."))
        #expect(!text.hasPrefix("\u{FEFF}"))
        #expect(DocExtractor.chunks(text, limit: 10).contains { $0.contains("nebula orchid") })
    }
}
#endif

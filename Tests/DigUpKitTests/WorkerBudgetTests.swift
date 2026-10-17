#if !os(Windows)
import Foundation
import Testing
@testable import DigUpKit

/// The JSON-lines contract, without a model or a Python environment.
@Suite struct WorkerBudgetTests {
    private func withWorker(reply: String, limit: Int? = 77, _ test: (EmbeddingWorker) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("worker.sh")
        let limitField = limit.map { ",\"text_token_limit\":\($0)" } ?? ""
        let ready = "{\"ready\":true,\"info\":{\"model\":\"mock\",\"revision\":\"1\",\"runtime\":\"test\",\"dtype\":\"f32\",\"dim\":768,\"text_only\":true\(limitField)}}"
        try """
            printf '%s\\n' '\(ready)'
            while IFS= read -r line; do
                case "$line" in
                    *token_count*) printf '%s\\n' '\(reply)' ;;
                    *quit*) exit 0 ;;
                esac
            done
            """.write(to: script, atomically: true, encoding: .utf8)
        let worker = try EmbeddingWorker(WorkerConfig(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path]),
                                         textOnly: true)
        defer { worker.close() }
        try test(worker)
    }

    @Test func countsAndSnakeCaseLimitRoundTrip() throws {
        try withWorker(reply: #"{"id":1,"ok":true,"counts":[42]}"#) { worker in
            #expect(worker.info.textOnly)
            #expect(worker.info.textTokenLimit == 77)
            #expect(worker.textTokenLimit == 77)
            let count = try worker.textTokenCount("title: public | text: 租房")
            #expect(count == 42)
        }
    }

    @Test func legacyUnsupportedCountFailsExplicitly() throws {
        try withWorker(reply: #"{"id":1,"ok":false,"error":"unknown op token_count"}"#, limit: nil) { worker in
            #expect(worker.textTokenLimit == 2048)
            #expect(throws: WorkerError.self) { try worker.textTokenCount("public") }
        }
    }

    @Test(arguments: [#"{"id":2,"ok":true,"counts":[42]}"#,
                      #"{"id":1,"ok":true,"counts":[-1]}"#,
                      #"{"id":1,"ok":true,"counts":[1,2]}"#])
    func malformedCountsFailExplicitly(_ reply: String) throws {
        try withWorker(reply: reply) { worker in
            #expect(throws: WorkerError.self) { try worker.textTokenCount("public") }
        }
    }
}
#endif

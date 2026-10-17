import DigUpKit
import Foundation
import Testing
@testable import LlamaRuntime

@Suite(.serialized) struct NativeTextBudgetTests {
    static let textModelPresent = (try? LlamaModels.locate()) != nil

    @Test(.enabled(if: textModelPresent)) func oversizedTextNeverSilentlyDropsItsTail() throws {
        let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: true)
        defer { embedder.close() }
        // Synthetic unspaced Han is far beyond the query encoder's 512-token context.
        #expect(throws: (any Error).self) {
            _ = try embedder.embedTexts([String(repeating: "租房合同", count: 1500) + "尾部标记"])
        }
    }

    @Test(.enabled(if: textModelPresent)) func actualTokenizerBudgetPreservesEverySyntheticRecord() throws {
        let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: true)
        defer { embedder.close() }
        let records = (1...180).map { "公开记录\($0)的租房合同。" }
        let parts = try embedder.documentChunks(records.joined() + "尾部标记", title: "公开合成回归")
        #expect(parts.count > 1)
        #expect(try parts.allSatisfy {
            try embedder.textTokenCount(Prompts.document(title: "公开合成回归", text: $0)) <= embedder.textTokenLimit
        })
        #expect(records.allSatisfy { record in parts.contains { $0.contains(record) } })
        #expect(parts.last?.hasSuffix("尾部标记") == true)
        let vectors = try embedder.embedTexts(parts.prefix(2).map {
            Prompts.document(title: "公开合成回归", text: $0)
        })
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == embedder.info.dim && $0.allSatisfy(\.isFinite) })
        print("NATIVE_TEXT_BUDGET actual tokenizer: \(parts.count) complete parts within \(embedder.textTokenLimit) tokens; 2 inference vectors validated")
    }
}

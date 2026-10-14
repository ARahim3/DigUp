#if canImport(CoreML)
import CoreML
import DigUpKit
import Foundation
import Testing
@testable import LlamaRuntime

@Suite struct NeuralEngineVisionTests {
    static let filesThere = NeuralEngineVision.locate() != nil && (try? LlamaModels.locate())?.media != nil

    /// A 528 × 288 frame: 33 × 18 patches pooled to 11 × 6 tokens, in the conversion's layout.
    @Test func inputsFollowTheConversionsLayout() throws {
        let grid = NeuralEngineVision.Grid(columns: 33, rows: 18)
        let width = NeuralEngineVision.patchWidth
        var table = [Float](repeating: 0, count: 2 * NeuralEngineVision.tableRows * width)
        for x in 0..<NeuralEngineVision.tableRows { table[x * width] = Float(x) }
        for y in 0..<NeuralEngineVision.tableRows { table[(NeuralEngineVision.tableRows + y) * width + 1] = Float(y) }
        let shape = try NeuralEngineVision.shape(grid, table: table)
        let n = NeuralEngineVision.patchCount
        let positions = shape.positions.dataPointer.bindMemory(to: Float16.self, capacity: n * 2)
        let embeddings = shape.embeddings.dataPointer.bindMemory(to: Float16.self, capacity: n * width)
        let valid = shape.valid.dataPointer.bindMemory(to: Float16.self, capacity: n)
        let pool = shape.pool.dataPointer.bindMemory(to: Float16.self, capacity: NeuralEngineVision.budget * n)

        let patch = 2 * 33 + 5   // x 5, y 2
        #expect(positions[patch * 2] == 5 && positions[patch * 2 + 1] == 2)
        #expect(embeddings[patch * width] == 5 && embeddings[patch * width + 1] == 2)
        #expect(valid[grid.count - 1] == 1 && valid[grid.count] == 0)
        #expect(positions[grid.count * 2] == -1)
        // Token 1 is the second block of the first row: patches x 3–5, y 0–2.
        let members = (0..<n).filter { pool[1 * n + $0] != 0 }
        #expect(members == [3, 4, 5, 36, 37, 38, 69, 70, 71])
        for token in 0..<NeuralEngineVision.budget {
            let sum = (0..<n).reduce(Float(0)) { $0 + Float(pool[token * n + $1]) }
            #expect(abs(sum - (token < grid.tokens ? 1 : 0)) < 0.01)
        }
    }

    @Test func patchesAreReadingOrderRGB() throws {
        let grid = NeuralEngineVision.Grid(columns: 3, rows: 3)
        let width = 48
        let pixels = (0..<(width * 48 * 3)).map { UInt8($0 % 251) }
        let patches = try pixels.withUnsafeBufferPointer {
            try NeuralEngineVision.patches($0.baseAddress!, width: width, grid: grid)
        }
        let values = patches.dataPointer.bindMemory(to: Float16.self, capacity: patches.count)
        // Patch 4 (x 1, y 1), its row 2, column 0, green: pixel (16, 18).
        let expected = Float(pixels[((16 + 2) * width + 16) * 3 + 1]) / 255
        #expect(abs(Float(values[4 * NeuralEngineVision.patchWidth + 2 * 48 + 1]) - expected) < 0.001)
    }

    /// The same frame through the Neural Engine and through llama.cpp's encoder, both into the text model.
    @Test(.enabled(if: filesThere)) func framesAgreeWithTheGPUEncoder() throws {
        let photo = ReferenceVectorTests.folder.appendingPathComponent("photo.jpg").path
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("digup-neural-engine-tests.log")
        func frame(neuralEngine: Bool) throws -> [Float] {
            let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: false, neuralEngine: neuralEngine,
                                             log: log)
            defer { embedder.close() }
            #expect(embedder.framesOnNeuralEngine == neuralEngine)
            let embedding = try embedder.embedImages([photo], budget: NeuralEngineVision.budget)[0]
            return try #require(embedding.vector, "\(embedding.error ?? "no vector")")
        }
        let gpu = try frame(neuralEngine: false), neuralEngine = try frame(neuralEngine: true)
        let cosine = zip(gpu, neuralEngine).reduce(0) { $0 + $1.0 * $1.1 }
        #expect(cosine >= ReferenceVectorTests.agreement, "cosine \(cosine)")
    }
}
#endif

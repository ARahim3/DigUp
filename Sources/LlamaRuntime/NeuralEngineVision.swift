#if canImport(CoreML)
import CoreML
import DigUpKit
import Foundation

/// EmbeddingGemma 2's vision encoder on the Neural Engine, for 70-token images (video frames): FluidInference's Core ML
/// conversion of the same weights (Apache-2.0), function `vision_70`. It takes an image as llama.cpp's encoder does,
/// already sized by `ImageSizing`, and returns the same 512-wide rows for the text model, so the GPU is left to the
/// text model and sound while the Neural Engine encodes the next frames.
///
/// Its fp16 arithmetic moves a frame's vector a little: against llama.cpp's encoder, cosine 0.9998 on the reference
/// frame (`NeuralEngineVisionTests`) and 0.9996 on average over 101 frames of 1080p video, none below 0.998.
final class NeuralEngineVision: @unchecked Sendable {
    static let budget = 70
    static let repository = "FluidInference/embeddinggemma-2-coreml"
    static let revision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
    static let package = "EmbeddingGemma2Vision.mlpackage"
    static let positionTable = "position_embeddings.f16"

    static let patchCount = 630, patchSide = 16, patchWidth = 768, rowWidth = 512, merge = 3, tableRows = 1024

    private let model: MLModel
    private let table: [Float]   // x rows then y rows, tableRows × patchWidth each
    private let lock = NSLock()
    private var shapes: [Grid: Shape] = [:]

    /// Where the files are: `neural-engine` in the models folder (`$DIGUP_MODELS` or the app's), or the Hugging Face
    /// cache at the pinned revision, where this puts them:
    ///
    ///     hf download FluidInference/embeddinggemma-2-coreml --revision <revision> \
    ///         --include "EmbeddingGemma2Vision.mlpackage/*" position_embeddings.f16
    static func locate() -> URL? {
        var folders = LlamaModels.folders.map { $0.appendingPathComponent("neural-engine") }
        folders.append(ModelFiles.huggingFaceSnapshot(repository: repository, revision: revision))
        return folders.first { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(package).path)
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(positionTable).path)
        }
    }

    init(folder: URL) throws {
        guard #available(macOS 15, *) else { throw LlamaError("the Neural Engine encoder needs macOS 15") }
        guard MLComputeDevice.allComputeDevices.contains(where: { if case .neuralEngine = $0 { true } else { false } })
        else { throw LlamaError("this Mac has no Neural Engine") }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = "vision_\(Self.budget)"
        model = try MLModel(contentsOf: try Self.compiled(folder.appendingPathComponent(Self.package)),
                            configuration: configuration)
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.positionTable))
        guard data.count == 2 * Self.tableRows * Self.patchWidth * MemoryLayout<Float16>.size else {
            throw LlamaError("\(Self.positionTable) isn't the conversion's position table")
        }
        table = data.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) }
    }

    /// The compiled model, built once per package revision in the caches folder (compiling takes seconds).
    private static func compiled(_ package: URL) throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DigUp", isDirectory: true)
        let target = caches.appendingPathComponent("EmbeddingGemma2Vision-\(revision.prefix(7)).mlmodelc")
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let built = try MLModel.compileModel(at: package)
        do {
            try fm.moveItem(at: built, to: target)
        } catch where fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: built)   // another helper compiled it first
        }
        return target
    }

    /// The encoder rows for an RGB image (`width` × `height`, sides multiples of 48, at most 630 patches): one row of
    /// `rowWidth` floats per 3×3 block of patches, left to right, top to bottom.
    func encode(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) throws -> [Float] {
        let grid = Grid(columns: width / Self.patchSide, rows: height / Self.patchSide)
        guard grid.columns * Self.patchSide == width, grid.rows * Self.patchSide == height,
              grid.columns % Self.merge == 0, grid.rows % Self.merge == 0,
              grid.count <= Self.patchCount, grid.columns <= Self.tableRows, grid.rows <= Self.tableRows else {
            throw LlamaError("a \(width)×\(height) image doesn't fit the Neural Engine's \(Self.budget)-token shape")
        }
        let shape = try self.shape(grid)
        let patches = try Self.patches(pixels, width: width, grid: grid)
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "patches": patches, "positions": shape.positions, "position_embeddings": shape.embeddings,
            "valid": shape.valid, "pool": shape.pool,
        ])
        let output = try lock.withLock { try model.prediction(from: inputs) }
        guard let tokens = output.featureValue(for: "image_tokens")?.multiArrayValue else {
            throw LlamaError("the Neural Engine encoder returned no image tokens")
        }
        return try Self.rows(tokens, count: grid.tokens)
    }

    // MARK: Inputs (the conversion's config.json)

    struct Grid: Hashable {
        let columns: Int
        let rows: Int
        var count: Int { columns * rows }
        var tokens: Int { (columns / NeuralEngineVision.merge) * (rows / NeuralEngineVision.merge) }
    }

    /// Everything but the pixels, which depends only on the patch grid.
    struct Shape {
        let positions: MLMultiArray     // [1, 630, 2]: each patch's x, y; −1 for padding
        let embeddings: MLMultiArray    // [1, 630, 768]: x row + y row of the position table
        let valid: MLMultiArray         // [1, 630]: 1 for a patch, 0 for padding
        let pool: MLMultiArray          // [70, 630]: 1/9 for each patch of a token's 3×3 block
    }

    private func shape(_ grid: Grid) throws -> Shape {
        if let shape = lock.withLock({ shapes[grid] }) { return shape }
        let shape = try Self.shape(grid, table: table)
        lock.withLock { shapes[grid] = shape }
        return shape
    }

    static func shape(_ grid: Grid, table: [Float]) throws -> Shape {
        let n = patchCount, width = patchWidth
        let positions = try array([1, n, 2], filling: -1)
        let embeddings = try array([1, n, width], filling: 0)
        let valid = try array([1, n], filling: 0)
        let pool = try array([budget, n], filling: 0)
        let p = positions.float16, e = embeddings.float16, v = valid.float16, q = pool.float16
        let columnsOut = grid.columns / merge
        for patch in 0..<grid.count {
            let x = patch % grid.columns, y = patch / grid.columns
            p[patch * 2] = Float16(Float(x))
            p[patch * 2 + 1] = Float16(Float(y))
            let column = x * width, row = (tableRows + y) * width
            for k in 0..<width { e[patch * width + k] = Float16(table[column + k] + table[row + k]) }
            v[patch] = 1
            q[((y / merge) * columnsOut + x / merge) * n + patch] = Float16(1.0 / 9)
        }
        return Shape(positions: positions, embeddings: embeddings, valid: valid, pool: pool)
    }

    /// Patches in reading order, each 16 rows × 16 columns × RGB, scaled to [0, 1]; padding left at zero.
    static func patches(_ pixels: UnsafePointer<UInt8>, width: Int, grid: Grid) throws -> MLMultiArray {
        let patches = try array([1, patchCount, patchWidth], filling: 0)
        let out = patches.float16
        let rowBytes = patchSide * 3
        for patch in 0..<grid.count {
            let x = patch % grid.columns, y = patch / grid.columns
            for line in 0..<patchSide {
                let source = pixels + ((y * patchSide + line) * width + x * patchSide) * 3
                let target = out + patch * patchWidth + line * rowBytes
                for k in 0..<rowBytes { target[k] = Float16(Float(source[k]) / 255) }
            }
        }
        return patches
    }

    /// The first `count` rows of the encoder's [1, 70, 512] (or [70, 512]) output, whatever its strides and type.
    static func rows(_ tokens: MLMultiArray, count: Int) throws -> [Float] {
        let strides = tokens.strides.map(\.intValue)
        guard strides.count >= 2, tokens.shape[tokens.shape.count - 1].intValue == rowWidth else {
            throw LlamaError("unexpected image token shape \(tokens.shape)")
        }
        let row = strides[strides.count - 2], column = strides[strides.count - 1]
        var rows = [Float](repeating: 0, count: count * rowWidth)
        switch tokens.dataType {
        case .float16:
            let t = tokens.dataPointer.bindMemory(to: Float16.self, capacity: tokens.count)
            for r in 0..<count { for k in 0..<rowWidth { rows[r * rowWidth + k] = Float(t[r * row + k * column]) } }
        case .float32:
            let t = tokens.dataPointer.bindMemory(to: Float.self, capacity: tokens.count)
            for r in 0..<count { for k in 0..<rowWidth { rows[r * rowWidth + k] = t[r * row + k * column] } }
        default:
            throw LlamaError("unexpected image token type \(tokens.dataType.rawValue)")
        }
        return rows
    }

    private static func array(_ shape: [Int], filling value: Float16) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        array.float16.initialize(repeating: value, count: array.count)
        return array
    }
}

private extension MLMultiArray {
    var float16: UnsafeMutablePointer<Float16> { dataPointer.bindMemory(to: Float16.self, capacity: count) }
}
#endif

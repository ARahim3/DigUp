import CLlama
import DigUpKit
import Foundation

/// Local Causal Small Language Model (SLM) Generator (`Qwen2.5-3B-Instruct-Q4_K_M` / `1.5B`) on `llama.cpp`,
/// engineered for an 8-core CPU, 12GB RAM PC:
///   - Uses `GGML_TYPE_Q8_0` KV-cache quantization to halve memory footprint (~350 MB for 8,192 tokens).
///   - Reserves 6 threads by default on an 8-core processor so OS/UI and `search-service` remain responsive.
///   - Supports Cache-Augmented Generation (CAG) via `llama_state_seq_save_file` and `llama_state_seq_load_file`
///     to persist pre-evaluated KV states of pinned files/contexts to disk.
///   - Supports hot-swappable `.gguf` LoRA adapters (`llama_adapter_lora_init`) trained from user `.jsonl` datasets.
public final class LlamaGenerator {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var loraAdapter: OpaquePointer?
    private let vocab: OpaquePointer?
    public let modelPath: URL
    public private(set) var loraPath: URL?
    public let contextSize: Int
    private var nPast: llama_pos = 0

    /// Optimal thread count for causal generation on an 8-core CPU (leaves 2 cores for OS + UI responsiveness).
    public static let chatThreads: Int32 = {
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_CHAT_THREADS"].flatMap(Int32.init) {
            return max(1, chosen)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return Int32(max(2, min(cores > 4 ? cores - 2 : cores, 6)))
    }()

    public init(paths: LlamaModels.ChatModelPaths, contextSize: Int = 8192, log: URL? = nil) throws {
        LlamaLog.shared.send(to: log)
        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = LlamaEmbedder.cpuOnly ? 0 : 999
        mparams.use_mmap = true
        guard let loadedModel = llama_model_load_from_file(paths.model.path, mparams) else {
            throw WorkerError.failed("can't load chat SLM \(paths.model.path)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize)
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        cparams.embeddings = false   // Causal generation mode: enables last-token logits!
        cparams.type_k = GGML_TYPE_Q8_0
        cparams.type_v = GGML_TYPE_Q8_0
        cparams.n_threads = Self.chatThreads
        cparams.n_threads_batch = Self.chatThreads

        guard let loadedCtx = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            throw WorkerError.failed("can't create causal llama_context for \(paths.model.lastPathComponent)")
        }

        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(42))

        self.model = loadedModel
        self.context = loadedCtx
        self.sampler = chain
        self.vocab = llama_model_get_vocab(loadedModel)
        self.modelPath = paths.model
        self.contextSize = contextSize

        if let lora = paths.loraAdapter {
            try applyLoraAdapter(at: lora)
        }
    }

    deinit { close() }

    public func close() {
        if let loraAdapter, let context {
            llama_rm_adapter_lora(context, loraAdapter)
            llama_adapter_lora_free(loraAdapter)
        }
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (loraAdapter, sampler, context, model) = (nil, nil, nil, nil)
    }

    // MARK: Hot-Swappable LoRA Adapter Support

    public func applyLoraAdapter(at url: URL, scale: Float = 1.0) throws {
        guard let model, let context else { throw WorkerError.failed("generator is closed") }
        if let existing = loraAdapter {
            llama_rm_adapter_lora(context, existing)
            llama_adapter_lora_free(existing)
            loraAdapter = nil
            loraPath = nil
        }
        guard let adapter = llama_adapter_lora_init(model, url.path) else {
            throw WorkerError.failed("can't load LoRA adapter at \(url.path)")
        }
        guard llama_set_adapter_lora(context, adapter, scale) == 0 else {
            llama_adapter_lora_free(adapter)
            throw WorkerError.failed("can't attach LoRA adapter \(url.lastPathComponent)")
        }
        self.loraAdapter = adapter
        self.loraPath = url
    }

    // MARK: Cache-Augmented Generation (CAG) KV-State Persistence

    /// Pre-evaluates `prefixText` (e.g. system instructions + pinned documents/code) into sequence 0 and saves
    /// the KV-cache state to `cacheFile` so future turns skip CPU prompt evaluation.
    public func buildAndSaveCAGSlot(prefixText: String, to cacheFile: URL) throws -> (tokens: Int, ms: Int) {
        guard let context else { throw WorkerError.failed("generator closed") }
        let started = Date()
        llama_kv_self_clear(context)
        nPast = 0
        let tokens = tokenize(prefixText, addSpecial: true)
        try decodeTokens(tokens)
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = tokens.withUnsafeBufferPointer { buf in
            llama_state_seq_save_file(context, cacheFile.path, 0, buf.baseAddress, buf.count)
        }
        guard saved > 0 else {
            throw WorkerError.failed("failed to serialize CAG KV state to \(cacheFile.path)")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return (tokens.count, elapsed)
    }

    /// Restores a previously saved CAG KV-cache slot from disk into sequence 0 in milliseconds.
    public func loadCAGSlot(from cacheFile: URL) throws -> (tokens: Int, ms: Int) {
        guard let context else { throw WorkerError.failed("generator closed") }
        let started = Date()
        llama_kv_self_clear(context)
        var tokenOut = [llama_token](repeating: 0, count: contextSize)
        var countOut: Int = 0
        let readBytes = tokenOut.withUnsafeMutableBufferPointer { buf in
            llama_state_seq_load_file(context, cacheFile.path, 0, buf.baseAddress, buf.count, &countOut)
        }
        guard readBytes > 0 else {
            throw WorkerError.failed("failed to load CAG KV state from \(cacheFile.path)")
        }
        nPast = llama_pos(countOut)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return (countOut, elapsed)
    }

    // MARK: Streaming Causal Generation

    public func generate(prompt: String, maxNewTokens: Int = 512, keepPrefix: Bool = false,
                         shouldStop: () -> Bool = { false },
                         onToken: (String) -> Void) throws -> String {
        guard let context, let sampler, let vocab else { throw WorkerError.failed("generator closed") }
        if !keepPrefix {
            llama_kv_self_clear(context)
            nPast = 0
        }
        let promptTokens = tokenize(prompt, addSpecial: nPast == 0)
        try decodeTokens(promptTokens)

        var fullOutput = ""
        for _ in 0..<maxNewTokens {
            if shouldStop() { break }
            let nextToken = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, nextToken)
            if llama_vocab_is_eog(vocab, nextToken) { break }
            let piece = detokenize(nextToken)
            fullOutput += piece
            onToken(piece)
            try decodeTokens([nextToken])
        }
        return fullOutput
    }

    private func decodeTokens(_ tokens: [llama_token]) throws {
        guard let context, !tokens.isEmpty else { return }
        let chunkSize = 512
        var offset = 0
        while offset < tokens.count {
            let end = min(offset + chunkSize, tokens.count)
            var slice = Array(tokens[offset..<end])
            let count = Int32(slice.count)
            let status = slice.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress, count)
                return llama_decode(context, batch)
            }
            guard status == 0 else {
                throw WorkerError.failed("llama_decode failed with status \(status)")
            }
            nPast += count
            offset = end
        }
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), addSpecial, true)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        return tokens
    }

    private func detokenize(_ token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count - 1), 0, true)
        guard n > 0 else { return "" }
        buf[Int(n)] = 0
        return String(cString: buf)
    }
}

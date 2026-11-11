import DigUpKit
import Foundation
import LlamaRuntime

/// `digup chat-service`: Interactive RAG + CAG + GraphRAG chat process over `LlamaGenerator` and `IndexStore`.
///
/// Protocol (JSON-lines over stdin/stdout):
///   {"op":"chat","id":…,"q":…,"code":bool,"cag_slot":?string,"max_tokens":512}
///     → streams {"event":"token","id":…,"token":…} and finishes with
///       {"id":…,"answer":…,"citations":[…],"cag_used":bool,"ms":{…}}
///   {"op":"cag_pin","id":…,"slot":string,"paths":[string]}
///     → pre-computes KV-cache state for pinned files into `<index>/cag_cache/<slot>.kv`
///   {"op":"load_lora","id":…,"path":string}
///     → hot-swaps a fine-tuned `.gguf` LoRA adapter at runtime
///   {"op":"status","id":…}
///     → reports loaded SLM, active LoRA adapter, thread count, and CAG slots
final class ChatService: @unchecked Sendable {
    private let indexFolder: URL
    private let cagFolder: URL
    private var generator: LlamaGenerator?
    private let lock = NSLock()
    private let output = NSLock()

    init(indexFolder: URL) throws {
        self.indexFolder = indexFolder
        self.cagFolder = indexFolder.appendingPathComponent("cag_cache")
        try FileManager.default.createDirectory(at: cagFolder, withIntermediateDirectories: true)
    }

    func serve() -> Int32 {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id: Any = request["id"] ?? NSNull()
            let op = request["op"] as? String ?? ""
            if op == "quit" {
                write(["id": id, "ok": true])
                return 0
            }
            do {
                var reply = try handle(op, request, id: id)
                reply["id"] = id
                write(reply)
            } catch {
                write(["id": id, "error": "\(error)"])
            }
        }
        return 0
    }

    private func ensureGenerator() throws -> LlamaGenerator {
        if let generator { return generator }
        let paths = try LlamaModels.locateChat()
        let created = try LlamaGenerator(
            paths: paths,
            log: indexFolder.appendingPathComponent("chat.log")
        )
        self.generator = created
        return created
    }

    private func handle(_ op: String, _ request: [String: Any], id: Any) throws -> [String: Any] {
        switch op {
        case "status":
            let paths = try? LlamaModels.locateChat()
            let slots = (try? FileManager.default.contentsOfDirectory(atPath: cagFolder.path))?
                .filter { $0.hasSuffix(".kv") }
                .map { String($0.dropLast(3)) } ?? []
            return [
                "ready": paths != nil,
                "model": paths?.model.lastPathComponent ?? NSNull(),
                "lora": (generator?.loraPath ?? paths?.loraAdapter)?.lastPathComponent ?? NSNull(),
                "threads": LlamaGenerator.chatThreads,
                "cag_slots": slots,
            ]

        case "load_lora":
            guard let path = request["path"] as? String, !path.isEmpty else {
                throw CLIError("load_lora requires a path to a .gguf LoRA adapter")
            }
            let gen = try ensureGenerator()
            try gen.applyLoraAdapter(at: URL(fileURLWithPath: path))
            return ["ok": true, "lora": path]

        case "cag_pin":
            let slot = (request["slot"] as? String ?? "default").replacingOccurrences(of: "/", with: "_")
            let paths = request["paths"] as? [String] ?? []
            let gen = try ensureGenerator()
            let store = try IndexStore(directory: indexFolder)
            let searcher = try Searcher(store: store, loadVectors: false)
            var combined = "<|im_start|>system\nYou are DigUp Local AI, a 100% private assistant with access to the user's pinned local files.\n"
            for filePath in paths {
                var segIDs: [Int64] = []
                try store.db.query("""
                    SELECT s.id FROM segments s JOIN files f ON f.id = s.file
                    WHERE f.path = ? AND s.kind != 'name' ORDER BY s.loc LIMIT 12
                    """, [.text(filePath)]) { segIDs.append($0.int(0)) }
                let snippets = segIDs.compactMap { try? searcher.text(ofSegment: $0) }.joined(separator: "\n")
                if !snippets.isEmpty {
                    combined += "\n### Pinned File: \(filePath)\n\(String(snippets.prefix(2400)))\n"
                }
            }
            combined += "<|im_end|>\n"
            let kvFile = cagFolder.appendingPathComponent("\(slot).kv")
            let stats = try gen.buildAndSaveCAGSlot(prefixText: combined, to: kvFile)
            return ["ok": true, "slot": slot, "tokens": stats.tokens, "ms": stats.ms]

        case "chat":
            let query = request["q"] as? String ?? ""
            let isCode = request["code"] as? Bool ?? false
            let maxTokens = request["max_tokens"] as? Int ?? 512
            let cagSlot = request["cag_slot"] as? String
            let gen = try ensureGenerator()

            let store = try IndexStore(directory: indexFolder, file: isCode ? IndexStore.codeFile : IndexStore.mainFile)
            let searcher = try Searcher(store: store, loadVectors: false)
            let hits = try searcher.search(query, queryVector: nil, limit: 6)
            let graphPieces = try searcher.retrieveGraphContext(query: query, seeds: hits, hops: 1, maxSeeds: 4, maxNeighbors: 3)

            var cagLoaded = false
            if let slot = cagSlot, !slot.isEmpty {
                let kvFile = cagFolder.appendingPathComponent("\(slot).kv")
                if FileManager.default.fileExists(atPath: kvFile.path) {
                    _ = try? gen.loadCAGSlot(from: kvFile)
                    cagLoaded = true
                }
            }

            var contextBlock = ""
            var citations: [[String: Any]] = []
            for (idx, piece) in graphPieces.enumerated() {
                let fileName = (piece.path as NSString).lastPathComponent
                let locLabel = piece.loc.map { "loc:\(Int($0))" } ?? "full"
                contextBlock += "[\(idx + 1)] \(fileName) (\(locLabel), hop=\(piece.hop)):\n\(piece.text)\n\n"
                var cite: [String: Any] = [
                    "index": idx + 1, "path": piece.path, "kind": piece.kind,
                    "segment_id": piece.segmentID, "hop": piece.hop,
                ]
                if let loc = piece.loc { cite["loc"] = loc }
                if let via = piece.linkedVia { cite["linked_via"] = via }
                citations.append(cite)
            }

            let prompt: String
            if cagLoaded {
                prompt = "<|im_start|>user\nRetrieved Context:\n\(contextBlock)\nQuestion: \(query)\nCite sources using [1], [2].<|im_end|>\n<|im_start|>assistant\n"
            } else {
                prompt = """
                <|im_start|>system
                You are DigUp Local AI, a 100% private offline assistant running on the user's PC. Answer strictly using the retrieved local files and GraphRAG context below, citing sources with [1], [2].<|im_end|>
                <|im_start|>user
                Retrieved Context:
                \(contextBlock)
                Question: \(query)<|im_end|>
                <|im_start|>assistant
                """
            }

            let started = Date()
            let answer = try gen.generate(prompt: prompt, maxNewTokens: maxTokens, keepPrefix: cagLoaded) { tokenPiece in
                self.write(["event": "token", "id": id, "token": tokenPiece])
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return [
                "answer": answer,
                "citations": citations,
                "cag_used": cagLoaded,
                "ms": ["generate": elapsed],
            ]

        default:
            throw CLIError("unknown chat-service op \(op)")
        }
    }

    private func write(_ fields: [String: Any]) {
        output.withLock { emit(fields) }
    }
}

func chatService(_ args: Arguments) throws -> Int32 {
    try ChatService(indexFolder: args.indexFolder).serve()
}

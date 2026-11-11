# Phase 2 Report: Model Management (`Qwen2.5-3B` / `1.5B` GGUF & LoRA Adapters)

## 1. Completed Actions

1. **Extended `Sources/DigUpKit/ModelFiles.swift`**:
   - Parameterized `ModelFiles.File` with `repository` and `revision` while preserving backward-compatible defaults for `EmbeddingGemma 2`.
   - Added `ModelFiles.chatDefault` (`qwen2.5-3b-instruct-q4_k_m.gguf`, 2.10 GB, `Qwen/Qwen2.5-3B-Instruct-GGUF`) and `ModelFiles.chatTurbo` (`qwen2.5-1.5b-instruct-q4_k_m.gguf`, 1.12 GB, `Qwen/Qwen2.5-1.5B-Instruct-GGUF`) with SHA-256 checksums.
2. **Extended `Sources/LlamaRuntime/LlamaModels.swift`**:
   - Added `ChatModelPaths` and `LlamaModels.locateChat(customModel:customLora:)` supporting:
     - Explicit user-configured `.gguf` model paths (`DIGUP_CHAT_MODEL` or Settings UI).
     - Optional fine-tuned LoRA adapter `.gguf` files (`DIGUP_LORA_ADAPTER` or Settings UI).
     - Automatic fallback from `qwen2.5-3b-instruct-q4_k_m.gguf` to `qwen2.5-1.5b-instruct-q4_k_m.gguf` in the `Models` directory.
3. **Extended `Sources/digup/DownloadModel.swift`**:
   - Added `--chat` and `--turbo` flags to `digup download-model` with resumable HTTP range downloads and SHA-256 verification.

---

## 2. Obstacles & Edge Cases Addressed

- **Decoupled First-Launch Indexing from Optional Chat SLM Download**:
  - Downloading 865 MB (`EmbeddingGemma 2`) + 1.93 GB (`Qwen2.5-3B`) simultaneously on first launch could stall onboarding on slower connections. By keeping `ModelFiles.all` scoped to `EmbeddingGemma 2` and exposing `--chat` / `--turbo` (plus local `.gguf` file selection), search indexing starts immediately while the chat SLM downloads on demand or loads from an existing local GGUF file.
- **Zero-Duplicate Storage for Fine-Tuned Weights**:
  - Instead of exporting a new 2 GB merged GGUF every time the user fine-tunes on their `.jsonl` data, `locateChat` resolves a base `.gguf` model + a lightweight `.lora.gguf` adapter (typically 15–40 MB), saving gigabytes of disk space and allowing instant adapter switching.

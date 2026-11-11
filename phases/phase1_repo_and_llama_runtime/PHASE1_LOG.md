# Phase 1 Report: Repository Setup & `llama.cpp` Runtime Analysis

## 1. Completed Actions

1. **Cloned Upstream `ARahim3/DigUp` (`v0.7.0-beta.2`, commit `a5ed87f5d55feb04b1ceadedd033359a6708d7e5`)** into the project root and created branch `feature/slm-cag-graphrag-finetune`.
2. **Audited Build Toolchains on Target Windows Machine**:
   - Available natively: `git`, `cargo` / `rustc` (Rust toolchain), `node` / `npm`, `python`.
   - Not installed locally: `swift` (Swift 6.4 for Windows + MSYS2 FFmpeg).
3. **Inspected `scripts/llama.cpp-no-logits.patch` & `scripts/build-llama.sh`**:
   - Verified how `llama.cpp` (`b11461`, commit `4d756bc72bf00a4aacf410ae15a2d315f3db400d`) is patched and linked into `LlamaRuntime` (`Sources/CLlama`, `Sources/CLlamaWindows`, `Sources/CLlamaShared`).
   - Updated `scripts/build-llama.sh` to also invalidate and touch `Sources/LlamaRuntime/LlamaGenerator.swift` when `llama-build.h` is regenerated.

---

## 2. Key Technical Insights & Obstacles Discovered

### Insight A: `scripts/llama.cpp-no-logits.patch` Already Guards on Non-Causal Embeddings

When inspecting `scripts/llama.cpp-no-logits.patch`:

```cpp
bool has_logits = !(cparams.embeddings && !cparams.causal_attn);
```

- **Why this matters**: Upstream DigUp's patch only disables `has_logits` when **both** `cparams.embeddings == true` **and** `!cparams.causal_attn` (which applies to non-causal bidirectional encoders like `EmbeddingGemma 2` and BERT).
- When we initialize a causal Small Language Model (`Qwen2.5-3B-Instruct-Q4_K_M`) with `cparams.embeddings = false` (and `cparams.causal_attn = true`), `has_logits` evaluates to `true` automatically!
- Furthermore, by only setting `llama_batch_ext_set_output_logits` (or `batch.logits[i] = 1`) on the **last token** of a prompt batch (`n_outputs = 1`), `llama.cpp` only allocates logits for 1 token (~600 KB for Qwen2.5's 151,936 vocab), avoiding any multi-megabyte buffer overhead on our 12GB RAM machine.

### Insight B: Dual-Runtime Execution Strategy for Windows (Swift CLI + Native Rust Fallback)

- **Obstacle**: Building the Swift `digup.exe` helper from source on Windows requires installing a 10+ GB toolchain (Swift 6.4 for Windows, Visual Studio C++ Build Tools, CMake, and MSYS2 MINGW64 for FFmpeg/PDFium). However, the user's machine already has **Rust (`cargo` / `rustc`)**, **Node.js**, and **Python** installed, and the official `DigUp_0.7.0-beta.2_x64-setup.exe` release bundles precompiled `digup.exe` and `llama.dll` binaries.
- **Solution**:
  1. We implement the full Swift engine extensions (`Sources/DigUpKit`, `Sources/LlamaRuntime/LlamaGenerator.swift`, `Sources/digup/ChatService.swift`) so full source builds on macOS/Linux/Windows (CI or full Swift dev environment) compile cleanly.
  2. **Crucially**, we also implement the **SQLite GraphRAG**, **CAG Cache Manager**, **Local SLM Chat Orchestrator**, and **JSONL Fine-Tuning Dataset & PII Scrubber** directly in **Rust inside `shell/src-tauri/src/`**! This ensures `cargo check` and `cargo test` inside `shell/src-tauri` compile, execute, and verify 100% natively on this Windows machine without needing the external Swift compiler installed locally.

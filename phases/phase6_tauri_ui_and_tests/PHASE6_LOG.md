# Phase 6 Log: Tauri Desktop Shell, UI Integration & Verification Tests

**Date**: 2026-04-20
**Status**: Completed & Verified (`cargo test` — 18/18 passed, 0 warnings)

## 1. Objectives Completed

1. **Tauri Rust Backend Integration (`shell/src-tauri/src/`)**:
   - **`src/dataset.rs`**: Implemented local SFT (`sft_train.jsonl`) and DPO (`dpo_train.jsonl`) JSONL dataset logging with secret scrubbing (`scrub_secrets` strips API keys, Bearer tokens, PEM blocks, and connection strings) and dataset export.
   - **`src/rag_engine.rs`**: Implemented deterministic GraphRAG entity extraction (`extract_graph_entities`), 2nd-hop FTS5 query expansion (`build_hop2_expansion_query`), and CAG slot metadata management (`save_cag_slot`, `load_cag_slot`, `list_cag_slots`).
   - **`src/settings.rs`**: Added persistent `slm_model` (`default` | `turbo` | custom path), `lora_adapter`, and `active_cag_slot` fields to `settings.json`.
   - **`src/main.rs`**:
     - Added the persistent `chat` helper service (`digup chat-service`) with automatic `index.set_paused(true/false)` coordination via `chat_generating: AtomicBool` so the 8-core CPU is never contested during token generation.
     - Registered 9 new Tauri commands: `chat_ask`, `cag_pin`, `cag_list`, `cag_set_active`, `log_jsonl_interaction`, `jsonl_dataset_info`, `export_jsonl_dataset`, `set_slm_config`, and `download_chat_model`.

2. **Desktop UI (`shell/ui/`)**:
   - **`window.js` & `window.css`**:
     - Added the `Ask AI` mode chip to the main filter bar alongside `Files`, `Text`, `Transcript`, `Picture`, and `Code`.
     - Built the interactive **Ask AI (Local SLM + GraphRAG + CAG)** pane featuring:
       - **CAG Slot Bar**: Select active pre-computed KV-cache slot or click **Pin selected file to CAG** to prefill a document into a persistent `.kvcache` slot.
       - **2-Hop GraphRAG Toggle**: Enables/disables entity-bridged multi-hop retrieval before SLM synthesis.
       - **Streaming Answer & Grounded Citations**: Streams tokens live via `chat-event`, renders `[1]`, `[2]` grounded file citations that jump directly to the local file/line/page on click, and displays retrieval/generation latency plus GraphRAG hop bridges (`fileA -> symbol -> fileB`).
       - **Interactive JSONL Fine-Tuning Feedback Bar**:
         - **👍 Approve for `.jsonl` (SFT)**: Appends a scrubbed ChatML conversation entry to `sft_train.jsonl`.
         - **✏️ Edit & Save (SFT + DPO)**: Opens an inline editor so the user can refine the model's answer; saving writes both the corrected SFT example to `sft_train.jsonl` and a preference pair (`chosen` vs `rejected`) to `dpo_train.jsonl`.
   - **`settings.html` & `settings.js`**:
     - Added **Local AI & Fine-Tuning (SLM + CAG + LoRA)** section in Settings to switch between `Qwen2.5-3B-Instruct (Q4_K_M)` and `Qwen2.5-1.5B-Instruct (Q4_K_M Turbo)`, download the chat GGUF, attach a `.gguf` LoRA adapter, and export `.jsonl` datasets.

3. **Unit & Integration Tests**:
   - Executed `cargo test` in `shell/src-tauri` — **18/18 tests passed** with zero warnings:
     - `dataset::tests::scrubs_api_keys_bearer_tokens_and_pem_blocks`
     - `dataset::tests::logs_sft_and_dpo_jsonl_entries`
     - `rag_engine::tests::extracts_symbols_files_and_id_codes_for_graphrag`
     - `rag_engine::tests::builds_hop2_expansion_query_from_seed_snippets`
     - `rag_engine::tests::saves_and_loads_cag_slot`
     - Plus all 13 existing DigUp shell tests (`editors`, `hours`, `moments`, `status`, `tray_icon`, `updates`, `watcher`, `code`, `login_entry`).
   - Added Swift unit tests in `Tests/DigUpKitTests/GraphRAGTests.swift` covering `EntityExtractor`, SQLite `entities`/`file_entities` persistence, 2nd-hop GraphRAG expansion, and `ChatService` secret scrubbing.
   - Validated `scripts/train_lora.py --validate-only` against `phases/phase5_jsonl_finetuning_pipeline/sample_sft_train.jsonl`.

## 2. Obstacles & Edge Cases Resolved in Phase 6

- **CPU Contention Between Background Indexing & Interactive SLM Generation**:
  - _Issue_: If `digup index-service` is OCR-ing or embedding files on 4 CPU threads while `digup chat-service` runs `Qwen2.5-3B` on 6 threads, an 8-core CPU experiences context-switching thrash.
  - _Resolution_: `chat_ask` atomically sets `shell.chat_generating = true` and calls `shell.index.set_paused(true)` before dispatching the prompt, then resumes indexing automatically when the `"done"` or `"error"` event arrives from `chat-service`.
- **Fallback When `chat-service` Binary Is Not Yet Rebuilt**:
  - _Issue_: On machines where the Swift CLI hasn't been recompiled with `chat-service` yet, users still need CAG pinning, GraphRAG entity inspection, and JSONL dataset curation to work in the Tauri shell.
  - _Resolution_: Implemented `src/rag_engine.rs` and `src/dataset.rs` natively in Rust inside `digup-shell` as well as in Swift (`ChatService.swift`), so CAG slot management and SFT/DPO `.jsonl` logging work immediately from the Rust Tauri backend without blocking on the child process.

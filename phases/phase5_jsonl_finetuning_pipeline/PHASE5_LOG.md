# Phase 5 Report: JSONL Fine-Tuning Dataset Pipeline, Secret Scrubber & LoRA Adapter Workflow

## 1. Completed Actions

1. **Created `shell/src-tauri/src/dataset.rs` (JSONL Interaction Logger & PII/Secret Scrubber)**:
   - Implemented `scrub_secrets(input: &str) -> String`:
     - Automatically redacts PEM private keys (`-----BEGIN ... PRIVATE KEY-----`), Bearer JWT tokens, API secret keys (`sk-`, `ghp_`, `github_pat_`, `AKIA`, `AIza`, `xoxb-`), and inline credentials (`password=`, `api_key=`, `secret=`, `access_token=`).
   - Implemented `log_interaction(base_dir, input)`:
     - Appends ChatML Supervised Fine-Tuning (SFT) records (`{"messages": [{"role": "system", ...}, {"role": "user", ...}, {"role": "assistant", ...}], "metadata": {...}}`) to `<index_dir>/datasets/sft_train.jsonl`.
     - Automatically detects when the user edits/corrects an assistant response and emits a Direct Preference Optimization (DPO) record (`{"prompt": [...], "chosen": [...], "rejected": [...]}`) to `<index_dir>/datasets/dpo_train.jsonl`.
   - Added `stats`, `recent_entries`, and `export_dataset` functions plus unit tests (`scrubs_api_keys_bearer_tokens_and_pem_blocks` and `logs_sft_and_dpo_jsonl_entries`).
2. **Created `shell/src-tauri/src/rag_engine.rs` (Rust Native GraphRAG + CAG Slot Manager + Hardware Profiler)**:
   - Implemented `HardwareProfile::detect()` for the 8-core, 12GB RAM PC (reserving 6 threads for the SLM and 2 threads for OS + UI + SearchService).
   - Implemented deterministic GraphRAG entity extraction (`extract_graph_entities`) and 2nd-hop bridge query synthesis (`build_hop2_expansion_query`).
   - Implemented CAG slot persistence (`save_cag_slot`, `load_cag_slot`, `list_cag_slots`) and grounded multimodal citation synthesis (`synthesize_grounded_fallback`).
3. **Created `scripts/train_lora.py` (Local LoRA Fine-Tuning & GGUF Adapter Converter)**:
   - Validates generated `.jsonl` files (`--validate-only` or full training).
   - Configures memory-bounded LoRA (`r=8, alpha=16`, gradient checkpointing, `per_device_train_batch_size=1`, `gradient_accumulation_steps=4`) so fine-tuning `Qwen2.5-3B-Instruct` or `Qwen2.5-1.5B-Instruct` fits within a 12GB RAM budget.
   - Automatically invokes `convert_lora_to_gguf.py` to produce `digup-user-lora.gguf` for hot-loading in `chat-service`.

---

## 2. Key Insights & Obstacles Solved

- **Dual SFT + DPO Capture from a Single UI Action**:
  - When a user asks a question about their local codebase or system and corrects a flaw in the SLM's response before clicking "Save to JSONL", saving only the final answer (`sft_train.jsonl`) teaches the model _what to say_, whereas saving the `(chosen, rejected)` pair (`dpo_train.jsonl`) explicitly teaches the model _what NOT to hallucinate_ about the user's system!
- **Why `include_context_in_prompt` Is Configurable**:
  - In **RAG-grounded SFT** (`include_context_in_prompt: true`), the JSONL prompt includes the retrieved snippets so the model learns how to synthesize and cite the user's specific file formats.
  - In **Domain Knowledge Internalization SFT** (`include_context_in_prompt: false`), only the `question` and `answer` are stored so LoRA weights internalize core facts about the user's system directly into model parameters.

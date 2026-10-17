# Han body search and complete text embeddings

This change is based on upstream `ec28973268b81f836be72187ff23b3a16ef4fd97`.

## Scope

- Index Han characters in document, PDF, OCR, code, and folder bodies as adjacent FTS tokens. Quoted query phrases preserve contiguity; punctuation and whitespace cannot disappear between characters.
- Keep `fts.name` normalized and **unspaced**, including after moves and migration. This preserves whole-name/prefix search and compatibility with the separate filename substring proposal (`instr(fts.name, ...)`). No filename trigram index is added.
- Highlight original text, including mixed Latin/Han text, without exposing indexing separators. Keep excerpts bounded for unspaced Han.
- Split complete title-plus-body prompts against the runtime tokenizer, including special tokens. Preserve document continuation offsets and PDF page/code line locations. Remove the old 4,000-character code-line cut and PDF text prefix cut. Both runtimes reject oversized requests instead of silently truncating them.
- Forward token counts through the JSON-lines worker and the indexing service's shared-model wrapper.

No app identity, index location, media recovery/ranking, startup, localization, packaging, or model-version changes are included.

## Existing indexes

Schema 5 becomes schema 6 in one transaction. Bodies are rebuilt from `coalesce(original, body)`; names, vectors, file state, and segment locations remain intact. Migration does not read source files or require them to be connected. Older binaries cannot open schema 6, as with other schema upgrades.

An old vector may already have lost a long passage's tail. Migration cannot reconstruct missing source text or replace those embeddings without reading the file and loading the tokenizer. The new splitting applies to new/changed files. To repair unchanged files, explicitly reindex when their folders are available, for example:

```sh
digup index /path/to/folder --index /path/to/index --reindex
```

`--reindex` resets the selected index, so include all folders that belong in it; it is not a per-file repair command. Use the corresponding code index with `--code` when needed. Keep an index backup if rollback to an older binary is required.

## Regression coverage

`ChineseSearchTests`, `TextBudgetTests`, `CodeTests`, and `WorkerBudgetTests` cover body phrase contiguity, original snippets, supplementary-plane Han, filename compatibility, schema-5/offline-cache preservation, overlap, tail coverage, multi-pass documents, >4,000-character code lines, source line focus, impossible per-file budgets, and token-count protocol validation.

`NativeTextBudgetTests` uses the actual pinned model when available. It checks oversized-input rejection, every synthetic record and final marker surviving a tokenizer-budget split, and finite 768-dimensional inference vectors. It explicitly skips without the model, which is not an inference pass. Python worker contract tests use deterministic stubs and do not load MLX:

```sh
python -m unittest discover -s worker -p test_text_budget.py -v
```

### Measured before/after (Linux, Swift 6.2)

- Same nine public synthetic keyword-only cases: upstream R@1 **2/9**, this change **9/9**. This is a narrow lexical regression corpus, not a multilingual semantic ranking benchmark.
- Actual pinned text model, query encoder's 512-token budget: upstream accepts a 3,013-token input and two different tails produce identical vectors. This change returns an explicit over-budget error.
- Actual tokenizer: 180 synthetic Han records plus a final marker become five complete parts within 512 tokens; every record survives and two inference vectors are validated.
- Full upstream suite: 92 tests, seven assertion issues. Full changed suite: 113 tests, the same seven baseline issues, no additional failures. Six are portable TIFF/HEIC/WebP orientation assertions with this environment's image reader; one is `placeInItsRepo` encountering the sandbox's synthetic `.git` parent. The final run excluding those two affected test functions passes all **111 selected tests with no skips**, including the actual-model budget tests and existing media/text `ReferenceVectorTests` with both pinned models. The long-document reference passes; no reference vectors or model version were changed.
- Python tokenizer contract: three tests pass.

For Linux native model runs, set `DIGUP_MODELS` to the model folder and `DIGUP_BACKENDS` to `Vendor/llama/lib`; a development test binary does not carry ggml backend modules beside itself. All model files are pinned by `ModelFiles` and checksum-verified.

The upstream `evals/` semantic suites need their generated `DigUpTestbed` source corpus, which is not bundled here. They are not claimed as run. macOS PDF extraction/rendering, Apple frameworks, and packaged-app validation remain separate from Linux engine validation.

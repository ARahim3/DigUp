---
name: digup
description: Search and retrieve local source code, PDFs, documents, screenshots, images, audio transcripts, and video frames using the DigUp local semantic + keyword search index (EmbeddingGemma 2 + SQLite FTS5). Use when searching across codebases or inside the current repo by meaning ("where do we retry with backoff?", "how are embeddings quantized?"), finding symbol definitions across repos, or looking up local PDFs, notes, screenshots, or recordings.
---

# DigUp CLI (`digup`)

DigUp is a local multimodal semantic + keyword search engine for macOS, Windows and Linux. It maintains two indexes in its index folder:

- macOS: `~/Library/Application Support/DigUp/index.noindex/`
- Windows: `%LOCALAPPDATA%\DigUp\index\`
- Linux: `$XDG_DATA_HOME/digup/index/` (default `~/.local/share/digup/index/`)

The indexes:

1. **Main index (`index.sqlite`, default)**: Screenshots, images, PDFs (with page numbers), documents (`.md`, `.txt`, `.docx`, `.pptx`, `.xlsx`, `.rtf`, `.html`), audio recordings (Whisper transcripts with timestamps), and videos (frames + transcripts with timestamps).
2. **Code index (`code.sqlite`, `--code`)**: Source code, configs, shell scripts, and Jupyter notebooks across indexed repositories, chunked at blank-line boundaries into ~45-line stretches (`loc`..`loc_end`) with automatic definition line detection (`focus`).

Every search blends **vector similarity** (768-d Matryoshka embeddings from EmbeddingGemma 2, normalized to a per-query z-score across the index) with **SQLite FTS5 BM25 keyword search** and **symbol definition ranking**.

## Binary Location

Run `digup` directly if it's on `PATH` (`scripts/install-cli.sh` puts it at `~/.local/bin/digup` on macOS and Linux; `scripts/install-cli.ps1` adds the app's helper folder to the user `PATH` on Windows). Otherwise invoke the copy inside the installed app:

- macOS: `/Applications/DigUp.app/Contents/Helpers/digup`
- Windows: `%LOCALAPPDATA%\DigUp\helper\digup.exe` (PowerShell: `& "$env:LOCALAPPDATA\DigUp\helper\digup.exe"`)
- Linux (.deb): `/usr/lib/DigUp/helper/digup`

On Windows, paths work in either form (`C:\src\repo` or `C:/src/repo`) and scopes ignore case, as Windows does.

## Quick Reference

```bash
# 1. Search code in the current repo (automatically maps git worktrees to the main repo)
digup search --code --here "hybrid search score fusion" --text -n 5

# 2. Search code across ALL indexed repositories on this computer
digup search --code "exponential backoff retry" --text -n 5

# 3. Fast keyword + symbol definition lookup (~10 ms, skips model & vector loading)
digup search --code --here --keyword "Searcher" --text -n 5

# 4. Search personal files (PDFs, docs, screenshots, audio, video)
digup search "tax receipt" --kind pdf,doc --text -n 5

# 5. Search BOTH personal files and code in a single pass
digup search --all "sqlite wal checkpoint" --text -n 10

# 6. Inspect full stored text of a segment ID or all segments of a file
digup show 48219
digup show Sources/DigUpKit/Searcher.swift

# 7. Check index health and whether the current repo is indexed
digup status --all
digup status --code --here
```

## When to Use `digup` vs `rg`

| Need | Best Tool |
|---|---|
| Exact string or regex in the current working tree | `rg` / `grep` |
| Conceptual / "how does X work" search in the current repo | `digup search --code --here "<question>" --text` |
| Finding how another repo on the user's machine solves a problem | `digup search --code "<concept>" --text` |
| Finding a symbol definition across multiple repos in ~10 ms | `digup search --code --keyword "<SymbolName>" --text` |
| Finding a PDF, screenshot, note, deck, or audio/video recording | `digup search "<query>" --text` |

> **Git Worktree Note**: DigUp skips indexing git worktrees directly and indexes the main repository checkout instead. When you pass `--here` (`-C`) or `--in <worktree-path>`, `digup` automatically resolves the `.git` worktree pointer back to the main repository path so scoped searches work seamlessly inside Claude Code and Antigravity worktrees.

## Commands & Flags

### `digup search [options] <query>`

| Flag | Description |
|---|---|
| `--code` | Search the code index (`code.sqlite`). Prefixing the query with `code:` does the same. |
| `--all` | Search both `index.sqlite` and `code.sqlite` using a single query-encoder pass. |
| `-C`, `--here` | Scope results to the current working directory (resolves git worktrees to their main repo path). |
| `--in <path>` | Scope results to a folder or file path. Repeatable (`--in ~/dev/repoA --in ~/dev/repoB`). |
| `--kind <k1,k2>` | Filter by file kind: `screenshot`, `image`, `pdf`, `doc` (or `document`), `audio`, `video`, `code`. |
| `-n <count>` | Maximum number of results to return (default `10`). |
| `--text` | Print the full stored text of each matched segment (numbered by source line for code). |
| `--keyword` | Fast FTS5 keyword + symbol definition search only (skips loading GGUF model and vectors). |
| `--strong` | Keep only strong hits (scores $\ge 0.5\times$ the top result's score; hides weaker tail matches). |
| `--json` | Output structured JSON array. |
| `--zgate <float>` | Minimum z-score threshold for semantic matches (default `2.0`; `--z-gate` also accepted). |
| `--word-weight <float>` | Weight given to keyword rank vs semantic z-score (default `1.2`). |

### `digup show [options] <segment-id | file>...`

Fetches the full stored text and metadata for one or more segment IDs (`seg <id>` from search output) or file paths without loading the embedding model or vectors.

- Checks `index.sqlite` then `code.sqlite` automatically unless `--code` or `--all` is specified.
- Supports `--json` for structured output (`segment_id`, `kind`, `segment`, `path`, `loc`, `loc_end`, `excerpt`, `text`).

### `digup status [--code | --all] [--in <path> | --here] [--json]`

Reports vector counts, segment counts, file counts by kind and state (`done`, `pending`, `skipped`, `failed`), unfinished long files, and database size. Combine with `--code --here` to verify whether the current repository is indexed in `code.sqlite`.

### `digup index [--code] [--limit <n>] [<folder>...]`

Incrementally syncs and indexes folders (defaults to the folders configured in the DigUp app).

## Interpreting Results & JSON Fields

When `--json` is passed to `digup search`, each element in the returned array has:

```json
{
  "cosine": 0.4812,
  "excerpt": "public func search(_ query: String, ...",
  "focus": 133,
  "info": {
    "lines": "515",
    "repo": "/path/to/DigUp"
  },
  "keyword_rank": 1,
  "kind": "code",
  "loc": 133,
  "loc_end": 182,
  "modified": 1761860000,
  "path": "/path/to/DigUp/Sources/DigUpKit/Searcher.swift",
  "score": 3.551,
  "segment": "lines",
  "segment_id": 217121,
  "size": 24190,
  "strong": true,
  "text": "public func search(...)",
  "z": 4.751
}
```

- `path`: Absolute path on disk.
- `loc` / `loc_end`:
  - `code`: 1-based start and end line numbers (`lines 133–182`), or notebook cell numbers (`segment == "cells"`).
  - `pdf`: 1-based page number.
  - `document`: 1-based part/chunk number.
  - `audio` / `video`: Start and end timestamps in seconds.
- `focus`: Exact 1-based line number within `loc`..`loc_end` where a queried symbol is defined or where query keywords first appear.
- `z`: Standard deviations above the index mean cosine similarity for this query (`z >= 2.5` is meaningful; `z >= 4.0` is a strong semantic match).
- `keyword_rank`: 1-based BM25 / symbol-lookup rank if matched by words (omitted for pure semantic matches).
- `strong`: `true` if `score >= 0.5 * top_score`.
- `segment_id`: Segment ID (`seg <id>` in text output) that can be passed to `digup show <segment_id>`.

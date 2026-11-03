# Stage 3 — engine adapter + contract tests: the server speaks DigUp's own protocols

Date: 2026-11-02. The adapter is the server's window on the engine: `server/digup_server/engine/`
spawns the documented `search-service` / `index-service` JSON-lines helpers and the read-only
one-shot CLI, supervises their processes, and passes their replies through **verbatim**.
The contract tests run inside the shipped engine payload (`server-test` Docker stage) against
the real engine, real corpus, real model, real index — no mocks, by the rules
([README.md](README.md) §8, §10.2).

## The adapter

| file | role |
|---|---|
| `config.py` | `EngineConfig`: one frozen record — index, roots, binary, excludes, `DIGUP_MODELS`, `--encoder-idle` — and every argv list (`search_argv`, `index_argv`, `status_argv`, `estimate_argv`, `speed_argv`). `--index` is always explicit (the CLI default is the desktop app's folder); `DIGUP_MODELS` is pinned so a stray cache can't feed the engine a different model. |
| `protocol.py` | `JsonLinesProcess`: spawn, reader thread, replies routed by `id`, event queue, `EngineExited` with the stderr tail. No `shell=True`, no wrappers (see §Supervision). Plain-text lines via `send_line`. Stdin writes serialized by a lock so lines never interleave. |
| `search.py` | `SearchService`: one method per documented op (`search`, `embed_ahead`, `text`, `render`, `reload`, `status`, `summaries`, `prewarm`, `folders`, `quit`) + `raw` passthrough. Idle-exit (`--encoder-idle`, self-exit at 2×) is treated as a **restart, not a failure**: the next request respawns and replays the last `folders` change. Requests serialized: one query in flight, encoder warm for the typist. |
| `index.py` | `IndexService`: plain-line commands (`sync`, `sync code`, `stop`, `backfill on/off`), event stream, and the server's **single writer**: `flock` on `<index>/.digup-server.writer.lock` held exactly as long as the helper lives; a second writer gets `IndexBusy` and never races the first. EOF (close stdin) = stop, the engine's own rule. `run_sync` starts the service if it isn't running — it idles out between jobs, so a job *is* a spawn. |
| `cli.py` | `status` parsed from the CLI's own lines (unparseable fields stay `None`, never guessed); `estimate --json` + plain `estimate`; `speed --model --json` → the single `{"event":"speed",…}` line (kinds, load, device, agreement). |

## Protocol facts, pinned from source and probe

From `Sources/digup/SearchService.swift` / `IndexService.swift` (headers + `emit` call sites),
verified live in the container:

1. **search-service** opens with `{"event":"ready","index":…}`; replies carry the request's
   `id`; errors answer `{ok:false, error}` (`unknown op: …`); `render` writes a real JPEG
   under `<index>/previews` and answers its path; `status.vectors` is **0 until the vectors
   load** — a fresh searcher loads lazily, so the post-indexing flow is `reload` → `prewarm`
   (the desktop shell's own sequence).
2. **search-service self-exit** at 2×`--encoder-idle` (`{"event":"exit","reason":"idle"}`) is
   normal service: the engine *expects* the shell to start it again. The adapter does,
   transparently — tested with `--encoder-idle 2` (search → 6 s sleep → engine gone → search
   again, same hits).
3. **index-service event semantics** (probed live, not guessed): the first `sync` event
   carries the **crawl** counts (`new` = queued to index); the engine re-syncs between
   batches, so mid-stream `sync` events are transient (searchable can read 0 mid-run);
   the post-index truth rides the **`idle`** event (`files, searchable, pending, vectors,
   unfinished`); then `exit` after `--linger`. A missing folder arrives as
   `{"event":"missing","folders":[…]}` and indexing goes on regardless — the engine never
   treats an absent root as "everything deleted".
4. **`estimate --json` streams one JSON line per folder** (readable, per-kind counts,
   seconds, skipped, left_out). It is a ParentWatch helper — see below.

## Supervision (the ParentWatch rule)

`index-service`, `worker`, `search-service`, `download-model` and `estimate --json` all call
`ParentWatch.start()` (`Sources/digup/ParentWatch.swift`). On Linux that is a 1 s `getppid`
loop, and its first line is `guard parent != 1 else { _exit(0) }` — **parent PID 1 means
"the app is gone"**, and the helper exits within a second, silently, exit 0.

This is the root cause of Stage 2's "estimate --json prints nothing" report (corrected,
reconnaissance §15 item 8): the proof's `bash` *is* PID 1's script. The engine was behaving
exactly as designed. The binding rule it leaves the server:

> **The API process is the long-lived parent of every helper.** Spawn helpers as direct
> children (argv lists, `subprocess.Popen`, never through a PID-1 shell wrapper), so
> ParentWatch ties their lifetime to the server's — a killed server takes its helpers with
> it, which is the point of the mechanism. `protocol.py` enforces this; the contract suite
> proves `estimate --json` answers for a live parent (`test_cli.py`).

Consequence for scripts: a PID-1 `bash script` must use plain `estimate` (proof.sh does,
and says why in a comment).

## Test harness

- **Dockerfile stage `server-test`** = `engine-payload` (the shipped binaries) +
  `python:3.12-slim` (measured: Debian 13 trixie, glibc 2.41 — newer than the payload's
  build glibc 2.35, forward never back) + `uv sync --frozen`.
  The suite proves the *shipped payload*, so a green suite is a statement about the runtime
  image, not about a dev box. Image: **465 MB** (arm64).
- `uv` project (`pyproject.toml` + `uv.lock`, repo convention from `worker/`); the adapter
  itself is **stdlib-only** (subprocess/json/fcntl/threading); pytest as dev-group dep.
- The suite **skips itself** when `DIGUP_SERVER_CORPUS` / `DIGUP_SERVER_MODELS` / the binary
  are absent. There is no mock path.

Run (arm64 on this Mac; x86_64 natively on the prod box):

```sh
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 --target server-test \
  -f server/docker/Dockerfile -t digup-server-test:local .

docker run --rm --platform linux/arm64 \
  -v "$PWD/server/tests/corpus/media:/corpus:ro" \
  -v "$PWD/server/tests/corpus:/corpus-root:ro" \
  -v "$HOME/Projects/digup-data/models:/models:ro" \
  -v "$HOME/Projects/digup-data/index:/index" \
  digup-server-test:local
```

The 22 default tests run in ~90 s (the shared index mount is pre-filled by Stage 2; conftest
fills it with `digup index` on a fresh run, ~4 min). `pytest -m slow` adds the model timing.

## The contract suite

`server/tests/` — every expectation is what the engine *says*, from source or from the
Stage-2/Stage-3 probes:

**search** (`test_search_contract.py`, 13): ready handshake; `status` counts (files/searchable/
pending, the corpus inside); `wakeboarding` ranks the wakeboards; hit fields are exactly
`hitFields()` (no invented fields, no re-ranking); `hiking` finds the video *moment* with
`loc` inside the duration; kind filter engine-side; **"no good matches" stays an empty
answer** (the refusal published, not papered over); controls stay out of hits; `summaries`
root counts (12 image / 3 video); `embed_ahead` `{ok:true}`; unknown op → the engine's
`{ok:false, error}`; `render` → real JPEG bytes under `<index>/previews`; **idle-exit →
transparent restart** with the same hits.

**index** (`test_index_contract.py`, 6): sync events count real files (`new == 6`, per-file
events all `done` with the engine's field set, `idle` totals `files 6 / searchable 6 /
pending 0 / vectors ≥ 6`, exit event ends the stream, zero errors); counts land in the index
(`status`: image 4 / video 1 / doc 1); **second writer gets `IndexBusy`**; missing root is
*reported* and indexing continues; `text` returns the passage a hit points at, verbatim;
new file → `run_sync` → `reload` → `prewarm` → vectors moved → the new file searches back.

**cli** (`test_cli.py`, 3 + 1 slow): `status` lines parsed (vectors ≥ 15, build tag,
fingerprint, per-kind); plain `estimate` paragraph; **`estimate --json` answers for the
server as parent** (skipped files counted — the root cause of the Stage-2 report, pinned
as a test); `speed --model --json` (slow mark) reports the device and per-kind multipliers.

## Suite result

2026-11-02, the command above, `digup-server-test:local` (arm64) on this Mac — the run's
own output:

```
......................                                                   [100%]
22 passed, 1 deselected in 88.75s (0:01:28)
```

`pytest -m slow` (the model timing, `speed --model --json`) runs separately:
`1 passed, 22 deselected in 41.43s` — the engine's `{"event":"speed",…}` line with per-kind
multipliers, load seconds and `device: cpu` on this image.

Alongside it, the Stage-2 proof (`server/tests/proof.sh`) re-runs green with the corrected
`estimate` comment (plain estimate is PID-1-correct; the engine's numbers unchanged).

The three assertions the first run caught (19/3) were **adapter/test bugs, not engine
bugs**, and each fix pinned a real fact: `run_sync` must start the idled-out service; the
post-index truth rides the `idle` event (`files 6 / searchable 6 / pending 0 / vectors ≥ 6`),
not the transient mid-stream syncs; and `estimate --json`'s Stage-2 "silence" was ParentWatch's
PID-1 rule, not an engine fault — the corrected finding runs through
[reconnaissance.md](reconnaissance.md) §15 item 8 and
[stage-2-headless-proof.md](stage-2-headless-proof.md).

## What this proves / does not

- **Proves**: the adapter speaks the shipping protocols against the shipped payload —
  replies verbatim, events as the engine emits them, honest empties, the engine's own
  supervision semantics (idle-exit restart, EOF-stop, ParentWatch) handled as designed,
  and the single-writer guarantee enforced outside SQLite.
- **Does not prove**: GPU (no Vulkan/CUDA in this image, by design), scale (15 files),
  concurrency under HTTP load (Stage 4/5), the desktop shell's behaviour.
- Costs measured: suite ≈ 90 s warm index; cold fill ≈ 4 min; a cold `search-service`
  first query pays encoder start-up (~3–6 s on CPU) — the API's `prewarm` story (Stage 4).

## Carried to Stage 4 (the API)

1. FastAPI on top of `SearchService` — never around it; uvicorn is the long-lived parent
   (§Supervision), helpers are its direct children.
2. `/health` publishes engine version, vector source, llama.cpp build tag, device — from
   `status` + `speed` results, read-only.
3. `estimate --json` is usable from the API (the parent rule); plain `estimate` stays for
   humans.
4. Preview policy: read `<index>/previews` via `render` replies, never serve raw paths.
5. The job flow (Stage 5): `IndexService` (lock held) → on finish `SearchService.reload()`
   → `prewarm()` — the tested sequence.

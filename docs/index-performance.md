# Indexing performance

The indexing engine avoids three kinds of repeated work:

- `Database` keeps up to 64 prepared statements per connection. Each query takes its statement out of the cache,
  then resets it and clears its bound values before returning it. Recursive queries use separate statements.
  Statements retained by a caller keep their own ownership. Errors still propagate and transactions still roll back.
- Schema 6 adds `files_queue`, ordered by state, file-kind priority, and descending modification time. Limited queue
  reads can stop after the requested rows instead of sorting every pending file. Migration keeps extracted text and
  vectors. Older DigUp versions reject schema 6, so downgrading requires a separate index or rebuilding it.
- The serial preparation queue keeps one document's chunks during a run. Later steps reuse those chunks after
  checking path, size, modification time, inode, device, and chunk limit. A changed or missing file is read again.
  Only one document is cached, with at most `maxChunks + 1` chunks. Pausing, completion, or an error clears it after
  the outstanding preparation finishes. Nothing is cached on disk.

Search ranking, chunk boundaries, model prompts, and vectors are unchanged. Embedding and PDF rendering still cost
the same. These changes reduce engine overhead; they do not promise the same speedup for total indexing time.

## Benchmark

On macOS, run this from the checkout:

```sh
scripts/benchmark-index.sh
```

It compiles the engine with `swiftc -O`, without llama.cpp or a model, and uses a temporary SQLite database and
document. The script removes its build directory, and the executable removes its test data when it exits normally.
Run the same benchmark against both versions on the same machine, with other heavy work stopped.

Measured on the same Apple Silicon Mac on October 14, 2026, against `f9b8106`. Each number is the median of three
runs using optimized binaries. The document benchmark processes 30 consecutive 40-chunk steps of a 2.2 MB plain
text file, through `Indexer.prepare`. The baseline harness uses the same loop with the cache argument omitted,
because that version has no document cache.

| Operation | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| 100 queue reads, 40 results from 10,000 pending files | 305 ms | 3 ms | About 100x |
| Prepare 30 steps of a long document | 3,195 ms | 115 ms | About 28x |
| Insert 10,000 files and 30,000 text segments in one transaction | 821 ms | 706 ms | About 1.2x |

Insertion times varied substantially, including one 1,778 ms run after the change, so the small insertion gain is
less reliable than the queue and document results. These are synthetic engine measurements, not a live app or
model-throughput benchmark.

Regression tests cover statement bindings, failures and rollback, recursive queries, retained rows, schema changes,
cache eviction, document changes, unchanged chunk boundaries, and queue migration and query planning. The existing
long-file tests cover stopping and resuming indexing and searchable later chunks.

All 91 DigUpKit tests passed in an engine-only temporary Swift package using the checkout's sources and tests.
The normal repository-wide `swift test` command could not build LlamaRuntime because `Vendor/llama/include/llama.h`
is absent in this checkout. Model integration and live app behavior were not tested.

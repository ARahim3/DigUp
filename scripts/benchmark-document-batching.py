#!/usr/bin/env python3
"""Measure end-to-end indexing throughput for a deterministic text-document corpus."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time


PHRASES = (
    "Researchers compare field notes with archived measurements and record the assumptions behind each result.",
    "The engineering team tracks reliability, latency, and memory use across repeated experiments.",
    "A clear description of the source material helps future readers understand the decision and its context.",
    "Several independent observations support the conclusion, while uncertain details remain explicitly marked.",
    "The report summarizes methods, evidence, limitations, and the next steps for the investigation.",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="built digup executable")
    parser.add_argument("--output", required=True, type=Path, help="new directory for corpus, index, log, and summary")
    parser.add_argument("--documents", type=int, default=128)
    parser.add_argument("--characters", type=int, default=400, help="characters per document; keep below 1800 for one chunk")
    args = parser.parse_args()

    binary = args.binary.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not binary.is_file():
        parser.error(f"binary not found: {binary}")
    if args.documents < 1 or args.characters < 200:
        parser.error("documents must be positive and characters must be at least 200")
    if output.exists():
        parser.error(f"output directory already exists; choose a new path: {output}")

    model_dir = Path(os.environ.get("DIGUP_MODELS", Path.home() / "Library/Application Support/DigUp/Models"))
    expected_models = ("embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf")
    missing = [name for name in expected_models if not (model_dir / name).is_file()]
    if missing:
        parser.error(f"model files missing from {model_dir}: {', '.join(missing)}")

    corpus = output / "corpus"
    index = output / "index"
    log_path = output / "index.log"
    corpus.mkdir(parents=True)
    index.mkdir(parents=True)
    for number in range(args.documents):
        prefix = f"Record {number:04d} covers a distinct observation from the benchmark corpus. "
        pieces = [prefix]
        cursor = 0
        while sum(map(len, pieces)) < args.characters:
            pieces.append(PHRASES[(number + cursor) % len(PHRASES)] + " ")
            cursor += 1
        text = "".join(pieces)[: args.characters]
        (corpus / f"record-{number:04d}.txt").write_text(text, encoding="utf-8")

    environment = os.environ.copy()
    environment["DIGUP_MODELS"] = str(model_dir.resolve())
    command = [str(binary), "index", "--index", str(index), str(corpus)]
    started = time.perf_counter()
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=environment, check=False)
    elapsed = time.perf_counter() - started
    if result.returncode:
        print(f"digup exited {result.returncode}; see {log_path}", file=sys.stderr)
        return result.returncode

    database = index / "index.sqlite"
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        states = dict(connection.execute("SELECT state, COUNT(*) FROM files GROUP BY state"))
        chunks = connection.execute(
            "SELECT COUNT(*) FROM segments WHERE kind = 'chunk' AND vec IS NOT NULL"
        ).fetchone()[0]

    summary = {
        "documents": args.documents,
        "characters_per_document": args.characters,
        "indexed_chunk_vectors": chunks,
        "elapsed_seconds": round(elapsed, 3),
        "chunk_vectors_per_second": round(chunks / elapsed, 3) if elapsed else None,
        "file_states": states,
        "binary": str(binary),
        "model_directory": str(model_dir.resolve()),
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    print(f"Full index log: {log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

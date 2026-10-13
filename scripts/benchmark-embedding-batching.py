#!/usr/bin/env python3
"""Compare repeated one-text embedding requests with batches in one persistent DigUp worker."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
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


def inputs(documents: int, characters: int) -> list[str]:
    prompts = []
    for number in range(documents):
        pieces = [f"Record {number:04d} covers a distinct observation from the benchmark corpus. "]
        cursor = 0
        while sum(map(len, pieces)) < characters:
            pieces.append(PHRASES[(number + cursor) % len(PHRASES)] + " ")
            cursor += 1
        text = "".join(pieces)[:characters]
        prompts.append(f"title: record-{number:04d} | text: {text}")
    return prompts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="built digup executable")
    parser.add_argument("--mode", choices=("single", "batch"), required=True)
    parser.add_argument("--documents", type=int, default=128)
    parser.add_argument("--characters", type=int, default=400)
    parser.add_argument("--batch-size", type=int, default=16)
    args = parser.parse_args()

    binary = args.binary.expanduser().resolve()
    if not binary.is_file():
        parser.error(f"binary not found: {binary}")
    if args.documents < 1 or args.characters < 200 or args.batch_size < 1:
        parser.error("documents and batch-size must be positive; characters must be at least 200")

    model_dir = Path(os.environ.get("DIGUP_MODELS", Path.home() / "Library/Application Support/DigUp/Models"))
    expected_models = ("embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf")
    missing = [name for name in expected_models if not (model_dir / name).is_file()]
    if missing:
        parser.error(f"model files missing from {model_dir}: {', '.join(missing)}")

    environment = os.environ.copy()
    environment["DIGUP_MODELS"] = str(model_dir.resolve())
    started = time.perf_counter()
    process = subprocess.Popen([str(binary), "worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1, env=environment)
    assert process.stdin is not None and process.stdout is not None
    ready_line = process.stdout.readline()
    if not ready_line:
        process.kill()
        parser.error("worker exited before it became ready")
    ready = json.loads(ready_line)
    if not ready.get("ready"):
        process.kill()
        parser.error(f"worker did not become ready: {ready.get('error', ready)}")
    startup_seconds = time.perf_counter() - started

    prompts = inputs(args.documents, args.characters)
    width = 1 if args.mode == "single" else args.batch_size
    started = time.perf_counter()
    for offset in range(0, len(prompts), width):
        batch = prompts[offset : offset + width]
        request = {"id": offset, "op": "text", "inputs": batch}
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
        reply_line = process.stdout.readline()
        if not reply_line:
            process.kill()
            parser.error("worker exited during embedding; see the worker's stderr for details")
        reply = json.loads(reply_line)
        if not reply.get("ok") or reply.get("count") != len(batch):
            process.kill()
            parser.error(f"embedding request failed: {reply.get('error', reply)}")
    elapsed = time.perf_counter() - started

    process.stdin.write('{"id":"quit","op":"quit"}\n')
    process.stdin.flush()
    process.stdout.readline()
    process.wait(timeout=10)
    summary = {
        "mode": args.mode,
        "documents": args.documents,
        "characters_per_input": args.characters,
        "request_batch_size": width,
        "startup_seconds": round(startup_seconds, 3),
        "embedding_seconds": round(elapsed, 3),
        "inputs_per_second": round(args.documents / elapsed, 3) if elapsed else None,
        "worker_load_seconds": ready.get("info", {}).get("load_seconds"),
        "binary": str(binary),
        "model_directory": str(model_dir.resolve()),
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""DigUp embedding worker: EmbeddingGemma 2 on MLX (mlx-vlm), one process per session.

Protocol: one JSON object per line on stdin, one JSON reply per line on stdout. Logs go to stderr.
The first line the worker prints is {"ready": true, "info": {...}} once the model is loaded.

  {"id": 1, "op": "info"}
  {"id": 2, "op": "text",  "inputs": ["task: search result | query: cat", ...]}
  {"id": 3, "op": "image", "inputs": ["/tmp/a.jpg", ...], "budget": 280}
  {"id": 4, "op": "audio", "inputs": ["/tmp/a.wav", ...]}
  {"id": 5, "op": "quit"}

Reply: {"id": 2, "ok": true, "dim": 768, "count": N, "vectors": "<base64 float32 LE, N x dim>", "errors": [...]}.
A failed item gets a zero vector and a message in "errors"; a failed request gets {"ok": false, "error": "..."}.
Text inputs arrive already prompted ("task: search result | query: ..."); prompts are the caller's business.
All MLX work stays on this one thread (MLX streams are per-thread).
"""

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

DIM = 768
BATCH = {"text": 16, "image": 4, "audio": 2}
BUDGETS = (70, 140, 280, 560, 1120)


def log(*parts):
    print("[worker]", *parts, file=sys.stderr, flush=True)


def resolve_model(model):
    if os.path.isdir(model):
        return model
    from huggingface_hub import snapshot_download

    try:
        return snapshot_download(model, local_files_only=True)
    except Exception:
        log(f"downloading {model} (first run only)")
        return snapshot_download(model)


def mlx_vlm_source():
    """The git commit (or version) of mlx-vlm, for the index fingerprint."""
    from importlib import metadata

    dist = metadata.distribution("mlx-vlm")
    try:
        direct = json.loads(dist.read_text("direct_url.json") or "{}")
        commit = direct.get("vcs_info", {}).get("commit_id")
        if commit:
            return f"git-{commit[:7]}"
    except Exception:
        pass
    return dist.version


class Embedder:
    def __init__(self, model, text_only):
        import mlx.core as mx

        self.mx = mx
        self.text_only = text_only
        path = resolve_model(model)
        started = time.perf_counter()
        if text_only:
            from mlx_vlm.embedding_loader import load_embedding_model
            from mlx_vlm.utils import load_config
            from transformers import AutoTokenizer

            config = load_config(path)
            config["audio_config"] = None
            config["vision_config"] = None
            self.model = load_embedding_model(Path(path), config=config)
            self.tokenizer = AutoTokenizer.from_pretrained(path)
            self.processor = None
        else:
            from mlx_vlm import load

            self.model, self.processor = load(path)
            self.tokenizer = self.processor.tokenizer
        mx.eval(self.model.parameters())
        mx.set_cache_limit(512 * 1024 * 1024)
        if text_only:
            # The first calls compile kernels (~18 ms instead of ~6 ms): pay that now, while the panel is opening.
            for _ in range(2):
                self._vectors(self.model(**{k: mx.array(v) for k, v in self.tokenizer(
                    ["task: search result | query: warm up"], return_tensors="np").items()}))
        self.info = {
            "model": model,
            "revision": Path(path).name,
            "runtime": f"mlx-{mx.__version__}+mlx-vlm-{mlx_vlm_source()}",
            "dtype": "bf16",
            "dim": DIM,
            "text_only": text_only,
            "load_seconds": round(time.perf_counter() - started, 2),
        }

    def _vectors(self, output):
        return np.array(output.text_embeds.astype(self.mx.float32))

    def text(self, inputs):
        rows = []
        for i in range(0, len(inputs), BATCH["text"]):
            batch = inputs[i : i + BATCH["text"]]
            tokens = self.tokenizer(batch, padding=True, truncation=True, max_length=2048, return_tensors="np")
            rows.append(self._vectors(self.model(**{k: self.mx.array(v) for k, v in tokens.items()})))
        return np.concatenate(rows), [None] * len(inputs)

    def media(self, kind, inputs, budget=None):
        if self.processor is None:
            raise RuntimeError("this worker was started --text-only")
        if kind == "image":
            budget = budget or 280
            if budget not in BUDGETS:
                raise ValueError(f"budget must be one of {BUDGETS}")
            self.processor.image_processor.max_soft_tokens = budget
        rows, errors = [], []
        size = BATCH[kind]
        for i in range(0, len(inputs), size):
            batch = inputs[i : i + size]
            try:
                rows.append(self._media_batch(kind, batch))
                errors += [None] * len(batch)
            except Exception:
                # One unreadable file must not sink its neighbours: retry the batch item by item.
                for path in batch:
                    try:
                        rows.append(self._media_batch(kind, [path]))
                        errors.append(None)
                    except Exception as item_error:
                        rows.append(np.zeros((1, DIM), np.float32))
                        errors.append(f"{type(item_error).__name__}: {item_error}"[:300])
        return np.concatenate(rows), errors

    def _media_batch(self, kind, paths):
        conversations = [[{"role": "user", "content": [{"type": kind, "url": p}]}] for p in paths]
        inputs = self.processor.apply_chat_template(conversations, tokenize=True, return_dict=True, return_tensors="mlx")
        return self._vectors(self.model(**inputs))


def reply(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", default="google/embeddinggemma-2")
    parser.add_argument("--text-only", action="store_true", help="load only the 271M text part (for queries)")
    args = parser.parse_args()

    try:
        embedder = Embedder(args.model, args.text_only)
    except Exception as error:
        reply({"ready": False, "error": f"{type(error).__name__}: {error}"})
        return 1
    log(f"ready in {embedder.info['load_seconds']} s ({'text-only' if args.text_only else 'full'})")
    reply({"ready": True, "info": embedder.info})

    for line in sys.stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id, op = request.get("id"), request.get("op")
            if op == "quit":
                reply({"id": request_id, "ok": True})
                break
            if op == "info":
                reply({"id": request_id, "ok": True, "info": embedder.info})
                continue
            inputs = request.get("inputs") or []
            if op == "text":
                vectors, errors = embedder.text(inputs)
            elif op in ("image", "audio"):
                vectors, errors = embedder.media(op, inputs, request.get("budget"))
            else:
                raise ValueError(f"unknown op {op!r}")
            reply({
                "id": request_id, "ok": True, "dim": DIM, "count": len(inputs),
                "vectors": base64.b64encode(vectors.astype("<f4").tobytes()).decode("ascii"),
                "errors": errors,
            })
        except Exception as error:
            reply({"id": request_id, "ok": False, "error": f"{type(error).__name__}: {error}"[:500]})
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Document embedding batching benchmark

Measured on 2026-10-12 with macOS 26.5.2, an Apple M1, 16 GB RAM, and the local EmbeddingGemma 2 Q8 model. The end-to-end benchmark indexed 128 deterministic synthetic `.txt` files into a fresh SQLite index for every run. Each file produced one chunk vector, and all 128 files completed in every run.

| Text per document | Upstream `main` median | Batched median | Elapsed change | Vector throughput change |
| --- | ---: | ---: | ---: | ---: |
| 400 characters | 5.705 s (5.478, 5.705, 6.173) | 4.183 s (5.601, 4.183, 4.088) | 26.7% lower | 22.4 to 30.6 vectors/s (+36.4%) |
| 1,400 characters | 12.501 s (11.750, 12.501, 20.036) | 12.026 s (11.266, 12.026, 12.720) | 3.8% lower | No clear gain beyond run-to-run variation |

The direct persistent-worker diagnostic at 400 characters measured 31.39 inputs/s for one-input requests and 44.04 inputs/s for batches of 16 in one run each. At 1,400 characters, the same diagnostic measured 9.888 s for single-input requests and 9.877 s for batches, effectively unchanged. This points to reduced per-request overhead as the source of the improvement; longer inputs spend more time in model inference.

The final Release build's 400-character result includes the three verification runs after the final code changes. The end-to-end result is strongest for indexes containing many short documents. It does not establish a similar speedup for long documents or image, audio, and video indexing. Timings are local measurements from three end-to-end runs per case, not a broad hardware comparison.

## Reproducing

Build `digup` from the baseline commit (`f9b8106`) and the batching branch in separate checkouts. The benchmark script creates a fresh corpus and index and refuses to overwrite an existing output directory. It defaults to the local model directory at `~/Library/Application Support/DigUp/Models`; set `DIGUP_MODELS` if the model is elsewhere.

```sh
python3 scripts/benchmark-document-batching.py \
  --binary /path/to/baseline/.build/release/digup \
  --output /tmp/digup-baseline-400-1 \
  --documents 128 --characters 400

python3 scripts/benchmark-document-batching.py \
  --binary /path/to/batched/.build/release/digup \
  --output /tmp/digup-batched-400-1 \
  --documents 128 --characters 400
```

Repeat each case with a new output directory. Change `--characters` to `1400` and use distinct output paths to measure the longer-document case. The companion `benchmark-embedding-batching.py` script isolates worker request overhead with `--mode single` and `--mode batch`.

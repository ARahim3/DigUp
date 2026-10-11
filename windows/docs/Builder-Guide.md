# DigUp for Windows — Builder Guide

Plain words first:

- **Vector** — 768 numbers holding the meaning of one picture, page,
  passage, video frame, or 30 seconds of sound. Same space as Mac
  (EmbeddingGemma 2, Q8_0). A search turns your words into the same
  kind of numbers and compares.
- **Fingerprint** — a short text naming which model and settings made
  the vectors. A new fingerprint means "embed again".
- **Self-contained publish** — the app folder holds .NET itself, so the
  user installs nothing extra.

## You need (build PC only; users need none of this)

- Windows 10/11, x64. Git. Python 3.12 (only for the CMake venv).
- .NET 9 SDK (this repo used 9.0.318). Check: `dotnet --list-sdks`.
- Visual Studio 2022 (for the llama.cpp step) + NVIDIA CUDA toolkit
  (only for the GPU build; CPU/Vulkan build without it).
- CMake + Ninja (or let `build-llama-windows.ps1` fetch them into
  `Vendor\`, this window only — no system change).

Users need: Windows 10 22H2+ or 11. Nothing else (no .NET, no Python,
no FFmpeg, no admin). NVIDIA driver if they have NVIDIA.

## Build

```powershell
# 1. Model runtime (pinned tag b11461 + no-logits patch, CUDA+Vulkan+CPU, mtmd on)
powershell -File windows\scripts\build-llama-windows.ps1
# -> windows\native\x64\llama.dll + mtmd.dll (+ ggml*.dll)

PDF reading is Chromium's Pdfium, prebuilt (no compile):
`bblanchon/pdfium-binaries` release `chromium/8086` (PDFium 157.0.8086.0),
`pdfium-win-x64.tgz` (SHA-256
`1FD8AF952832DBB0EB16D9249F68FE09E5F5EBF7C3DD9F6066EA2720CC28487D`)
→ `windows\native\x64\pdfium.dll`, staged to dev-run/ship by the
`*.dll` copy in `dev-run-windows.ps1`. License: BSD-3 (already in the
license list below).

# 2. Code
dotnet build windows\DigUp.Windows.sln -c Release

# 3. Dev folder (all three exes + DLLs + loud smoke checks) and start the app
powershell -File windows\scripts\dev-run-windows.ps1
# CLI only: ... dev-run-windows.ps1 cli  ->  windows\dev-run\digup.exe

# 4. Try the CLI (words-only until step 1 + models exist)
windows\dev-run\digup.exe estimate %USERPROFILE%\Documents
```

The app exe is DigUpApp.exe on purpose: DigUp.dll would overwrite
digup.dll on case-insensitive disks (the Mac build does the same).

Model files (same as Mac, checked by size + SHA-256, see
`DigUp.Core/ModelFiles.cs`): `embeddinggemma-2-Q8_0.gguf` (310 MB) +
`mmproj-embeddinggemma-2-Q8_0.gguf` (555 MB) from
`ggml-org/embeddinggemma-2-GGUF`. Put them in
`%LocalAppData%\DigUp\Models\` (or set `DIGUP_MODELS`).

## Project map (Mac file → Windows file)

| Mac (`Sources/…`) | Windows (`windows/src/…`) | Notes |
|---|---|---|
| `DigUpKit/Crawler.swift`, `Rules.swift`, `FolderSelection.swift`, `Estimator.swift` | `DigUp.Core/Crawler.cs`, `Rules.cs`, `FolderSelection.cs`, `Costs.cs`, `Classification.cs`, `FileKind.cs` | Same skips; OneDrive placeholders replace iCloud; symlinked folders never followed |
| `DigUpKit/Extractors.swift`, `MediaExtractors.swift` | `DigUp.Core/ImageExtractor.cs` (WIC), `PdfExtractor.cs` (Pdfium), `AudioVideoExtractor.cs` (FFmpeg), `DocExtractor.cs`, `IExtractor.cs`, `ExtractorRunner.cs`, `Pieces.cs` | Engines are injected interfaces; stubs throw `NotSupportedException` with the wiring plan until built |
| `DigUpKit/CodeExtractor.swift` | `DigUp.Core/CodeExtractor.cs` | Same gitignore/vendored/secret rules |
| `DigUpKit/Database.swift`, `IndexStore.swift`, `Vectors.swift`, `Searcher.swift`, `SearchText.swift`, `Model*.swift` | Same names in `DigUp.Core/` | Same SQLite schema (v5), FTS5 porter tokenizer, float16 store, per-modality norm, word boost |
| `DigUpKit/Indexer.swift`, `Worker.swift`, `digup/*.swift` | `DigUp.Core/Indexer.cs`, `WorkerClient.cs` + `digup/Program.cs` | Same JSON-lines protocol; helper quits when idle |
| `LlamaRuntime/*.swift`, `CLlama/*` | `DigUp.Embed/Program.cs` + `scripts/build-llama-windows.ps1` | Metal→CUDA/Vulkan; native encode is the open item (protocol + plumbing done, see below) |
| `DigUpApp/*.swift` (27 files) | `DigUp.App/` (`App`, `MainWindow`, `Engine`, `Settings`, `Hotkey`, `Editors`) | WPF + WinForms tray; Carbon hotkey→`RegisterHotKey`; Sparkle→Velopack (notes in `setup/`) |

## Proven on 2026-10-11 (this PC: Win11 x64, RTX 5070 Ti, CUDA 13.1)

- llama.cpp b11461 + no-logits patch, CUDA sm_120 + CPU, mtmd on.
  `windows\native\x64\` holds llama.dll, mtmd.dll, ggml*.dll.
- Reference parity: 9/9 vectors cosine >= 0.999 vs
  `Tests/LlamaRuntimeTests/Reference/vectors.json` (worst: frame-70,
  0.999664). Same bar as the Mac `ReferenceVectorTests`.
- Mixed set (2 text, 2 code, 4 images, 4 spoken-word sounds, 1 video with
  soundtrack): `digup eval` scores top1 8/8, top5 8/8.
- Full solution builds with 0 warnings, 0 errors.
- App idles at ~115 MB (model loads on demand, helper quits when done).

## Open items (honest list)

1. **Vulkan build** for AMD/Intel GPUs: needs a Vulkan SDK (a system
   install, so not done on this PC). `WITH_VULKAN=1` in
   `build-llama-windows.ps1` covers it; CPU fallback works everywhere now.
2. **ARM64**: `build-llama-windows.ps1` picks arm64 on ARM64 machines;
   untested (no such machine here).
3. **Screenshot OCR**: `WindowsOcrEngineStub` still throws (Windows.Media.Ocr
   not wired). Screenshots index by picture alone until then; garbled PDF
   layers fall back to the rendered page instead of OCR.
4. **Velopack feed**: `setup/velopack-notes.md` defines the package and
   the VM safety proof. Wire the NuGet + feed when the release page exists.
5. **`dotnet test` projects** for Rules/SearchText/Vectors parity.

## Checks before a release

- `dotnet build windows\DigUp.Windows.sln -c Release` — 0 errors.
- `digup.exe estimate/eval` on the testbed; parity within 5% of Mac.
- Unicode sanity: lone-surrogate text through Normalized/Snippet/Tokenize
  must not throw (see TextSanitize; regression of the "invalid Unicode
  code points" search-killer).
- Kill the app mid-index, relaunch: pending files resume, done files are
  not re-embedded, no file is marked done without vectors.
- PDF checks: a text PDF indexes as text (title read), a scanned PDF as
  a picture, a corrupt PDF fails with a plain message (no crash).
- Fresh-VM install → run → update → uninstall (see `setup/velopack-notes.md`).
- License file ships: EmbeddingGemma 2 (Apache 2.0), llama.cpp (MIT),
  Pdfium, Tesseract, FFmpeg (LGPL, dynamic link + note), SQLite (public domain).

## What we never touch

Mac files, `build.sh`, release flow, and anything outside `windows/`.
`git status` must show no change to tracked files — only `windows/`
(plus this plan in `plans/`).

# Linux port (branch `linux-port-x86_64`, x86_64 first)

Scope: the `digup` CLI (estimate / index / search / status / eval /
index-service / worker) and its engine. The menubar app (`DigUpApp`,
AppKit/SwiftUI/Sparkle) stays macOS-only and is excluded from the Linux
package graph (`Package.swift` appends it only on macOS).

## What works on Linux today

- text, markdown, HTML and code indexing + search (pure `Foundation` paths)
- SQLite index + FTS5 keyword search + float16 meaning search (portable
  `Float` fallback where Accelerate is missing)
- extension-based file typing (no `UniformTypeIdentifiers`)
- `pdfinfo` page counts and `ffprobe` durations for estimates
- llama.cpp CPU build (`scripts/build-llama.sh` detects Linux, uses `ar`,
  keeps `GGML_NATIVE=OFF` so `-bin` packages run on any x86_64)

## Honest stubs (report why, never crash)

- images/screenshots: `Extractors_Linux.swift` (needs stb/VIPS + resize)
- PDFs: `Extractors_Linux.swift` (needs poppler: `pdftotext`/`pdftoppm`)
- OCR: names only for now (needs tesseract)
- audio/video: `MediaExtractors_Linux.swift` (needs ffmpeg decode)
- rich documents (docx/doc/odt/rtf): needs pandoc/libreoffice

The indexer records these as skipped/failed per file, so mixed folders
index everything else.

## Build

```sh
sudo apt install cmake ninja-build libsqlite3-dev ffmpeg poppler-utils  # Debian/Ubuntu
# Arch: yay -S swift-bin cmake ninja sqlite ffmpeg poppler
scripts/build-llama.sh
swift build -c release --product digup
swift test --filter DigUpKitTests   # PDF/output tests run on macOS only
```

Index and model locations follow `$XDG_DATA_HOME` (`~/.local/share` fallback)
instead of `~/Library/Application Support`.

## Binary installs (no compile)

```sh
scripts/package-linux.sh            # → dist/*.tar.gz (+ .deb with dpkg-deb)
```

- generic tarball → manual install, and the base for `digup-bin` on AUR
  (`packaging/PKGBUILD-bin`: bump `pkgver`, `updpkgsums`)
- `.deb` → Debian/Ubuntu (`Depends: libsqlite3-0, ffmpeg, poppler-utils`)
- `.rpm` → built in CI from `packaging/digup.spec`
- releases: `.github/workflows/linux-release.yml` uploads all three plus
  `SHA256SUMS` on every published tag. aarch64 is a second job, not started.

The 865 MB model is never bundled: it downloads on first use
(`ModelFiles`, `LlamaModels`), same as macOS.

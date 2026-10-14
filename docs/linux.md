# Linux CLI status

DigUp's portable engine and `digup` CLI build on Linux. This is an experimental
source build and CLI archive, not the released macOS menu bar app. The Linux
desktop shell is still in development.

The CLI keeps the same local EmbeddingGemma 2 model, SQLite index, and meaning
plus keyword search. It reads text, code, PDF pages, common images, audio and
video. PDFium renders scanned pages for image search, but Linux has no screenshot
or scanned-page OCR for exact words yet. RAW images and presentation decks are
not supported. HEIC and some orientation-sensitive TIFF/WebP images need FFmpeg
8.1; Ubuntu 24.04's FFmpeg 6.1 fails the existing image fixture tests. Legacy
`.doc` text needs LibreOffice Writer; `.docx`, `.odt`, and `.rtf` use the
built-in readers. File-specific failures are reported while other files
continue indexing.

## Build on Ubuntu 24.04 x86_64

Install Swift 6.2 or later and the build tools (`git`, `curl`, `python3`, `cmake`,
`ninja-build`, and a C++ compiler). Install `ffmpeg` for media. LibreOffice
Writer is optional for legacy `.doc` files.

```sh
scripts/fetch-vendor.sh
DIGUP_CPU_ONLY=1 scripts/build-llama.sh
swift build -c release --product digup
.build/release/digup --help
.build/release/digup download-model
```

`download-model` downloads and verifies the pinned model files (about 865 MB).
The CLI keeps its model and index under `$XDG_DATA_HOME/digup` or
`~/.local/share/digup`. Use `digup --help` for indexing and search commands.

## CLI archive

On Linux x86_64, make a CPU archive with:

```sh
scripts/package-linux.sh --version 0.6.1
```

The script builds the CLI with the Swift runtime linked statically, bundles
the pinned PDFium and llama.cpp shared libraries and CPU backends beside the
binary, and writes a tarball and `SHA256SUMS` under `dist/`. Extract it and run
`./digup` inside its directory, or keep the libraries beside the binary when
moving it. The model files are downloaded separately.

The archive targets the Linux ABI of the build runner (Ubuntu 24.04 in CI). It
still uses system glibc, C++/OpenMP libraries, and `ffmpeg` for media. It is
not a `.deb` or `.rpm`, and no Linux desktop app is included. CI builds and
tests the CLI and stores the tarball as an artifact. CI excludes the image
fixture suite until its FFmpeg requirement is met; the other tests run.
Publishing the archive as a release requires a separate decision.

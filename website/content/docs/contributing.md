+++
title = "Contributing"
description = "How to propose a change, what a pull request needs, how to build DigUp from source, and where things are in the code."
section = "Project"
order = 1
+++

DigUp is a small project with one maintainer and a plan for where it's going. Reports, ideas and fixes are welcome, and a few notes up front save everyone time.

## Open an issue first

Please open an issue before you write any code, for a fix as much as for a feature. The same fix or feature may already be in progress and not pushed yet. An issue gets you a clear "yes", "not now" or "here's how it should fit" before you spend an evening on it. A pull request that arrives without one may be closed with a link back here.

DigUp keeps everything on your computer, so changes that send data elsewhere, like telemetry or cloud services, aren't a fit.

## Pull requests

Once an issue says go:

- Keep it to one fix or one feature, with the reason in the description.
- Make sure `swift test` passes, and `cargo test` in `shell/src-tauri` if you change the Windows and Linux app.
- If it changes what search returns, run the evals in `evals/` before and after, and include both results.
- For speed or memory changes, measure before and after on the same computer.

Not every pull request will be merged, even good ones. The project has a direction, and some changes won't fit it; others get reworked to fit work in progress, and then you're credited in the release notes. Replies can take a few days: a quiet week means busy, not ignored, and every issue gets an answer.

## Build from source

:::: tabs
::: tab Mac
You'll need Xcode 26, git, and CMake (or `uv`) for llama.cpp. If `xcode-select -p` shows the Command Line Tools, switch to Xcode first (`sudo xcode-select -s /Applications/Xcode.app`): they lack the SwiftUI and Swift Testing macros the build needs.

```sh
git clone {{ site.github }} && cd DigUp
scripts/build-llama.sh            # llama.cpp at a pinned tag, with a one-line patch
swift build -c release && swift test
./build.sh                        # builds build.noindex/DigUp.app
```
:::
::: tab Windows and Linux
You'll need Swift 6.4, Rust and Node; on Windows also Visual Studio's C++ build tools, with the commands run in Git for Windows' bash. `scripts/fetch-vendor.sh` and `scripts/build-llama.sh` get the libraries, then `scripts/package-linux.sh` makes the .deb and the AppImage, and `scripts/package-windows.sh` the installer. [The packages workflow]({{ site.github }}/blob/main/.github/workflows/packages.yml) has every step, down to the packages each system needs.
:::
::::

`scripts/fetch-vendor.sh` checks every download against pinned SHA-256 values before using it. There's also a command-line tool, `.build/release/digup`, that indexes, searches and runs the evals from a terminal (`digup --help`), and `scripts/make-testbed.sh` builds a folder of test files to try it on.

## Where things are

The search engine, `Sources/DigUpKit`, is the same Swift code on every system; what differs by system lives in its `Platform/Apple` and `Platform/Portable` folders. The Mac app is `Sources/DigUpApp` (SwiftUI). The Windows and Linux app is `shell/` (Tauri: Rust, with plain HTML and JavaScript for its windows), which runs the engine as a helper program. `scripts/` builds llama.cpp, FFmpeg and the packages.

This website is in `website/`: Markdown pages in `website/content/`, built with `uv run website/build.py --serve`. A fix to the docs is as welcome as a fix to the code.

## Supporting the project

DigUp is free and stays that way. If it helps you, you can [support it]({{ site.support }}). Stars, good bug reports and telling people about it help just as much.

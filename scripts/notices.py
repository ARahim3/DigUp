#!/usr/bin/env python3
"""Writes the third-party notices DigUp's Windows and Linux packages carry: the license of every library they ship, from
the libraries' own license files (llama.cpp's and PDFium's from Vendor/, ffmpeg's, dav1d's and zlib's from the small
ffmpeg scripts/build-ffmpeg.sh makes, Swift's from the toolchain or scripts/licenses), and of every Rust crate the app
is built from (Cargo's own record of them, normal dependencies only: build tools and macros don't end up in the app).

    scripts/notices.py linux|windows <out.txt>

Run it from the packaging scripts, after scripts/fetch-vendor.sh, scripts/build-llama.sh and scripts/build-ffmpeg.sh.
It stops if a license it needs is missing: the packages don't go out without their notices.
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor"
RULE = "=" * 80
LICENSE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|copyright|notice|unlicense)([-_.].*)?$")


def read(path):
    return Path(path).read_text(encoding="utf-8", errors="replace").strip()


def need(path):
    path = Path(path)
    if not path.is_file():
        sys.exit(f"notices: missing {path} (run the vendor and ffmpeg scripts first)")
    return read(path)


def section(title, *texts):
    return "\n".join([RULE, title, RULE, "", *[t.strip() + "\n" for t in texts if t]])


def build_ffmpeg_versions():
    script = read(ROOT / "scripts/build-ffmpeg.sh")
    ffmpeg = re.search(r"^FFMPEG_VERSION=(\S+)", script, re.M).group(1)
    dav1d = re.search(r"^DAV1D_VERSION=(\S+)", script, re.M).group(1)
    return ffmpeg, dav1d


def swift_license():
    """The toolchain's own LICENSE.txt (Linux), else the copy in scripts/licenses (Windows' toolchain ships none)."""
    swift = shutil.which("swift")
    if swift:
        found = Path(swift).resolve().parent.parent / "share" / "swift" / "LICENSE.txt"
        if found.is_file():
            return read(found)
    return need(ROOT / "scripts/licenses/swift-LICENSE.txt")


def stb_license():
    header = need(VENDOR / "stb/include/stb_image.h")
    start = header.rfind("This software is available under 2 licenses")
    if start < 0:
        sys.exit("notices: stb_image.h has no license block")
    block = header[start:].replace("*/", "")
    return "\n".join(line.rstrip() for line in block.splitlines()).strip()


def miniz_license():
    if (VENDOR / "miniz/LICENSE").is_file():
        return read(VENDOR / "miniz/LICENSE")
    sys.exit("notices: Vendor/miniz/LICENSE is missing (run scripts/fetch-vendor.sh)")


def rust_crates(platform):
    """The crates in the app's binary for the platform: Cargo's resolve graph from the app, through normal
    dependencies, without proc-macro crates (they run while compiling)."""
    target = {"linux": "x86_64-unknown-linux-gnu", "windows": "x86_64-pc-windows-msvc"}[platform]
    metadata = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", target],
        cwd=ROOT / "shell/src-tauri", check=True, capture_output=True, encoding="utf-8").stdout)
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    seen, stack = set(), [root]
    while stack:
        current = stack.pop()
        if current in seen:
            continue
        seen.add(current)
        for dependency in nodes[current]["deps"]:
            if not any(kind["kind"] is None for kind in dependency["dep_kinds"]):
                continue
            package = packages[dependency["pkg"]]
            if any("proc-macro" in target_["kind"] for target_ in package["targets"]):
                continue
            stack.append(dependency["pkg"])
    seen.discard(root)
    return sorted((packages[i] for i in seen), key=lambda package: (package["name"], package["version"]))


def rust_section(platform):
    crates = rust_crates(platform)
    by_text = {}   # a license file's text, its spacing aside → the text and the crates that ship it (printed once)
    without = []
    for crate in crates:
        folder = Path(crate["manifest_path"]).parent
        files = sorted(path for path in folder.iterdir() if path.is_file() and LICENSE_FILE.match(path.name))
        label = f"{crate['name']} {crate['version']} ({crate.get('license') or 'see its files'})"
        if not files:
            without.append((label, crate))
        for path in files:
            text = read(path)
            by_text.setdefault(" ".join(text.split()), (text, []))[1].append(label)
    parts = [RULE, f"Rust crates in the app ({len(crates)}), each under its own license", RULE, "",
             "The app around DigUp's search on Windows and Linux is written in Rust with Tauri (https://tauri.app). "
             "These are the crates it is built from, with the license files they ship; a text several crates share "
             "is printed once, after their names.", ""]
    for text, labels in sorted(by_text.values(), key=lambda item: item[1][0]):
        parts += ["-" * 80, *labels, "-" * 80, "", text, ""]
    if without:
        parts += ["-" * 80, "Crates that ship no license file: their license, authors and source (the license texts are "
                  "above, as other crates ship them):", "-" * 80, ""]
        for label, crate in without:
            authors = ", ".join(crate.get("authors") or []) or "its authors"
            source = crate.get("repository") or f"https://crates.io/crates/{crate['name']}"
            parts += [f"{label}: copyright {authors}; source {source}"]
        parts += [""]
    return "\n".join(parts)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("linux", "windows"):
        sys.exit(__doc__)
    platform, out = sys.argv[1], Path(sys.argv[2])
    ffmpeg, dav1d = build_ffmpeg_versions()
    llama = VENDOR / "llama.cpp"
    pdfium = VENDOR / "pdfium"
    ffmpeg_licenses = VENDOR / "ffmpeg/licenses"
    windows = platform == "windows"

    parts = [
        "DigUp for Windows and Linux includes code from these projects, under their own licenses. Thank you.",
        "",
        "DigUp (https://github.com/ARahim3/DigUp) is MIT licensed; its license is the first one below. The model it uses, "
        "Google DeepMind's EmbeddingGemma 2 (Apache 2.0), isn't part of this download: DigUp downloads it from Hugging "
        "Face on first launch.",
        "",
        section("DigUp", need(ROOT / "LICENSE")),
        section("llama.cpp and ggml (https://github.com/ggml-org/llama.cpp), the embedding runtime, with one small "
                "change in scripts/llama.cpp-no-logits.patch",
                need(llama / "LICENSE"),
                *[f"{path.name}:\n\n{read(path)}" for path in sorted((llama / "licenses").glob("*")) if path.is_file()]),
        section("Vulkan headers (https://github.com/KhronosGroup/Vulkan-Headers), compiled into ggml's Vulkan backend",
                "Copyright 2015-2026 The Khronos Group Inc. Licensed under the Apache License, Version 2.0 or the MIT "
                "License, at your option (texts of both are in this file)."),
        section("PDFium (https://pdfium.googlesource.com/pdfium/), built by Benoit Blanchon's pdfium-binaries "
                "(https://github.com/bblanchon/pdfium-binaries), reads PDFs; it includes the libraries whose licenses "
                "follow it",
                need(pdfium / "LICENSE"),
                *[f"{path.name}:\n\n{read(path)}" for path in sorted((pdfium / "licenses").glob("*")) if path.is_file()]),
        section(f"FFmpeg {ffmpeg} (https://ffmpeg.org), reads audio, video and some pictures, as the separate programs "
                f"ffmpeg and ffprobe",
                "FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later. This build uses "
                "no GPL or nonfree parts. Its source is FFmpeg's release tarball, "
                f"https://ffmpeg.org/releases/ffmpeg-{ffmpeg}.tar.xz, unmodified, configured and built by "
                "scripts/build-ffmpeg.sh in DigUp's repository (https://github.com/ARahim3/DigUp), which also builds "
                "dav1d and links zlib. ffmpeg and ffprobe run as programs of their own: you can replace them in DigUp's "
                "helper folder with your own build.",
                f"What this build says about itself:\n\n{need(ffmpeg_licenses / 'ffmpeg-version.txt')}",
                need(ffmpeg_licenses / "ffmpeg-LICENSE.md"),
                need(ffmpeg_licenses / "ffmpeg-COPYING.LGPLv2.1")),
        section(f"dav1d {dav1d} (https://code.videolan.org/videolan/dav1d), decodes AV1 inside ffmpeg",
                need(ffmpeg_licenses / "dav1d-COPYING")),
        section("zlib (https://zlib.net), linked into ffmpeg", need(pdfium / "licenses/zlib.txt")),
        section("SQLite (https://sqlite.org), the index",
                "SQLite is in the public domain: \"The author disclaims copyright to this source code. In place of a "
                "legal notice, here is a blessing: May you do good and not evil. May you find forgiveness for yourself "
                "and forgive others. May you share freely, never taking more than you give.\""),
        section("stb (https://github.com/nothings/stb), reads and writes pictures", stb_license()),
        section("miniz (https://github.com/richgel999/miniz), reads docx and odt files", miniz_license()),
        section("Swift's runtime, Foundation and libdispatch (https://swift.org), which DigUp's helper is written with",
                swift_license()),
        section("ICU (https://icu.unicode.org), in Swift's Foundation and in PDFium (the same license, printed with "
                "PDFium's above)", need(pdfium / "licenses/icu.txt")),
    ]
    if windows:
        parts += [section("Microsoft Visual C++ runtime and WebView2",
                          "DigUp's helper ships Microsoft's Visual C++ runtime libraries, which their license allows "
                          "redistributing, and the app's window uses the Microsoft Edge WebView2 runtime that Windows "
                          "provides (its loader is linked into the app under the WebView2 SDK's license).")]
    else:
        parts += [section("The AppImage's libraries",
                          "The AppImage also carries the libraries the app's window uses (GTK, WebKitGTK, GStreamer and "
                          "the plugins it plays sound and video with, and what they need) from Ubuntu 22.04, each with "
                          "its copyright file in usr/share/doc inside the AppImage. "
                          "Their source is Ubuntu's: https://packages.ubuntu.com/jammy. The .deb uses your system's "
                          "own copies instead.")]
    parts.append(rust_section(platform))
    out.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"{out}: {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()

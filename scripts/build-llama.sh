#!/bin/bash
# Builds llama.cpp (MIT), the embedding runtime: the pinned build tag plus scripts/llama.cpp-no-logits.patch, as static
# libraries combined into Vendor/llama/lib/libllamacpp.a, with the headers in Vendor/llama/include (all out of git).
# macOS: Metal shaders are embedded and compiled on first use, so no Metal toolchain is needed.
# Linux (x86_64 CPU first): plain CPU build with GGML_NATIVE=OFF so -bin packages run on any x86_64.
# CMake comes from PATH, or from a venv in Vendor/ (needs uv). Does nothing when that build is already there.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461   # the first tags with EmbeddingGemma 2 (text + vision + audio) are b11452+
# A new TAG ships only if `swift test` passes: ReferenceVectorTests checks it makes the same vectors, so every index is
# kept. If it fails, keep this TAG, or bump LlamaEmbedder.vectorVersion and write the reference vectors again
# (DIGUP_WRITE_REFERENCE=1 swift test --filter ReferenceVectorTests): every index then embeds again.
PATCH=scripts/llama.cpp-no-logits.patch
SOURCE=Vendor/llama.cpp
OUT=Vendor/llama
UNAME="$(uname -s)"
if [[ "$UNAME" == "Darwin" ]]; then
  STAMP="$TAG $(shasum -a 256 "$PATCH" | cut -c1-12)"
else
  STAMP="$TAG-Linux $(sha256sum "$PATCH" | cut -c1-12)"
fi
if [[ -f "$OUT/lib/libllamacpp.a" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2>/dev/null)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"   # --force also drops the old patch
fi
# Without the patch, every input token costs 1 MiB of logits that an embedding model never produces (262k vocabulary).
if git -C "$SOURCE" apply --check "../../$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "../../$PATCH"
fi

if ! command -v cmake > /dev/null; then
  if [[ ! -x Vendor/cmake-venv/bin/cmake ]]; then
    uv venv --quiet Vendor/cmake-venv --python 3.12
    uv pip install --quiet --python Vendor/cmake-venv/bin/python cmake ninja
  fi
  export PATH="$PWD/Vendor/cmake-venv/bin:$PATH"
fi
GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
CPUS=$(command -v nproc > /dev/null && nproc || sysctl -n hw.ncpu)
# Only the libraries: no tools, no server, nothing downloaded at build time.
if [[ "$UNAME" == "Darwin" ]]; then
  cmake -S "$SOURCE" -B Vendor/llama-build -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
else
  # Linux x86_64: CPU build (CUDA/Vulkan later). GGML_NATIVE=OFF keeps -bin packages portable.
  cmake -S "$SOURCE" -B Vendor/llama-build -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON -DLLAMA_BUILD_MTMD=ON \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
fi
cmake --build Vendor/llama-build --config Release -j "$CPUS" --target llama mtmd > /dev/null

B=Vendor/llama-build
mkdir -p "$OUT/lib" "$OUT/include"
if [[ "$UNAME" == "Darwin" ]]; then
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" \
    $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
    $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a \
    $B/vendor/hash/libvendor-hash.a
else
  # GNU libtool can't merge archives: unpack and re-archive.
  TMP="$OUT/combine-tmp"
  rm -rf "$TMP"
  mkdir -p "$TMP"
  for lib in $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
    $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-blas/libggml-blas.a $B/vendor/hash/libvendor-hash.a; do
    (cd "$TMP" && ar x "$PWD/$lib")
  done
  ar crus "$OUT/lib/libllamacpp.a" "$TMP"/*.o
  ranlib "$OUT/lib/libllamacpp.a" 2>/dev/null || true
  rm -rf "$TMP"
fi
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
# The build, for logs and `digup status` (indexes record LlamaEmbedder.vectorVersion, not this). SwiftPM doesn't see a
# changed header, so the Swift file that reads it is touched.
printf '// Written by scripts/build-llama.sh.\n#define LLAMA_BUILD_TAG "%s"\n' "$TAG" > "$OUT/include/llama-build.h"
touch Sources/LlamaRuntime/LlamaEmbedder.swift
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched) into $OUT"

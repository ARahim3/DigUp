#!/bin/bash
# Engine-only benchmark. No model downloads or llama.cpp build required.
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/DigUpBenchmarkBuild.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find Sources/DigUpKit -name '*.swift' -type f)
swiftc -O -module-cache-path "$work_dir/module-cache" -o "$work_dir/benchmark" \
    "${sources[@]}" scripts/benchmarks/index.swift
"$work_dir/benchmark"

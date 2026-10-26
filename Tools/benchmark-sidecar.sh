#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER_SOURCE="${1:-$ROOT/Sources/Redlight/DisplayFilterController.swift}"
mkdir -p "$ROOT/.build"
BENCHMARK_DIR="$(mktemp -d "$ROOT/.build/sidecar-benchmark.XXXXXX")"
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
xcrun swiftc -O -swift-version 6 \
    "$ROOT/Sources/Redlight/GammaController.swift" "$FILTER_SOURCE" \
    "$ROOT/Tools/benchmark-sidecar.swift" -o "$BENCHMARK_DIR/benchmark"
"$BENCHMARK_DIR/benchmark"

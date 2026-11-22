#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPILE_ONLY=0
if [[ "${1:-}" == --compile-only ]]; then
    COMPILE_ONLY=1
    shift
fi
if [[ "${1:-}" == --help || $# -gt 1 ]]; then
    echo "usage: $0 [--compile-only] [DisplayFilterController.swift]"
    if (( $# > 1 )); then exit 2; fi
    exit 0
fi
FILTER_SOURCE="${1:-$ROOT/Sources/Redlight/DisplayFilterController.swift}"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-benchmark.XXXXXX")"
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
xcrun swiftc -O -swift-version 6 \
    "$ROOT/Sources/Redlight/GammaController.swift" "$FILTER_SOURCE" \
    "$ROOT/Tools/benchmark-sidecar.swift" -o "$BENCHMARK_DIR/benchmark"
if (( !COMPILE_ONLY )); then "$BENCHMARK_DIR/benchmark"; fi

#!/bin/bash
# Inspect a built bundle without launching it or touching display state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 || "${1:-}" == --help ]]; then
    echo "usage: $0 [Redlight.app]"
    if (( $# > 1 )); then exit 2; fi
    exit 0
fi
APP="${1:-$ROOT/Redlight.app}"
python3 "$ROOT/Tools/app-intents-metadata.py" verify --app "$APP"

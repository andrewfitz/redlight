#!/bin/bash
# Inspect a built bundle without launching it or touching display state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/Redlight.app}"
python3 "$ROOT/Tools/app-intents-metadata.py" verify --app "$APP"

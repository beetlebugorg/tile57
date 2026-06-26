#!/usr/bin/env bash
# Generate style/chart-{day,dusk,night}.json from the color tables, pointing at
# the local PMTiles archive (absolute path, so the binary can run from anywhere).
# These styles are machine-specific (absolute paths) and gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PMTILES="${PMTILES:-$ROOT/reference/tiles/annapolis.pmtiles}"
COLORS="${COLORS:-$ROOT/reference/assets/colortables.json}"

for scheme in day dusk night; do
  python3 "$ROOT/style/build_style.py" \
    --pmtiles "$PMTILES" --colortables "$COLORS" \
    --scheme "$scheme" -o "$ROOT/style/chart-$scheme.json"
done

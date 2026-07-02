#!/usr/bin/env bash
# Bake an S-57 cell (or ENC_ROOT) for the web demo:
#   bundle/      MLT chart bundle (tiles + assets + manifest) — the demo default
#   bundle-mvt/  MVT variant — load with ?pmtiles=bundle-mvt/tiles/chart.pmtiles
# MapLibre GL JS >= 5.12 renders MLT (source encoding:"mlt"); the demo
# auto-detects the format from the archive.
# Usage: ./bake.sh <cell.000 | ENC_ROOT>
set -euo pipefail
cd "$(dirname "$0")"
CELL="${1:?usage: ./bake.sh <cell.000 | ENC_ROOT>}"
# The tile57 CLI: built by `zig build` at the repo root, or set TILE57=.
TILE57="${TILE57:-../../../../zig-out/bin/tile57}"
[ -x "$TILE57" ] || { echo "tile57 not found at $TILE57 — run 'zig build' at the repo root, or set TILE57=" >&2; exit 1; }
"$TILE57" bake "$CELL" -o bundle --format mlt
"$TILE57" bake "$CELL" -o bundle-mvt --format mvt
echo "baked -> bundle/tiles/chart.pmtiles (MLT, default) + bundle-mvt/tiles/chart.pmtiles (MVT)"

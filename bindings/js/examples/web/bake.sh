#!/usr/bin/env bash
# Bake an S-57 cell (or ENC_ROOT) into PMTiles + assets for the web demo.
# Usage: ./bake.sh <cell.000 | ENC_ROOT>   (output -> ./chart/)
set -euo pipefail
cd "$(dirname "$0")"
CELL="${1:?usage: ./bake.sh <cell.000 | ENC_ROOT>}"
# The tile57 CLI: built by `zig build` at the repo root (../../../zig-out/bin/tile57),
# or point TILE57 at any tile57 binary.
TILE57="${TILE57:-../../../zig-out/bin/tile57}"
[ -x "$TILE57" ] || { echo "tile57 not found at $TILE57 — run 'zig build' at the repo root, or set TILE57=" >&2; exit 1; }
"$TILE57" bake "$CELL" -o chart --format mvt   # MapLibre GL JS reads MVT, not MLT
echo "baked -> chart/tiles/chart.pmtiles (+ chart/assets, chart/manifest.json)"

#!/usr/bin/env bash
# Generate style/chart-{day,dusk,night}.json from the color tables, pointing at
# the local PMTiles archive (absolute path, so the binary can run from anywhere).
# These styles are machine-specific (absolute paths) and gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PMTILES="${PMTILES:-$ROOT/reference/tiles/annapolis.pmtiles}"
COLORS="${COLORS:-$ROOT/reference/assets/colortables.json}"
GLYPHS="${GLYPHS:-$ROOT/reference/assets/glyphs}"
SPRITE="${SPRITE:-$ROOT/reference/assets/sprite-mln}"

# Build the MapLibre-format sprite sheet from the Go-emitted atlas if missing.
if [[ ! -f "$SPRITE.json" && -f "$ROOT/reference/assets/sprite.json" ]]; then
  python3 "$ROOT/scripts/build_sprite.py" --sprite "$ROOT/reference/assets/sprite.json" -o "$SPRITE"
fi

for scheme in day dusk night; do
  python3 "$ROOT/style/build_style.py" \
    --pmtiles "$PMTILES" --colortables "$COLORS" --glyphs "$GLYPHS" --sprite "$SPRITE" \
    --scheme "$scheme" -o "$ROOT/style/chart-$scheme.json"
done

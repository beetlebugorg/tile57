#!/usr/bin/env bash
# Generate style/chart-{day,dusk,night}.json from the color tables, pointing at
# the local PMTiles archive (absolute path, so the binary can run from anywhere).
# These styles are machine-specific (absolute paths) and gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/scripts/py.sh"   # runs Python in the project venv (auto-creates, installs Pillow)
PMTILES="${PMTILES:-$ROOT/reference/tiles/annapolis.pmtiles}"
COLORS="${COLORS:-$ROOT/reference/assets/colortables.json}"
GLYPHS="${GLYPHS:-$ROOT/reference/assets/glyphs}"
SPRITE="${SPRITE:-$ROOT/reference/assets/sprite-mln}"

# Build the MapLibre-format sprite sheet (symbols + area patterns) if missing.
if [[ ! -f "$SPRITE.json" && -f "$ROOT/reference/assets/sprite.json" ]]; then
  "$PY" "$ROOT/scripts/build_sprite.py" \
    --sprite "$ROOT/reference/assets/sprite.json" \
    --patterns "$ROOT/reference/assets/patterns.json" \
    --tiles "$PMTILES" -o "$SPRITE"
fi

for scheme in day dusk night; do
  "$PY" "$ROOT/style/build_style.py" \
    --pmtiles "$PMTILES" --colortables "$COLORS" --glyphs "$GLYPHS" --sprite "$SPRITE" \
    --scheme "$scheme" -o "$ROOT/style/chart-$scheme.json"
done

# A day style whose chart source is served by the Zig FileSource (ChartTileSource,
# used by chartplotter / chartplotter-render). The zigtiles:// scheme is the
# internal routing key matched by ChartTileSource::canRequest.
"$PY" "$ROOT/style/build_style.py" \
  --pmtiles "$PMTILES" --colortables "$COLORS" --glyphs "$GLYPHS" --sprite "$SPRITE" \
  --scheme day --source-tiles "zigtiles://{z}/{x}/{y}" --minzoom 5 --maxzoom 16 \
  -o "$ROOT/style/chart-zig-day.json"

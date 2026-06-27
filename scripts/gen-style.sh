#!/usr/bin/env bash
# Generate style/chart-{day,dusk,night}.json + chart-zig-day.json from the colour
# tables via the Zig style generator (engine/src/assets/style.zig, exposed as
# `chartplotter-bake style`). The styles point at local absolute paths so the host
# binary can run from anywhere; they are machine-specific and gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"   # zig lives here on the dev box
PY="$ROOT/scripts/py.sh"               # Python in the project venv (Pillow for sprites)
PMTILES="${PMTILES:-$ROOT/reference/tiles/annapolis.pmtiles}"
COLORS="${COLORS:-$ROOT/reference/assets/colortables.json}"
GLYPHS="${GLYPHS:-$ROOT/reference/assets/glyphs}"
SPRITE="${SPRITE:-$ROOT/reference/assets/sprite-mln}"

# Build the baker if it isn't built yet.
BAKE="$ROOT/engine/zig-out/bin/chartplotter-bake"
[[ -x "$BAKE" ]] || ( cd "$ROOT/engine" && zig build )

# Build the MapLibre-format sprite sheet (symbols + area patterns) if missing.
if [[ ! -f "$SPRITE.json" && -f "$ROOT/reference/assets/sprite.json" ]]; then
  "$PY" "$ROOT/scripts/build_sprite.py" \
    --sprite "$ROOT/reference/assets/sprite.json" \
    --patterns "$ROOT/reference/assets/patterns.json" \
    --tiles "$PMTILES" -o "$SPRITE"
fi

# style <scheme> <out> [extra source args] — colours from the emitted colortables.
gen() {
  "$BAKE" style --colortables "$COLORS" \
    --sprite "file://$SPRITE" --glyphs "file://$GLYPHS/{fontstack}/{range}.pbf" \
    --scheme "$1" -o "$2" "${@:3}"
}

for scheme in day dusk night; do
  gen "$scheme" "$ROOT/style/chart-$scheme.json" --pmtiles-url "pmtiles://file://$PMTILES"
done

# A day style whose chart source is served by the Zig FileSource (ChartTileSource,
# used by chartplotter / chartplotter-render). The zigtiles:// scheme is the
# internal routing key matched by ChartTileSource::canRequest.
gen day "$ROOT/style/chart-zig-day.json" \
  --source-tiles "zigtiles://{z}/{x}/{y}" --minzoom 5 --maxzoom 16

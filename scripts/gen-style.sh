#!/usr/bin/env bash
# Generate style/chart-{day,dusk,night}.json + chart-zig-day.json from the colour
# tables via the Zig style generator (src/assets/style.zig, exposed as
# `tile57 style`). The styles point at local absolute paths so the host
# binary can run from anywhere; they are machine-specific and gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"   # zig lives here on the dev box
PMTILES="${PMTILES:-$ROOT/reference/tiles/annapolis.pmtiles}"
COLORS="${COLORS:-$ROOT/reference/assets/colortables.json}"
GLYPHS="${GLYPHS:-$ROOT/reference/assets/glyphs}"
SPRITE="${SPRITE:-$ROOT/reference/assets/sprite-mln}"

# Build the baker if it isn't built yet.
BAKE="$ROOT/zig-out/bin/tile57"
[[ -x "$BAKE" ]] || ( cd "$ROOT" && zig build )

# Build the MapLibre-format sprite sheet (centred symbols + ctr:/pat: variants)
# if missing — pure Zig, straight from the vendored S-101 Portrayal Catalogue.
[[ -f "$SPRITE.json" ]] || "$BAKE" sprite-mln -o "$(dirname "$SPRITE")"

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
# used by chartplotter / chartplotter-render). The tile57:// scheme is the
# internal routing key matched by ChartTileSource::canRequest.
gen day "$ROOT/style/chart-zig-day.json" \
  --source-tiles "tile57://{z}/{x}/{y}" --minzoom 5 --maxzoom 16

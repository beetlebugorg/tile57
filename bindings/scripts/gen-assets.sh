#!/usr/bin/env bash
# Regenerate the embedded base template + S-52 colortables for the wasm style
# engine. Run this whenever the catalogue or the style/colortable generators
# change. Outputs are committed (so the npm package is self-contained) into
# bindings/wasm/assets/. They are then @embedFile'd by build.zig into the wasm.
#
# The template is the output of `tile57 style` (assets.styleJson) — the base style
# that chartstyle.buildStyle then PATCHES with the mariner settings. We generate it
# with --sprite/--glyphs so the full layer set (soundings, point_symbols, text,
# contour-labels) is present and exercises every buildStyle patch path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
ASSETS="$ROOT/bindings/wasm/assets"
BAKE="$ROOT/zig-out/bin/tile57"

[[ -x "$BAKE" ]] || ( cd "$ROOT" && zig build )

mkdir -p "$ASSETS"

# Base template (day palette; buildStyle recolours per scheme at runtime). The
# source/sprite/glyphs URLs are placeholders the front-end overrides as needed.
"$BAKE" style --scheme day -o "$ASSETS/template.json" \
  --source-tiles "tile57://{z}/{x}/{y}" --minzoom 5 --maxzoom 16 \
  --sprite "sprite" --glyphs "glyphs/{fontstack}/{range}.pbf"

# S-52 colortables (day/dusk/night palettes) from the embedded colour profile.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$BAKE" assets -o "$TMP"
cp "$TMP/colortables.json" "$ASSETS/colortables.json"

echo "regenerated:"
echo "  $ASSETS/template.json    ($(wc -c < "$ASSETS/template.json") bytes)"
echo "  $ASSETS/colortables.json ($(wc -c < "$ASSETS/colortables.json") bytes)"
echo "now rebuild the wasm: bindings/scripts/build-wasm.sh"

#!/usr/bin/env bash
# Render the chart to a PNG offscreen via MapLibre Native's mbgl-render (headless
# EGL). This is the upstream generic render path; our own headless host is
# chartplotter-render (see docs/docs/getting-started.md).
#
# Env overrides: STYLE OUT LAT LON ZOOM W H RATIO BEARING DEBUG
#   DEBUG=1 draws tile borders + parse status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Find mbgl-render in whichever build dir exists (Linux headless or macOS).
RENDER="${RENDER:-}"
if [[ -z "$RENDER" ]]; then
  for d in build build-macos; do
    cand="$ROOT/$d/vendor/maplibre-native/bin/mbgl-render"
    [[ -x "$cand" ]] && { RENDER="$cand"; break; }
  done
fi

STYLE="${STYLE:-$ROOT/style/chart-day.json}"
OUT="${OUT:-$ROOT/renders/out.png}"
# Default view: Annapolis harbour.
LAT="${LAT:-38.97}"
LON="${LON:--76.49}"
ZOOM="${ZOOM:-13}"
W="${W:-1024}"
H="${H:-768}"
RATIO="${RATIO:-1}"
BEARING="${BEARING:-0}"

if [[ ! -x "$RENDER" ]]; then
  echo "mbgl-render not built yet: $RENDER" >&2
  exit 1
fi

mkdir -p "$ROOT/renders"
cd "$ROOT/renders"   # cache.sqlite lands here

args=(-s "$STYLE" -y "$LAT" -x "$LON" -z "$ZOOM" -w "$W" -h "$H" -r "$RATIO" -b "$BEARING" -o "$OUT")
[[ "${DEBUG:-0}" == "1" ]] && args+=(--debug)

echo "+ mbgl-render ${args[*]}" >&2
"$RENDER" "${args[@]}"
echo "wrote $OUT ($(wc -c < "$OUT" 2>/dev/null | tr -d ' ') bytes)"

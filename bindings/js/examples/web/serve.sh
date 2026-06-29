#!/usr/bin/env bash
# Serve the tile57 web demo on 0.0.0.0:3000. Vendors the engine module next to the
# page (so the served root is self-contained) and checks the tiles are baked.
set -euo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-3000}"

# Vendor the npm module (index.js + .wasm) into ./engine so the demo loads it from
# the served root. In a real app you'd `npm install @beetlebug/tile57-style-engine`.
mkdir -p engine
cp -f ../../index.js ../../index.d.ts ../../style-engine.wasm engine/

if [ ! -f chart/tiles/chart.pmtiles ]; then
  echo "no baked tiles yet — run e.g.:" >&2
  echo "  ./bake.sh /path/to/US4MD81M.000" >&2
  exit 1
fi

echo "serving the tile57 demo on http://0.0.0.0:${PORT}/  (Ctrl-C to stop)"
# NB: a Range-capable server — pmtiles reads byte ranges and stock `python -m
# http.server` ignores Range (returns the whole file), which breaks tile loading.
exec python3 serve.py

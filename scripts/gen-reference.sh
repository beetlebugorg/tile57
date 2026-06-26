#!/usr/bin/env bash
# Regenerate the reference data the native app renders: S-52 client assets +
# a baked PMTiles chart archive. Uses the prebuilt Go binary from ../chartplotter-go
# for the current OS/arch. Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO="${GO:-$ROOT/../chartplotter-go}"

# Pick the matching prebuilt Go binary (…_s101 embeds the catalogue).
os="$(uname -s | tr '[:upper:]' '[:lower:]')"   # linux | darwin
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
esac
BIN="${BIN:-$GO/dist/chartplotter_${os}_${arch}_s101}"

if [[ ! -x "$BIN" ]]; then
  echo "Go binary not found/executable: $BIN" >&2
  echo "Build it in $GO (make build) or set BIN=…" >&2
  exit 1
fi

mkdir -p "$ROOT/reference/tiles" "$ROOT/reference/assets"

echo "==> emit-assets" >&2
"$BIN" emit-assets "$ROOT/reference/assets"

echo "==> copy glyphs (Noto Sans, from the Go web assets)" >&2
cp -r "$GO/web/glyphs" "$ROOT/reference/assets/glyphs"

echo "==> bake annapolis.pmtiles" >&2
"$BIN" bake -o "$ROOT/reference/tiles/annapolis.pmtiles" \
  "$GO/testdata/US4MD81M.000" "$GO/testdata/US5MD1MC.000"

echo "==> styles" >&2
"$ROOT/scripts/gen-style.sh"

echo "done." >&2

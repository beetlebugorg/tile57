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
# Find a usable Go binary: BIN override, then a prebuilt dist/ binary for this
# OS/arch (_s101 = catalogue embedded), then a locally-built bin/chartplotter.
BIN="${BIN:-}"
if [[ -z "$BIN" ]]; then
  for cand in \
    "$GO/dist/chartplotter_${os}_${arch}_s101" \
    "$GO/dist/chartplotter_${os}_${arch}" \
    "$GO/bin/chartplotter"; do
    [[ -x "$cand" ]] && { BIN="$cand"; break; }
  done
fi

if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  echo "No Go binary found. Build it first:" >&2
  echo "    (cd $GO && make build)        # -> bin/chartplotter (embeds the S-101 catalogue)" >&2
  echo "  then re-run, or set BIN=/path/to/chartplotter" >&2
  exit 1
fi
echo "using Go binary: $BIN" >&2

# A plain (non-_s101) build needs the catalogue pointed at on disk. emit-assets
# takes only --s101 <PortrayalCatalog>; bake also takes --s101-fc <FC.xml>.
EMIT_S101=()
BAKE_S101=()
CATDIR="$GO/internal/engine/s101catalog/catalog"
if [[ "$BIN" != *_s101 ]] && [[ -d "$CATDIR/PortrayalCatalog" ]]; then
  EMIT_S101=(--s101 "$CATDIR/PortrayalCatalog")
  BAKE_S101=(--s101 "$CATDIR/PortrayalCatalog" --s101-fc "$CATDIR/FeatureCatalogue.xml")
fi

mkdir -p "$ROOT/reference/tiles" "$ROOT/reference/assets"

echo "==> emit-assets" >&2
"$BIN" emit-assets ${EMIT_S101[@]+"${EMIT_S101[@]}"} "$ROOT/reference/assets"

echo "==> copy glyphs (Noto Sans, from the Go web assets)" >&2
cp -r "$GO/web/glyphs" "$ROOT/reference/assets/glyphs"

echo "==> bake annapolis.pmtiles" >&2
"$BIN" bake ${BAKE_S101[@]+"${BAKE_S101[@]}"} -o "$ROOT/reference/tiles/annapolis.pmtiles" \
  "$GO/testdata/US4MD81M.000" "$GO/testdata/US5MD1MC.000"

echo "==> styles" >&2
"$ROOT/scripts/gen-style.sh"

echo "done." >&2

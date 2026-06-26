#!/usr/bin/env bash
# Regenerate the reference data the native app renders: S-52 client assets +
# a baked PMTiles chart archive. Uses the prebuilt Go binary from ../chartplotter-go
# for the current OS/arch. Run from anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os="$(uname -s | tr '[:upper:]' '[:lower:]')"   # linux | darwin
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
esac

BIN="${BIN:-}"
GO="${GO:-}"

# Resolve the Go repo. If BIN is given, derive it from BIN's location; else look
# for chartplotter-go or chartplotter as a sibling.
if [[ -n "$BIN" && -z "$GO" ]]; then
  GO="$(cd "$(dirname "$BIN")/.." 2>/dev/null && pwd || true)"
fi
if [[ -z "$GO" || ! -d "$GO/internal/engine/s101catalog" ]]; then
  for cand in "$ROOT/../chartplotter-go" "$ROOT/../chartplotter"; do
    [[ -d "$cand/internal/engine/s101catalog" ]] && GO="$cand" && break
  done
fi
GO="${GO:-$ROOT/../chartplotter-go}"

# Find a usable Go binary: BIN override, then a prebuilt dist/ binary, then a
# locally-built bin/chartplotter.
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
  echo "    (cd $GO && make build)        # -> bin/chartplotter" >&2
  echo "  then re-run, or set BIN=/path/to/chartplotter" >&2
  exit 1
fi
echo "using Go binary: $BIN   (Go repo: $GO)" >&2

# Always point emit-assets/bake at the on-disk S-101 catalogue when present
# (harmless override for _s101 builds; required for plain builds). emit-assets
# takes only --s101 <PortrayalCatalog>; bake also takes --s101-fc <FC.xml>.
EMIT_S101=()
BAKE_S101=()
CATDIR="$GO/internal/engine/s101catalog/catalog"
if [[ -d "$CATDIR/PortrayalCatalog" ]]; then
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

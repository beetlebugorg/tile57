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

# Locate the PortrayalCatalog dir and FeatureCatalogue.xml. They may live in
# different directories, so find each independently (override with S101_PC /
# S101_FC). emit-assets takes only --s101 <PortrayalCatalog>; bake also takes
# --s101-fc <FC.xml>. Always passed when found (required for a plain build,
# harmless override for an _s101 build).
find_one() { find "$GO" \( -name .git -o -name worktrees -o -name node_modules \) -prune -o "$@" -print 2>/dev/null | head -1; }
# Prefer the vendored official IHO catalogue (git submodules); else hunt the Go
# repo (anchor the PortrayalCatalog on its LineStyles subdir; find FC.xml
# independently). Override with S101_PC / S101_FC.
PC="${S101_PC:-}"
FC="${S101_FC:-}"
VPC="$ROOT/vendor/S-101_Portrayal-Catalogue/PortrayalCatalog"
VFC="$ROOT/vendor/S-101-Documentation-and-FC/S-101FC/FeatureCatalogue.xml"
[[ -z "$PC" && -d "$VPC/LineStyles" ]] && PC="$VPC"
[[ -z "$FC" && -f "$VFC" ]] && FC="$VFC"
if [[ -z "$PC" ]]; then
  ls_dir="$(find_one -type d -name LineStyles)"
  [[ -n "$ls_dir" ]] && PC="$(cd "$(dirname "$ls_dir")" && pwd)"
fi
[[ -z "$FC" ]] && FC="$(find_one -type f -name FeatureCatalogue.xml)"
echo "  PortrayalCatalog: ${PC:-<not found>}" >&2
echo "  FeatureCatalogue: ${FC:-<not found>}" >&2

EMIT_S101=()
BAKE_S101=()
[[ -n "$PC" ]] && EMIT_S101=(--s101 "$PC")
if [[ -n "$PC" && -n "$FC" ]]; then
  BAKE_S101=(--s101 "$PC" --s101-fc "$FC")
elif [[ -n "$PC" ]]; then
  BAKE_S101=(--s101 "$PC")
fi
if [[ "$BIN" != *_s101 && -z "$PC" ]]; then
  echo "No PortrayalCatalog found under $GO. Set S101_PC=/path/to/PortrayalCatalog" >&2
  echo "(and S101_FC=/path/to/FeatureCatalogue.xml), or use an _s101 binary." >&2
  exit 1
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

#!/usr/bin/env bash
# Differential test: the Zig style generator (assets/style.zig, via
# `chartplotter-bake style`) must emit the same MapLibre layer set as the Python
# reference style/build_style.py, for every palette. Compares the parsed
# `layers` arrays (order-sensitive); top-level source/sprite/glyphs differ by
# design and are ignored. Exits non-zero on any mismatch.
#
# Usage: scripts/check-style-parity.sh   (run from the repo root)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

CT=reference/assets/colortables.json
SRC='zigtiles://{z}/{x}/{y}'
BIN=engine/zig-out/bin/chartplotter-bake
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$CT" ]; then
  echo "missing $CT — run scripts/gen-reference.sh first" >&2
  exit 2
fi

( cd engine && zig build ) >/dev/null

fail=0
for sc in day dusk night; do
  python3 style/build_style.py --pmtiles /tmp/x.pmtiles --colortables "$CT" --scheme "$sc" \
    --source-tiles "$SRC" --sprite /x/sprite --glyphs /x/glyphs -o "$TMP/ref-$sc.json" 2>/dev/null
  "$BIN" style --scheme "$sc" --source-tiles "$SRC" --sprite /x/sprite --glyphs /x/glyphs \
    -o "$TMP/mine-$sc.json" >/dev/null
  if python3 - "$TMP/ref-$sc.json" "$TMP/mine-$sc.json" "$sc" <<'PY'
import json, sys
ref = json.load(open(sys.argv[1]))["layers"]
mine = json.load(open(sys.argv[2]))["layers"]
sc = sys.argv[3]
if ref == mine:
    print(f"  {sc}: PASS ({len(mine)} layers identical)")
    sys.exit(0)
print(f"  {sc}: FAIL  ref={len(ref)} mine={len(mine)}")
ri = {l['id']: l for l in ref}; mi = {l['id']: l for l in mine}
for l in ref:
    if mi.get(l['id']) != l:
        print("   first diff in layer:", l['id'])
        break
sys.exit(1)
PY
  then :; else fail=1; fi
done

if [ "$fail" -eq 0 ]; then echo "style parity OK (Zig == build_style.py)"; else echo "style parity FAILED" >&2; fi
exit "$fail"

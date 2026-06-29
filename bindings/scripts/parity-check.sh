#!/usr/bin/env bash
# Parity check: for several mariner-setting combinations, generate the MapLibre
# style.json via BOTH backends and assert they are byte-identical:
#   - native:  zig-out/bin/style-parity  (chartstyle.buildStyle, native target)
#   - wasm/JS: bindings/js/index.js       (chartstyle.buildStyle, wasm32 target)
# Both embed the SAME template + colortables and share the SAME settings parser
# (bindings/shared/settings.zig), so any difference is a real backend divergence.
#
# A FIXED now_unix makes the "today" date resolution deterministic on both sides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
NOW=1700000000
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build the native oracle (and wasm) if needed.
[[ -x "$ROOT/zig-out/bin/style-parity" ]] || ( cd "$ROOT" && zig build style-parity )
[[ -f "$ROOT/bindings/js/style-engine.wasm" ]] || "$ROOT/bindings/scripts/build-wasm.sh"

cases=(
  '{}'
  '{"scheme":"dusk"}'
  '{"scheme":"night","depth_unit":"feet"}'
  '{"scheme":"night","depth_unit":"feet","safety_contour":15,"deep_contour":40,"boundary_style":"plain","display_other":true}'
  '{"four_shade_water":false,"simplified_points":true,"data_quality":true}'
  '{"date_view":"20240115","highlight_date_dependent":true,"text_names":false}'
)

fail=0
i=0
for c in "${cases[@]}"; do
  i=$((i+1))
  echo "$c" > "$TMP/settings.json"
  "$ROOT/zig-out/bin/style-parity" "$TMP/settings.json" "$NOW" "$TMP/native.json" >/dev/null
  node --input-type=module -e '
    import { loadStyleEngine } from "'"$ROOT"'/bindings/js/index.js";
    import { readFileSync, writeFileSync } from "node:fs";
    const s = JSON.parse(readFileSync("'"$TMP"'/settings.json","utf8"));
    const engine = await loadStyleEngine();
    writeFileSync("'"$TMP"'/wasm.json", engine.generateStyle(s, { nowUnix: '"$NOW"', asString: true }));
  '
  if cmp -s "$TMP/native.json" "$TMP/wasm.json"; then
    printf "  ok   case %d  (%d bytes)  %s\n" "$i" "$(wc -c < "$TMP/native.json")" "$c"
  else
    printf "  FAIL case %d  %s\n" "$i" "$c"
    diff <(python3 -m json.tool "$TMP/native.json" 2>/dev/null || cat "$TMP/native.json") \
         <(python3 -m json.tool "$TMP/wasm.json" 2>/dev/null || cat "$TMP/wasm.json") | head -20 || true
    fail=1
  fi
done

if [[ "$fail" == 0 ]]; then
  echo "PARITY OK: native and wasm outputs are byte-identical for all cases."
else
  echo "PARITY FAILED"; exit 1
fi

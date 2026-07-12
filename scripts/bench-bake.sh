#!/usr/bin/env bash
# Repeatable single-cell bake benchmark via perf stat (best-of-N by wall).
# Reports wall, total CPU time, page-faults and context-switches
# (the page-faults/ctx-switches are the mmap/syscall-churn signal).
#
# Usage: bench-bake.sh [cell.000 | ENC_ROOT] [runs]
#   The source defaults to $BENCH_CELL, else the first *.000 under $ENC_ROOT,
#   else the first *.000 under the repo's charts/ENC_ROOT. Pass a path to pin it.
#   MLT is the only bake format; the live-composite structure lands under
#   $OUT/tiles/<STEM>.pmtiles.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CELL="${1:-${BENCH_CELL:-}}"
if [ -z "$CELL" ]; then
  CELL="$(find "${ENC_ROOT:-$REPO/charts/ENC_ROOT}" -name '*.000' 2>/dev/null | sort | head -1)"
fi
[ -n "$CELL" ] && [ -e "$CELL" ] || {
  echo "usage: $(basename "$0") [cell.000 | ENC_ROOT] [runs]   (or set BENCH_CELL / ENC_ROOT)" >&2
  exit 2
}
RUNS="${2:-3}"
BIN="$REPO/zig-out/bin/tile57"
OUT=/tmp/bench-out

bestwall=""
for i in $(seq 1 "$RUNS"); do
  rm -rf "$OUT"
  perf stat -e task-clock,faults,context-switches -- \
        "$BIN" bake "$CELL" -o "$OUT" >/dev/null 2>/tmp/bench.perf
  # perf names the events task-clock:u / faults:u / context-switches:u and prints
  # thousands with commas; anchor on the field so prose (a failed run's usage
  # text) can't masquerade as a counter, and strip the commas.
  cpu=$(awk '$3 ~ /^task-clock/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  faults=$(awk '$2 ~ /^faults/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  csw=$(awk '$2 ~ /^context-switches/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  wall=$(awk '/seconds time elapsed/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  echo "  run $i: wall=${wall}s  cpu=${cpu}ms  page-faults=${faults}  ctx-switches=${csw}"
  if [ -z "$bestwall" ] || awk "BEGIN{exit !($wall < $bestwall)}"; then bestwall=$wall; bestline="wall=${wall}s cpu=${cpu}ms faults=${faults} csw=${csw}"; fi
done
echo "BEST: $bestline  ($(basename "$CELL"))"
[ -d "$OUT/tiles" ] && echo "tiles size: $(du -sh "$OUT/tiles" | cut -f1)"

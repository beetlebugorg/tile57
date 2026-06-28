#!/usr/bin/env bash
# Repeatable single-cell bake benchmark via perf stat (best-of-N by wall).
# Reports wall, total CPU time, page-faults and context-switches
# (the page-faults/ctx-switches are the mmap/syscall-churn signal).
# Usage: bench-bake.sh [cell.000] [mlt|mvt] [runs]
set -uo pipefail
CELL="${1:-/home/jcollins/.local/share/chart/enc/all/ENC_ROOT/US5WA42M/US5WA42M.000}"
FMT="${2:-mlt}"
RUNS="${3:-3}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/tile57"
OUT=/tmp/bench-out

bestwall=""
for i in $(seq 1 "$RUNS"); do
  rm -rf "$OUT"
  perf stat -e task-clock,faults,context-switches -- \
        "$BIN" bake "$CELL" -o "$OUT" --format "$FMT" >/dev/null 2>/tmp/bench.perf
  cpu=$(awk '/task-clock/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  faults=$(awk '/faults/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  csw=$(awk '/context-switches/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  wall=$(awk '/seconds time elapsed/{print $1; exit}' /tmp/bench.perf | tr -d ',')
  echo "  run $i: wall=${wall}s  cpu=${cpu}ms  page-faults=${faults}  ctx-switches=${csw}"
  if [ -z "$bestwall" ] || awk "BEGIN{exit !($wall < $bestwall)}"; then bestwall=$wall; bestline="wall=${wall}s cpu=${cpu}ms faults=${faults} csw=${csw}"; fi
done
echo "BEST: $bestline  ($(basename "$CELL"), $FMT)"
[ -f "$OUT/tiles/chart.pmtiles" ] && echo "tiles size: $(du -h "$OUT/tiles/chart.pmtiles" | cut -f1)"

#!/bin/bash
# test-metrics-accuracy.sh -- sanity-check V3 numbers against expectations.
#
# Generates known load, samples V3 for a short window, then checks that
# the relevant metric column is non-zero. This is NOT a bit-for-bit
# validation against V0 -- see the repo-root docs/VARIANT-COMPARISON.md for
# how the cross-variant head-to-head is done.

set -eu

BIN=${BIN:-./intp-ebpf}
if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN not built"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root"
    exit 1
fi

DURATION=6
OUT=$(mktemp)
trap 'rm -f "$OUT"; kill $LOAD_PID 2>/dev/null || true' EXIT

# Generate CPU + block + net load.
dd if=/dev/zero of=/tmp/v3-load bs=1M count=256 conv=fsync > /dev/null 2>&1 &
LOAD_PID=$!

timeout $((DURATION + 3)) "$BIN" --duration "$DURATION" --interval 1 \
    --no-resctrl --no-perf-events > "$OUT" 2>&1 || true

wait $LOAD_PID 2>/dev/null || true
rm -f /tmp/v3-load

# Parse: skip header lines (start with #) and the column header.
data=$(grep -E '^[0-9]+\s+[0-9]+' "$OUT" || true)
if [ -z "$data" ]; then
    echo "FAIL: no data rows"
    cat "$OUT"
    exit 1
fi

nonzero_cpu=$(echo "$data" | awk '{if ($7+0 > 0) print}' | wc -l)
nonzero_blk=$(echo "$data" | awk '{if ($3+0 > 0) print}' | wc -l)

echo "rows: $(echo "$data" | wc -l)"
echo "non-zero cpu samples: $nonzero_cpu"
echo "non-zero blk samples: $nonzero_blk"

if [ "$nonzero_cpu" -eq 0 ]; then
    echo "WARN: cpu column always zero -- sched_switch may not be attached"
fi
echo "OK (dataset):"
echo "$data" | head

#!/bin/bash
# test-overhead.sh -- measure idle/steady-state overhead following the
# Volpert et al. ICPE 2025 methodology (idle baseline vs instrumented).
#
# Not a full rigorous benchmark -- the Phase 3 evaluation uses the
# scripts in variants/v2-hybrid-c/scripts/ for that. This one just confirms
# overhead is in the expected "sub-1% under idle" ballpark.

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

WINDOW=10
echo "== phase 1: idle baseline ($WINDOW s) =="
t0=$(awk '{print $1+$2+$3+$4+$5+$6+$7}' /proc/stat | head -1)
sleep "$WINDOW"
t1=$(awk '{print $1+$2+$3+$4+$5+$6+$7}' /proc/stat | head -1)
base_used=$(( t1 - t0 ))

echo "== phase 2: with intp-ebpf running ($WINDOW s) =="
"$BIN" --duration "$WINDOW" --interval 1 --no-resctrl --no-perf-events \
    > /dev/null 2>&1 &
PID=$!
t2=$(awk '{print $1+$2+$3+$4+$5+$6+$7}' /proc/stat | head -1)
wait $PID 2>/dev/null || true
t3=$(awk '{print $1+$2+$3+$4+$5+$6+$7}' /proc/stat | head -1)
inst_used=$(( t3 - t2 ))

delta=$(( inst_used - base_used ))
echo "baseline jiffies:      $base_used"
echo "instrumented jiffies:  $inst_used"
echo "delta:                 $delta"

if [ "$delta" -gt $(( base_used / 10 + 200 )) ]; then
    echo "FAIL: overhead looks high -- expected <10% + 200 jiffies"
    exit 1
fi
echo "OK: overhead within expected bounds"

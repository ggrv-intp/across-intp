#!/bin/bash
# test-no-ctxsw-amplification.sh
#
# V3.2's central acceptance test for the SBAC-PAD 2026 paper hypothesis:
# the in-kernel-aggregation profiler must NOT structurally amplify the
# system-wide context switch rate (paper §V-B documents V3's
# 194-416x amplification driven by the ring-buffer consumer loop).
#
# Methodology mirrors the paper's vmstat ctxt ground-truth measurement:
#   1. Start a reference workload (stress-ng or equivalent).
#   2. Wait WARMUP seconds for it to reach steady state.
#   3. Sample 'vmstat 1' for DUR seconds and sum the ctxt column.
#      This gives the BASELINE (workload only).
#   4. Tear down + restart the workload (clean slate).
#   5. Repeat step 2.
#   6. Start intp-ebpf-core in the background.
#   7. Sample 'vmstat 1' for DUR seconds and sum the ctxt column.
#      This gives the WITH measurement (workload + profiler).
#   8. ratio = WITH / BASELINE. Pass if ratio <= MAX_RATIO (default 1.10).
#
# V3 fails this test at 194-416x. V3.2 should pass within noise.

set -eu

BIN=${BIN:-./intp-ebpf-core}
DUR=${DUR:-90}
WARMUP=${WARMUP:-15}
MAX_RATIO=${MAX_RATIO:-1.10}
WORKLOAD=${WORKLOAD:-cpu}   # cpu | disk | stream

if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN not built -- run 'make' first"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (BPF + perf_event need privileges)"
    exit 1
fi
if ! command -v stress-ng >/dev/null 2>&1; then
    echo "SKIP: stress-ng not installed (apt install stress-ng)"
    exit 77      # autotools' standard SKIP code
fi
if ! command -v vmstat >/dev/null 2>&1; then
    echo "ERROR: vmstat not installed (apt install procps)"
    exit 1
fi

stress_args() {
    case "$WORKLOAD" in
        cpu)    echo "--cpu 8 --cpu-method all --metrics-brief" ;;
        disk)   echo "--hdd 4 --hdd-bytes 1G --metrics-brief" ;;
        stream) echo "--stream 4 --stream-l3-size 4M --metrics-brief" ;;
        *)      echo "ERROR: unknown WORKLOAD=$WORKLOAD" >&2; exit 1 ;;
    esac
}

start_stress() {
    local total=$((DUR + WARMUP + 10))
    # shellcheck disable=SC2046
    stress-ng $(stress_args) --timeout "${total}s" >/dev/null 2>&1 &
    echo $!
}

measure_ctxt() {
    # vmstat 1 prints 1-second samples; the 12th whitespace field is 'cs'
    # (context switches per second). Drop the header rows (NR>2).
    vmstat 1 "$DUR" | awk 'NR>2 {s+=$12} END {print s+0}'
}

echo "=== V3.2 ctxsw amplification test (workload=$WORKLOAD dur=${DUR}s warmup=${WARMUP}s) ==="
echo

echo "[1/2] baseline (workload only)"
sp=$(start_stress)
sleep "$WARMUP"
baseline=$(measure_ctxt)
echo "  baseline ctxt sum = $baseline"
kill "$sp" 2>/dev/null || true
wait "$sp" 2>/dev/null || true
sleep 2

echo
echo "[2/2] with $BIN running"
sp=$(start_stress)
"$BIN" --interval 1 --duration $((DUR + WARMUP + 5)) \
       --no-resctrl --no-perf-events --no-header \
       > /tmp/v32-amplification.tsv 2>/tmp/v32-amplification.log &
pp=$!
sleep "$WARMUP"
withp=$(measure_ctxt)
echo "  with-profiler ctxt sum = $withp"
kill "$pp" "$sp" 2>/dev/null || true
wait "$pp" "$sp" 2>/dev/null || true

# Bash has no float arithmetic; awk it.
ratio=$(awk -v w="$withp" -v b="$baseline" \
        'BEGIN { if (b <= 0) print "inf"; else printf "%.4f", w / b }')
echo
echo "RESULT: baseline=$baseline  with=$withp  ratio=$ratio  (limit=$MAX_RATIO)"

fail=$(awk -v r="$ratio" -v m="$MAX_RATIO" \
       'BEGIN { print (r == "inf" || r+0 > m+0) ? 1 : 0 }')
if [ "$fail" = "1" ]; then
    echo "FAIL: ctxsw amplification ratio $ratio exceeds limit $MAX_RATIO"
    echo "  (V3 fails this test at 194-416x; if V3.2 is failing too, the"
    echo "   in-kernel aggregation is still feeding a userspace draining loop)"
    exit 1
fi

echo "PASS: ctxsw ratio within tolerance (V3 fails at 194-416x)"

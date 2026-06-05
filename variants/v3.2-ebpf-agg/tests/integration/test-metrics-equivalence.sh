#!/bin/bash
# test-metrics-equivalence.sh -- V3 vs V3.2 head-to-head numeric check.
#
# Runs both profilers back-to-back over the same workload (stress-ng
# --vm 4 --vm-bytes 1G, 30s) and verifies each of the 7 canonical
# metrics (netp/nets/blk/mbw/llcmr/llcocc/cpu) agrees within ABS_TOL
# absolute percentage points when both medians are below NEAR_ZERO,
# OR within REL_TOL fractional tolerance when above.
#
# This is a smoke check, not a measurement: the two profilers see
# slightly different sample windows and probe sites, so we accept
# 15% by default. The cross-variant statistical validation lives in
# shared/validate-cross-variant.sh.

set -eu

# Sibling variant under variants/; this test is run with CWD = the v3.2
# variant root (where ./intp-ebpf-agg sits), so the sibling is one level up.
V3_BIN=${V3_BIN:-../v3-ebpf-ring/intp-ebpf}
V32_BIN=${V32_BIN:-./intp-ebpf-agg}
DUR=${DUR:-30}
REL_TOL=${REL_TOL:-0.15}    # 15% fractional tolerance
ABS_TOL=${ABS_TOL:-5}       # 5 percentage points when median is near zero
NEAR_ZERO=${NEAR_ZERO:-2}   # below this, switch from REL to ABS tolerance

if [ ! -x "$V32_BIN" ]; then
    echo "ERROR: $V32_BIN not built"
    exit 1
fi
if [ ! -x "$V3_BIN" ]; then
    echo "SKIP: $V3_BIN not built (run 'make' in variants/v3-ebpf-ring first)"
    exit 77
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root"
    exit 1
fi
if ! command -v stress-ng >/dev/null 2>&1; then
    echo "SKIP: stress-ng not installed"
    exit 77
fi

V3_OUT=$(mktemp)
V32_OUT=$(mktemp)
STRESS_LOG=$(mktemp)
trap 'rm -f "$V3_OUT" "$V32_OUT" "$STRESS_LOG"' EXIT

run_once() {
    local label="$1"; local bin="$2"; local out="$3"
    echo "[$label] starting stress-ng --vm 4 --vm-bytes 1G --timeout $((DUR+10))s"
    stress-ng --vm 4 --vm-bytes 1G --timeout $((DUR + 10))s \
        > "$STRESS_LOG" 2>&1 &
    local sp=$!
    sleep 3
    echo "[$label] profiling $bin for ${DUR}s"
    timeout $((DUR + 5)) "$bin" --interval 1 --duration "$DUR" \
        --no-resctrl > "$out" 2>/dev/null || true
    kill "$sp" 2>/dev/null || true
    wait "$sp" 2>/dev/null || true
    sleep 2
}

run_once "V3"   "$V3_BIN"  "$V3_OUT"
run_once "V3.2" "$V32_BIN" "$V32_OUT"

# Awk-based median across the 7 canonical columns.
medians() {
    # Skip header lines starting with # and the column-header line.
    awk -F'\t' '
        /^#/      { next }
        /^[a-z]/  { next }      # column header
        NF >= 7   {
            for (i = 1; i <= 7; i++) v[i, n[i]++] = $i + 0
        }
        END {
            for (i = 1; i <= 7; i++) {
                m = n[i]
                if (m == 0) { printf "0"; if (i<7) printf "\t"; continue }
                # crude sort + middle
                for (a = 0; a < m; a++)
                    for (b = a+1; b < m; b++)
                        if (v[i,b] < v[i,a]) {
                            t = v[i,a]; v[i,a] = v[i,b]; v[i,b] = t
                        }
                printf "%.2f", (m % 2 == 1) ? v[i, int(m/2)]
                                            : (v[i, m/2 - 1] + v[i, m/2]) / 2.0
                if (i < 7) printf "\t"
            }
            print ""
        }
    ' "$1"
}

V3_MED=$(medians "$V3_OUT")
V32_MED=$(medians "$V32_OUT")

echo
echo "metric   V3       V3.2     |diff|   tol"
printf "header   netp nets blk mbw llcmr llcocc cpu\n"
echo "V3       $V3_MED"
echo "V3.2     $V32_MED"

names=(netp nets blk mbw llcmr llcocc cpu)
fail=0
for i in 1 2 3 4 5 6 7; do
    v3=$(echo "$V3_MED"  | cut -f"$i")
    v32=$(echo "$V32_MED" | cut -f"$i")
    pass=$(awk -v a="$v3" -v b="$v32" -v rt="$REL_TOL" -v at="$ABS_TOL" -v nz="$NEAR_ZERO" \
           'BEGIN {
                d = (a > b) ? a - b : b - a;
                max = (a > b) ? a : b;
                # near-zero: use abs tolerance
                if (max < nz) { print (d <= at) ? "ok" : "fail" }
                # otherwise: relative tolerance
                else { print (d / max <= rt) ? "ok" : "fail" }
            }')
    name="${names[i-1]}"
    if [ "$pass" = "ok" ]; then
        echo "  $name $v3 vs $v32  -- ok"
    else
        echo "  $name $v3 vs $v32  -- FAIL"
        fail=1
    fi
done

if [ $fail -ne 0 ]; then
    echo
    echo "FAIL: V3 / V3.2 medians diverge beyond tolerance on at least one metric"
    exit 1
fi
echo
echo "PASS: V3 and V3.2 medians agree within tolerance on all 7 metrics"

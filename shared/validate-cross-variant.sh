#!/bin/bash
# -----------------------------------------------------------------------------
# validate-cross-variant.sh
#
# Cross-variant byte-equivalence test for IntP V2/V3.1/V3/V3.2 (the
# runtime-binary variants; the stap-based variants are not covered here).
#
# Runs each available variant under identical conditions (same target PID,
# same interval, same duration), captures TSV output, then compares the
# seven metric columns across all variants.
#
# Requirements:
#   - Root privileges (for tracing / resctrl access)
#   - A workload PID to monitor (e.g. stress-ng)
#   - At least two variants built and available
#
# Usage:
#   sudo ./validate-cross-variant.sh [options]
#
# Options:
#   --pid PID             Target PID (required unless --start-workload)
#   --start-workload      Auto-start stress-ng as the workload
#   --interval SECONDS    Sampling interval (default: 1)
#   --duration SECONDS    Collection duration (default: 10)
#   --tolerance PCT       Max allowed column divergence in % points (default: 15)
#   --output-dir DIR      Directory for captured outputs (default: /tmp/intp-xval-*)
#   --v2-bin PATH         Path to V2 binary (default: ../variants/v2-hybrid-c/intp-hybrid)
#   --v3.1-script PATH    Path to V3.1 launcher (default: ../variants/v3.1-bpftrace/run-intp-bpftrace.sh)
#   --v3-bin PATH         Path to V3 binary (default: ../variants/v3-ebpf-ring/intp-ebpf)
#   --v3.2-bin PATH       Path to V3.2 binary (default: ../variants/v3.2-ebpf-agg/intp-ebpf-agg)
#   --nic-speed-bps N    Force NIC speed (bytes/sec) for all variants
#   --mem-bw-max-bps N   Force memory bandwidth ceiling (bytes/sec) for all variants
#   --llc-size-bytes N   Force LLC size (bytes) for all variants
#   --dry-run             Show what would be run without executing
#   -h, --help            Show this help
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
TARGET_PID=0
START_WORKLOAD=0
INTERVAL=1
DURATION=10
TOLERANCE=15
OUTPUT_DIR=""
DRY_RUN=0
WORKLOAD_PID=""
NIC_SPEED_BPS=""
MEM_BW_MAX_BPS=""
LLC_SIZE_BYTES=""

V2_BIN="${REPO_ROOT}/variants/v2-hybrid-c/intp-hybrid"
V3_1_SCRIPT="${REPO_ROOT}/variants/v3.1-bpftrace/run-intp-bpftrace.sh"
V3_BIN="${REPO_ROOT}/variants/v3-ebpf-ring/intp-ebpf"
V3_2_BIN="${REPO_ROOT}/variants/v3.2-ebpf-agg/intp-ebpf-agg"

METRICS=("netp" "nets" "blk" "mbw" "llcmr" "llcocc" "cpu")

# -- Argument parsing ----------------------------------------------------------

usage() {
    sed -n '/^# Usage:/,/^# ---/{ /^# ---/d; s/^# //; s/^#//; p; }' "$0"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid)            TARGET_PID="$2"; shift 2 ;;
            --start-workload) START_WORKLOAD=1; shift ;;
            --interval)       INTERVAL="$2"; shift 2 ;;
            --duration)       DURATION="$2"; shift 2 ;;
            --tolerance)      TOLERANCE="$2"; shift 2 ;;
            --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
            --v2-bin)         V2_BIN="$2"; shift 2 ;;
            --v3.1-script)    V3_1_SCRIPT="$2"; shift 2 ;;
            --v3-bin)         V3_BIN="$2"; shift 2 ;;
            --v3.2-bin)       V3_2_BIN="$2"; shift 2 ;;
            --nic-speed-bps)  NIC_SPEED_BPS="$2"; shift 2 ;;
            --mem-bw-max-bps) MEM_BW_MAX_BPS="$2"; shift 2 ;;
            --llc-size-bytes) LLC_SIZE_BYTES="$2"; shift 2 ;;
            --dry-run)        DRY_RUN=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                echo "Unknown option: $1" >&2; usage; exit 2 ;;
        esac
    done
}

# -- Utility functions ---------------------------------------------------------

log()  { echo "[xval] $*"; }
warn() { echo "[xval] WARNING: $*" >&2; }
die()  { echo "[xval] FATAL: $*" >&2; exit 1; }

cleanup() {
    if [[ -n "$WORKLOAD_PID" ]]; then
        kill "$WORKLOAD_PID" 2>/dev/null || true
        wait "$WORKLOAD_PID" 2>/dev/null || true
        log "Stopped workload (PID $WORKLOAD_PID)"
    fi
}

# Check if a variant is available and return 0 if so
variant_available() {
    local name="$1"
    case "$name" in
        v2)
            [[ -x "$V2_BIN" ]]
            ;;
        v3.1)
            [[ -x "$V3_1_SCRIPT" ]] && command -v bpftrace >/dev/null 2>&1
            ;;
        v3)
            [[ -x "$V3_BIN" ]]
            ;;
        v3.2)
            [[ -x "$V3_2_BIN" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# Run a variant and capture TSV output
run_variant() {
    local name="$1"
    local outfile="$2"

    log "Running $name (interval=${INTERVAL}s, duration=${DURATION}s, pid=${TARGET_PID})..."

    local pid_args=()
    if [[ "$TARGET_PID" -gt 0 ]]; then
        pid_args=(--pid "$TARGET_PID")
        # V2 uses --pids (plural)
        [[ "$name" == "v2" ]] && pid_args=(--pids "$TARGET_PID")
    fi

    # Hardware overrides ensure all variants normalise against the same
    # constants, eliminating detect-path divergence as a noise source.
    local hw_args=()
    [[ -n "$NIC_SPEED_BPS" ]]  && hw_args+=(--nic-speed-bps "$NIC_SPEED_BPS")
    [[ -n "$MEM_BW_MAX_BPS" ]] && hw_args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    [[ -n "$LLC_SIZE_BYTES" ]] && hw_args+=(--llc-size-bytes "$LLC_SIZE_BYTES")

    case "$name" in
        v2)
            timeout "$((DURATION + 5))" "$V2_BIN" \
                "${pid_args[@]}" \
                "${hw_args[@]}" \
                --interval "$INTERVAL" \
                --duration "$DURATION" \
                --output tsv \
                --no-header \
                > "$outfile" 2>"${outfile}.err" || true
            ;;
        v3.1)
            timeout "$((DURATION + 5))" "$V3_1_SCRIPT" \
                "${pid_args[@]}" \
                "${hw_args[@]}" \
                --interval "$INTERVAL" \
                --duration "$DURATION" \
                > "$outfile" 2>"${outfile}.err" || true
            ;;
        v3)
            timeout "$((DURATION + 5))" "$V3_BIN" \
                "${pid_args[@]}" \
                "${hw_args[@]}" \
                --interval "$INTERVAL" \
                --duration "$DURATION" \
                --output tsv \
                --no-header \
                > "$outfile" 2>"${outfile}.err" || true
            ;;
        v3.2)
            # --no-raw-mbw keeps V3.2 column count at 7 so column_means
            # and compare_pair stay byte-compatible with the other
            # variants. The mbw_raw_mbps diagnostic stream isn't part of
            # the cross-variant equivalence check.
            timeout "$((DURATION + 5))" "$V3_2_BIN" \
                "${pid_args[@]}" \
                "${hw_args[@]}" \
                --interval "$INTERVAL" \
                --duration "$DURATION" \
                --output tsv \
                --no-header \
                --no-raw-mbw \
                > "$outfile" 2>"${outfile}.err" || true
            ;;
    esac

    local lines
    lines=$(grep -cE '^[0-9]' "$outfile" 2>/dev/null || echo 0)
    log "  $name: captured $lines data rows -> $outfile"
}

# Extract column means from a TSV file (skip comment/header lines)
column_means() {
    local file="$1"
    awk -F'\t' '
    /^[0-9]/ {
        for (i = 1; i <= NF; i++) {
            sum[i] += $i
        }
        n++
    }
    END {
        if (n == 0) { print "NO_DATA"; exit }
        for (i = 1; i <= 7; i++) {
            printf "%.2f", sum[i] / n
            if (i < 7) printf "\t"
        }
        printf "\n"
    }' "$file"
}

# Compare two TSV files column-by-column
compare_pair() {
    local name_a="$1"
    local file_a="$2"
    local name_b="$3"
    local file_b="$4"
    local tol="$5"

    local means_a means_b
    means_a=$(column_means "$file_a")
    means_b=$(column_means "$file_b")

    if [[ "$means_a" == "NO_DATA" || "$means_b" == "NO_DATA" ]]; then
        warn "$name_a vs $name_b: insufficient data for comparison"
        return 1
    fi

    local pass=0
    local fail=0
    local i=0

    local IFS=$'\t'
    read -ra vals_a <<< "$means_a"
    read -ra vals_b <<< "$means_b"

    echo ""
    printf "  %-7s  %6s  %6s  %6s  %s\n" "Metric" "$name_a" "$name_b" "Delta" "Status"
    printf "  %-7s  %6s  %6s  %6s  %s\n" "-------" "------" "------" "------" "------"

    for metric in "${METRICS[@]}"; do
        local a="${vals_a[$i]}"
        local b="${vals_b[$i]}"
        local delta
        delta=$(awk "BEGIN { d = $a - $b; print (d < 0 ? -d : d) }")
        local status
        if awk "BEGIN { exit !($delta <= $tol) }"; then
            status="OK"
            ((pass++)) || true
        else
            status="DIVERGENT"
            ((fail++)) || true
        fi
        printf "  %-7s  %6s  %6s  %6.2f  %s\n" "$metric" "$a" "$b" "$delta" "$status"
        ((i++)) || true
    done

    echo ""
    if [[ "$fail" -gt 0 ]]; then
        warn "$name_a vs $name_b: $fail of 7 metrics exceed tolerance (${tol}%)"
        return 1
    else
        log "$name_a vs $name_b: all 7 metrics within tolerance (${tol}%)"
        return 0
    fi
}

# -- Main ----------------------------------------------------------------------

main() {
    parse_args "$@"

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR=$(mktemp -d /tmp/intp-xval-XXXXXX)
    else
        mkdir -p "$OUTPUT_DIR"
    fi

    trap cleanup EXIT INT TERM

    # Discover available variants
    local available=()
    for v in v2 v3.1 v3 v3.2; do
        if variant_available "$v"; then
            available+=("$v")
            log "Variant $v: available"
        else
            log "Variant $v: not found (skipping)"
        fi
    done

    if [[ "${#available[@]}" -lt 2 ]]; then
        die "Need at least 2 available variants for comparison (found: ${available[*]:-none})"
    fi

    # Start workload if requested
    if [[ "$START_WORKLOAD" -eq 1 ]]; then
        if ! command -v stress-ng >/dev/null 2>&1; then
            die "--start-workload requires stress-ng (apt install stress-ng)"
        fi
        stress-ng --cpu 2 --vm 1 --vm-bytes 64M --hdd 1 \
                  --sock 1 --timeout "$((DURATION + 15))s" --quiet &
        WORKLOAD_PID=$!
        TARGET_PID=$WORKLOAD_PID
        log "Started stress-ng workload (PID $WORKLOAD_PID)"
        sleep 2  # let workload stabilize
    fi

    if [[ "$TARGET_PID" -eq 0 ]]; then
        log "No --pid specified; running system-wide"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY RUN -- would run: ${available[*]}"
        log "  interval=$INTERVAL  duration=$DURATION  pid=$TARGET_PID"
        log "  output_dir=$OUTPUT_DIR  tolerance=$TOLERANCE"
        exit 0
    fi

    # Run each variant sequentially (avoids resource contention)
    for v in "${available[@]}"; do
        run_variant "$v" "$OUTPUT_DIR/${v}.tsv"
    done

    # Compare all pairs
    log "=== Cross-variant comparison (tolerance: ${TOLERANCE}%) ==="

    local total_pass=0
    local total_fail=0
    local n_pairs=0

    for ((i = 0; i < ${#available[@]}; i++)); do
        for ((j = i + 1; j < ${#available[@]}; j++)); do
            local a="${available[$i]}"
            local b="${available[$j]}"
            ((n_pairs++)) || true
            if compare_pair "$a" "$OUTPUT_DIR/${a}.tsv" \
                            "$b" "$OUTPUT_DIR/${b}.tsv" \
                            "$TOLERANCE"; then
                ((total_pass++)) || true
            else
                ((total_fail++)) || true
            fi
        done
    done

    # Summary
    echo ""
    log "=== Summary ==="
    log "  Variants tested: ${available[*]}"
    log "  Pairs compared:  $n_pairs"
    log "  Passed:          $total_pass"
    log "  Failed:          $total_fail"
    log "  Output:          $OUTPUT_DIR"

    # Generate Markdown report
    local report="$OUTPUT_DIR/report.md"
    {
        echo "# IntP Cross-Variant Equivalence Report"
        echo ""
        echo "Date: $(date -Iseconds)"
        echo ""
        echo "| Parameter | Value |"
        echo "|-----------|-------|"
        echo "| Target PID | $TARGET_PID |"
        echo "| Interval | ${INTERVAL}s |"
        echo "| Duration | ${DURATION}s |"
        echo "| Tolerance | ${TOLERANCE}% |"
        echo "| Variants | ${available[*]} |"
        [[ -n "$NIC_SPEED_BPS" ]]  && echo "| NIC speed override | ${NIC_SPEED_BPS} B/s |"
        [[ -n "$MEM_BW_MAX_BPS" ]] && echo "| Mem BW override | ${MEM_BW_MAX_BPS} B/s |"
        [[ -n "$LLC_SIZE_BYTES" ]] && echo "| LLC size override | ${LLC_SIZE_BYTES} B |"
        echo ""
        echo "## Per-Variant Output"
        echo ""
        for v in "${available[@]}"; do
            local lines
            lines=$(grep -cE '^[0-9]' "$OUTPUT_DIR/${v}.tsv" 2>/dev/null || echo 0)
            local means
            means=$(column_means "$OUTPUT_DIR/${v}.tsv")
            echo "### $v ($lines rows)"
            echo ""
            echo '```'
            echo "Mean: $means"
            echo '```'
            echo ""
        done
        echo "## Result"
        echo ""
        if [[ "$total_fail" -eq 0 ]]; then
            echo "**PASS** -- all $n_pairs variant pairs agree within ${TOLERANCE}%."
        else
            echo "**FAIL** -- $total_fail of $n_pairs pairs exceed the ${TOLERANCE}% tolerance."
        fi
    } > "$report"
    log "  Report:          $report"

    if [[ "$total_fail" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"

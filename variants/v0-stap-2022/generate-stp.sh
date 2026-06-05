#!/bin/bash
# -----------------------------------------------------------------------------
# generate-stp.sh -- recalibrate V0's intp.stp for the current host.
#
# Reads intp.stp.template, substitutes @@PLACEHOLDER@@ tokens with values
# detected by shared/intp-detect.sh (extended), writes intp.recal.stp.
#
# intp.stp itself is read-only (paper-faithful 2022 baseline). All host
# adaptation flows through this generator.
#
# Output stdout: KEY=VALUE lines documenting every substituted value. The
# launcher captures this as <rep-dir>/v0-calibration.kv per run.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# This variant lives at variants/<name>/; the repo root is two levels up.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"

TEMPLATE="$SCRIPT_DIR/intp.stp.template"
OUTPUT="$SCRIPT_DIR/intp.recal.stp"
DETECT="$REPO_ROOT/shared/intp-detect.sh"

[ -f "$TEMPLATE" ] || { echo "generate-stp.sh: template missing: $TEMPLATE" >&2; exit 2; }
[ -x "$DETECT" ]   || { echo "generate-stp.sh: detect missing/not exec: $DETECT" >&2; exit 2; }

# -- Source detection output --------------------------------------------------
# intp-detect.sh prints `KEY=VALUE` lines; eval imports them into our scope.
_detect_out="$("$DETECT")"
# shellcheck disable=SC2046
eval "$(echo "$_detect_out" | grep -E '^INTP_[A-Z0-9_]+=')"

# -- Required variables for V0 recalibration ---------------------------------
required=(
    INTP_NIC_SPEED_MBPS
    INTP_LLC_SIZE_KB
    INTP_MEM_BW_MBPS
    INTP_IMC_PMU_TYPE
    INTP_IMC_CHANNEL_COUNT
    INTP_CMT_SCALE_FACTOR
)
missing=()
for v in "${required[@]}"; do
    if [ -z "${!v:-}" ]; then
        missing+=("$v")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "generate-stp.sh: required variables not set by intp-detect.sh: ${missing[*]}" >&2
    exit 3
fi

# -- Unit conversions ---------------------------------------------------------
# NIC: Mbps (decimal 10^6 bits/sec) -> bytes/sec = Mbps * 10^6 / 8 = Mbps * 125000.
# LLC: binary KB (sysfs) -> bytes = KB * 1024.
# MEM: Mbps -> bytes/sec = Mbps * 125000.
NIC_BYTES_PER_SEC=$(( INTP_NIC_SPEED_MBPS * 125000 ))
LLC_BYTES=$(( INTP_LLC_SIZE_KB * 1024 ))
MEM_BW_BYTES_PER_SEC=$(( INTP_MEM_BW_MBPS * 125000 ))
IMC_PMU_TYPE="$INTP_IMC_PMU_TYPE"
CMT_SCALE_FACTOR="$INTP_CMT_SCALE_FACTOR"

# -- Warnings (do not abort) --------------------------------------------------
# OPERATOR: validate against actual host output.
if [ "$INTP_IMC_CHANNEL_COUNT" -gt 2 ] 2>/dev/null; then
    echo "WARN: $INTP_IMC_CHANNEL_COUNT IMC channels detected; V0 script samples only 2" \
         "(CPUs 0 and 1) — measured mbw will be a lower bound" >&2
fi
if [ "${INTP_CMT_SCALE_FACTOR_FALLBACK:-0}" = "1" ]; then
    echo "WARN: INTP_CMT_SCALE_FACTOR fell back to 49152 (could not read from sysfs)" >&2
fi

# -- Substitute (one sed call per placeholder for readable logs) -------------
cp -- "$TEMPLATE" "$OUTPUT"

sed -i "s|@@NIC_BYTES_PER_SEC@@|${NIC_BYTES_PER_SEC}|g"     "$OUTPUT"
sed -i "s|@@LLC_BYTES@@|${LLC_BYTES}|g"                     "$OUTPUT"
sed -i "s|@@MEM_BW_BYTES_PER_SEC@@|${MEM_BW_BYTES_PER_SEC}|g" "$OUTPUT"
sed -i "s|@@IMC_PMU_TYPE@@|${IMC_PMU_TYPE}|g"               "$OUTPUT"
sed -i "s|@@CMT_SCALE_FACTOR@@|${CMT_SCALE_FACTOR}|g"       "$OUTPUT"

# -- Verify all placeholders were consumed ------------------------------------
remaining=$(grep -nE '@@[A-Z0-9_]+@@' "$OUTPUT" || true)
if [ -n "$remaining" ]; then
    echo "generate-stp.sh: unsubstituted placeholders remain in $OUTPUT:" >&2
    echo "$remaining" >&2
    exit 4
fi

# -- Calibration log (stdout) -------------------------------------------------
cat <<KV
INTP_NIC_SPEED_MBPS=$INTP_NIC_SPEED_MBPS
INTP_LLC_SIZE_KB=$INTP_LLC_SIZE_KB
INTP_MEM_BW_MBPS=$INTP_MEM_BW_MBPS
INTP_IMC_PMU_TYPE=$INTP_IMC_PMU_TYPE
INTP_IMC_CHANNEL_COUNT=$INTP_IMC_CHANNEL_COUNT
INTP_CMT_SCALE_FACTOR=$INTP_CMT_SCALE_FACTOR
INTP_CMT_SCALE_FACTOR_FALLBACK=${INTP_CMT_SCALE_FACTOR_FALLBACK:-0}
SUBST_NIC_BYTES_PER_SEC=$NIC_BYTES_PER_SEC
SUBST_LLC_BYTES=$LLC_BYTES
SUBST_MEM_BW_BYTES_PER_SEC=$MEM_BW_BYTES_PER_SEC
SUBST_IMC_PMU_TYPE=$IMC_PMU_TYPE
SUBST_CMT_SCALE_FACTOR=$CMT_SCALE_FACTOR
OUTPUT_PATH=$OUTPUT
KV

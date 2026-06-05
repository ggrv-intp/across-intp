#!/bin/bash
# -----------------------------------------------------------------------------
# generate-stp.sh -- recalibrate v0.2's intp.stp for the current host.
#
# Reads intp.stp.template, substitutes @@NIC_BYTES_PER_SEC@@ with the value
# detected by shared/intp-detect.sh, writes intp.recal.stp.
#
# v0.2 has fewer placeholders than v0 because the RCU-unsafe IMC + cqm_rmid
# operations now live in the userspace helper (intp-helper). All host-side
# calibration for those metrics flows through helper environment variables
# (INTP_HELPER_DRAM_BW_MBPS, INTP_HELPER_L3_SIZE_KB, INTP_HELPER_IMC_PMU_TYPE);
# the bench launcher derives those from intp-detect.sh at run time.
#
# Output stdout: KEY=VALUE lines documenting every substituted value. The
# launcher captures this as <rep-dir>/v0.2-calibration.kv per run.
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

_detect_out="$("$DETECT")"
# shellcheck disable=SC2046
eval "$(echo "$_detect_out" | grep -E '^INTP_[A-Z0-9_]+=')"

required=(
    INTP_NIC_SPEED_MBPS
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

NIC_BYTES_PER_SEC=$(( INTP_NIC_SPEED_MBPS * 125000 ))

cp -- "$TEMPLATE" "$OUTPUT"

sed -i "s|@@NIC_BYTES_PER_SEC@@|${NIC_BYTES_PER_SEC}|g" "$OUTPUT"

remaining=$(grep -nE '@@[A-Z0-9_]+@@' "$OUTPUT" || true)
if [ -n "$remaining" ]; then
    echo "generate-stp.sh: unsubstituted placeholders remain in $OUTPUT:" >&2
    echo "$remaining" >&2
    exit 4
fi

cat <<KV
INTP_NIC_SPEED_MBPS=$INTP_NIC_SPEED_MBPS
SUBST_NIC_BYTES_PER_SEC=$NIC_BYTES_PER_SEC
OUTPUT_PATH=$OUTPUT
KV

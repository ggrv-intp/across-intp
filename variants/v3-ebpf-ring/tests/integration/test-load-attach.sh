#!/bin/bash
# test-load-attach.sh -- smoke test: launch intp-ebpf, verify programs
# load and attach, let it run briefly, check no programs leak.

set -eu

BIN=${BIN:-./intp-ebpf}
DURATION=${DURATION:-3}

if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN not built -- run 'make' first"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (BPF + perf_event need privileges)"
    exit 1
fi

pre_count="$(bpftool prog show 2>/dev/null | wc -l | tr -d '[:space:]')"
pre_count="${pre_count:-0}"
echo "pre-run BPF program count: $pre_count"

out=$(mktemp)
trap 'rm -f "$out"' EXIT

echo "running $BIN --duration $DURATION --interval 1 --no-resctrl --no-perf-events"
timeout $((DURATION + 5)) "$BIN" --duration "$DURATION" --interval 1 \
    --no-resctrl --no-perf-events > "$out" 2>&1 || true

post_count="$(bpftool prog show 2>/dev/null | wc -l | tr -d '[:space:]')"
post_count="${post_count:-0}"
echo "post-run BPF program count: $post_count"

if [ "$post_count" -gt "$pre_count" ]; then
    echo "FAIL: leaked BPF programs (pre=$pre_count post=$post_count)"
    bpftool prog show 2>&1 | head -40
    exit 1
fi

lines="$(awk -F '\t' '/^[0-9]+\t/{c++} END{print c+0}' "$out")"
if [ "$lines" -lt 1 ]; then
    echo "FAIL: no TSV lines produced (output follows)"
    cat "$out"
    exit 1
fi

echo "OK: produced $lines TSV samples, no leaked programs"

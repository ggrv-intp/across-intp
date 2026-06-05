#!/bin/bash
# test-core-portability.sh -- verify that the compiled BPF object loads
# under the running kernel using CO-RE relocation.
#
# This does not, by itself, test cross-kernel portability -- that
# requires running the same `intp.bpf.o` on several distinct kernels.
# What it does prove is that:
#   - the skeleton/program verifies against the *current* kernel's BTF
#   - every CO-RE relocation is resolvable (no "field not found" errors)
#
# Usage:
#   bash scripts/test-core-portability.sh          # uses src/intp.bpf.o
#   bash scripts/test-core-portability.sh PATH.o   # uses a given object

set -eu

OBJ=${1:-src/intp.bpf.o}
PIN_ROOT=/sys/fs/bpf/intp-v3-core-test

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (bpftool needs CAP_BPF + CAP_PERFMON)"
    exit 1
fi
if [ ! -f "$OBJ" ]; then
    echo "ERROR: BPF object '$OBJ' not found -- run 'make' first"
    exit 1
fi

echo "== kernel: $(uname -r) ==  BPF object: $OBJ"

rm -rf "$PIN_ROOT"
if ! bpftool prog loadall "$OBJ" "$PIN_ROOT"; then
    echo "FAIL: loadall on $(uname -r) failed"
    exit 1
fi

loaded=$(bpftool prog show pinned "$PIN_ROOT" 2>/dev/null | wc -l)
if [ "$loaded" -eq 0 ]; then
    echo "FAIL: loadall reported success but no programs pinned"
    rm -rf "$PIN_ROOT"
    exit 1
fi

echo "loaded ${loaded} programs under $PIN_ROOT"
bpftool prog show pinned "$PIN_ROOT" 2>/dev/null || true

rm -rf "$PIN_ROOT"
echo "OK: CO-RE load succeeded on $(uname -r)"
echo
echo "To test cross-kernel portability, run this same object on a"
echo "different kernel without rebuilding. A successful load there"
echo "proves BTF-based relocation is doing its job."

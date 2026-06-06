#!/bin/bash
# gen-vmlinux.sh -- dump the running kernel's BTF into vmlinux.h.
#
# This is the one and only header the BPF programs need for CO-RE --
# it contains every kernel type definition we might reference. Standard
# kernel headers are NOT used on the BPF side.
#
# Requires: bpftool, kernel built with CONFIG_DEBUG_INFO_BTF=y.

set -eu

OUTPUT=${1:-src/vmlinux.h}
BTF=/sys/kernel/btf/vmlinux

if ! command -v bpftool >/dev/null 2>&1; then
    echo "ERROR: bpftool not found (try: apt install linux-tools-generic)"
    exit 1
fi
if [ ! -f "$BTF" ]; then
    echo "ERROR: $BTF not present"
    echo "       The running kernel must be built with CONFIG_DEBUG_INFO_BTF=y."
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
bpftool btf dump file "$BTF" format c > "$OUTPUT"
lines=$(wc -l < "$OUTPUT")
echo "generated $OUTPUT (${lines} lines)"

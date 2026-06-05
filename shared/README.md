# Shared Components

This directory contains scripts and utilities used across multiple IntP variants.

## Files

### intp-preflight.sh

Host capability checker. Verifies, without installing or mounting anything,
that the machine has every hardware and software interface needed to build
and run each IntP variant (v0 (stap-2022), v0.1 (stap-nollc), v0.2 (stap-legacy), v1 (stap-nohelper), v1.1 (stap-modern), v2 (hybrid-c), v3.1 (bpftrace), v3 (ebpf-ring), v3.2 (ebpf-agg)) plus
the bench harness in `bench/run-intp-bench.sh`. Output is a per-variant BUILD/RUN
matrix and a 7-metric coverage map (netp / nets / blk / mbw / llcmr /
llcocc / cpu).

Usage:

```bash
./intp-preflight.sh                      # check every variant
./intp-preflight.sh --variants v2,v3.1   # restrict to selected variants
./intp-preflight.sh --json               # machine-readable summary
./intp-preflight.sh --strict             # non-zero exit on DEGRADED, too
./intp-preflight.sh --quiet              # only the final tables
make preflight                           # convenience wrapper at repo root
make preflight PREFLIGHT_ARGS="--strict --variants v3"
```

Exit codes: `0` if every selected variant is OK (or DEGRADED in non-strict
mode), `2` if any selected variant has a MISSING required check.

Each verdict aggregates the underlying checks (kernel version, RDT/PQoS
flags, resctrl, BTF, perf_event_paranoid, NIC, debuginfo, toolchains,
privileges) following the per-variant requirement matrix in
`README.md` and `docs/HARDWARE-COMPATIBILITY.md`.

### intp-detect.sh

Hardware capability detection script. Auto-detects NIC speed, LLC size, RDT/PQoS
support, CPU vendor, socket count, and memory bandwidth. Outputs shell variables
that can be eval'd by other scripts.

Usage:

```bash
eval $(./intp-detect.sh)
echo "NIC speed: ${INTP_NIC_SPEED_MBPS} Mbps"
echo "LLC size: ${INTP_LLC_SIZE_KB} KB"
```

### intp-resctrl-helper.sh

Bash-based companion daemon for managing resctrl monitoring groups. This
script is a legacy artifact from the original `v3-updated-resctrl` design;
**no current variant uses it directly**:

- **v1 (stap-nohelper)** does not use a helper at all (mbw / llcocc disabled).
- **v1.1 (stap-modern)** uses its own C helper at `variants/v1.1-stap-modern/intp-helper`.
- **v2 (hybrid-c) / v3.1 (bpftrace) / v3 (ebpf-ring)** each integrate resctrl access in their own runtime
  (C in `variants/v2-hybrid-c/`, Python in `variants/v3.1-bpftrace/orchestrator/`,
  C in `variants/v3-ebpf-ring/resctrl/`).

The script is kept here for reproducing experiments against the legacy
`v3-updated-resctrl` lineage (preserved at git tag `pre-rename-2026-05-05`).

### validate-cross-variant.sh

Cross-variant byte-equivalence validator. Runs the runtime-binary variants
(hybrid-c / bpftrace / ebpf-ring / ebpf-agg) under identical conditions and compares the seven
metric columns within a tolerance, emitting a Markdown report.

Run with `--help` for the option list.

Usage of the legacy helper (still works for the pre-rename v3 build):

```bash
sudo ./intp-resctrl-helper.sh start <PID>   # Create monitoring group
sudo ./intp-resctrl-helper.sh stop          # Clean up
sudo ./intp-resctrl-helper.sh status        # Show current groups
```

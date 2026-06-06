# V3.1 -- bpftrace + resctrl Implementation

IntP reimplemented using bpftrace scripts (eBPF) for software metrics and
the resctrl filesystem for hardware metrics. No SystemTap, no kernel
modules, no debuginfo packages required (uses BTF).

## Why bpftrace

bpftrace is to eBPF what SystemTap is to kernel modules: a high-level DSL
that compiles to low-level instrumentation. V3.1 demonstrates that the
SystemTap-based IntP can be replaced with bpftrace scripts at comparable
expressiveness, while gaining:

- **Safety**: the BPF verifier prevents kernel crashes (unsafe programs
  will not load at all).
- **Portability**: BTF eliminates the debuginfo dependency.
- **Fast startup**: seconds instead of SystemTap's 10-30s kernel-module
  compilation.
- **No kernel module**: no `modprobe`, no version matching.

V3.1 is the pragmatic middle ground between the SystemTap lineage (V1
stap-native, V1.1 stap+helper) and V3 (full C/libbpf eBPF + resctrl).

## Architecture

```
        bpftrace scripts                orchestrator
  +-------------------------+      +------------------+
  | netp.bt, nets.bt,       |----->  aggregator.py    |
  | blk.bt, cpu.bt,         |      | (JSON parsing,   |
  | llcmr.bt                |      |  delta compute,  |
  +-------------------------+      |  normalization,  |
                                   |  TSV output)     |
  resctrl filesystem               |                  |
    mbw, llcocc  --------------->  | resctrl_reader.py|
                                   +-------------------+
                                            |
                                            v
                                   IntP TSV output
                                   (7 columns, stdout)
```

Each `.bt` script streams one metric as newline-delimited JSON on a named
pipe. The Python aggregator reads the pipes in parallel, polls resctrl
for `mbw`/`llcocc`, and emits a single TSV row per interval in the IntP
format that IADA and downstream classifiers already consume.

## Quick start

```bash
# Check dependencies
make deps

# Validate scripts compile
make validate

# Run (system-wide, 1-second interval)
sudo ./run-intp-bpftrace.sh

# Monitor a specific PID
sudo ./run-intp-bpftrace.sh --pid 1234

# Show what backends are being used
sudo ./run-intp-bpftrace.sh --list-capabilities
```

## Requirements

- Linux kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`.
- bpftrace >= 0.14.
- Python 3.8+.
- resctrl (mounted at `/sys/fs/resctrl`) for `mbw` and `llcocc`.
- Intel RDT, AMD PQoS (Rome+), or ARM MPAM (kernel 6.19+) for hardware
  metrics.

## Privileges

- bpftrace scripts require `CAP_BPF + CAP_PERFMON` (or root).
- Creating resctrl `mon_groups` requires root.

## Supported platforms

| Platform                | Software metrics | Hardware metrics |
|-------------------------|------------------|------------------|
| Intel Xeon (RDT)        | full (bpftrace)  | full (resctrl)   |
| Intel Consumer          | full (bpftrace)  | unavailable      |
| AMD EPYC Rome+          | full (bpftrace)  | full (resctrl)   |
| AMD EPYC pre-Rome       | full (bpftrace)  | unavailable      |
| ARM Neoverse + MPAM 6.19| full (bpftrace)  | full (resctrl)   |
| ARM Neoverse (no MPAM)  | full (bpftrace)  | unavailable      |
| Container (privileged)  | full             | requires mount   |
| VM (passthrough)        | full             | depends          |

## Known limitations

1. **llcmr accuracy**: bpftrace hardware probes sample events (every
   10,000 by default), not exact counters. The miss ratio converges over
   1-second intervals but has more noise than V2's `perf_event_open`
   approach.
2. **nets approximation**: bpftrace cannot attach to `__napi_schedule_irqoff`
   and `napi_complete_done` as stable tracepoints on all kernels. We use
   `napi:napi_poll` as the closest approximation. Accuracy is lower than
   V0.
3. **No guru mode**: unlike SystemTap, bpftrace cannot access arbitrary
   kernel internals. This is the safety trade-off -- V3.1 cannot implement
   features that require embedded C direct memory access.

## Files

- `run-intp-bpftrace.sh` -- entry point (launches scripts + aggregator).
- `scripts/netp.bt`, `nets.bt`, `blk.bt`, `cpu.bt`, `llcmr.bt` -- one
  bpftrace script per software metric.
- `orchestrator/aggregator.py` -- reads JSON streams, polls resctrl,
  emits IntP TSV.
- `orchestrator/resctrl_reader.py` -- resctrl mon_group lifecycle and
  counter polling.
- `orchestrator/detect.py` -- thin wrapper around `shared/intp-detect.sh`.
- `tests/validate-scripts.sh`, `check-btf.sh`, `test-output-format.sh`.

## References

- bpftrace: https://github.com/iovisor/bpftrace
- BTF (BPF Type Format): https://docs.kernel.org/bpf/btf.html
- resctrl: https://docs.kernel.org/filesystems/resctrl.html

## Standalone use (packaging)

This folder builds and runs on its own (see the steps above) with **one** repo-level
dependency: `shared/intp-detect.sh` (hardware autodetection, wrapped by
`orchestrator/detect.py`). To use this folder outside the repository, copy
`shared/intp-detect.sh` next to it (or keep a repo checkout on hand).

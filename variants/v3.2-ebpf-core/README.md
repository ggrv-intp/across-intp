# V3.2 (eBPF-CORE) -- eBPF In-Kernel Aggregating IntP

The fourth extension of the dissertation work, specified in
§III-A of the SBAC-PAD 2026 paper: an in-kernel-aggregating
variant of V3 (ebpf-ring) that replaces ebpf-ring's 16 MiB ring buffer with per-CPU
counter maps + per-PID hash maps polled once per sampling interval.

The hypothesis eBPF-CORE tests is structural, not optimization:

> "the structurally-coupled consumer-wakeup and induced-preemption
> mechanisms both vanish by construction when the userspace consumer
> is no longer draining a continuous event stream."

ebpf-ring incurs 194-416x context-switch amplification (paper §V-B)
because its userspace process loops on `ring_buffer__poll` returning
records and is scheduled-in / scheduled-out at the event rate. eBPF-CORE
removes the loop: BPF probes atomically increment counters; userspace
sleeps `--interval` seconds and reads a snapshot. The only
context-switch contribution from eBPF-CORE's userspace is the wakeup from
nanosleep once per interval.

## Architecture vs. V3 (ebpf-ring)

| Aspect                    | V3 (ebpf-ring)                              | V3.2 (eBPF-CORE)                                   |
|---------------------------|---------------------------------------------|---------------------------------------------------|
| Transport kernel -> user  | `BPF_MAP_TYPE_RINGBUF` 16 MiB               | `PERCPU_ARRAY` + `HASH` of `struct intp_counters` |
| Userspace loop            | `ring_buffer__poll` continuous              | `clock_nanosleep` 1 Hz + map read                 |
| Per-event introspect      | yes (`--trace`)                             | no (removed)                                      |
| Ordering                  | MPSC FIFO per producer                      | not applicable                                    |
| Probe set                 | netp/nets/blk/cpu/llcmr                     | same                                              |
| Resctrl integration       | resctrl mon_group, mbw/llcocc               | same + `mbw_raw_mbps` diagnostic column           |
| Min kernel                | 5.8 (BTF + CO-RE)                           | 5.8 (no change; same map types as ebpf-ring)      |
| Per-PID attribution       | hash `descendant_tgids` + filter            | same machinery, plus per-TGID counter slot        |

Trade-offs accepted by design:

- Per-event introspectability lost (`--trace` is gone).
- MPSC FIFO ordering between probes lost.

These costs were judged worthwhile for the structural removal of the
amplification mechanism, per paper §III-A.

## Build requirements

Identical to ebpf-ring:

- Linux kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`.
- clang >= 11.
- libbpf >= 0.8 with development headers.
- bpftool from `linux-tools-*`.
- libelf-dev, zlib1g-dev.
- resctrl filesystem for mbw and llcocc (Intel RDT, AMD QoS Rome+, ARM
  MPAM on 6.19+).

On Ubuntu 24.04:

```bash
sudo apt install clang libbpf-dev libelf-dev zlib1g-dev \
                 linux-tools-common linux-tools-generic
```

## Quick start

```bash
# Build everything: generates vmlinux.h, compiles BPF, builds the binary.
make

# Print detected capabilities (no root needed for read-only checks).
sudo ./intp-ebpf-core --list-capabilities

# Run system-wide, 1-second samples, IntP-compatible TSV output
# (8 columns: 7 canonical + mbw_raw_mbps diagnostic).
sudo ./intp-ebpf-core --interval 1

# Match ebpf-ring's column shape exactly (no mbw_raw_mbps).
sudo ./intp-ebpf-core --interval 1 --no-raw-mbw

# Restore the legacy ebpf-ring cap-at-99 clip on mbw (default is unclipped).
sudo ./intp-ebpf-core --interval 1 --clip-mbw

# Monitor specific PIDs for 60 seconds.
sudo ./intp-ebpf-core --pids 1234,5678 --interval 1 --duration 60
```

## Output format

The 7 canonical IntP columns come first (byte-compatible with ebpf-ring's
`intp-ebpf-ring` output and the IADA contract). eBPF-CORE appends one trailing
column, `mbw_raw_mbps`, with the underlying memory-bandwidth reading
in megabytes per second. The new column is suppressed with
`--no-raw-mbw`.

```text
# v3.2 eBPF-COREregate -- netp:tracepoint nets:softirq blk:tracepoint cpu:sched_switch llcmr:perf_event mbw:resctrl llcocc:resctrl
# kernel 6.17 env=bare-metal
# mbw_pct = (mbm_total_bytes_delta / interval) / mem_bw_max_bps * 100  (clip_mbw=off)
# mbw_raw_mbps = (mbm_total_bytes_delta / interval) / 1e6  (diagnostic, see paper IV-E)
netp    nets    blk     mbw     llcmr   llcocc  cpu     mbw_raw_mbps
12      01      05      23      03      45      67      5650
```

Alternative output formats: `--output json` and `--output prometheus`.
Both include `mbw_raw_mbps` by default (suppressible with
`--no-raw-mbw`).

When the unclipped `mbw_pct` exceeds 100% an analyst-facing warning
fires once to stderr; the value is still reported faithfully. The
canonical reason for `pct > 100` is a misconfigured
`--mem-bw-max-bps`; `docs/V3-OVERHEAD-FINDINGS.md` §3 details the chain.

## Acceptance tests

eBPF-CORE ships two integration tests on top of the ebpf-ring smoke test:

- `tests/integration/test-no-ctxsw-amplification.sh` (`make test-amplification`)
  -- the structural acceptance test for the paper's V-D hypothesis.
  Runs stress-ng under vmstat for 90 s with and without the profiler,
  computes the ratio of context switches, and fails if the ratio
  exceeds 1.10. ebpf-ring fails this test at 194-416x.
- `tests/integration/test-metrics-equivalence.sh` -- runs ebpf-ring and eBPF-CORE
  back-to-back over the same stress-ng workload and verifies each of
  the 7 canonical metric medians agrees within 15% relative tolerance.

The host-side unit test `tests/unit/test-counter-snapshot.c` covers
the saturating subtraction `counters_diff()` relies on.

## Files

- `Makefile` -- build pipeline (BTF dump -> BPF compile -> skeleton gen -> link).
- `src/intp_agg.bpf.c` -- kernel-side eBPF programs + counter maps.
- `src/intp_agg.bpf.h` -- shared types (struct intp_counters).
- `src/intp_agg.c` -- userspace main (polling loop, per-CPU snapshot diff).
- `src/intp_agg_args.{c,h}` -- CLI argument parser.
- `src/vmlinux.h` -- generated from kernel BTF (git-ignored).
- `src/intp_agg.skel.h` -- generated libbpf skeleton (git-ignored).
- `resctrl/resctrl.{c,h}` -- resctrl mon_group helper (extended with
  `resctrl_read_mbm_pct_and_raw()` for the dual-output reading).
- `detect/detect.{c,h}` -- hardware / environment capability detection.
- `scripts/gen-vmlinux.sh` -- manual BTF -> vmlinux.h dump.
- `scripts/test-core-portability.sh` -- verify CO-RE load under current kernel.
- `tests/unit/test-counter-snapshot.c` -- saturating subtraction test.
- `tests/integration/test-*.sh` -- load/attach + amplification + equivalence.

## When to pick V3.2 (eBPF-CORE) over V3 (ebpf-ring)

- You're running ebpf-ring against a sustained-workload campaign and the
  paper's V-D amplification is showing up in your numbers.
- You don't need per-event introspectability for this campaign.
- You don't need MPSC FIFO ordering between probes.

If you need per-event traces (e.g., investigating a specific request
latency spike), ebpf-ring's `--trace` flag is still the right tool. eBPF-CORE is
the steady-state profiler; ebpf-ring is the introspection profiler.

## References

- **Original IntP:** Xavier, M. G., Cano, C. H. C., Meyer, V., and De Rose, C. A. F. (2022). *IntP: Quantifying cross-application interference via system-level instrumentation*. SBAC-PAD 2022, pp. 231-240. IEEE. PUCRS.
- **In-kernel aggregation pattern, iprof:**
  - Gögge, R. (2023). *Finding noisy neighbours: Measuring application interference with system-level instrumentation using eBPF*. Master's thesis, Technical University of Berlin. (Chapter 3.3 documents the `PERCPU_ARRAY + HASH` pattern eBPF-CORE reuses.)
  - Becker, S., Goegge, R., Kao, O. (2024). *Measuring application interference with system-level instrumentation*. UCC Companion 2024, IEEE/ACM.
- **PRISM:** Landau, D., Barbosa, J., Saurabh, N. (2025). *eBPF-based instrumentation for generalisable diagnosis of performance degradation*. arXiv:2505.13160. (Statistical summaries polled every second -- adjacent point on the same axis.)
- **CO-RE portability study:** Zhong, S. et al. (2025). *Revealing the unstable foundations of eBPF-based kernel extensions*. EuroSys '25. ACM.
- libbpf: <https://github.com/libbpf/libbpf>
- Nakryiko, A. *BPF CO-RE reference guide*. <https://nakryiko.com/posts/bpf-core-reference-guide/>

## Standalone use (packaging)

This folder is self-contained: copy it into your own project and use it on its own —
no other folder from this repository is required. `make` in this directory builds the
profiler binary; run it per the section(s) above.

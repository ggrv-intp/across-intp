# V3 (ebpf-ring) -- Full eBPF/CO-RE IntP Implementation (predecessor of V3.2 (eBPF-CORE))

The dissertation's Phase 2 prototype: IntP implemented in C with libbpf
and CO-RE (Compile Once, Run Everywhere). ebpf-ring was the original eBPF
endpoint; **eBPF-CORE (`variants/v3.2-ebpf-core/`) supersedes it as the
measured eBPF endpoint** for the SBAC-PAD 2026 campaign by replacing
ebpf-ring's 16 MiB ring buffer with in-kernel counter aggregation. ebpf-ring is
retained in the repository as the empirical-evidence predecessor and
the introspection profiler; see `docs/V3-OVERHEAD-FINDINGS.md` for
the measurement record (194-416x context-switch amplification, mbw
silent clip) that motivated eBPF-CORE.

ebpf-ring is still evaluated head-to-head against the SystemTap lineage
(stap-2022 original, stap-nohelper stap-native, stap-modern stap+helper), the framework-free C-ABI,
and the bpftrace-based bpftrace, since the comparison is structural, not
about the ebpf-ring vs eBPF-CORE trade-off.

## Architecture

ebpf-ring uses eBPF programs written in C, compiled once to portable bytecode,
and loaded via libbpf with BTF-based runtime relocation. Software
metrics flow through a single ring buffer; hardware metrics (mbw,
llcocc) use the resctrl filesystem.

Comparison across variants in the repo:

- V0 (stap-2022) / V0.1 (stap-nollc) / V1 (stap-nohelper): SystemTap DSL + embedded C, compiled to kernel `.ko`,
  requires debuginfo. Differ in kernel-version coverage and metric set.
- V1.1 (stap-modern): SystemTap + userspace helper (`variants/v1.1-stap-modern/intp-helper`)
  for RCU-unsafe operations; full 7 metrics.
- V2 (C-ABI): no framework, pure C / procfs / `perf_event_open` / resctrl polling.
- V3.1 (bpftrace): bpftrace DSL (interpreted) + Python orchestrator + resctrl.
- **V3 (ebpf-ring): native C eBPF + libbpf skeleton + resctrl (this variant).**

## Key advantages of V3 (ebpf-ring) over V3.1 (bpftrace)

- Lower startup overhead: skeleton load, no DSL parse.
- Full control over ring buffer handling and event aggregation.
- Lower per-event overhead: no DSL runtime dispatch per probe.
- Production-grade: matches the architecture of BCC tools, Cilium, Pixie.

## Key advantages of V3 (ebpf-ring) over V1 (stap-nohelper) / V1.1 (stap-modern) (SystemTap)

- No kernel module: the verifier guarantees safety in userspace.
- No debuginfo dependency: BTF provides kernel type information.
- CO-RE: one compile, runs on any kernel 5.8+ (subject to Zhong et al.
  2025 caveats about inlined/renamed functions).
- Fast startup (~1 s vs. 10-30 s for SystemTap).
- Sub-microsecond probe overhead.

## Build requirements

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
sudo ./intp-ebpf-ring --list-capabilities

# Run system-wide, 1-second samples, IntP-compatible TSV output.
sudo ./intp-ebpf-ring --interval 1

# Monitor specific PIDs for 60 seconds.
sudo ./intp-ebpf-ring --pids 1234,5678 --interval 1 --duration 60

# Monitor a cgroup v2 path.
sudo ./intp-ebpf-ring --cgroup /sys/fs/cgroup/myservice --interval 0.5
```

## Output format

Byte-compatible with stap-2022's `intp.stp` for downstream IADA integration.
The leading header line documents which backend supplied each column.

```text
# v3 ebpf-core -- netp:tracepoint nets:kprobe blk:tracepoint cpu:sched_switch llcmr:perf_event mbw:resctrl llcocc:resctrl
# kernel 6.17 env=bare-metal
netp    nets    blk     mbw     llcmr   llcocc  cpu
12      01      05      23      03      45      67
```

Alternative formats:

- `--output json` -- line-delimited JSON with timestamps.
- `--output prometheus` -- scrapable exposition format.

## Files

- `Makefile` -- build pipeline (BTF dump -> BPF compile -> skeleton gen -> link).
- `src/intp.bpf.c` -- kernel-side eBPF programs (all metrics).
- `src/intp.bpf.h` -- types shared between kernel and user.
- `src/intp.c` -- userspace main (skeleton, ring buffer, output).
- `src/intp_args.{c,h}` -- CLI argument parser.
- `src/vmlinux.h` -- generated from kernel BTF by bpftool (git-ignored).
- `src/intp.skel.h` -- generated libbpf skeleton (git-ignored).
- `resctrl/resctrl.{c,h}` -- resctrl mon_group helper (hardware metrics).
- `detect/detect.{c,h}` -- hardware / environment capability detection.
- `scripts/gen-vmlinux.sh` -- manual BTF -> vmlinux.h dump.
- `scripts/test-core-portability.sh` -- verify CO-RE load under current kernel.
- `tests/unit/test-detect.c` -- host-side detection unit test.
- `tests/integration/test-*.sh` -- load-attach / accuracy / overhead tests.

## Supported platforms

| Platform                     | Software metrics | Hardware metrics |
|------------------------------|------------------|------------------|
| Intel Xeon (RDT)             | full (eBPF)      | full (resctrl)   |
| Intel Consumer               | full (eBPF)      | unavailable      |
| AMD EPYC Rome+               | full (eBPF)      | full (resctrl)   |
| AMD EPYC pre-Rome            | full (eBPF)      | unavailable      |
| ARM Neoverse + MPAM (6.19+)  | full (eBPF)      | full (resctrl)   |
| ARM Neoverse (no MPAM)       | full (eBPF)      | unavailable      |
| Container (CAP_BPF)          | full             | resctrl mount    |
| VM (BTF + PMU passthrough)   | full             | depends on host  |

## References

- libbpf: <https://github.com/libbpf/libbpf>
- libbpf-bootstrap: <https://github.com/libbpf/libbpf-bootstrap>
- Nakryiko, A. *BPF CO-RE reference guide*. <https://nakryiko.com/posts/bpf-core-reference-guide/>
- **Original IntP:** Xavier, M. G., Cano, C. H. C., Meyer, V., and De Rose, C. A. F. (2022). *IntP: Quantifying cross-application interference via system-level instrumentation*. SBAC-PAD 2022, pp. 231-240. IEEE. PUCRS.
- **iprof (related work, TU Berlin):**
  - Gögge, R. (2023). *Finding noisy neighbours: Measuring application interference with system-level instrumentation using eBPF*. Master's thesis, Technical University of Berlin. Supervised by Sören Becker and Prof. Dr. Odej Kao.
  - Becker, S., Goegge, R., Kao, O. (2024). *Measuring application interference with system-level instrumentation*. UCC Companion 2024, IEEE/ACM. Technical University of Berlin.
- **PRISM:** Landau, D., Barbosa, J., Saurabh, N. (2025). *eBPF-based instrumentation for generalisable diagnosis of performance degradation*. arXiv:2505.13160. <https://arxiv.org/abs/2505.13160>. Code: <https://github.com/EC-labs/prism>.
- **eBPF/SystemTap overhead:** Volpert, S. et al. (2025). *Towards eBPF overhead quantification: An exemplary comparison of eBPF and SystemTap*. ICPE '25 Companion. ACM.
- **CO-RE portability study:** Zhong, S. et al. (2025). *Revealing the unstable foundations of eBPF-based kernel extensions*. EuroSys '25. ACM.

## Standalone use (packaging)

This folder is self-contained: copy it into your own project and use it on its own —
no other folder from this repository is required. `make` in this directory builds the
profiler binary; run it per the section(s) above.

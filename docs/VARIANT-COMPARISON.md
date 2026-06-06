# Variant Comparison

Detailed comparison of all 7 implementation variants with rationale for each.

## Overview

The dissertation compares seven instrumentation approaches for collecting the
same 7 interference metrics. Each variant represents a different point in the
tradeoff space between measurement fidelity, portability, safety, and
deployment complexity.

## Evidence trail

Narrative claims in this document should be read alongside the benchmark
findings in:

- `bench/findings/README.md`
- `bench/findings/v0-baseline-failure-diagnosis.md`
- `bench/findings/v1-modernization-reliability-findings.md`

## Variants

### V0 (stap-2022) -- Original IntP (SystemTap, requires `intel_cqm` driver)

**Status.** *Measured baseline on Ubuntu 22.04 + kernel 5.15 GA* for
the legacy-V0 campaign. stap-2022 was previously listed as "not built or run";
it is now the stap-2022-side of the measured comparison. Two scoping
constraints carry into the runs: stap-2022 is excluded from the HiBench
segment (sustained-load runs trigger the systemd-logind /
`stap_*` module-accumulation cliff documented in
`bench/findings/v0-baseline-failure-diagnosis.md`), and every stap-2022 rep
runs under `bench/v0-stall-monitor.sh` so forensic evidence is
captured before the host stops accepting new SSH sessions.

**Recalibration.** `variants/v0-stap-2022/intp.stp` stays read-only (paper
contract). Host adaptation flows through `intp.stp.template` (the same
script with hardware constants replaced by `@@PLACEHOLDER@@` tokens)
and `generate-stp.sh`, which sources `shared/intp-detect.sh` to
populate NIC line-rate, LLC size, peak memory bandwidth, the IMC PMU
type, and the CMT scale factor at the start of every rep. The
generated script is written to `intp.recal.stp` (gitignored) and the
substituted values are saved next to the rep's TSV as
`v0-calibration.kv` for audit. See
[`variants/v0-stap-2022/README.md`](../variants/v0-stap-2022/README.md) for the
constants table.

**Architecture summary.** stap-2022 is the unmodified 2022 baseline by
Xavier and De Rose (PUCRS), published as "IntP: Quantifying
cross-application interference via system-level instrumentation"
(`variants/v0-stap-2022/intp.stp`, 660 lines) that runs in guru mode and
embeds raw kernel C inside `%{ ... %}` blocks to read MSRs, walk
`struct perf_event`, and operate on internal CQM data structures
(see `METRICS-DEEP-DIVE.md` sections 4 and 6 for the line-level
breakdown). Output is a 7-column TSV exposed through a
`procfs("intestbench")` node.

**Backend / probe map.** stap-2022 hardcodes one mechanism per metric:
`netfilter.ip.local_in/out` for netp; kprobes on
`__dev_queue_xmit`/`napi_complete_done` for nets; the
`block_rq_complete` tracepoint for blk; raw `perf_event_open` of
uncore IMC channels (`type=14`, configs `0x0304`/`0x0c04`) for mbw;
`PERF_TYPE_HW_CACHE` for llcmr; and `PERF_TYPE_INTEL_CQM` (`type=9`)
plus direct `wrmsr/rdmsrl` of `MSR_IA32_QM_CTR/QM_EVTSEL` for llcocc.
Several normalising constants are baked into the script (1 GbE NIC,
34 GB/s memory bandwidth, 34 MB LLC, CMT scale factor 49152) so stap-2022
output on any non-2022-PUCRS-dev-machine carries calibration error.

**Measurement fidelity.** Highest of all variants for the metrics it
collects: events are captured per-packet, per-bio, and per-MSR-read,
not aggregated by polling. The score sheet sets the upper bound that
C-ABI through ebpf-ring are measured against in Phase 3.

**Deployment requirements.** SystemTap >= 4.9, kernel debuginfo for
the running kernel, root, and a kernel that still exposes the
`intel_cqm` perf PMU driver. The field `cqm_rmid` (and the driver
that populated it) was removed from mainline in kernel 4.14
(November 2017, commit `c39a0e2c8850`); the replacement is the
`resctrl` filesystem. stap-2022 only builds against kernels that either
preserve `intel_cqm` via a vendor backport (some enterprise LTS
lines did so until ~2019-2020) or were hand-compiled with the
driver restored. Empirically the field is already absent from
Ubuntu 22.04's stock 5.15 kernel, and the 6.x line is simply the
point at which no mainstream distro still carries the backport.
Module build takes 10-30 s at first run; SystemTap loads a
per-script `.ko` into the kernel and the script runs there.

**Performance overhead.** Tracepoint and kprobe overhead is moderate
(~hundreds of ns per event); MSR reads are CPU-broadcast via
`on_each_cpu_mask` and are the most expensive path. The PUCRS paper
reports negligible overhead on idle systems and a few percent CPU on
network-heavy workloads.

**Known limitations.**

1. *Kernel version coupling.* Internal struct fields (`pe->hw.cqm_rmid`,
   `$rq->__data_len`, etc.) and unexported symbols are accessed
   directly. Any kernel upgrade can break the script silently or
   loudly.
2. *Hardware coupling.* Constants (1 GbE, 34 GB/s, 34 MB LLC,
   `* 49152` CMT factor, IMC type=14, two channels at fixed configs)
   were calibrated for the 2022 dev machine. Modern multi-socket
   systems and non-Intel CPUs require source edits to produce
   correct percentages.
3. *Crash risk.* Running with `-g` (guru mode) can panic the kernel
   if the embedded C is wrong; the verifier-free model is what
   bpftrace/eBPF replace.

**Relationship to other variants.** stap-2022 is the canonical fidelity
reference. stap-nollc is the smallest possible patch on top of it; stap-nohelper keeps
the SystemTap shape but replaces the broken CQM path. C-ABI through ebpf-ring replace
SystemTap altogether and are evaluated against stap-2022's output via
`shared/validate-cross-variant.sh`.

### V0.1 (stap-nollc) -- Updated for Kernel 6.8 (LLC disabled)

**Architecture summary.** A minimal compatibility patch over stap-2022
(`variants/v0.1-stap-nollc/intp-6.8.stp`, 624 lines vs stap-2022's 660). Two surgical
changes: (1) drop the script's `MSR_IA32_QM_CTR/QM_EVTSEL` redefinitions
because kernel 6.8 moved the canonical definitions into
`<asm/msr-index.h>`, causing redefinition errors; (2) comment out the
entire `perf_kernel_start(...,9,1)` LLC path because `cqm_rmid` no
longer exists on `struct hw_perf_event`. `print_llc_report()` returns
0; `llcocc` is the only column that loses fidelity.

**Backend / probe map.** Identical to stap-2022 except llcocc is disabled.
6/7 metrics work exactly as in stap-2022; the stap-2022 calibration constants and
hardware coupling are inherited unchanged.

**Measurement fidelity.** Same as stap-2022 for 6 metrics; `llcocc` is
hard-zeroed.

**Deployment requirements.** Kernel 6.8+, SystemTap 5.0+, `-B
CONFIG_MODVERSIONS=y` if the kernel was built with module version
checks (most distro kernels are). All other stap-2022 dependencies still
apply (debuginfo, guru mode, root).

**Performance overhead.** Same envelope as stap-2022.

**Known limitations.** Loses the LLC occupancy dimension entirely.
Inherits all of stap-2022's other limitations (kernel-version and hardware
coupling). stap-nollc's purpose is to demonstrate "the smallest possible patch
recovers 6/7 metrics on a modern kernel" -- it is the negative result
that motivates stap-nohelper.

**Relationship to other variants.** stap-nollc -> stap-nohelper is a focused upgrade:
keep the SystemTap engine and patch the `print_llc_report()`
implementation to read from resctrl rather than from `cqm_rmid`. stap-nollc
is rarely the best deployment choice in practice but has a clear
pedagogical role in the dissertation.

### V0.2 (legacy-intp-baseline) -- V0 semantics + userspace helper (target: kernel 5.15 GA, U22)

**Status.** *Active (legacy-V0 campaign).* Scaffolded 2026-05-11;
pending operator-side smoke validation on a U22 host.

**Architecture summary.** legacy-intp-baseline keeps the paper-faithful stap-2022 stap probe
set for `netp`, `nets`, `blk`, `llcmr`, and `cpu` (all RCU-safe) and
moves the two RCU-unsafe operations -- uncore IMC perf events
(`mbw`) and `cqm_rmid`-based LLC occupancy (`llcocc`) -- into a small
userspace daemon (`variants/v0.2-legacy-intp-baseline/intp-helper.c`). The helper writes
the latest values atomically to `/tmp/intp-v0.2-hw-data`; the stap
script reads that file from a `procfs.read` probe via the same
RCU-safe `filp_open + kernel_read` pattern stap-modern uses. Target kernel
is **5.15 GA (Ubuntu 22.04)**; the variant is explicitly gated to the
window `5.10 ≤ k < 6.0` because on 6.x stap-modern is the right variant
(same helper pattern, but with stap-nohelper's probe set).

**Backend / probe map.** Identical to stap-2022 for the 5 RCU-safe metrics.
For mbw and llcocc, the data path is: helper opens IMC events via
`perf_event_open(2)` and reads `llc_occupancy` via the resctrl
mon_groups filesystem; the stap script reads the helper's output file
from a procfs read probe. No `perf_event_create_kernel_counter()` and
no `on_each_cpu_mask()` from probe context.

**Measurement fidelity.** Same envelope as stap-2022 for the 5 RCU-safe
metrics. For mbw and llcocc, fidelity matches stap-modern's helper output
(percentage normalized against host DRAM bandwidth and L3 size; the
bench launcher passes `INTP_HELPER_DRAM_BW_MBPS`, `INTP_HELPER_L3_SIZE_KB`,
and `INTP_HELPER_IMC_PMU_TYPE` from `shared/intp-detect.sh`).

**Recalibration.** `variants/v0.2-legacy-intp-baseline/intp.stp.template` carries only one
placeholder (`@@NIC_BYTES_PER_SEC@@`); all other host knobs flow
through helper environment variables and are read at helper startup.
`variants/v0-stap-2022/intp.stp` is unchanged.

**Deployment requirements.** Kernel 5.10..6.0, SystemTap 5.0+,
matching kernel headers + debuginfo, root (for stap), and resctrl
with `L3_MON` enabled (for `llcocc`). Without resctrl L3_MON, the
helper warns at startup and reports llcocc=0; the rest of the metrics
continue to work.

**Known limitations.** Same as stap-modern's helper architecture: per-PID
attribution depends on the helper scanning `/proc` once per second
and adding new matches to the mon_group `tasks` file -- short-lived
PIDs that complete inside a poll interval will be missed. Helper
boots empty for ~1 s on each rep, during which mbw and llcocc read
as 0; the bench harness sleeps 0.3 s before starting the stap run to
let the helper write its first line.

**Relationship to other variants.** stap-2022 -> legacy-intp-baseline is a kernel-era port:
keep stap-2022's probes where they are RCU-safe, replace the two RCU-unsafe
ones with a userspace path. legacy-intp-baseline -> stap-modern is the same architecture
applied to a different stap probe set (stap-nohelper's modern set vs stap-2022's paper
set). legacy-intp-baseline and stap-modern do not coexist in the same campaign by intent --
they target different kernels.

### V1 (stap-nohelper) -- Stap-native (kernel 6.8+, 5/7 metrics, no helper)

**Architecture summary.** stap-nohelper is the result of restoring the legacy
`v3-updated-resctrl` lineage to a stap-2022-faithful approach after kernel
>= 5.15 began enforcing "voluntary context switch within RCU read-side
critical section". The legacy build called `perf_event_create_kernel_counter()`
and resctrl `filp_open`/`kernel_write` from stap embedded C in probe
context; that pattern is fundamentally unsafe on modern RCU and triggered
RCU stalls / unrecoverable system hangs in production benchmarking.
stap-nohelper keeps the SystemTap engine but uses ONLY stap-native probes -- no
embedded C creating perf events, no embedded I/O. The single script
(`variants/v1-stap-nohelper/intp-resctrl.stp`, 432 lines) is self-contained.

**Backend / probe map.** Identical to stap-2022 / stap-nollc for netp, nets, blk,
cpu. LLC miss ratio comes from `probe perf.type(3).config(0x000002).process(@1)`
and `probe perf.type(3).config(0x010002).process(@1)` -- the stap-native
syntax that stap-2022 uses. mbw and llcocc are reported as 0 in this build:
they require operations that cannot run safely from a stap probe
context on modern kernels. stap-modern restores both via a userspace helper.

**Measurement fidelity.** 5/7 metrics with stap-2022-equivalent fidelity. mbw
and llcocc are zeroed (not approximated, just absent from this build).

**Deployment requirements.** Kernel 6.8+, SystemTap 5.0+, kernel
debuginfo, root. Single process; no helper daemon, no resctrl, no
uncore PMU access required.

**Performance overhead.** Slightly lower than the legacy V3 build (no
embedded C overhead from synthetic perf event creation); same as stap-2022
for the probes that remain.

**Known limitations.**

1. mbw and llcocc are unavailable -- anyone needing 7/7 metrics on
   kernel 6.8+ should use stap-modern (stap + helper) or C-ABI / bpftrace / ebpf-ring.
2. Inherits stap-2022's debuginfo and guru-mode requirements; the SystemTap
   `.ko` is still loaded into the kernel.

**Relationship to other variants.** stap-nohelper is the stap-only baseline for
"how much can SystemTap alone deliver on kernel 6.8+". stap-modern adds a
userspace helper to recover mbw and llcocc without breaking RCU
safety. C-ABI / bpftrace / ebpf-ring abandon SystemTap entirely.

### V1.1 (stap-modern) -- Stap + userspace helper (kernel 6.8+, full 7 metrics, RCU-safe)

**Architecture summary.** stap-modern pairs the stap-nohelper stap script with a
userspace helper (`variants/v1.1-stap-modern/intp-helper.c`, ~370 lines C99)
that owns every RCU-unsafe operation: opening uncore IMC perf events
via `perf_event_open(2)`, managing a resctrl `mon_groups/intp-<pid>/`
group, and polling its counters. The helper rewrites
`/tmp/intp-hw-data` once per second with a single line:
`<timestamp_ns>\t<mbw_pct>\t<llcocc_pct>\n` (atomic via tmpfile +
rename). The matching stap script
(`variants/v1.1-stap-modern/intp-v1.1.stp`) is identical to stap-nohelper plus an
embedded-C `kernel_read()` of that file from a
`procfs("intestbench").read` probe -- the only context in stap where
file I/O is RCU-safe (procfs read runs in user-task context, no RCU
read lock held).

**Backend / probe map.** Identical to stap-nohelper for software metrics
(netp, nets, blk, cpu, llcmr). For hardware metrics:

| metric | mechanism                                                                              |
|--------|----------------------------------------------------------------------------------------|
| mbw    | helper opens 24 SPR uncore IMC events (CPU 0); polls 1 s; sums and normalises          |
| llcocc | helper creates `mon_groups/intp-<pid>/`; polls `mon_data/mon_L3_*/llc_occupancy`; sums |

**Measurement fidelity.** Equivalent to stap-2022 for software metrics. For
hardware metrics, equivalent to C-ABI / bpftrace / ebpf-ring (resctrl source is the
same). mbw resolution is bounded by the 1-second helper polling rate.
Both mbw and llcocc gracefully degrade to 0 if the helper is not
running or the hardware is unavailable.

**Deployment requirements.** Kernel 6.8+, SystemTap 5.x, kernel
debuginfo, Intel RDT or AMD PQoS hardware (Broadwell-EP+, EPYC Rome+),
uncore IMC PMU exposed as `/sys/bus/event_source/devices/uncore_imc_*`.
Two processes during a session: helper (foreground or background;
root for `perf_event_open` and resctrl writes) and the stap-loaded
`.ko`.

**Performance overhead.** Helper poll cost ~ms per second of
monitoring (one syscall per IMC event + one read per L3 domain + one
file write). Stap side same as stap-nohelper plus a single `kernel_read` of a
~24-byte file per procfs read.

**Known limitations.**

1. *Hardware defaults assume Sapphire Rapids* (Xeon Gold 5412U): IMC
   PMU types 78..89, DRAM bandwidth 281600 MB/s, L3 size 46080 KB.
   Override via env vars `INTP_HELPER_DRAM_BW_MBPS`,
   `INTP_HELPER_L3_SIZE_KB`. Multi-socket support is TODO (events
   are opened on CPU 0 only).
2. *Lifecycle ordering*: the helper must be running before the stap
   script reports non-zero mbw/llcocc. Out-of-order startup yields
   zeros until the first helper write. The bench harness brackets
   helper + stap together to avoid this.
3. *Comm-prefix matching* via `/proc/<pid>/comm` (15 chars). Workloads
   that mask their `comm` would need the helper extended to read
   `cmdline` instead.
4. *blk clock-domain bug* (fixed 2026-05-10 in commit `7fd557f`):
   `intp-v1.1.stp` previously rejected nearly all `block_rq_issue`
   events on kernel ≥ 6.8, leaving the blk column at zero across
   stress-ng and HiBench campaigns. The fix adds an alternative
   `kernel.trace("block:block_rq_issue")` tapset and a clock-domain
   correction. Campaigns produced before this commit need re-collection
   for v1.1/blk. See `docs/EXPERIMENT-STRATEGY.md` § V1.1.

**Relationship to other variants.** stap-modern demonstrates that adding a
userspace co-process to a SystemTap-based design recovers full
functionality on modern kernels without abandoning SystemTap. The
architectural decision (RCU-unsafe operations live in userspace; the
kernel side stays in safe contexts) is the same that bpftrace and ebpf-ring take
with their bpftrace-Python and libbpf-userspace orchestrators
respectively. stap-modern is the dissertation's "how much can SystemTap
deliver if we stop trying to do everything inside the probe context"
data point.

### V2 (C-ABI) -- Hybrid procfs/perf_event/resctrl (no framework)

**Architecture summary.** C-ABI is a single C99 binary
(`variants/v2-c-abi/intp-c-abi`) with no kernel module, no debuginfo
dependency, and no compile-time selection of a collection path. Each of
the seven metrics (netp, nets, blk, mbw, llcmr, llcocc, cpu) carries an
ordered list of backends. At startup the binary runs a capability
detection pass (CPU vendor, resctrl availability, perf_event_paranoid,
execution environment, PMU passthrough for VMs) and then probes each
metric's backends in order, binding the first one that succeeds. The
output is IntP-compatible 7-column TSV, plus JSON and Prometheus
exposition formats. A leading `# v2 backends:` banner in the TSV lets
downstream consumers see which backend produced each column.

**Backend hierarchy per metric.** The decision tree below is the
operational contract of C-ABI; `variants/v2-c-abi/DESIGN.md` section 2
carries the full per-backend detail including minimum kernel versions
and privilege requirements.

| metric | 1st choice     | 2nd choice            | 3rd / 4th choice          |
|--------|----------------|-----------------------|---------------------------|
| netp   | sysfs          | procfs                |                           |
| nets   | procfs_softirq | procfs_throughput     |                           |
| blk    | diskstats      | sysfs                 |                           |
| mbw    | resctrl_mbm    | perf_uncore_imc       | perf_amd_df, perf_arm_cmn |
| llcmr  | perf_hwcache   | perf_raw              |                           |
| llcocc | resctrl        | proxy_from_miss_ratio |                           |
| cpu    | procfs_pid     | procfs_system         |                           |

**Measurement fidelity.** C-ABI produces seconds-resolution aggregate data,
not sub-second event capture. Samples are integrated over the
`--interval` window (default 1 s) and reported as a single value per
metric per sample. This is an intentional design decision, not a
workaround: IntP's target is steady-state interference
characterisation, and aggregate readings from stable kernel ABIs are
sufficient for that regime. When a sample cannot be computed reliably
(e.g. LLC miss ratio with no cache activity in the interval), the
runtime carries an explicit `status` field (`ok`, `degraded`, `proxy`,
`unavailable`) plus an optional `note` on each sample, so consumers can
always tell a real reading from a fallback or an approximation.

**Deployment requirements.** The binary depends only on glibc and
libpthread. `/sys/fs/resctrl` is optional: when mounted (or mountable
by root) the hardware metrics `mbw` and `llcocc` use kernel resctrl
byte counters, otherwise they fall back to perf uncore counters or to
the llcmr-based directional proxy. Uncore PMU access requires
`perf_event_paranoid<=-1` or `CAP_PERFMON`/`CAP_SYS_ADMIN`. The build
is a plain `make` against C99 flags with `-Wall -Wextra -Wpedantic
-Wshadow -Wstrict-prototypes -Wmissing-prototypes`; a Debian package
build is provided via `scripts/build-deb.sh`. No kernel module, no BTF,
no libbpf, no SystemTap runtime, no Python at collection time.

**Performance overhead analysis.** Definitive numbers come from the
Phase 3 evaluation, which runs the same workload under stap-2022, stap-nohelper, and C-ABI
bare-metal / container / VM and reports RSS, CPU%, and per-metric
correlation. The expected order of magnitude for the polling loop is
around 10^2 microseconds per sample: one `fread` each on `/proc/stat`,
`/proc/diskstats`, `/proc/net/dev`, `/proc/softirqs`, a handful of
sysfs byte reads, and either a resctrl byte-counter read or a
`read(perf_fd)`. None of these allocate in the hot path. The loop
itself uses `clock_nanosleep(TIMER_ABSTIME)` so overhead is
deterministic and drift-free; there are no event storms, no verifier
stalls, and no probe re-insertion cost.

**Known limitations.** C-ABI does **not** address three aspects that an
event-driven tracer can:

1. *Sub-second events.* Transient spikes shorter than `--interval` are
   smoothed into the surrounding window. bpftrace and ebpf-ring
   (eBPF/CO-RE) cover this case via tracepoints and kprobes.
2. *Causal attribution.* resctrl and perf counters show *what* hit the
   cache, bandwidth, or softirq, but not *whose* instruction did so
   to *whose* cache line. stap-2022's SystemTap probes can tag stack frames
   with the calling task; C-ABI cannot replicate that.
3. *Per-packet service time for nets.* Both nets backends are
   approximations (softirq-fraction ratio or a fixed 1us/packet
   heuristic). Both carry `status=degraded`;
   `variants/v2-c-abi/DESIGN.md` section 3 explains the gap.

**Relationship to other variants.** C-ABI differs from **stap-2022** in trading
event-driven SystemTap probes for polling over stable ABIs, losing
per-event resolution but removing kernel-module risk. C-ABI differs from
**stap-nohelper** by not using SystemTap at all, instead reaching resctrl directly
and adding perf_event_open as a second hardware-counter path. C-ABI
differs from **bpftrace** by not using bpftrace: no BTF dependency and no
per-event handler, at the cost of causal attribution. C-ABI differs from
**ebpf-ring** by not using eBPF/CO-RE: no verifier, no maps, no BPF object
loading, at the cost of kernel-internal counters that are only exposed
through tracepoints.

### V3.1 (bpftrace) -- bpftrace (eBPF scripts)

**Status.** *Implemented; measurement out of scope for this campaign.*
The implementation under `variants/v3.1-bpftrace/` is unchanged and remains
runnable via `BENCH_VARIANTS="...,v3.1"`. The legacy-V0 campaign
compares stap-2022's recalibrated baseline against the operationally robust
variants (stap-nohelper, stap-modern, C-ABI, ebpf-ring); bpftrace is held out of the default matrix
as a scoping decision, not a quality judgement. See
[`docs/EXPERIMENT-STRATEGY.md`](EXPERIMENT-STRATEGY.md) §
"V3.1 -- out of scope for this campaign".

**Architecture summary.** bpftrace is to the bpftrace DSL what stap-2022 is to SystemTap: a
high-level DSL for kernel instrumentation, with the safety of the BPF
verifier and the portability of BTF (no debuginfo). The implementation
is split into five `.bt` scripts (one per software metric:
`netp.bt`, `nets.bt`, `blk.bt`, `cpu.bt`, `llcmr.bt` -- all under
`variants/v3.1-bpftrace/scripts/`), each streaming newline-delimited JSON on a
named pipe, plus a Python 3 orchestrator (`orchestrator/aggregator.py`
and `resctrl_reader.py`) that reads the pipes in parallel, polls
resctrl for `mbw`/`llcocc`, and emits the IntP-format 7-column TSV.
The entry point is `run-intp-bpftrace.sh`.

**Backend / probe map.**

| metric | mechanism                                                       |
|--------|-----------------------------------------------------------------|
| netp   | `tracepoint:net:net_dev_xmit` + `netif_receive_skb` byte counts |
| nets   | `tracepoint:napi:napi_poll` (RX approximation) + softirq stats  |
| blk    | `tracepoint:block:block_rq_complete` (same as stap-2022)        |
| cpu    | `tracepoint:sched:sched_switch` + per-task ticks                |
| llcmr  | bpftrace `hardware:cache-references` / `cache-misses` events    |
| mbw    | resctrl `mbm_total_bytes` polled by `resctrl_reader.py`         |
| llcocc | resctrl `llc_occupancy` polled by `resctrl_reader.py`           |

**Measurement fidelity.**

- `netp`, `blk`, `cpu` are byte-equivalent to stap-2022.
- `nets` is degraded relative to stap-2022 because bpftrace cannot attach to
  `__napi_schedule_irqoff`/`napi_complete_done` as stable tracepoints
  on every kernel; the closest portable surface is `napi:napi_poll`,
  which captures only part of the RX latency window. bpftrace reports
  `status=degraded` and a note for this column.
- `llcmr` is *sampled*, not exact: bpftrace hardware events default
  to a 10 000 sample period, so the miss ratio converges over the
  1-second window but has more noise than C-ABI's `perf_event_open`
  approach. Within one interval the noise is bounded by the central
  limit.
- `mbw` and `llcocc` go straight through resctrl, so they match stap-nohelper (and
  exceed stap-2022's two-channel uncore IMC fallback on multi-channel hosts).

**Deployment requirements.** Kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`,
bpftrace >= 0.14, Python 3.8+, `CAP_BPF + CAP_PERFMON` (or root),
resctrl mounted for `mbw`/`llcocc` on Intel RDT, AMD PQoS (Rome+), or
ARM MPAM (kernel 6.19+) hardware.

**Performance overhead.** Higher per-event cost than ebpf-ring because the
bpftrace runtime dispatches each probe through its DSL interpreter
within the BPF program; lower than stap-2022/stap-nohelper because there is no kernel
module to load and no debuginfo to walk. Startup is 1-3 s (the bpftrace
parse + verifier load for five scripts in parallel).

**Known limitations.**

1. *No guru mode.* bpftrace deliberately cannot access arbitrary kernel
   internals -- it is the safety/expressiveness trade.
2. *Multi-process design.* Five bpftrace processes plus the Python
   aggregator. The orchestrator must keep them in sync; lost stdout
   on a script means a missing column.
3. *Sampled hardware events.* See llcmr fidelity note above.
4. *Forked-descendant tracking bug* (fixed 2026-05-08): same root cause
   as ebpf-ring's bug above — bpftrace scripts now follow
   `tracepoint:sched:sched_process_fork` and propagate filtration to
   the whole process tree. Pre-fix bpftrace data on multi-process workloads
   (stress-ng, HiBench Spark) under-reports every metric that depends
   on event capture from forked children. See
   `docs/EXPERIMENT-STRATEGY.md` § V3.1.

**Relationship to other variants.** bpftrace is the pragmatic middle ground
between stap-nohelper (SystemTap + resctrl) and ebpf-ring (full C eBPF + resctrl). It
keeps the resctrl helper-pattern of stap-nohelper but routes it through Python
instead of SystemTap embedded C. ebpf-ring keeps the same hardware-via-resctrl
split but moves the software side to a single libbpf-loaded BPF object
and removes the DSL runtime cost.

### V3 (ebpf-ring) -- eBPF/CO-RE with libbpf (full prototype)

**Architecture summary.** ebpf-ring is the dissertation's "Phase 2 prototype":
a single libbpf-skeleton-loaded BPF object (`variants/v3-ebpf-ring/src/intp.bpf.c`
+ generated `intp.skel.h`) plus a userspace orchestrator
(`src/intp.c`) that polls a shared 16 MiB ring buffer (single
`BPF_MAP_TYPE_RINGBUF`), aggregates events by metric, and reads
resctrl for `mbw`/`llcocc`. CO-RE (Compile Once Run Everywhere) means
the same `intp.bpf.o` loads on any kernel >= 5.8 with BTF; libbpf
relocates struct field accesses against the running kernel's BTF at
load time. Output is stap-2022-compatible TSV with a header line declaring
which backend supplied each column; `--output json` and `--output
prometheus` are also offered.

**Backend / probe map.**

| metric | mechanism                                                                  |
|--------|----------------------------------------------------------------------------|
| netp   | `tracepoint:net:net_dev_xmit` + `tracepoint:net:netif_receive_skb` lengths |
| nets   | TX: `tracepoint:net:net_dev_start_xmit` + `kretprobe/__dev_queue_xmit`. RX: `fentry/fexit` on `napi_poll` (preferred), or per-CPU `kprobe/kretprobe`, or `softirq_entry` + `napi:napi_poll` tracepoint pair -- see DESIGN.md 10.1. |
| blk    | `tracepoint:block:block_rq_complete` field reads via `BPF_CORE_READ`       |
| cpu    | `tracepoint:sched:sched_switch` + per-task time                            |
| llcmr  | `BPF_PROG_TYPE_PERF_EVENT` + `PERF_TYPE_HW_CACHE`                          |
| mbw    | resctrl `mbm_total_bytes` (via userspace `resctrl/resctrl.c`)              |
| llcocc | resctrl `llc_occupancy` (per-domain sum)                                   |

In-kernel PID filtering is done via a single-entry `BPF_MAP_TYPE_ARRAY`
config (`target_pids[INTP_MAX_PIDS=64]` + `system_wide` flag) so events
for non-target PIDs are never reserved in the ring buffer (DESIGN.md
section 7).

**Measurement fidelity.**

- `netp`, `blk`, `cpu`, `llcmr`: full fidelity matching stap-2022.
- `nets` TX: exact (the `skbaddr` from `net:net_dev_start_xmit` allows
  end-to-end correlation).
- `nets` RX: full fidelity on the **`fentry/fexit`** path (BPF
  trampoline gives the `napi_struct *` argument on both entry and
  exit, so RX latency closes byte-equivalent to stap-2022). At load time
  ebpf-ring falls back, in order, to (a) a per-CPU slot keyed by softirq
  non-reentrancy with `kprobe + kretprobe`, then (b) coarser
  `softirq_entry` + `napi:napi_poll` tracepoint pair (status=
  `degraded`). The chosen backend is declared in the output header
  and surfaced via `--list-capabilities`. DESIGN.md section 10.1
  details the three paths and why fentry/fexit is the default.
- `mbw`, `llcocc`: matches stap-nohelper/bpftrace (same resctrl source).

**Deployment requirements.** Kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y`,
clang >= 11, libbpf >= 0.8 with headers, `bpftool` (linux-tools-*),
`libelf-dev`, `zlib1g-dev`. Runtime: `CAP_BPF`, `CAP_PERFMON`,
`CAP_SYS_RESOURCE`, plus root (or fine-grained file caps) on
`/sys/fs/resctrl`. The compiled `.bpf.o` is portable across kernels;
the userspace binary is a normal native build.

**Performance overhead.**

- Probe overhead ~100-200 ns per event (consistent with published
  eBPF tracepoint numbers).
- Ring buffer >= 1 M events/sec at 16 MiB without drops on Xeon
  Platinum 8360Y.
- Startup ~500 ms (verifier load).
- Steady-state userspace I/O-bound on `ring_buffer__poll`; aggregation
  is integer additions inside a switch.

**Known limitations.**

1. *NAPI RX attach prerequisites* (DESIGN.md 10.1) -- the highest-
   fidelity path needs BPF trampoline support (`CONFIG_FUNCTION_TRACER`
   + `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`). On distro kernels
   this is enabled by default; on hardened or custom kernels ebpf-ring
   degrades through the per-CPU kprobe path or the tracepoint pair
   rather than failing.
2. *No RDT MSR access from eBPF* -- the verifier blocks raw MSR reads,
   which is why ebpf-ring still needs resctrl as a userspace co-process for
   `mbw`/`llcocc`. This is a kernel/eBPF-policy boundary, not an ebpf-ring
   shortcoming.
3. *CO-RE limits* -- per Zhong et al. (2025), ~83% of studied eBPF
   tools are affected by at least one inlined/renamed/static-marked
   symbol failure across major kernel versions. ebpf-ring mitigates by
   preferring tracepoints over kprobes wherever possible and by
   degrading gracefully (zero output) rather than crashing on missing
   symbols.
4. *LLC miss ratio context handling bug* (fixed 2026-05-08): the
   `BPF_PROG_TYPE_PERF_EVENT` reader was reading the wrong context
   field, causing llcmr to report zero even when the hardware counter
   was incrementing correctly. The fix uses the proper
   `bpf_perf_event_read_value` call site. Campaigns prior to the fix
   under-report v3/llcmr; data from the in-flight veth campaign is the
   first clean source.
5. *Forked-descendant tracking bug* (fixed 2026-05-08): the previous
   build kept a single-entry PID array and never re-checked for forks.
   `stress-ng --cpu 24` (or any workload that forks N stressors at
   launch) ran with the BPF programs filtering out every fork
   descendant — parent stayed in the array, children did the work, no
   events captured. The fix follows `sched_process_fork` and adds
   descendant PIDs to the target set. blk and cpu under-reporting in
   pre-fix campaigns was traced to this. See
   `docs/EXPERIMENT-STRATEGY.md` § V3.

**Relationship to other variants.** ebpf-ring sits at the "native eBPF" end
of the spectrum: same safety guarantees as bpftrace, same cross-kernel
portability as C-ABI, but with the per-event cost profile of compiled C.
In Phase 3 it plays the "modern eBPF" role against stap-2022 (original
SystemTap) and stap-nohelper (refactored SystemTap), evaluated on accuracy,
overhead (Volpert et al. ICPE 2025 methodology), portability,
deployment complexity, and execution-environment behaviour
(bare-metal / container / VM).

### V3.2 (eBPF-CORE) -- eBPF in-kernel aggregation (paper section VIII)

**Architecture summary.** eBPF-CORE is ebpf-ring's structural alternative: a
distinct point on the streaming-vs-aggregation axis the paper
enumerates, not an optimization of ebpf-ring. The same eBPF probe sites
(net_dev_xmit, block_rq_complete, sched_switch, softirq_entry/exit,
perf_event LLC counters) fire, but every event lands as a 64-bit
atomic increment on a per-CPU counter slot
(`BPF_MAP_TYPE_PERCPU_ARRAY`) and a per-TGID counter slot
(`BPF_MAP_TYPE_HASH`), not as a record in a 16 MiB ring buffer.
Userspace `nanosleep`s for `--interval` seconds, calls
`bpf_map_lookup_elem` on `agg_global` once (returning one
`struct intp_counters` per CPU), sums across CPUs, diffs against the
previous snapshot, normalizes, and emits one TSV row. There is no
`ring_buffer__poll`, no event handler dispatch table, no per-event
work in userspace.

**Backend / probe map.** Same as ebpf-ring except `nets` uses softirq
tracepoints exclusively (kernel 6.x has napi_poll inlined, so the
fentry/fexit and kprobe paths ebpf-ring documents are unreachable
anyway):

| metric | mechanism                                                                  |
|--------|----------------------------------------------------------------------------|
| netp   | tracepoint:net/net_dev_xmit + netif_receive_skb -> agg counters            |
| nets   | tracepoint:irq/softirq_entry+exit vec={2,3} -> per-CPU keyed deltas        |
| blk    | tracepoint:block/block_rq_issue + complete + (dev<<32)|sector key          |
| cpu    | tracepoint:sched/sched_switch + task_oncpu_start hash                      |
| llcmr  | perf_event programs scaled by sample_period (10000 -> 1000 retune)         |
| mbw    | resctrl mbm_total_bytes + new dual reader (percent AND raw MB/s)           |
| llcocc | resctrl llc_occupancy (unchanged)                                          |

**Measurement fidelity.** Equivalent to ebpf-ring within the 15% relative
tolerance the cross-variant equivalence test enforces. The
`test-metrics-equivalence.sh` script makes the contract explicit.
Per-event introspectability is lost; MPSC FIFO ordering between
probes is lost; sample-loss visibility is lost. None of these are
needed for the steady-state IntP workload the paper studies.

**Deployment requirements.** Same as ebpf-ring (kernel 5.8+ with BTF,
clang 11+, libbpf 0.8+, bpftool, libelf, zlib; CAP_BPF / CAP_PERFMON
at runtime; resctrl for hardware metrics).

**Performance characteristics.** The structural goal is to converge
with C-ABI on scheduler-perturbation while keeping eBPF portability and
the 7-metric coverage. The acceptance test enforces this:
`test-no-ctxsw-amplification.sh` measures vmstat ctxt across a 90s
window with and without the profiler and fails if the ratio exceeds
1.10 (ebpf-ring fails this test at 188-390x).

**mbw normalization.** eBPF-CORE fixes the silent clip documented in
paper section IV-E. The legacy V3 `resctrl_read_mbm_delta()` hard-
clips at 100% (producing the bimodal discrete 96/80/64/48/32/16/0
pattern when `mem_bw_max_bps` is misconfigured); eBPF-CORE's
`resctrl_read_mbm_pct_and_raw()` returns the unclipped percent AND
the raw MB/s in one counter step. A trailing `mbw_raw_mbps` TSV
column carries the raw reading; `--no-raw-mbw` suppresses it for
byte-compat. The clip-at-99 behavior is opt-in via `--clip-mbw`.

**Known limitations.**

1. *Loss of per-event introspection.* No `--trace` flag. Tools built
   on eBPF-CORE reason about intervals, not events.
2. *Loss of MPSC FIFO ordering* between probes. A blk completion
   that lands at the same instant as a sched_switch is unordered.
3. *Per-PID nets attribution is structurally impossible.* Same as
   ebpf-ring: softirqs run in interrupted context. Only system-wide nets
   is attributable.

**Relationship to other variants.** eBPF-CORE sits "below" ebpf-ring on the
streaming-vs-aggregation axis (less observability, less amplification)
and "above" C-ABI (eBPF probes with sub-microsecond cost vs. /proc
polling). It does not replace ebpf-ring -- ebpf-ring remains the introspection
profiler. eBPF-CORE is the steady-state profiler the paper section VIII
calls for.

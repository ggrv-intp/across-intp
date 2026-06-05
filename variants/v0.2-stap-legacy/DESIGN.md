# v0.2 design

## Problem

v0 (stap-2022) (`variants/v0-stap-2022/intp.stp`) is the paper-original IntP profiler from
Xavier and De Rose (SBAC-PAD 2022). It captures all seven metrics from a
single SystemTap script that includes an embedded C block to drive uncore
IMC perf events and to read `cqm_rmid`-based LLC occupancy. Both
operations run from inside stap probe context (specifically, from the
embedded C functions `perf_kernel_start()` / `perf_kernel_read()` and
`rmid_read()`).

Two distinct things later broke that design:

1. **`cqm_rmid` was removed from `struct hw_perf_event` in kernel
   4.14** (November 2017, commit `c39a0e2c8850`), together with the
   `intel_cqm` perf PMU driver that populated it; the replacement is
   the `resctrl` interface. stap-2022 only compiles on kernels that either
   (a) preserve the `intel_cqm` driver via a vendor backport (some
   enterprise LTS lines carried this until ~2019-2020), or (b) were
   hand-compiled with the driver restored. Empirically, on Ubuntu
   22.04's stock 5.15 kernel the field is already absent, and 6.8 is
   simply the point at which no mainstream distro still ships the
   backport. v0.1 (stap-nollc) is the minimal patch that keeps stap-2022 compilable on
   kernel 6.8 by disabling LLC occupancy; that gap is documented in
   `docs/VARIANT-COMPARISON.md`.

2. **Ubuntu 22.04's 5.15 kernel** ships with RCU-checking backports
   from Canonical (`CONFIG_PROVE_RCU=y` plus stricter `lockdep` hits)
   that destabilise stap-2022 even though `cqm_rmid` is still present.
   `perf_event_create_kernel_counter()` called from stap probe context
   triggers `RCU stall` and `BUG: scheduling while atomic` reports;
   `on_each_cpu_mask()` from the `rmid_read()` path tickles
   `softirq` deferred work scheduling in a way that pins CPU 0 in D
   state. Symptoms observed during the 2026-05 pilot: stapio orphans
   that survive `staprun -d`, `stap_*` kernel modules that accumulate
   across reps and eventually drain the systemd DBus object budget,
   `pam_systemd: Failed to create session` on the next SSH login, and
   D-state deadlock requiring a hard reboot.

stap-nollc addresses (1) by dropping LLC occupancy entirely; the cost is the
loss of one of the seven metrics. v1 (stap-nohelper) addresses both (1) and (2) by
moving to stap-native probes (no embedded C creating perf events) but
loses both `mbw` and `llcocc` because RDT cannot be driven from
RCU-safe probe context at all. v1.1 (stap-modern) recovers the full 7-metric coverage
by introducing a userspace helper for the RCU-unsafe operations, but
targets kernel 6.8+.

v0.2 (stap-legacy) is the missing leg: **paper-faithful stap-2022 semantics on kernel 5.15
GA, with the two RCU-unsafe operations moved out of probe context into
a userspace helper.**

## Architecture

```
                       host kernel 5.15 GA
   +---------------------------------------------+
   |                                             |
   |   stap probes (RCU-safe; stap-2022-faithful)|
   |   netfilter.* / kernel.trace("block_rq_*")  |
   |   __dev_queue_xmit / napi_complete_done     |
   |   perf.type(3).config(...).process(@1)      |
   |   timer.profile + perf.sw.cpu_clock         |
   |                                             |
   |   procfs("intestbench").read --------+      |
   |     calls read_hw_mbw()              |      |
   |     calls read_hw_llcocc()           |      |
   |                                      v      |
   |   embedded C in stap (only here):           |
   |     filp_open + kernel_read on              |
   |     "/tmp/intp-v0.2-hw-data"                |
   |                                             |
   +-----------------------+---------------------+
                           ^
                           | filesystem (RCU-safe at user-context read)
                           |
   +-----------------------+---------------------+
   |  userspace: intp-helper (this directory)    |
   |    perf_event_open(2)  uncore_imc_*  ──→ mbw|
   |    resctrl/mon_groups/intp-v02-<pid> ──→ occ|
   |    /proc/<pid>/comm  scan once per second   |
   |    atomic_replace("/tmp/intp-v0.2-hw-data") |
   +---------------------------------------------+
```

Key properties:

- **No embedded C from probe context creates perf events.** The only
  embedded C in the stap script is `filp_open + kernel_read` on a
  user-space file, invoked from `procfs.read`, which runs in user-task
  context. This is the same RCU-safe pattern stap-modern uses on kernel 6.8+.
- **No `on_each_cpu_mask` from probe context.** All cross-CPU coordination
  for IMC counters happens in the helper via `perf_event_open`'s normal
  per-cpu fd semantics.
- **Helper-side resctrl mon_group, not in-kernel cqm_rmid.** Same path
  stap-modern uses. On kernel 5.15 resctrl is also available via
  `/sys/fs/resctrl` with `L3_MON` support; the helper probes for it at
  startup and reports llcocc=0 with a warning if it's missing.
- **Per-PID file naming.** Mon-group is `intp-v02-<pid>` so a parallel
  stap-modern campaign (`intp-<pid>`) doesn't collide. Data file is
  `/tmp/intp-v0.2-hw-data` for the same reason.
- **Recalibration is two-tier.** NIC bandwidth flows from
  `shared/intp-detect.sh` through `generate-stp.sh` into the
  `.recal.stp` (host-specific stap-side normalization). DRAM bandwidth,
  L3 size, and IMC PMU types flow through helper environment variables
  (`INTP_HELPER_*`) set by the bench launcher from the same
  `intp-detect.sh` output. `variants/v0-stap-2022/intp.stp` stays read-only.

## Why not just patch v0 (stap-2022)?

Considered and rejected. The contract with the paper requires
`variants/v0-stap-2022/intp.stp` to stay byte-identical to the 2022 source. We
need at least one variant that exhibits the original fragility so the
dissertation can cite the reliability cliff. A patched stap-2022 would not
serve that role; stap-legacy sits next to stap-2022 and is selected explicitly by the
operator when the experiment goal is "stap-2022 semantics, but stable."

## Why not just use v1.1 (stap-modern)?

stap-modern targets kernel 6.8+. Its probe set has diverged from stap-2022's in
several places driven by changes in the modern tapsets (e.g., the
`net_dev_xmit` accounting is sligthly different, the block_rq path is
folded onto the `block_rq_complete` tracepoint with a different start-
time semantic). For the U22 / 5.15 leg of the experiment we want
*paper-faithful probe semantics where they are RCU-safe*. stap-legacy keeps
stap-2022's probe set verbatim and only diverges on the two probes that stap-2022
itself cannot run safely on 5.15 GA. The cost of duplication is bounded
to one stap script and a small fork of the helper; the benefit is
reproducibility against the paper's reported metrics on the U22 host
without the stap-2022 stability cliff.

## Status

Scaffolded 2026-05-11. Bench integration follows in the same commit; a
smoke run on a real U22 / 5.15 host is part of the operator-side
preflight (the bench harness's `run_profiler_systemtap_v0_2` will be
exercised as part of `SMOKE_V0_2=1` once added to `run-smoke-all.sh`).

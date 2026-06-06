# V1 (stap-nohelper) Modernization -- Reliability Findings on Modern Host

**Date range:** 2026-05-01
**Host:** intp-master (Hetzner SB)
**Kernel:** 6.8.0-111-generic (Ubuntu 24.04)
**CPU:** Intel Xeon Gold 5412U (Sapphire Rapids)
**SystemTap:** 5.2 (from source)

---

## Objective

Assess whether the V1 (stap-nohelper) SystemTap path can be considered a reliable modernized
equivalent of the original IntP methodology, while preserving the 7-metric
output contract.

---

## What was improved in V1 (stap-nohelper)

1. Build/runtime compatibility restored on kernel 6.8 via SystemTap 5.2 and
   script fixes.
2. Host-calibrated constants applied:
   - LLC size: 46080 KB (45 MiB).
   - Memory bandwidth max: 281600 MB/s.
   - IMC PMU types switched from legacy hardcode to host-valid values.
3. LLC miss-ratio collection changed from fragile per-process sampling to a
   more robust counter-based strategy suitable for Sapphire Rapids.
4. Procfs output and process lifecycle tracking work end-to-end during stress
   workload runs.

---

## Findings that still matter for reliability

1. **Probe skip pressure remains non-trivial under load**
   - `skipped probes` persists in realistic runs.
   - In `stap -t` mode, runs can still fail with "Skipped too many probes"
     depending on workload timing and probe pressure.

2. **CPU metric path is the primary contention hotspot on SystemTap**
   - `timer.profile`/cpu-clock based collection causes lock contention under
     modern workloads.
   - To stabilize stap-nohelper execution, CPU metric may need to be disabled (or moved
     to userspace side-channel collection) while preserving TSV schema.

3. **blk metric required defensive sanitization**
   - Rare invalid timestamp deltas can produce overflow-like artifacts if not
     filtered.
   - Robust guards are required to keep `blk` in a physically meaningful range
     [0,99].

4. **Operational sensitivity remains high compared to modern variants**
   - Small changes in probe set or verbosity materially affect stability.
   - This sensitivity itself is evidence of lower production robustness.

5. **Stap-mediated D-state deadlock with no userspace recovery path**
   - **Date observed:** 2026-05-03 (Hetzner Sapphire Rapids, kernel 6.8.0-111-generic)
   - **Symptoms:** Two `stapio` worker processes (intp-resctrl.stp and intp-6.8.stp,
     PIDs 6681 and 2666) and one `stress-ng` workload (PID 4744, in cgroup
     `intp-bench-bare-v3-app02_ml_llc`) entered uninterruptible sleep
     (`STAT D`, `WCHAN wait_r`) and stayed there for 47-49 minutes after
     the parent tmux session was killed.
   - **Recovery attempts that failed:**
     - `kill -KILL <pid>` — D-state ignores signals until the kernel
       returns from the blocked call.
     - `pkill -KILL -f stapio` / `pkill -KILL -f '^stap '` — same.
     - `rmmod -f stap_<hash>` — refused with `EAGAIN`/"Resource temporarily
       unavailable" because stapio still held module refcount = 1.
   - **Resolution:** Hard reboot. No userspace path recovers from this state
     once the probe handler is wedged behind a kernel completion.
   - **Operational consequence:** A single deadlock event invalidates all
     in-flight measurements, blocks new SystemTap variants from loading
     (procfs collision on `/proc/systemtap/<module>`), and requires physical
     or out-of-band reboot access. In a shared-tenant or production
     environment, this is a hard blocker on running the SystemTap-based
     variants for sustained campaigns.
   - **Implication for the framework comparison:** C-ABI (procfs polling),
     bpftrace and ebpf-ring (eBPF/CO-RE) cannot reach this failure class by
     construction — none of them install kernel probes that can recursively
     enter kernel locks held by the probed code path. eBPF in particular is
     verified to terminate.

---

## Interpretation for cross-variant comparison

This finding supports a two-layer conclusion:

1. **stap-nohelper is a successful compatibility bridge** for reproducing the legacy
   methodology on modern kernels/hardware.
2. **stap-nohelper is not the reliability endpoint**: C-ABI/bpftrace/ebpf-ring/eBPF-CORE remain more robust
   for sustained benchmarking because they avoid the high-friction SystemTap
   kernel instrumentation path. stap-modern (stap + userspace helper) recovers full
   7-metric coverage on modern kernels without putting RCU-unsafe operations
   in stap probe context.

In practice:

- Use stap-nohelper to preserve historical continuity and document legacy behavior.
- Use stap-modern, C-ABI, or eBPF-CORE as the reliability baseline for final comparative
  claims (these are three of the four "measured result" variants for the
  paper; the fourth is legacy-intp-baseline on the U22 / kernel 5.15 leg).

---

## Reporting guidance (paper/dissertation)

When presenting results, explicitly separate:

1. **Historical comparability** (stap-2022/stap-nohelper lineage).
2. **Operational reliability** (C-ABI/bpftrace/ebpf-ring).

Recommended phrasing:

> The modernization of the original SystemTap methodology (stap-nohelper) restored
> functional portability but retained non-negligible runtime fragility under
> high probe pressure. This gap motivated the framework transition in C-ABI/ebpf-ring,
> which improved repeatability and reduced instrumentation-induced loss.

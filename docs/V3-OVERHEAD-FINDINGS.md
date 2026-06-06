# v3 (ebpf-ring) overhead findings (motivation for v3.2 (eBPF-CORE))

This document summarises the empirical ebpf-ring measurements that motivated
the design of eBPF-CORE. It is the in-repo digest of paper section VI
(overhead decomposition). ebpf-ring itself is not deprecated: it remains the
introspection-friendly profiler and the *predecessor of record* for
eBPF-CORE's architectural decisions.

For full numbers, raw traces, and the paper-grade exposition, see:

- Paper section VI (overhead decomposition).
- `variants/v3-ebpf-ring/DESIGN.md` section 4 ("Ring buffer vs. perf event array").
- Specific run logs under `bench/findings/`.

---

## 1. System-wide context-switch amplification: 188-390x

Under steady-state load on `intp-master` (Xeon Gold 5412U / Sapphire
Rapids, kernel 6.8), ebpf-ring amplifies the host's system-wide
context-switch rate by a factor of **188x to 390x** depending on the
workload class. Idle floor and bursty I/O are at the low end of the
range; CPU-bound multithreaded workloads (HiBench Spark stages,
`stress-ng --cpu`) are at the high end.

### Measurement caveat

The amplification is observed via **`vmstat 1`** (the
`/proc/stat::ctxt` counter). `perf stat -e sched:sched_switch` reports
roughly 3 orders of magnitude *less* because ebpf-ring's BPF program is
attached to the same `sched_switch` tracepoint that perf is sampling:
the BPF handler runs first and then the perf sample is taken, so the
sample slot is consumed by ebpf-ring's own work and the "real" ctxsws under
load are not represented in the perf histogram. `vmstat` is the
ground-truth counter; perf under-reports by construction whenever a
BPF program is attached to the same tracepoint.

This is the single most surprising finding from the ebpf-ring campaign and
the reason `bench/v3-overhead-vmstat.sh` exists.

---

## 2. Decomposition: 50/50 between two structurally coupled mechanisms

The amplification splits roughly evenly between:

- **Mech #1 -- Consumer wakeups.** Every time a worker thread fires a
  probe, ebpf-ring's BPF program reserves a slot in a 16 MiB
  `BPF_MAP_TYPE_RINGBUF` and either calls `bpf_ringbuf_submit` or
  the kernel flushes once the wakeup threshold is reached. The
  userspace `intp` consumer is `epoll`-blocked on the ring's poll
  fd; the submit/flush wakes it, the kernel context-switches into
  the consumer, the consumer drains the ring, and goes back to
  sleep. Each round trip is one ctxsw, by construction.

- **Mech #2 -- Induced preemption of co-resident workers.** The
  consumer thread, once woken, runs on whatever CPU the scheduler
  hands it. On a CPU-bound workload, that CPU was already running
  a worker; the consumer's slice preempts it, the worker
  context-switches out, the consumer drains, the consumer goes
  back to sleep, the worker context-switches back in. That is two
  more ctxsws per drain on top of the wakeup itself.

### Why this is not load-dependent

Each Mech #1 wakeup *is* a Mech #2 preemption opportunity by
construction: the wakeup *has to* land on some CPU, and on a
saturated host that CPU is by definition running a worker. So the
two mechanisms are not independent contributors that happen to be
balanced -- they are coupled by the architecture of "drain a ring
buffer from a userspace thread". The split is 50/50 by design, not
by happy accident. Removing one without removing the other is
structurally impossible inside the streaming pattern. Removing both
is what eBPF-CORE does by aggregating in-kernel and polling once per
interval.

---

## 3. mbw normalisation: silent clipping and discrete-outlier artifact

ebpf-ring's `resctrl_read_mbm_delta()` normalises memory bandwidth as
`100 * bytes_per_sec / INTP_MEM_BW_MBPS_BYTES`. On `intp-master`,
`INTP_MEM_BW_MBPS` is 281 600 (8 DDR5 channels times the per-channel
theoretical peak). Two failure modes:

1. **Silent saturation at 100%.** When the observed bandwidth
   exceeds the configured ceiling -- which happens whenever the
   ceiling is misconfigured, or when a workload pushes past the
   theoretical peak under measurement skew -- ebpf-ring clips at 100% with
   no warning. The trailing fraction is lost.

2. **Discrete outliers (96, 80, 64, 48, 32, 16, 0).** When one or
   more of the 8 memory channels read as zero in a sample window,
   the normalised value lands on a multiple of `100 / 8 = 12.5%`,
   rounded -- producing the bimodal pattern of discrete outliers
   that was initially misread as a measurement artifact. The cause
   is per-channel zero reads, not a normalisation bug per se; the
   bug is that ebpf-ring cannot tell zero-read from genuinely-zero
   bandwidth and the clipping/discretisation hide both.

### Confirming the signal is real

The resctrl-derived `mbw` byte counter (read separately, before any
normalisation) shows the actual noise-floor bandwidth at about
**5.65 GB/s** under idle load on `intp-master`. The signal is
present and non-zero; ebpf-ring's binary normalisation is what produces
the misleading display. eBPF-CORE emits both `mbw_pct` (normalised) and
`mbw_raw_mbps` (the raw byte rate), so consumers can detect either
failure mode immediately. Clipping at 100% is opt-in via
`--clip-mbw` rather than the default.

---

## 4. Why v3 (ebpf-ring) stays in the repo

ebpf-ring is retained as the predecessor of eBPF-CORE for two reasons:

1. **Empirical justification.** The overhead measurements above are
   the empirical evidence that motivates the in-kernel-aggregation
   architecture. Removing ebpf-ring would orphan that evidence chain. Any
   future reviewer who asks "why not just stream events?" should be
   able to run ebpf-ring and reproduce the 188-390x amplification on their
   own host.

2. **Per-event introspection.** ebpf-ring retains `--trace` mode and the
   MPSC FIFO ordering of probe events that eBPF-CORE trades away. For
   debugging individual probe sites or chasing causal ordering bugs,
   the streaming pattern is the right tool. eBPF-CORE is the right tool
   for steady-state interference characterisation.

ebpf-ring is the *introspection profiler*; eBPF-CORE is the *steady-state
profiler*. Both have a home.

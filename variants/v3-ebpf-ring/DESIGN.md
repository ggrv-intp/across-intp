# V3 (ebpf-ring) Design -- eBPF / CO-RE / libbpf

## 1. Research positioning

ebpf-ring is the canonical **alternative-technology prototype** promised in the
Plano de Pesquisa (PeP) for this dissertation. The research hypothesis
argues that eBPF is the appropriate modern replacement for SystemTap as
the kernel instrumentation framework for IntP; ebpf-ring is the concrete
implementation of that claim. In the Phase 3 head-to-head comparison it
plays the "eBPF" role against:

- stap-2022 -- original SystemTap IntP (Xavier and De Rose -- PUCRS, SBAC-PAD 2022).
- stap-nohelper -- refactored SystemTap IntP (this dissertation, chapter 4).

The comparison is evaluated on five dimensions: measurement accuracy,
runtime overhead (following Volpert et al. ICPE 2025), cross-kernel
portability, deployment complexity, and execution environment behavior
(bare-metal, container, VM).

ebpf-ring is **not** a reimplementation of `iprof` (Gögge 2023, TU Berlin
master's thesis; Becker, Goegge, Kao 2024, UCC Companion) or PRISM
(Landau, Barbosa, Saurabh 2025, Utrecht University,
arXiv:2505.13160). ebpf-ring implements IntP's exact 7-metric set with
matching semantics, which neither tool does: `iprof` covers 5 metrics
and omits RDT; PRISM covers 16 software metrics but no hardware PMU.
Neither is a PUCRS work -- they are external eBPF-based interference
profilers in the related-work landscape, not predecessors of IntP.

## 2. CO-RE mechanics in detail

CO-RE (Compile Once, Run Everywhere) is the mechanism that lets a single
compiled eBPF object load successfully on kernels with different struct
layouts. The pipeline is:

1. **Compile time.** The BPF program is compiled against `vmlinux.h`
   generated from *one* kernel's BTF. Every kernel-struct field access
   written as `BPF_CORE_READ(ptr, field)` (or the equivalent macros)
   produces a relocation entry in the `.BTF.ext` section of the object,
   recording the field name path rather than a concrete offset.
2. **Load time.** libbpf reads the *target* kernel's BTF from
   `/sys/kernel/btf/vmlinux`, walks each relocation, resolves field
   offsets against the running kernel's layout, and patches the
   bytecode before feeding it to the verifier.
3. **Result.** The same `.o` file works across kernel versions as long
   as the referenced field *exists* (possibly at a different offset or
   in a different enclosing struct).

What CO-RE does **not** rescue: functions that get inlined or renamed
between kernel versions, tracepoints that are removed, symbols that are
marked static. Zhong et al. (2025) report that ~83% of studied eBPF
tools are affected by at least one such failure across major kernel
versions. ebpf-ring mitigates this by:

- Preferring tracepoints over kprobes where both options exist (the
  tracepoint ABI is maintained more stably than symbol layouts).
- Keeping struct field access behind `BPF_CORE_READ` everywhere.
- Accepting that if the kernel removes a function we probe (e.g.
  `napi_poll`), ebpf-ring degrades gracefully -- that metric reports zero rather
  than crashing.

### 2.1 vmlinux.h generation

```bash
bpftool btf dump file /sys/kernel/btf/vmlinux format c > src/vmlinux.h
```

One header, every kernel type. Replaces `-I` flags pointing at kernel
headers. The Makefile regenerates this file as a normal dependency so
that a newer kernel's BTF is picked up without manual intervention.

## 3. libbpf skeleton pattern

`bpftool gen skeleton src/intp.bpf.o > src/intp.skel.h` produces a
header that exposes, for the object named `intp.bpf.o`:

- `struct intp_bpf *intp_bpf__open(void);`
- `int intp_bpf__load(struct intp_bpf *);`
- `int intp_bpf__attach(struct intp_bpf *);`
- `void intp_bpf__destroy(struct intp_bpf *);`
- Named accessors for every program and map: `skel->progs.tp_sched_switch`,
  `skel->maps.events`, etc.

Why use the skeleton instead of raw `bpf()` syscalls:

- Type safety: the generated header encodes every map and program name,
  so references to nonexistent symbols are compile errors.
- Correct lifecycle: open -> set options -> load -> attach -> destroy is
  a well-defined state machine, and the skeleton encapsulates it.
- Production alignment: BCC tools, Cilium, Pixie, libbpf-bootstrap all
  use the skeleton pattern. ebpf-ring matches established practice.

## 4. Ring buffer vs. perf event array

ebpf-ring uses a single `BPF_MAP_TYPE_RINGBUF` map (16 MiB) rather than a
`BPF_MAP_TYPE_PERF_EVENT_ARRAY`:

| Aspect               | Ring buffer (V3 / ebpf-ring)     | Perf event array           |
|----------------------|----------------------------------|----------------------------|
| Kernel min           | 5.8                              | 4.3                        |
| Layout               | single shared buffer             | one per CPU                |
| Record size          | variable                         | fixed per reservation      |
| Memory waste         | none                             | proportional to CPU count  |
| Order guarantee      | MPSC FIFO (ordered per producer) | per-CPU                    |

Kernel 5.8 is ebpf-ring's minimum anyway (for `CAP_BPF`), so the
ring-buffer-only dependency is free. 16 MiB comfortably buffers bursts
at millions of events/second without drops; the size is configurable
via `--ringbuf-size`.

## 5. Comparison with iprof (Gögge 2023; Becker, Goegge, Kao 2024)

`iprof` is the eBPF-based interference profiler from Gögge's TU
Berlin master's thesis (advised by Sören Becker and Prof. Odej Kao,
2023), and the companion paper by Becker, Goegge, and Kao published
at UCC Companion 2024. ebpf-ring looks at it for architectural ideas only --
it is **not** a PUCRS predecessor of IntP, and ebpf-ring does not inherit
code from it. Differences:

| Aspect                  | iprof                                          | V3 (ebpf-ring) IntP        |
|-------------------------|------------------------------------------------|----------------------------|
| Metrics covered         | 5 categories (cpu, blk, netI/O, llc, mem)      | all 7 (netp/nets split, mbw + llcocc + llcmr split) |
| Hardware via resctrl    | no                                             | yes (MBM + CMT + MPAM)     |
| LLC miss ratio          | direct PERF_TYPE_HW_CACHE refs/misses, sample_period=1000 | identical encoding |
| LLC occupancy           | not measured                                   | direct RDT `llc_occupancy` |
| Memory BW metric        | stalled-backend-cycles ratio (Kim 2020 [15])   | direct MBM `mbm_total_bytes` |
| CPU metric              | run-queue occupancy at `finish_task_switch()`  | on-CPU time at `sched_switch` |
| Per-PID attribution     | limited / best-effort (single-app eval)        | in-kernel filter + fork tracking |
| Skeleton pattern        | cilium/ebpf `bpf2go`-generated (one per metric package) | libbpf skeleton (single object) |
| Transport               | counter maps polled once at process shutdown   | BPF_MAP_TYPE_RINGBUF + ring_buffer__poll loop |
| CO-RE                   | partial                                        | full                       |
| Output format           | custom                                         | stap-2022-compatible TSV   |

Note that iprof's transport model is a strictly *single-shot*
in-kernel-aggregation: BPF programs accumulate via
__sync_fetch_and_add into BPF_MAP_TYPE_HASH / BPF_MAP_TYPE_ARRAY /
BPF_MAP_TYPE_PERCPU_ARRAY maps for the entire profiling window,
and the userspace Go binary reads each map exactly once when the
context is cancelled (SIGINT/SIGTERM or the `-t` deadline). There
is no continuous consumer thread, no ring buffer, and no periodic
poll. ebpf-agg is therefore *closer* to iprof than ebpf-ring ever was on the
transport axis, and *closer to PRISM* than iprof on the temporal
axis (interval-based snapshots vs end-of-run single read).

The earlier characterisation of iprof's LLC metric as a
"stalled-backend-cycles proxy" was incorrect; iprof computes LLC miss
ratio directly via `perf_events` (paper §III.A "Last Level Cache":
"two eBPF programs, one ... for the reference count and another for
the miss count, to every generated `perf_event`"). What iprof
**does** approximate is `mem` -- following Kim et al. (IEEE Access
2020 [15]) it measures the ratio between total cycles and stalled
backend cycles, with no resctrl involvement. IntP ebpf-ring sidesteps that
proxy by using MBM directly when resctrl is available; the
stalled-cycles ratio remains a useful fallback when resctrl is fenced
off (e.g. unprivileged containers without `--cap-add=SYS_ADMIN`) and
is recorded here so it can be wired in if needed.

## 6. Comparison with PRISM (Landau et al. 2025)

PRISM covers 16 software metrics (scheduling, futexes, epoll, net,
block, pipes) via eBPF + Docker. It deliberately omits hardware PMU
instrumentation because RDT MSR access isn't exposed to the BPF
verifier. ebpf-ring is complementary: fewer software dimensions (the IntP
7-metric set), but includes the hardware layer by hybridizing eBPF with
resctrl.

Architectural ideas ebpf-ring borrows from PRISM:

- Single ring buffer as the event transport.
- Per-thread attribution via `(pid, tid)` keyed state.
- Container-first deployment pattern (see section 11).

## 7. Per-thread attribution strategy

Filtering happens **in-kernel**:

1. Userspace writes an `intp_config` record into a single-entry
   `BPF_MAP_TYPE_ARRAY`, containing `target_pids[INTP_MAX_PIDS]` and a
   `system_wide` flag.
2. Every probe calls `should_monitor_current()`, which looks up the
   config and (if not system-wide) compares `bpf_get_current_pid_tgid()`
   against the target PIDs in a bounded loop (verifier-friendly because
   `INTP_MAX_PIDS = 64`), then falls back to a lookup in
   `descendant_tgids` (a `BPF_MAP_TYPE_HASH`).
3. Events for non-target PIDs are never reserved in the ring buffer,
   keeping userspace cost proportional to the monitored workload, not
   to system activity.

Soft-IRQ-context probes (e.g. `netif_receive_skb`) have less reliable
PID context because the current task is whoever was interrupted rather
than the socket owner; ebpf-ring documents this as an approximation in those
paths.

### 7.1 Tracking the fork tree

The static `target_pids` array gets seeded with the PIDs the user
passed via `--pids`. Real workloads almost never stay as a single TGID:
stress-ng `--cache 24` forks 24 stressor children, HiBench's Spark
launches one driver process plus per-task executor processes,
HDFS DataNode forks worker processes at startup. Each child has a
**new TGID** (not just a new TID), so a filter that knows only the
parent rejects every child event and the per-PID profile collapses to
zero on `llcmr`, `nets`, `blk`, and `cpu`.

iprof's evaluation (Becker/Goegge/Kao 2024) doesn't trip this because
its setup runs on a "mostly idle" dedicated machine where system-wide
observation is fine; the paper explicitly states "either the
application provider must handle interference profiling and supply the
values, or profiling must be conducted on a dedicated machine"
(§II.B). IntP ebpf-ring is intended for cross-application interference
attribution, where per-PID is the whole point, so the fork tree must
be tracked.

ebpf-ring maintains the fork tree in two passes:

1. **Static seed at attach time** -- userspace walks
   `/proc/<pid>/task/<tid>/children` recursively for every PID in
   `cfg.target_pids` and writes each descendant TGID into the
   `descendant_tgids` BPF hash map via `bpf_map_update_elem`. This
   captures pre-existing forks that completed before profiler attach.
   See `seed_descendants_from_proc()` in `src/intp.c`.

2. **Dynamic tracking via tracepoint** -- a
   `tracepoint:sched:sched_process_fork` BPF program runs on every
   fork. It checks whether the parent's TGID is in either filter and,
   if so, adds the child's TGID. A paired
   `tracepoint:sched:sched_process_exit` removes thread-leader TGIDs
   on process exit so the map doesn't grow unbounded (the gate is
   `pid == tgid`, which only fires when the leader exits, i.e. at
   true process exit). See `tp_sched_process_fork` /
   `tp_sched_process_exit` in `src/intp.bpf.c`.

The order is deliberate: the BPF tracepoints attach first, so any
fork that races with the userspace seed is captured by the dynamic
path even if the userspace walk missed it (e.g. if the workload
forked between `intp_bpf__attach()` returning and the
`/proc` traversal starting).

The map is sized at 8192 entries -- sufficient for stress-ng
(≤ 32 stressors), HiBench (≤ a few hundred Spark executor TGIDs after
collapsing per-thread duplicates), and reasonable container densities.
Threads of the parent share its TGID, so they don't consume map slots.

This shortcoming is shared with iprof per its DESIGN comparison
(§5 below): iprof's PID filter is "limited / best-effort" because it
aggregates system-wide into counter maps with no in-kernel
PID-filter map, attributing per-application after the fact rather
than scoping in kernel; the paper sidesteps it by single-application
evaluation. ebpf-ring closes the gap.

## 8. Hybrid with resctrl

eBPF cannot touch the RDT / MPAM MSRs under the kernel verifier. The
resctrl filesystem (`/sys/fs/resctrl`) is the kernel's supported
interface for those counters. ebpf-ring uses:

- **eBPF** for software metrics (netp, nets, blk, cpu, llcmr via
  perf_event sampling).
- **resctrl** for hardware metrics (mbw via `mbm_total_bytes`, llcocc
  via `llc_occupancy`), summed across every `mon_L3_*` domain.

One `mon_group` per ebpf-ring run (named `intp-v3`), PIDs written into its
`tasks` file at start. On shutdown the group is removed.

## 9. Performance characteristics

- **Probe overhead**: ~100-200 ns per event (consistent with published
  eBPF tracepoint numbers). `net_dev_xmit` + `netif_receive_skb` at
  10 Gbps line rate add well under 1% CPU.
- **Ring buffer throughput**: in excess of 1M events/sec at 16 MiB
  without drops, measured on Intel Xeon Platinum 8360Y.
- **Startup**: ~500 ms -- dominated by `intp_bpf__load()` (verifier
  runs on every program on first load).
- **Steady-state userspace**: mostly I/O-bound on `ring_buffer__poll`;
  aggregation is a simple switch statement with integer additions.
- **Memory footprint**: ~16 MiB ring buffer + small hash maps
  (<100 KiB) + userspace heap.

## 10. Kernel version requirements and graceful degradation

| Feature                          | Min kernel                   |
|----------------------------------|------------------------------|
| `BPF_MAP_TYPE_RINGBUF`           | 5.8                          |
| `CAP_BPF` / `CAP_PERFMON`        | 5.8 / 5.9                    |
| CO-RE (BTF-based relocation)    | 5.2+ (5.8+ in practice)      |
| `bpf_loop()` helper              | 5.17 (we don't use it)       |
| MPAM (ARM) via resctrl           | 6.19                         |

If `/sys/kernel/btf/vmlinux` is missing (CONFIG_DEBUG_INFO_BTF=n), the
build aborts; there is no kernel-header fallback path. If resctrl is
unavailable, `--no-resctrl` disables mbw and llcocc. If perf_event is
restricted (paranoid level > 1), `--no-perf-events` disables llcmr.

### 10.1 NAPI RX latency: paired entry/exit on `napi_poll`

stap-2022 measures network-stack RX service time by stamping a timestamp on
entry to `__napi_schedule_irqoff` and reading it again on
`napi_complete_done`, keyed on the `napi_struct *`. ebpf-ring must reproduce
that pairing under the eBPF verifier without losing the
`napi_struct *` key on the exit side.

#### 10.1.1 Why a kprobe + kretprobe pair does not work

The naive port -- `kprobe/napi_poll` to stamp t0 keyed by
`PT_REGS_PARM1`, `kretprobe/napi_poll` to read t0 -- fails because
**kretprobes do not expose function arguments**. The kretprobe BPF
context carries only the saved return value and stack frame, not the
`pt_regs` from entry. The `napi_struct *` used as the entry-side map
key cannot be recovered on exit, so latency samples cannot be closed.
This is the gap ebpf-ring originally documented and the reason its `nets`
metric was reported as `degraded` on the RX leg. TX is unaffected
because `tracepoint:net:net_dev_start_xmit` carries `skbaddr`
directly in its TP_struct, so `__dev_queue_xmit` and `net_dev_xmit`
are correlated end-to-end without recovering arguments.

#### 10.1.2 Chosen approach: `fentry/fexit` (BPF trampoline)

ebpf-ring uses **`fentry/fexit` programs** (BPF trampoline, type
`BPF_PROG_TYPE_TRACING` attached as `BPF_TRACE_FENTRY` /
`BPF_TRACE_FEXIT`). Unlike kretprobes, an `fexit` program receives
**all of the function's original arguments AND the return value** in
one context, so the entry-side key is available on exit:

```c
SEC("fentry/napi_poll")
int BPF_PROG(napi_poll_entry, struct napi_struct *n, int budget)
{
    u64 t = bpf_ktime_get_ns();
    bpf_map_update_elem(&napi_start, &n, &t, BPF_ANY);
    return 0;
}

SEC("fexit/napi_poll")
int BPF_PROG(napi_poll_exit, struct napi_struct *n, int budget,
             int retval)
{
    u64 *t0 = bpf_map_lookup_elem(&napi_start, &n);
    if (!t0)
        return 0;
    u64 dt = bpf_ktime_get_ns() - *t0;
    /* emit INTP_EVENT_NAPI_RX_LAT { napi=n, ns=dt } via ringbuf */
    bpf_map_delete_elem(&napi_start, &n);
    return 0;
}
```

**Why this is the right default for ebpf-ring:**

- *Correctness.* Closes the stap-2022 fidelity gap completely; the RX leg of
  `nets` becomes byte-equivalent to stap-2022/stap-nohelper again.
- *Lower overhead than kprobe.* BPF trampoline does not take the
  int3/breakpoint path; published numbers put fentry/fexit at roughly
  half the per-call cost of an equivalent kprobe pair.
- *No DSL coupling.* Implementation lives in one C source file; no
  bpftrace runtime, no Python aggregator.
- *Already within ebpf-ring's portability envelope.* fentry/fexit have been
  available on x86_64 since kernel 5.5 and on ARM64 since 6.0; ebpf-ring
  already requires 5.8+ for `BPF_MAP_TYPE_RINGBUF` and `CAP_BPF`, so
  no new minimum kernel is introduced.

**Caveats / limits.**

- *Trampoline support per-arch.* fentry/fexit needs
  `CONFIG_FUNCTION_TRACER`/`CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`.
  Mainline distros enable it; minimal kernels (custom embedded
  builds, some hardened distros) may disable ftrace and break this
  path.
- *Inlined `napi_poll`.* If a future kernel inlines or renames
  `napi_poll`, the attach fails at load time. CO-RE relocates struct
  field accesses, not the attach symbol; that risk is the same one
  Zhong et al. (2025) flag for the ~83% of eBPF tools they study. ebpf-ring
  detects load failure at startup and falls back per 10.1.3 below.
- *Tracee-side scope.* `napi_poll` is the entry surface that stap-2022
  approximates with `__napi_schedule_irqoff` + `napi_complete_done`.
  The two are not identical: `napi_poll` covers one poll iteration,
  while stap-2022's pair brackets the whole softirq dispatch including
  scheduling delay. The metric semantics document calls this out
  explicitly so cross-variant comparisons are honest.

#### 10.1.3 Fallback A -- per-CPU map, kprobe/kretprobe pair

If `fentry/fexit` cannot attach (no trampoline support, or symbol
inlined out), ebpf-ring retries with a per-CPU storage scheme that does not
depend on recovering arguments at exit time:

```c
struct napi_slot { struct napi_struct *n; u64 t0; };
BPF_MAP_DEF(BPF_MAP_TYPE_PERCPU_ARRAY, struct napi_slot,
            max_entries = 1);

SEC("kprobe/napi_poll")
int kprobe_napi_poll(struct pt_regs *ctx)
{
    struct napi_slot s = {
        .n  = (void *)PT_REGS_PARM1(ctx),
        .t0 = bpf_ktime_get_ns(),
    };
    u32 zero = 0;
    bpf_map_update_elem(&napi_per_cpu, &zero, &s, BPF_ANY);
    return 0;
}

SEC("kretprobe/napi_poll")
int kretprobe_napi_poll(struct pt_regs *ctx)
{
    u32 zero = 0;
    struct napi_slot *s = bpf_map_lookup_elem(&napi_per_cpu, &zero);
    if (!s || !s->n)
        return 0;
    u64 dt = bpf_ktime_get_ns() - s->t0;
    /* emit INTP_EVENT_NAPI_RX_LAT { napi=s->n, ns=dt } */
    s->n = NULL;        /* mark slot consumed */
    return 0;
}
```

**Why it works.** `napi_poll` runs in softirq context, which is
non-reentrant on a given CPU: a softirq handler does not preempt
itself, and `napi_poll` is not recursively called from within itself
on the same CPU during one poll cycle. So the slot keyed implicitly
by "the running CPU" is sufficient -- we do not need to recover the
`napi_struct *` from the kretprobe context because the per-CPU slot
already holds it.

**Caveats.**

- Higher per-call cost than fentry/fexit (kprobe + kretprobe).
- A single `napi_struct *` per CPU at a time. In the rare case of
  budget-driven re-entry (one driver handing off to another inside a
  single softirq dispatch), the second call overwrites the first
  slot before the first exit sees it; the first sample is dropped.
  Frequency of this case in practice is negligible per published
  NAPI traces.

#### 10.1.4 Fallback B -- coarse-grained tracepoint pair

If neither fentry/fexit nor kprobe/kretprobe can attach (e.g. a
hardened kernel that strips both ftrace and kprobes), ebpf-ring uses two
stable tracepoints to bound RX latency at a coarser granularity:

- `tracepoint:irq:softirq_entry` filtered to `vec == NET_RX_SOFTIRQ`
  -> stamp t0 in a per-CPU slot.
- `tracepoint:napi:napi_poll` -> read t0, emit a sample.

**Why it works.** Both tracepoints are stable kernel ABI (present
since 4.x) and do not need argument recovery. The latency they bound
is "from softirq raise to first napi_poll completion" rather than
"per napi_poll iteration", which is coarser than stap-2022's pair but still
strictly better than zero. bpftrace uses this scheme already; ebpf-ring reuses the
same userspace correlator on this fallback path.

**Caveats.**

- Lower temporal resolution than 10.1.2 / 10.1.3.
- Soft-IRQ-context probes have less reliable PID context (the current
  task is whoever was interrupted, not the socket owner). On this
  fallback path ebpf-ring reports the `nets` RX leg with `status=degraded`
  and a `note=napi_softirq_pair` to make the gap explicit at consumer
  time.

#### 10.1.5 Selection at load time

`intp.c` runs through this preference order at startup, retrying on
each failure:

1. Attach `fentry/napi_poll` + `fexit/napi_poll` (10.1.2). On
   success, mark `nets.backend = napi_fentry_fexit`.
2. Else, attach `kprobe/napi_poll` + `kretprobe/napi_poll` with the
   per-CPU slot (10.1.3). On success, mark `nets.backend =
   napi_kprobe_percpu`.
3. Else, attach `irq:softirq_entry` + `napi:napi_poll` (10.1.4). On
   success, mark `nets.backend = napi_softirq_pair` and set
   `status=degraded`.
4. Else, RX leg disabled. `nets` reports TX-only with
   `status=degraded` and `note=napi_attach_failed`.

The chosen backend is declared in the `# v3 ebpf-core --` header line
and surfaced by `--list-capabilities`, so cross-variant validation
runs (`shared/validate-cross-variant.sh`) compare ebpf-ring against stap-2022 only
when ebpf-ring is operating on the highest-fidelity backend, and downstream
consumers of the JSON / Prometheus output can filter on the backend
field.

## 11. Execution environments

- **Bare-metal**: full functionality.
- **Container**: needs `CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_RESOURCE`,
  `/sys/kernel/btf/vmlinux` visible read-only, `/sys/fs/bpf` mount, and
  (for mbw/llcocc) either the host's `/sys/fs/resctrl` bind-mounted or
  the container given permission to create a `mon_group`.
- **VM**: needs BTF exposed to the guest (standard for any kernel with
  CONFIG_DEBUG_INFO_BTF=y), and -- for mbw/llcocc -- PMU/RDT
  passthrough. `detect_pmu_passthrough()` actively probes a hardware
  counter at startup and surfaces the result in `--list-capabilities`.

## 12. Comparison matrix (V3 (ebpf-ring) vs. V0 (stap-2022)/V1 (stap-nohelper)/V2 (hybrid-c)/V3.1 (bpftrace))

| Feature                | V0 (stap-2022) | V1 (stap-nohelper) | V2 (hybrid-c) | V3.1 (bpftrace) | V3 (ebpf-ring) |
|------------------------|:-------:|:---------------:|:---------:|:-----------:|:------------:|
| Kernel module          | yes     | yes             | no        | no          | no           |
| Debuginfo required     | yes     | yes             | no        | no (BTF)    | no (BTF)     |
| Crash risk             | high    | high            | none      | none        | none         |
| Min kernel             | <=6.6   | 6.8+            | 4.10+     | 5.8+        | 5.8+         |
| Startup                | 10-30 s | 10-30 s         | <100 ms   | 1-3 s       | ~500 ms      |
| Per-event overhead     | medium  | medium          | n/a poll  | medium (DSL)| low (native) |
| CO-RE                  | n/a     | n/a             | n/a       | script      | yes          |
| Hardware metrics       | PMU     | RDT             | RDT       | RDT         | RDT          |
| Output format          | TSV     | TSV             | TSV/JSON  | TSV         | TSV/JSON/Prom|

ebpf-ring is positioned at the **native eBPF** endpoint of the spectrum: same
safety guarantees as bpftrace, same cross-kernel portability as hybrid-c, but with
the per-event cost profile of a compiled-C implementation.

---

## 13. Why this design is no longer the V3.2 (ebpf-agg) endpoint

ebpf-ring is retained for empirical evidence and per-event introspection, but
**ebpf-agg supersedes it as the eBPF/CO-RE measured endpoint** for the
SBAC-PAD 2026 campaign. The shift is architectural, not incremental:
ebpf-ring streams events to userspace through a 16 MiB ring buffer; ebpf-agg
aggregates them in-kernel into hash and per-CPU array maps that
userspace polls once per interval.

### What V3.2 (ebpf-agg) fixes

The decision to introduce ebpf-agg was driven by three empirical findings
documented in `docs/V3-OVERHEAD-FINDINGS.md`:

1. **188-390x system-wide context-switch amplification.** ebpf-ring's
   ring-buffer streaming pattern forces a userspace consumer wakeup
   plus an induced preemption of co-resident workers for every drain
   cycle. The two mechanisms are structurally coupled (each wakeup
   *is* a preemption opportunity) and contribute 50/50; the only way
   to remove them is to not stream events at all. ebpf-agg does exactly
   that.

2. **mbw silent clipping at 100%.** ebpf-ring's
   `resctrl_read_mbm_delta()` clips at 100% whenever
   `bytes/sec > INTP_MEM_BW_MBPS`, and the bimodal discrete-outlier
   pattern (96/80/64/48/32/16/0) is per-channel zero reads at
   multiples of 12.5% (8 DDR5 channels). ebpf-agg emits both `mbw_pct`
   and `mbw_raw_mbps` so both failure modes are detectable; clipping
   is opt-in via `--clip-mbw`.

3. **`perf stat -e sched:sched_switch` under-reports by 3 orders of
   magnitude** when a BPF program is attached to the same tracepoint.
   This is not an ebpf-ring bug per se, but it means ebpf-ring's overhead has to be
   measured via `vmstat 1` (the kernel `/proc/stat::ctxt` counter),
   not via perf. ebpf-agg's amplification is bounded by
   `test-no-ctxsw-amplification.sh` at ratio <= 1.10.

### What V3.2 (ebpf-agg) trades away (and why V3 (ebpf-ring) stays)

ebpf-agg loses per-event introspectability, MPSC FIFO ordering between
probes, and sub-second temporal resolution. None of those are needed
for the steady-state IntP workload the paper studies, but they *are*
needed when debugging individual probe sites or chasing causal
ordering bugs. ebpf-ring remains the right tool for that work and is
retained in the repository as both the predecessor of record and the
introspection profiler.

### Where to look next

- `variants/v3.2-ebpf-agg/DESIGN.md` -- ebpf-agg's design, including the
  in-kernel-aggregation maps (`BPF_MAP_TYPE_HASH` keyed by
  `(pid_tgid, metric_id)` plus `BPF_MAP_TYPE_PERCPU_ARRAY` for
  global counters), the poll cycle, and the acceptance tests.
- `docs/V3-OVERHEAD-FINDINGS.md` -- the empirical case for ebpf-agg.
- `docs/EXPERIMENT-STRATEGY.md` § "Why it lives next to V3 instead
  of replacing it" -- the campaign-level decision.
- Paper section VI (overhead decomposition) and section VIII
  (in-kernel aggregation).

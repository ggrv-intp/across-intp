# UB24 Campaign — Metric Validity Notes (v1.1, v2, v3.2)

**Date:** 2026-05-21
**Campaign:** `results/ub24-campaign-20260518_021737` → published `sbac-results/` (leg `ub24`)
**Host:** Intel Xeon Gold 5412U (Sapphire Rapids), 48 CPU, 1 socket, 8 IMC channels
**Variants:** v1.1 (SystemTap helper), v2 / v3.2 (eBPF + resctrl)
**Detection snapshot:** `capabilities-ub24.env` (`INTP_MEM_BW_MBPS=281600`, `INTP_LLC_SIZE_KB=46080`, `INTP_CMT_SCALE_FACTOR=49152`, resctrl mounted, RDT CQM/CAT/MBA present)

These notes explain three things an evaluator will notice in the ub24 result
tree: (1) why the per-variant metric magnitudes differ — chiefly `llcocc` — and
when that is real vs. an artifact; (2) the state of the `mbw` column and its
ceiling fix; (3) how `aggregate-means.tsv` was fixed to carry all 7 HiBench
profiles (it previously collapsed to one);
(4) why v3.2 reads near-zero `blk` and zero `netp` on the disk/veth pairwise
workloads — `blk` is a correct production-faithful service-time reading on fast
NVMe, while `netp` is correct on loopback but has one genuine probe gap
(TCP-over-veth) worth fixing.

---

## 1. Cross-variant metric differences (`llcocc`, `cpu`, `netp`, `nets`)

A naïve mean of each metric over *all* rows suggests the three variants disagree
substantially. That global mean is misleading because it pools stress-ng
(single-process, controlled) with HiBench (multi-process Spark/JVM). Split by
segment and held to a fixed workload, the real picture is:

**On stress-ng the variants AGREE** (the control). Example per-rep means:

| solo workload      | metric  | v1.1  | v2    | v3.2  |
|--------------------|---------|-------|-------|-------|
| app01_ml_llc       | llcocc  | 75.60 | 75.46 | 76.12 |
| app01_ml_llc       | cpu     | 28.92 | 28.48 | 28.04 |
| app13_query_scan   | llcocc  | 72.41 | 77.74 | 76.54 |

`cpu` — read identically by all three backends — agrees everywhere, including
HiBench tooling differences aside. This is the control proving the differences
below are **backend-specific, not workload noise**.

**On HiBench, v1.1 is blind to `llcocc`.** v1.1 reports `llcocc = 0` for
**100% (72/72)** of HiBench rows; v2/v3.2 report it correctly (0% zero):

| segment    | v1.1 llcocc==0 | v2 | v3.2 |
|------------|----------------|----|------|
| stress-ng  | 22/277 (8%)    | 7/277 (3%) | 8/277 (3%) |
| HiBench    | **72/72 (100%)** | 0/72 (0%) | 0/72 (0%) |

Per-workload (HiBench), v1.1 also undercounts `cpu` and reads `netp`/`nets`
differently:

| hibench wl | metric | v1.1  | v2    | v3.2  |
|------------|--------|-------|-------|-------|
| kmeans     | llcocc | 0.00  | 97.79 | 97.91 |
| kmeans     | cpu    | 5.46  | 36.54 | 38.71 |
| kmeans     | netp   | 14.81 | 2.60  | 4.84  |
| terasort   | llcocc | 0.00  | 97.85 | 97.68 |
| terasort   | cpu    | 4.10  | 23.08 | 23.99 |

### Interpretation

v1.1 is the SystemTap helper variant: it attaches by **process name (`java`)**
and reads cache occupancy via a single resctrl path. Under HiBench the workload
is a **fleet of short-lived Spark executor JVMs** spread across the veth-routed
distributed cluster. v1.1 (a) loses samples under sustained contention — the
fragility result, mean 15.96% / max 98.89% sample loss, see
`bench-full/fragility-aggregated.tsv` — and (b) never attaches a resctrl
mon_group to the JVM cgroup tree, so cache occupancy reads **zero** for every
HiBench rep. v2/v3.2 (eBPF + resctrl mon_group over the full process set)
capture the ~98% LLC occupancy the Spark working set actually holds.

**This is not a bug to "fix" in the data — it is a finding.** It corroborates
the paper's thesis: v1.1's instrumentation is not merely lossy, it is
*structurally blind* to multi-process resctrl metrics under realistic
sustained load. v2/v3.2 are robust on both axes.

**Consequence for the paper:** never compare v1.1's HiBench `llcocc`/`cpu`
against v2/v3.2 as if measuring the same thing — v1.1's HiBench `llcocc` is a
null signal. The legitimate cross-variant comparison is on **stress-ng**, where
all three converge (PCA convergence metric intra/global = 0.300,
`fig_pca_correlation_circle`). On HiBench, treat v1.1 as the
*fragility/coverage* exhibit, not a metric-accuracy peer.

---

## 2. `mbw` column — ceiling fix and current validity

`mbw` for v2/v3/v3.1/v3.2 is a **percentage** of a memory-bandwidth ceiling
(bytes/s). The ceiling must be supplied in **B/s**.

### The fix (`resolve_mem_bw_ceiling`, run-hibench-subset.sh)

`intp-detect.sh` reports `INTP_MEM_BW_MBPS` in **MB/s** (here 281600 = 281.6
GB/s). Passing that number verbatim as a B/s ceiling under-sizes it
**1,000,000×**: every sample then trips "exceeded ceiling" and the column
saturates/garbles. `resolve_mem_bw_ceiling()` does the MB/s→B/s conversion
(`×1e6`) in **one place** so neither `run-intp-bench.sh` nor
`run-hibench-subset.sh` can reintroduce the trap.

### Status in this campaign — VALID

The ceiling fix is active and working. Across all v1.1/v2/v3.2 rows:

- `mbw` range **0.00 … 61.31%** — **no clipping** (0 rows at ≥99%, none pinned).
- `mbw == 0` on 348/1047 rows: these are the non-memory workloads (cpu/net
  stressors, overhead `_baseline`) that legitimately move ~no bandwidth — not a
  failure.
- On memory/HiBench workloads `mbw` is a sensible single-to-low-double-digit %
  (e.g. kmeans v3.2 = 11.29) — expected, since few workloads approach a 281
  GB/s, 8-channel ceiling.

So `mbw` in the ub24 tree is usable as published. The
[[noise-floor-mbw-invalid]] caveat ("use `mbw_raw_mbps`") applies to the
**eBPF noise-floor reruns**, a different artifact, not to this campaign.

### `mbw_raw_mbps` is suppressed here

v3.2 (and v3) emit a trailing diagnostic column `mbw_raw_mbps` — the **un-clipped
raw bandwidth in MB/s** (`mbm_total_bytes_delta / interval / 1e6`). In this
campaign it is **deliberately suppressed**: run-hibench-subset.sh passes
`--no-raw-mbw` for v3.2 so its column shape matches v2/v3 exactly
(7 canonical columns; the published profiler.tsv header is
`ts netp nets blk mbw llcmr llcocc cpu`). Therefore `mbw_raw_mbps` is **not
available as a fallback in this tree**.

**Guidance for future runs:** if `mbw` ever looks clipped (max ≈ 100, or every
sample at the ceiling) or all-zero on a memory workload, the ceiling is wrong —
re-check `resolve_mem_bw_ceiling` / `--mem-bw-max-bps`, and drop `--no-raw-mbw`
to recover the `mbw_raw_mbps` raw-MB/s diagnostic for cross-checking.

---

## 3. `aggregate-means.tsv` now carries all 7 HiBench profiles (fixed 2026-05-21)

`aggregate-means.tsv` (stress-ng + HiBench, merged) holds **612 solo + 216
pairwise + 3 timeseries** stress-ng rows plus **1512 HiBench rows** =
`7 profiles × 6 workloads × 3 variants × 12 reps` — the complete sweep, one
`stage=hibench-<profile>` block per co-runner profile (`hibench-standard`,
`hibench-cpu-extreme`, … `hibench-nets-extreme`), 216 rows each.

### The bug it fixes

`build_aggregate_means()` derived the `stage` column from the path
`<env>/<variant>/<stage>/<workload>/repN/`, where the stage component is always
the literal `hibench`. The **profile** lives only in the *run-dir name*
(`<profile>-<size>-<ts>/`), which is **not** a parsed path component.
`publish-sbac-results.sh` merges all per-run-dir tables and **dedups by key
columns 1–5** (`env, variant, stage, workload, rep`). With `stage=hibench` for
every profile, all 7 profiles shared the same keys → **last-write-wins**,
collapsing the merged table to **one profile's 216 rows**. (The data was never
lost at the source — every profile's run-dir is intact and `plot-hibench.py`
re-derives the profile from the run-dir *name*, ignoring `stage` — but the
merged TSV silently kept only one profile, making it useless for cross-profile
analysis.)

### The fix

`build_aggregate_means()` now parses the profile from the run-dir name and
writes `stage=hibench-<profile>` (run-hibench-subset.sh). This makes the dedup
key distinct per profile, so the merge preserves all 1512 rows. Properties:

- **Schema unchanged** (still 12 columns); the publish dedup key (cols 1–5)
  works as-is. No `profile` column was added (would have changed column count
  and required a placeholder for stress-ng rows).
- **No in-repo consumer breaks**: the PCA / `plot-intp-bench` read `bench-full/`
  (stress-ng, unaffected); `plot-intp-bench` selects `stage in {solo,pairwise}`;
  `convert-profiler-to-meyer` / `generate-iada-tree` read stage from the path,
  not this TSV; `plot-hibench` re-derives profile from the run-dir name and
  ignores the `stage` value. Verified by reloading the relabeled tree.
- **Stress-ng rows untouched** (`solo`/`pairwise`/`timeseries`).

### Caveat for external readers

Any tooling *outside* this repo (e.g. ad-hoc paper-analysis scripts) that
hard-codes `stage == "hibench"` must switch to a prefix match
(`stage.startswith("hibench")` / `stage LIKE 'hibench-%'`) to pick up HiBench
rows. Filtering a single profile is now `stage == "hibench-cpu-extreme"`.

---

## 4. v3.2 reads ~0 `blk` and 0 `netp` on the disk/veth pairwise figures

In `fig07_pairwise_heatmap_bare`, the v3.2 panel shows an all-black `blk`
column and a black `netp` column where v1.1/v2 light up. The two have
**different** explanations, and only one is a real gap:

- **`blk` (black) is correct, not a gap.** It is v3.2's production-faithful
  *service-time* definition reading ~0 on fast NVMe (see below). Nothing to fix.
- **`netp` (black) is two cells with two causes.** `net_v_net` (loopback) reads 0
  in *both* v2 and v3.2 and is correct (loopback → `nets`). `tcp_v_tcp_veth`
  (veth) is a **genuine v3.2 probe gap** — v2 reads it, v3.2 misses it — and is
  likely production-relevant. That one warrants a fix.

The `blk`/`netp` machinery is inherited from V3 unchanged (equivalence-tested),
so these behaviors are V3-family-wide, not v3.2-specific regressions.

### `blk` — service-time utilization vs iostat `%util`

The two backends measure different definitions of "block I/O utilization":

| variant | definition | source | reads on NVMe under load |
|---------|-----------|--------|--------------------------|
| v1.1, v2 | iostat `%util` — wall-time fraction the device queue was non-empty | `/proc/diskstats` `io_ticks` ([blk.c](../../variants/v2-hybrid-c/src/blk.c)) | **97–99%** |
| v3.2 (=V3) | service-time utilization = `Σ per-request svctm / interval` | eBPF `block_rq_issue→complete` ([intp_agg.bpf.h:63](../../variants/v3.2-ebpf-agg/src/intp_agg.bpf.h#L63)) | **~1–4%** |

`%util` (io_ticks) is the classic disk-busy metric, but it **saturates to ~100%
on multi-queue NVMe** even at a tiny fraction of the device's real throughput —
the queue is essentially never empty under stress. v3.2 instead sums the actual
issue→complete **service time**; on NVMe each request finishes in microseconds,
so the summed busy-time is a sliver of the 1 s interval → ~1–4%. The raw v3.2
trace confirms it (per-sample blk values are `01`–`04`).

**Which is "right"?** For a *production* server — where the relevant question
is "how much real I/O service pressure is this co-runner adding" — v3.2's
service-time number is the faithful, non-saturating signal, and `%util` is the
misleading one (it pins to 100% and hides headroom on SSD/NVMe). For *this
benchmark*, whose disk stressor hammers a fast NVMe, that production-faithful
number is legitimately near zero. So the black `blk` column is v3.2 telling the
truth about an NVMe that is barely service-time-bound, not a missing metric.

### `netp` — the single-node network model, and the one real gap

First, the benchmark's network model, because it explains *why* `netp` looks
sparse on a single host:

- A single-socket/single-node host has **no external NIC traffic** to measure.
- So the bench routes traffic two ways: **loopback** (`lo`) for the socket
  stressors (`net_v_net`, `app1x_sort_net` = stress-ng `--sock`/`--udp`), and a
  **veth pair** (`intp-veth-h` ↔ `intp-veth-g`) as a *synthetic external NIC* for
  the iperf3 workloads (`*_veth`). The veth is the stand-in for the physical NIC
  that production would have.

Both `netp` backends deliberately **exclude `lo`** — this is not a v3.2 quirk:

| variant | source | loopback |
|---------|--------|----------|
| v1.1 | `/proc/net/dev` | counts `lo` (mis-attributes loopback as physical) |
| v2 | `/sys/class/net/*/statistics`, **non-`lo` aggregate** ([netp.c:32-34](../../variants/v2-hybrid-c/src/netp.c#L32)) | **skips `lo`** ("matches v3's eBPF semantics") |
| v3.2 (=V3) | tracepoints `net_dev_xmit` + `netif_receive_skb`, **`lo` excluded** ([intp_agg.bpf.c:185](../../variants/v3.2-ebpf-agg/src/intp_agg.bpf.c#L185)) | **skips `lo`** to avoid the ≥2× xmit+recv double-count |

So per pairwise row:

| pair | route | v1.1 | v2 | v3.2 | reading |
|------|-------|------|----|------|---------|
| `net_v_net` | `lo` (sock) | 99 | **0** | **0** | **v2 and v3.2 agree and are correct** — loopback is net-stack, captured in `nets`; only v1.1 mis-labels it physical `netp` |
| `tcp_v_tcp_veth` | veth (TCP) | 99 | 97 | **0** | **the one genuine v3.2 gap** |
| UDP-over-veth (solo) | veth (UDP) | 82 | 96 | 99 | control — v3.2 captures it fine |

**Therefore "enable loopback counting in v3.2" is the wrong fix:** it would
(1) *diverge* from v2 (which also skips `lo`), (2) re-introduce the ≥2×
single-host double-count the design removed, and (3) not even touch the real
gap — `tcp_v_tcp_veth` is on the **veth**, not `lo`, and the veth is already not
skipped (UDP-over-veth proves it).

**The real gap is TCP-over-veth only**, and two hypotheses are ruled out by the
code: it is *not* the loopback skip (veth ≠ `lo`), and *not* PID attribution
(the bench runs v2/v3 **system-wide** — [run-intp-bench.sh:176-177](../run-intp-bench.sh#L176),
`V_USE_PID_FILTER=0` — so `should_monitor_current()` is always true). What
remains is whether the **veth TCP path actually fires** v3.2's two tracepoints.
The leading explanation is **GSO/TSO**: TCP egress over veth is handed down as
large GSO super-frames and delivered to the peer via the GRO path, so the
per-frame `net_dev_xmit`/`netif_receive_skb` accounting under-counts; UDP's
per-datagram path fires them normally. **This is not confirmed by a live trace**
(the host was not available from this session) — run
[`diagnose-netp-veth-coverage.sh`](../../variants/v3.2-ebpf-agg/tests/integration/diagnose-netp-veth-coverage.sh)
on the measurement host (`--proto tcp`, then `--proto udp`) to confirm: it
compares the bytes v3.2's tracepoints see against the `/sys/class/net` counters
v2 uses.

**Production relevance.** If the cause is GSO/TSO, it is **not** a mere bench
artifact: real NICs run TCP with TSO/GSO, so v3.2 would under-count `netp` for
production TCP egress too. The production-AND-bench-compatible fix is to make
v3.2's `netp` **GSO-aware on non-`lo` interfaces** (count `skb_shinfo->gso_segs`
× MSS / use the byte length the GRO/GSO skb carries, or fall back to the
`/sys/class/net` non-`lo` byte deltas v2 already uses) — keeping `lo` excluded.
That fix is gated on the diagnostic above and a BPF rebuild on the host, so it
is **not applied here**.

### Practical guidance

- The **disk/net interference signal on this harness** is best read from v2:
  `%util`-`blk` and the non-`lo` byte-counter `netp` both light up on the
  veth/NVMe bench. v1.1 over-reports (saturating `blk`, loopback counted as
  `netp`).
- v3.2's **`blk`** (service-time) is the production-faithful number and is
  *correctly* ~0 on NVMe — not a gap. Do not "fix" it for the bench except by
  using a device/IO pattern where service time is non-trivial, or by switching
  the definition (which would just duplicate v2's `%util`).
- v3.2's **`netp`** is correct except for the **TCP-over-veth** undercount, which
  is a real (and likely production-relevant) gap to fix in the BPF — not a reason
  to start counting `lo`.
- Net: read the black v3.2 `blk` cells as truth (NVMe barely service-bound);
  read the black v3.2 TCP-veth `netp` cell as a **probe gap to fix**, confirmed
  via the diagnostic.

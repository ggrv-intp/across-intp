# UB22 Campaign — Metric Validity Notes (v0.2)

**Date:** 2026-05-22
**Campaign:** `results/ub22-campaign-20260521_162957`
**Host:** `intp-v1-baseline` — Intel Xeon Gold 5412U (Sapphire Rapids), 48 CPU,
1 socket, 8 IMC channels, **Ubuntu 22.04.5 LTS, kernel 5.15.0-177-generic**
**Variant:** v0.2 (legacy-bridge: paper-faithful V0 SystemTap + userspace helper)
**Detection snapshot:** `capabilities.env` (`INTP_NIC_SPEED_MBPS=1000`,
`INTP_MEM_BW_MBPS=281600`, `INTP_LLC_SIZE_KB=46080`, resctrl mounted, RDT
CQM/CAT/MBA present)

This campaign is the **single-variant v0.2 leg** — the "historical portability"
exhibit of the dissertation's V0.2 / V1.1 / V2 / V3.2 comparison. Where the
[UB24 notes](ub24-campaign-metric-validity.md) explain cross-variant magnitude
differences, this leg has only one variant, so these notes instead cover:
(1) the framing every evaluator must keep straight — **v0.2 as the most
reproducible embodiment of V0 on a modern kernel, which is *not* the same as
physical ground truth**; (2) two **defects in the published tables that this
pass fixed** (throughput-overhead was blank; the fidelity figure was
mis-aligned); (3) which metric behaviours are **expected legacy artefacts, not
bugs**; and (4) the **genuine data caveats** and the `quality-flags.tsv` that
now records them.

The data is sound: **349/349 runs `rc=0`**, no crashes, no calibration
failures, all 17 solo workloads × 12 reps complete, 0 empty profiler outputs,
88% of profiled runs ≤5% sample loss.

---

## 0. Two senses of "ground truth" — keep them separate

v0 (the original 2022 IntP, classic SystemTap kprobes, kernel ≤4.18) **cannot
run** on kernel ≥6.8 and is *destabilising* even on 5.15: the Canonical
RCU-checking backports break V0's in-probe `perf_event_create_kernel_counter()`
path, producing stapio orphans, `stap_*` module accumulation, and eventually
systemd-logind deadlock (see [v0.2 README](../../variants/v0.2-legacy-bridge/README.md)
and [V1 modernization findings](v1-modernization-reliability-findings.md)).
**v0.2 is the variant that runs V0's probe set paper-faithfully on 5.15 GA
without that fragility cascade.** So:

- **Axis A — fidelity to V0 (reproducibility).** On this axis v0.2 *is* the
  reference: it is the most reachable, reproducible realisation of V0's design
  on current hardware. The legacy quirks below (saturating `blk`, loopback
  `netp`) are *features* of that fidelity, not regressions.
- **Axis B — fidelity to the physical system (`groundtruth.tsv`).** The
  `groundtruth.tsv` files are an **independent** measurement of physical reality
  (cpu/disk/net from `/proc`). v0.2's legacy formulas deliberately *depart* from
  physical truth (e.g. `blk` is ~100× over-amplified by design). v0.2 can be
  simultaneously a faithful reproduction of V0 **and** a low-physical-fidelity
  estimator — and that duality is the actual finding the leg demonstrates.

**Do not collapse these.** "v0.2 reproduces V0" (true) must never be read as
"v0.2's amplified `blk` is the correct disk-busy number" (false). The paper's
historical-portability claim lives on Axis A; the modern-reliability claim
(why the successors exist) lives on Axis B.

---

## 1. Throughput overhead was blank in the published tables — FIXED (parser + backfill)

`plots/overhead_summary.csv` shipped with an **empty `throughput_overhead_pct`**
column, and every `overhead/**/throughput.tsv` recorded `bogo_ops_total=NA`
(72/72 overhead runs), so `plots/overhead_raw.csv`'s `bogo_ops_per_s` was also
empty. The headline "how much does v0.2 slow the workload" number was therefore
unreadable from the published tree.

### Root cause — a stress-ng log-tag mismatch, not lost data

`_overhead_parse_stressng()` in [run-intp-bench.sh](../run-intp-bench.sh)
selected the metrics row by the tag `stress-ng: metrc:`. stress-ng **0.13.12**
(the build on this host, per `metadata.txt`) prints the `--metrics-brief` table
under the **`info:`** tag instead; the `metrc:` tag only appears on ≥0.15
builds. The awk matched zero lines → `n==0` → `NA`. The field offsets the parser
read (`$5`,`$6`,`$9`,`$10`) were already correct for the table — only the line
selector was wrong. **The raw data was never lost:** every `workload.log`
contains the stress-ng summary line.

### The fix

The selector now matches **either tag** (`$2 == "info:" || $2 == "metrc:"`)
and identifies a real per-stressor row by requiring numeric bogo-ops (`$5`),
real-time (`$6`) and bogo-ops/s-real (`$9`). The numeric guards also exclude the
two header rows and — newly — the `stream` stressor's trailing
`memory rate (MB|Mflop per sec)` lines, which have a numeric `$5` and would
otherwise have inflated the bogo-ops total once the selector was broadened.

The 72 existing `throughput.tsv` were **backfilled** from their `workload.log`
with the same logic, and `overhead_raw.csv` / `overhead_summary.csv` /
`fig04_overhead_throughput` were regenerated.

### Result — VALID, and recovered

Throughput overhead (v0.2 vs `_baseline`, bogo-ops/s real-time, n=12 each):

| ref         | overhead %         | note |
|-------------|--------------------|------|
| ref_cpu     | **+4.32%** (σ 0.31) | corroborated by the CPU-extra-jiffies overhead (~4%), which was always recorded |
| ref_stream  | **+1.33%** (σ 0.25) | small, stable |
| ref_disk    | **−6.21%** (σ **19.76**) | **not significant** — the σ dwarfs the mean; disk bogo-ops/s is noisy on this NVMe |

Read ref_cpu/ref_stream as the trustworthy overhead figures; report ref_disk as
"within noise" (or use the CPU-jiffies / scheduler-delta overhead, which are
tighter). `fig04_overhead_throughput` now renders (it was previously skipped for
having no data).

---

## 2. The fidelity figure understated v0.2 — FIXED (timestamp alignment)

`plots/fidelity_matrix.csv` / `fig05` reported near-zero profiler-vs-ground-truth
Pearson r (cpu 0.06, blk 0.06, netp 0.01), which reads as "v0.2 has no fidelity."
That was an **analysis artefact**.

### Root cause — row-index alignment against time-shifted series

`fig_fidelity_matrix()` in [plot-intp-bench.py](../plot/plot-intp-bench.py)
paired the profiler and ground-truth samples by **row index**
(`n=min(len); iloc[:n]`). But the profiler starts **~5 s (up to 13.7 s) after**
ground-truth — it only samples after the workload warm-up — and it drops samples
on read timeouts. So profiler row *i* is not ground-truth row *i* in wall-clock
time; the two series are sheared apart and the per-sample correlation collapses.
A startup counter spike in ground-truth row 0 (e.g. `disk_write_mb≈914693`)
made it worse.

### The fix

Alignment is now by **timestamp** (`pd.merge_asof(direction="nearest",
tolerance=0.75)`) after dropping the first few ground-truth rows. Result (solo,
v0.2):

| metric | published (index) | timestamp-aligned | reading |
|--------|-------------------|-------------------|---------|
| blk    | 0.06 | **0.70** | genuinely faithful once aligned |
| cpu    | 0.06 | 0.24 | low — see caveat |
| netp   | 0.01 | 0.07 | low — see caveat |

### Caveat — r is the wrong tool for two of the three metrics

cpu and netp stay low **even when correctly aligned**, and this is *not*
evidence of bad readings:

- **netp** is pinned at 99 (saturated, §3) on the net workloads → near-zero
  variance → Pearson r is meaningless / ~0.
- **cpu** is near-steady within a single solo run (the stressor holds a flat
  utilisation), and the profiler's `cpu` is the workload's share while
  ground-truth `cpu_busy_pct` is system-wide → a within-run correlation of two
  near-flat signals is dominated by noise.

So `fig05` is now a fair *lower bound*; treat blk's 0.70 as the real signal and
do **not** cite cpu/netp r as fidelity failures. **Only cpu, blk and netp can be
checked at all** — see §4 (ground-truth coverage gap).

---

## 3. Expected legacy behaviour — NOT bugs (Axis A)

All seven v0.2 metric formulas are `≡ V0` (see
[METRICS-ALIGNMENT.md](../../METRICS-ALIGNMENT.md)). The saturation an evaluator
sees is the documented price of that fidelity:

- **`blk` pinned at 99 on disk workloads** (48/276 solo+pairwise rows). V0's
  `blk = svctm_us × ops/s / 100` is **~100× over-amplified** and "saturates
  easily on modern hardware" — preserved deliberately for paper fidelity. On
  this NVMe it pins. This is the canonical Axis-A-vs-Axis-B exhibit: faithful to
  V0, far from physical disk-busy fraction. (V1.1/V3.2 drop the quirk; V2 uses
  io_ticks — see the UB24 notes.)
- **`netp`/`nets` at 99 on sock/loopback/veth** (netp 60/276, nets 24/276). V0
  uses a **125 MB/s (1 Gbps)** ceiling and counts loopback; the `sock`/`udp`
  stressors (`app11/app12_sort_net`) and veth iperf push past 1 Gbps-equivalent
  and peg. The host's real NIC is 1 Gbps, so the legacy 125 MB/s constant is
  *coincidentally* also physically correct for external traffic.
- **`mbw`/`llcocc` are NOT clipped and use MODERN ceilings.** Unlike netp/blk,
  the two helper-fed metrics were calibrated with **autodetected** ceilings
  (`profiler.helper.log`: `dram_bw=281600 MB/s`, `l3=46080 KB`), **not** V0's
  hardcoded 34 GB/s / 34 MB. `mbw` ranges 0–32% with **0 rows clipped**;
  `llcocc` maxes at 93.9%; both have healthy dynamic range.

  > **Calibration seam (important).** v0.2's calibration is therefore *mixed*:
  > the stap-native metrics (`netp`, `nets`, `blk`, `llcmr`, `cpu`) are
  > V0-faithful (legacy constants + amplification), but the helper-fed
  > `mbw`/`llcocc` are modernised (autodetected ceilings). Consequence:
  > `mbw`/`llcocc` magnitudes are **comparable to v1.1/v2/v3.2** (all
  > autodetect) but are **not** on the legacy-V0 scale a true-V0 run would
  > produce (which would read much higher and likely clip). When the paper
  > says "v0.2 reproduces V0", scope it to the stap-native metrics.

- **`mbw`/`llcmr`/`llcocc`/`cpu` never saturate** (max 32 / 97.4 / 93.9 / 64.6) —
  these columns carry real dynamic range across workloads.

---

## 4. Genuine data caveats (use these to scope claims)

### 4.1 `sock` workloads lose most samples — the historical-portability finding

| workload (solo)  | mean sample loss | min samples (of 90) |
|------------------|------------------|---------------------|
| app11_sort_net   | **69.4%**        | 22 |
| app12_sort_net   | 31.9%            | 45 |

Everything else is ≤~6%. The cause is the SystemTap probe failing to keep up
with the `stress-ng --sock` event flood (6 s gaps between samples; `netp` pegged
at 99). This is exactly v0.2's *reason for existing as the fragility exhibit* —
it is a finding, not corruption — but the **per-rep means for these two
workloads rest on 22–45 samples and must be reported as low-confidence**
(see `quality-flags.tsv`, §5). Prefer the median; do not present app11_sort_net
solo as a precise point estimate.

### 4.2 Two query workloads are bimodal across reps

- **app13_query_scan — REGIME_SHIFT.** 4/12 reps read `llcmr≈0` **and**
  `cpu≈2.5` while the other 8 read `llcmr≈62`, `cpu≈6.1`. Both the cache and CPU
  signals split together → the workload genuinely ran in two regimes (most
  plausibly page-cache warm vs cold across back-to-back reps), not a probe
  glitch. The mean represents neither mode; use the median or report both.
- **app14_query_join — PROBE_DROPOUT.** 4/12 reps read `llcmr≈0` while `cpu` is
  **unchanged** (≈3.3 in both clusters) → the `llcmr` probe intermittently read
  zero on an otherwise-identical run. It depresses the `llcmr` mean spuriously.
  (`ref_disk` in the overhead stage shows the same `llcmr` dropout.)

`app06/app07_ordering` flip `llcmr` 0↔~7 but the non-zero level is trivially
small, so it is near-zero noise, not meaningful bimodality (and is *not*
flagged).

### 4.3 Ground-truth coverage gap — 4 of 7 metrics are unvalidated

`groundtruth.tsv` populates **only the `/proc`-derived columns**
(`cpu_busy_pct`, `disk_*_mb`, `net_*_mb`) — in 204/204 solo files. The
hardware-counter columns (`instr`, `cycles`, `llc_ref`, `llc_miss`,
`resctrl_mbw_bps`, `resctrl_llcocc_bytes`) are `--` everywhere. Therefore only
**cpu, blk (vs disk), netp (vs net)** have any ground truth; **`nets`, `mbw`,
`llcmr`, `llcocc` cannot be fidelity-checked in this campaign** — they can only
be sanity-checked for range/saturation. State this explicitly in any
fidelity claim.

### 4.4 Minor artefacts

- **Ground-truth row-0 counter spike** (e.g. `disk_write_mb≈914693`): a
  first-sample counter-delta startup artefact. The fixed fidelity code drops the
  first few rows; any other consumer of `groundtruth.tsv` should too.
- **`aggregate-means.tsv` overhead-row schema is shifted.** Solo/pairwise rows
  are `env=bare, variant=v0.2, stage=solo, …`, but overhead rows are written as
  `env=overhead, variant=bare, stage=<arm>, workload=<ref>`. The columns still
  uniquely identify each group, but a reader filtering `env=='bare'` will miss
  overhead rows, and group labels for overhead read oddly (e.g. `stage=v0.2`).
  This is why `quality-flags.tsv` shows an `env=overhead` block.
- **Real I/O stalls** on `disk_v_disk` / `app15_query_inerge`: the stall monitor
  logged genuine `drop_caches`-induced stalls (loadavg ~35, ~30 procs in
  D-state). Expected for a cache-dropping disk benchmark; it elevates sample
  loss there modestly (still ≤~4.4%).

---

## 5. `quality-flags.tsv` — machine-readable confidence

`bench/plot/quality-flags.py` (now chained after `extract-fragility.py` in
[run-big-batch.sh](../../run-big-batch.sh)) emits
`plots/quality-flags.tsv`: one row per `(env,variant,stage,workload)` with mean
/ max sample-loss, min sample count, the flags (`LOW_SAMPLE`, `BIMODAL:<m>`,
`REGIME_SHIFT`, `PROBE_DROPOUT:<m>`), and a `recommended_estimator`
(`median` when flagged, else `mean`). For this campaign it flags exactly the
five groups in §4.1–§4.2; the remaining 25 are `OK`/`mean`. Use it as the
gate for which per-workload aggregates can be quoted as point estimates.

---

## 6. What is usable as published (after this pass)

- **Overhead:** ref_cpu **+4.3%**, ref_stream **+1.3%** throughput overhead are
  solid; ref_disk throughput overhead is noise (use CPU-jiffies/scheduler
  deltas). `overhead_summary.csv` / `overhead_raw.csv` / `fig04*` are now
  correct.
- **Fidelity:** `blk` r≈0.70 (timestamp-aligned) is a real fidelity signal;
  cpu/netp r are not interpretable (saturation / steady-state); `nets`/`mbw`/
  `llcmr`/`llcocc` have no ground truth here.
- **Interference fingerprints (solo/pairwise):** valid for all workloads
  **except** the two `sort_net` (thin samples) and `app13_query_scan` (bimodal);
  for those, use the median and the `quality-flags.tsv` annotation.
- **Legacy saturation** (`blk`=99 disk, `netp`=99 net) is correct Axis-A
  behaviour — present it as the historical-portability result, not a data fault.

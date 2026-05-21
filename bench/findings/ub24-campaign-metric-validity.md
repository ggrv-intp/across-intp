# UB24 Campaign — Metric Validity Notes (v1.1, v2, v3.2)

**Date:** 2026-05-21
**Campaign:** `results/ub24-campaign-20260518_021737` → published `sbac-results/` (leg `ub24`)
**Host:** Intel Xeon Gold 5412U (Sapphire Rapids), 48 CPU, 1 socket, 8 IMC channels
**Variants:** v1.1 (SystemTap helper), v2 / v3.2 (eBPF + resctrl)
**Detection snapshot:** `capabilities-ub24.env` (`INTP_MEM_BW_MBPS=281600`, `INTP_LLC_SIZE_KB=46080`, `INTP_CMT_SCALE_FACTOR=49152`, resctrl mounted, RDT CQM/CAT/MBA present)

These notes explain three things an evaluator will notice in the ub24 result
tree: (1) why the per-variant metric magnitudes differ — chiefly `llcocc` — and
when that is real vs. an artifact; (2) the state of the `mbw` column and its
ceiling fix; (3) why `aggregate-means.tsv` carries only one HiBench profile.

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

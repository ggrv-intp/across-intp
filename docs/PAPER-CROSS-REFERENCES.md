# Paper Cross-References

This document maps each `[TODO: ...]` placeholder in the paper draft to the
repository content that grounds it. Use it during writing as a "where do I
get the material to fill this in" index.

The TODOs are listed in the paper's section order. Each entry has:

- **What the TODO asks for** (paraphrased from the draft).
- **Repo doc(s) carrying the material** (relative paths from repo root).
- **Status**: `ready` (material in place), `partial` (needs synthesis from
  multiple sources), `pending` (needs new measurement or external content).

---

## Title

> [TODO: Modernizing IntP: A Multi-Variant Reimplementation for
> Cross-Application Interference Profiling on Modern Linux Kernels
> (verify)]

**Status:** ready. The working title is consistent with the abstract.
Suggestion: drop "(verify)" and confirm with advisor at the Monday
meeting.

---

## Abstract — overhead bound `[TODO: X%]`

> "with self-overhead bounded below [TODO: X%] for the eBPF and bpftrace
> variants"

**Source for the number:** the current campaign's overhead stage output
(profiler_overhead figure attached to the email of 2026-05-08; final
numbers come from the bench-full overhead stage of the in-flight veth
campaign).

**Where:** `results/<campaign>/bench-full/overhead/bare/<variant>/` after
the run; `bench/plot/plot-intp-bench.py::fig_overhead_bars` materialises it.

**Status:** partial. The email reports ±3–5% across stap-modern/C-ABI/ebpf-ring/bpftrace; final
campaign should narrow this for ebpf-ring and bpftrace specifically.

---

## Section I — Introduction

### Production evidence framing

> [TODO: Frame the problem with concrete production evidence: cite Borg
> next-generation (Tirmazi 2020), Azure noise dataset 2023, Alibaba
> microservice trace 2021. Two to three sentences.]

**Source in repo:** none — these are external citations.

**Suggested citations:**
- Tirmazi et al., "Borg: the next generation," EuroSys 2020.
- Cortez et al., "Resource central: understanding and predicting workloads
  for improved resource management in large cloud platforms," SOSP 2017
  (Azure-adjacent; the 2023 dataset is the public release of the same
  family).
- Luo et al., "Characterizing microservice dependency and performance:
  Alibaba trace analysis," SoCC 2021.

**Status:** pending. Needs 2–3 sentences in the introduction.

---

## Section II — Background

### II.A — Cross-application interference background

> [TODO: Two to three paragraphs framing the resources contended for in
> shared infrastructure, with a brief evolution from Bubble-Up to PARTIES.]

**Source in repo:** `README.md` lines 21–38 (Background section) and the
references at the bottom of the README (Bubble-Up is not yet there;
PARTIES is not yet there).

**External references to add:**
- Mars et al., "Bubble-Up: increasing utilization in modern warehouse
  scale computers via sensible co-locations," MICRO 2011.
- Chen et al., "PARTIES: QoS-aware resource partitioning for multiple
  interactive services," ASPLOS 2019.

**Status:** partial. The repo has the IntP lineage citations but not the
broader interference-measurement evolution.

### II.B — Linux instrumentation surfaces

> [TODO: One paragraph per substrate. Highlight the portability and
> stability axis: SystemTap is fragile across kernel versions and
> demands debuginfo; eBPF with CO-RE is portable via BTF and verified
> to terminate. resctrl is the userspace contract for RDT. Note
> explicitly that the RCU-safe-context constraint on modern kernels is
> what motivates stap-modern's userspace-helper architecture.]

**Source in repo:**
- SystemTap fragility → `bench/findings/v1-modernization-reliability-findings.md`
  and `docs/KERNEL-6.8-CHANGES.md`.
- RCU-safe-context constraint → `docs/KERNEL-6.8-CHANGES.md` and
  `variants/v1.1-stap-modern/DESIGN.md`.
- eBPF CO-RE portability → `docs/PORTABILITY-ROADMAP.md` and
  `variants/v3-ebpf-ring/DESIGN.md`.
- resctrl as RDT contract → `docs/HARDWARE-COMPATIBILITY.md` and
  `variants/v1-stap-nohelper/docs/RESCTRL-VALIDATION.md`.

**Status:** ready. Direct synthesis from the four documents above.

### II.C — Intel RDT on Sapphire Rapids

> [TODO: One to two paragraphs. Explicitly note that SKU-level RDT
> support varies and that the Xeon Gold 5412U used in this work has
> all four classes (CMT, MBM, CAT, MBA) functional, verified through
> /sys/fs/resctrl.]

**Source in repo:**
- 5412U full RDT validation →
  `bench/findings/v1-modernization-reliability-findings.md` and
  `docs/HARDWARE-COMPATIBILITY.md`.

**Status:** ready.

---

## Section III — IntP Modernized: Variant Design

Mostly written. The variant-by-variant subsections are summarised from
`docs/VARIANT-COMPARISON.md`. The taxonomy table (Table I) matches
`VERSIONS.md` and `README.md` directly.

No TODOs in this section.

---

## Section IV — Experimental Methodology

### IV.A — Hardware platform — DRAM bandwidth verification

> "the maximum sustainable DRAM bandwidth, derived from the IMC channel
> count and DDR5 transfer rate, is **281,600 MB/s** (8 DDR5-4800
> channels × 35.2 GB/s theoretical peak per channel, rounded). The
> empirical ceiling reported by the calibration step on `intp-master`
> is recorded alongside in `capabilities.env`."

**Source in repo:**
- 281,600 MB/s default →
  `bench/findings/v1-modernization-reliability-findings.md` (host
  config snapshot), stap-modern helper hardcoded defaults
  (`variants/v1.1-stap-modern/intp-helper.c`), and the `INTP_MEM_BW_MBPS`
  default exposed by `shared/intp-detect.sh`.
- Cross-validation tool: `bench/calibration/` (Stream-like benchmark
  invoked via `bench/setup/setup-host.sh --calibrate`).
- mbw normalization clip artifact at this ceiling →
  `docs/V3-OVERHEAD-FINDINGS.md` § 3 and paper § IV-E.

**Status:** resolved. 281,600 MB/s is the canonical theoretical
ceiling for the campaign; the empirical Stream measurement lives in
`capabilities.env` next to each rep. eBPF-CORE emits both `mbw_pct`
(normalised against this ceiling) and `mbw_raw_mbps` (the raw byte
rate) so consumers can detect either over-clipping or
under-calibration directly from the TSV.

### IV.D — Reproducibility envelope

> [TODO: Mention: capabilities.env captures the exact RDT/BTF/resctrl/IMC
> detection at run time. The driver scripts, workload definitions, and
> variant source code are open-source and tagged at the campaign commit.
> A voluntary ACM-style artifact appendix accompanies the submission.
> Cite Heiser benchmarking-crimes guidance.]

**Source in repo:**
- `capabilities.env` → produced by `shared/intp-detect.sh` at run start,
  saved alongside the campaign output. Documented in
  `bench/setup/REPRODUCTION.md`.
- Driver scripts and workload definitions → `run-big-batch.sh`,
  `bench/run-intp-bench.sh`, `bench/hibench/run-hibench-subset.sh`.
- Campaign commit tag → standard `git describe` against the campaign's
  big-batch.log first-line commit reference.
- Heiser citation: Heiser, G. "Systems Benchmarking Crimes" (2010,
  updated 2017–2024), https://gernot-heiser.org/benchmarking-crimes.html

**Status:** ready (just needs to be written into the prose).

---

## Section V — Results

All five subsections need the corresponding figure inserted plus a
discussion paragraph grounded in the campaign data.

### V.A — Per-application fingerprint (Fig. 1)

**Figure source:** `bench/plot/plot-intp-bench.py::fig_per_app_bars`
(produces `fig01_per_app_bars.png`).

**Discussion grounding:** the workload→metric stress map in
`docs/EXPERIMENT-STRATEGY.md` predicts which apps should activate which
metrics. The discussion should verify that all four reliable variants
surface that expected signal.

**Status:** pending campaign completion (current run-in-progress is the
authoritative one after the 3 recent bug fixes).

### V.B — Cross-variant agreement (Fig. 2, PCA)

**Figure source:** `bench/plot/plot-intp-bench.py::fig_pca_kmeans`
plus the PCA biplot script (committed as
`feat: add PCA biplot script for IntP variant comparison`, 0d83fd9).

**Discussion grounding:** Pearson correlation per metric across variants,
plotted alongside the biplot. Meyer 2021 reports llcocc/mbw correlated
> 0.95 — predict same in our data and verify.

**Status:** pending data.

### V.C — Pairwise interference matrix (Fig. 3)

**Figure source:** `bench/plot/plot-intp-bench.py::fig_pairwise_heatmap`
(produces `fig07_pairwise_heatmap.png`).

**Discussion grounding:** the four chosen pairs (cpu_v_cache,
stream_v_stream, disk_v_disk, tcp_v_tcp_veth) saturate distinct
subsystems. Discuss directionality (which app is the antagonist) and
which metric registers the strongest delta.

**Status:** pending data. Note: the pre-fix data (email attachment
`fig07_pairwise_heatmap_bare.png`) shows C-ABI/bpftrace mbw and ebpf-ring llcmr
zeroed — that's the bug evidence. The new run should fix all three.

### V.D — Self-overhead (Fig. 4) `[TODO: v3 (ebpf-ring)/v3.1 (bpftrace) < 1%; v2 (C-ABI) 1–3%; v1.1 (stap-modern) higher]`

**Figure source:** `bench/plot/plot-intp-bench.py::fig_overhead_bars`
(produces `fig04_overhead_bars.png`).

**Discussion grounding:**
- Volpert et al. ICPE 2025 reports <1% for eBPF, ~2–3% for SystemTap
  on lightweight workloads. Our methodology mirrors theirs.
- The email attachment `fig04_overhead_throughput.png` shows ±3–5% across
  all variants on the pre-fix campaign, with stap-modern ref_disk being the
  outlier (5% with larger error bars) due to stap module load/unload
  cost between runs.

**Status:** pending the new overhead stage to refine the numbers.

### V.E — Long-trace stability (Fig. 5, 600 s)

**Figure source:** `bench/plot/plot-intp-bench.py::fig_timeseries`
(produces `fig03_timeseries.png`).

**Discussion grounding:** identify any variant with non-trivial warm-up
or drift over a 600-second window. The stap-modern helper has a 1-second
polling cadence; mbw and llcocc may show "stairs" early on.

**Status:** pending data.

### V.F — HiBench validation (Fig. 6)

**Figure source:** `bench/plot/plot-hibench.py::fig_metric_availability`
(produces `fig11_metric_availability.png`) plus the per-workload
fingerprint figures.

**Discussion grounding:** the HiBench campaign in pseudo-distributed
mode with the Driver inside a netns is the closest substitute we have
for a multi-node Spark cluster. Discuss what generalises from the
stress-ng signal (the synthetic per-resource saturators) to a real
analytics workload (terasort, wordcount, kmeans, bayes, dfsioe,
pagerank).

**Status:** pending data. Validation strategy detailed in
`docs/EXPERIMENT-STRATEGY.md` § "Workload → metric stress map".

---

## Section VI — Discussion

### VI.A — Portability and reliability cliffs

> [TODO: Argue that stap-2022/stap-nollc's compilation failure and stap-nohelper's sustained-load
> reliability degradation are themselves results, not missing data.
> Connect to Volpert et al. on eBPF stability vs. SystemTap. Distinguish
> portability (stap-2022, stap-nollc) from reliability (stap-nohelper) cliffs.]

**Source in repo:**
- stap-2022 compilation failure → `bench/findings/v0-baseline-failure-diagnosis.md`.
- stap-nohelper reliability under sustained load →
  `bench/findings/v1-modernization-reliability-findings.md`.
- Volpert ICPE 2025 framing → `README.md` references and the
  `docs/PORTABILITY-ROADMAP.md`.

**Status:** ready. Material is in place; needs the prose argument.

### VI.B — Where variants disagree, and why

> [TODO: Identify any metric on which stap-modern and C-ABI/ebpf-ring/bpftrace systematically
> differ, and explain the likely cause: helper-side polling cadence
> (1 s) versus eBPF tracepoint sampling, IMC unit selection on
> Sapphire Rapids, system-wide vs. per-process attribution semantics
> where applicable.]

**Source in repo:**
- 1-second polling cadence in stap-modern → `variants/v1.1-stap-modern/DESIGN.md` and
  `docs/METRICS-DEEP-DIVE.md` § mbw.
- IMC unit selection → `variants/v1.1-stap-modern/intp-helper.c` and
  `docs/HARDWARE-COMPATIBILITY.md`.
- @system vs per-process attribution → `docs/EXPERIMENT-STRATEGY.md`
  § stap-modern dual-mode operation.

**Status:** partial. Material exists; the actual data-driven divergence
will come from V.B (PCA agreement) once the new campaign finishes.

### VI.C — Threats to validity

> [TODO: Single-host evaluation; stress-ng is not a benchmark; distributed
> mode via netns + veth is a partial substitute for a real multi-node
> testbed; HiBench Spark single-node pseudo-distributed is not
> production-scale Spark.]

**Source in repo:**
- stress-ng is not a benchmark → directly stated in the original
  upstream documentation; cited in the paper already (ref [8]).
- netns + veth as substitute → `bench/setup/setup-netns-pair.sh` and
  `bench/setup/setup-distributed-mode.sh` comment headers; also
  `docs/EXPERIMENT-STRATEGY.md` Rule 3.
- Single-host → `docs/HARDWARE-COMPATIBILITY.md` and the implicit
  scope of the campaign.

**Status:** ready. Straightforward synthesis.

---

## Section VII — Related Work

> [TODO: Three short paragraphs covering each cluster. Make positioning
> explicit: this work modernizes the IntP lineage cited in cluster (3),
> is methodologically aligned with cluster (2), and feeds cluster (1)
> downstream.]

**Source in repo:**
- The README.md references section already groups the three clusters:
  - Cluster (1) — interference-aware scheduling consumers: IADA (Meyer
    2022), the placement and classifier predecessors (Ludwig 2019, Meyer
    2021).
  - Cluster (2) — modern instrumentation methodology: iprof (Becker
    2024 / Gögge 2023), PRISM (Landau 2025), Volpert (2025), Zhong (2025
    CO-RE study), Sohal (2022 RDT).
  - Cluster (3) — the IntP lineage origin: Xavier 2022.

**Status:** ready. The clusters are pre-organised; needs the positioning
paragraphs.

---

## Section VIII — Conclusion and Future Work

> [TODO: Two paragraphs. First: restate the modernization contribution
> across the seven variants and the headline cross-variant agreement
> and overhead numbers. Second: future work — closed-loop integration
> with sched_ext or with the existing IADA scheduling architecture,
> container/VM cross-environment evaluation, and a multi-node
> distributed campaign that replaces the veth-and-netns substitute used
> here.]

**Source in repo (future work paths):**
- IADA integration → `bench/iada/docs/iada-campaign.md` and the
  CloudSimInterference fork (https://github.com/ggrv-intp/CloudSimInterference)
  + interference-classifier fork.
- Container/VM cross-environment → `bench/deploy/` (qcow2 build/snapshot
  scripts, Docker integration in `run-intp-bench.sh`).
- Multi-node — open; the email of 2026-05-08 lists the prerequisites for a
  PUCRS LAD or equivalent multi-host testbed.

**Also pending future-work candidates (from the same email):**
- Head-to-head with iprof (Volpert workflows, nf-core).
- Cross-kernel validation (Ubuntu 22 5.15 vs 24 6.x, isolating
  CFS→EEVDF drift).
- Two additional Volpert-inspired metrics (PSL, PSP).
- Volpert's 8-scenario adversarial benchmark (Underutilized /
  Self-preempting / Subharmony / Harmony / Steal / Starving /
  Competing / Baseline) → first published interference-profiler
  confusion matrix.
- Segmented vs one-shot classification on the Meyer 2021 lineage
  (Acc/F1/RandIdx).
- GRU/ARIMA workload prediction for proactive IADA.
- PCA on the 7 metrics to assess redundancy.

**Status:** ready. The repo has the operational hooks; the paper's
future-work paragraph needs to pick 2–3.

---

## Status summary

| Section                | TODOs in section | Material ready | Pending data |
|------------------------|------------------|----------------|--------------|
| Title                  | 1                | 1              | 0            |
| Abstract               | 1                | 0              | 1            |
| I. Introduction        | 1                | 0              | 1 (external) |
| II. Background         | 3                | 2 (B, C)       | 1 (A external)|
| IV. Methodology        | 2                | 1 (D)          | 1 (A)        |
| V. Results             | 6                | 0              | 6 (campaign) |
| VI. Discussion         | 3                | 2 (A, C)       | 1 (B)        |
| VII. Related Work      | 1                | 1              | 0            |
| VIII. Conclusion       | 1                | 1              | 0            |

**Bottom line:** all conceptual content has material in the repo. The
six Section V figure/discussion TODOs are gated on the in-flight
campaign. The non-Section-V TODOs are writing tasks, not measurement
tasks.

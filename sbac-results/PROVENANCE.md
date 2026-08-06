# PROVENANCE — SBAC-PAD 2026 campaign

Provenance chain behind the results reported in the SBAC-PAD 2026 paper:
from the source measurement campaigns, through the fusion tree the plotters
consume, to the published artifact and the camera-ready figures. The
published tree in release v0.1.0 (`sbac_results-publish/`) is the
anonymized copy of the fusion tree described here (`ub22-and-24-full`);
measurement values are untouched.

## Source campaigns and hosts

The four measured endpoints come from five campaign sessions on **two
different hosts** (both Intel Xeon Gold 5412U machines per
`capabilities-<leg>.env`; hostnames and internal IPs in the published copy
are placeholders — see `ANONYMIZATION.md`):

| Leg | OS / kernel | stress-ng | Sessions |
| --- | --- | --- | --- |
| `ub24` | Ubuntu 24.04.4 LTS, kernel 6.8.0-111-generic | 0.17.06 | v1.1/v2 from `ub24-campaign-20260518_021737` (run3); v3.2 stress-ng from `ub24-campaign-20260522_183908` (run2); v3.2 hibench from `ub24-campaign-20260523_131301` (run1) |
| `ub22` | Ubuntu 22.04.5 LTS, kernel 5.15.0-177-generic | 0.13.12 | v0.2 stress-ng from `ub22-campaign-20260521_162957`; v0.2 hibench from `ub22-campaign-20260523_184651` |

The ub24 sessions were first fused into `ub24-concat` (its own
PROVENANCE.md documents that step; run3's original v3.2 was discarded,
not pooled), then united with the ub22 leg into `ub22-and-24-full` — a
pure union, since the legs touch disjoint variant subtrees (v0.2 vs
v1.1/v2/v3.2). Source campaigns were not modified.

The v0.2 (legacy-intp-baseline) leg runs on 22.04/5.15 by design: it ports
the original V0 probe semantics to the userspace-helper pattern so the
kernel-5.15 GA environment is runnable without the V0 fragility cliff (see
`VERSIONS.md`).

## Composition (layer × version)

| Version | stress-ng `bare` | hibench | overhead baseline |
| --- | --- | --- | --- |
| **v0.2** | ub22 (kernel 5.15) | ub22 | `_baseline.v0.2` (ub22) |
| v1.1, v2 | ub24 run3 | ub24 run3 | `_baseline` (ub24 run3) |
| v3.2 | ub24 run2 | ub24 run1 | `_baseline.v3.2` (ub24 run2) |

## Per-version overhead baselines

The overhead figure is a within-session ratio
`(baseline − with-profiler)/baseline`. The no-profiler baseline drifts
across sessions and much more across hosts, so each variant divides by the
baseline measured on its own host/session. Three baselines coexist under
`overhead/bare/`: `_baseline` (serves v1.1, v2), `_baseline.v3.2` and
`_baseline.v0.2`. `plot-intp-bench.py` picks `_baseline.<variant>` when
present, else the shared `_baseline`. The ratio cancels the absolute
level, so variants remain comparable in fig04/04b/04c even though v0.2 is
a different host.

## v0.2 throughput recovery

ub22's `overhead/.../throughput.tsv` was written `NA` at capture time:
stress-ng 0.13.12 prints its metrics block under the `info:` tag, and the
parser then in use only recognized the newer `metrc:` tag. The data was
never lost — every ub22 `workload.log` has the bogo-ops line. The 72 ub22
`throughput.tsv` files in the fusion tree (not the source) were re-derived
with the current parser (`run-intp-bench.sh::_overhead_parse_stressng`,
which accepts both tags), so v0.2 appears in the throughput axis (fig04)
too. CPU-jiffies (fig04b) and sched-switch (fig04c) were already valid
from `cpu_stat.tsv` / `perf_stat.csv`.

## Fusion details

- `aggregate-means.tsv`, `index.tsv` = ub24-concat's rows + ub22's v0.2
  rows (overhead `_baseline` relabeled `_baseline.v0.2`; index paths
  repointed).
- `fragility-*.tsv` regenerated over all four variants (1108 runs):
  v1.1 ≈16%, v0.2 ≈6.4% sample loss (both SystemTap), v2/v3.2 = 0%.
- hibench: 21 run-dirs (14 from ub24-concat + 7 ub22 v0.2), uniform
  12 reps per (variant, profile): run3 had run each profile twice for
  v1.1/v2, so one run-dir per profile was dropped, keeping the
  higher-sample-capture replicate (ties → earliest; netp kept the later
  `20260521_040403`).
- `capabilities-ub24.env` / `capabilities-ub22.env` record each host;
  `capabilities.env` is ub24's (primary).

## Harness invocations

Each leg is driven end-to-end by its one-command driver at the repository
root — `ub24run.sh` and `ub22run.sh` (documented in
`bench/setup/REPRODUCTION.md` §9b) — which invoke:

- `bench/run-intp-bench.sh` — stress-ng campaign
  (`detect,build,solo,pairwise,overhead,timeseries,report`), env `bare`,
  reps=12, duration 90 s (warmup 15, cooldown 10, interval 1 s),
  timeseries 600 s, overhead 90 s (Volpert mode), run_seed 1779063461.
  Per-workload stress-ng invocations are tabulated in `bench/OVERVIEW.md`.
- `bench/hibench/run-hibench-subset.sh` — HiBench campaign: 7 co-runner
  profiles × 6 workloads × 12 reps = 504 reps per variant.

Full run parameters: `metadata-full.txt` in the published artifact;
per-run metadata in each `rep<R>/run.json`.

## Variant identity

The exact profiler binaries/scripts measured are pinned by sha256 in
`variants-full.manifest` (variant → path → sha256 → mtime). That manifest
predates the 2026-05-05 directory renaming, so its paths use the legacy
directory names; the mapping from legacy to current `variants/v{tag}-*/`
names is `VERSIONS.md`. The four measured versions are v0.2
(legacy-intp-baseline), v1.1 (stap-modern), v2 (C-ABI) and v3.2
(eBPF-CORE).

## Published artifact

The public data pointer cited by the paper is release **v0.1.0** (tag at
commit `9795c5b`). It carries three assets:

**`across-intp-sbac-results-v0.1.0.tar.gz`** — the anonymized artifact:

- `sbac_results-publish/` — the anonymized fusion tree (layout in
  `sbac-results/README.md`), plus `MANIFEST-full.txt`, `index-full.tsv`
  and `metadata-full.txt` as the file-level audit trail.
- `published/{baseline,new,merged}/` — the reduced-variant figure sets
  used by the paper (refreshed 2026-08-06 with the camera-ready render).
- `extra/intp-aux-rerun-{v3,v3.2}-*/` — self-contained auxiliary reruns
  (2026-05-24, distinct from the earlier 2026-05-17/18 pre-rename pair):
  each dir carries its own raw `noise_floor/` and `ringbuf_pidstat/`
  traces, `env.txt`, `run.log` and the `plots/` cited by Fig. 6.

**`consolidation-raw.tar.gz`** (added 2026-08-06) — the pre-anonymization
raw sources behind the artifact: the five measurement sessions, the
published auxiliary reruns, and the fusion trees (`ub24-concat`,
`ub22-and-24-full`) with their PROVENANCE records, a README and a file
MANIFEST. Published deliberately after the testbed nodes were
decommissioned; for v0.2 stall counts the published fragility tables
remain canonical.

**`SHA256SUMS`** — integrity reference covering both tarballs.

Release assets are updated in place when figures are regenerated; the tag
does not move.

## Figure regeneration (camera-ready)

Camera-ready figures are rendered at their exact printed size by
`bench/plot/render-paper-figures.py` (shared style:
`bench/plot/paper_style.py`) and gated by `bench/plot/qa_fig_fonts.py`,
which measures page geometry and embedded font sizes from the produced
PDFs — floor 6.5 pt (heatmap annotations) / 7.0 pt (axis, tick, legend,
label text). The gate report ships as `QA-FIGS.md` next to the rendered
set and includes a per-figure visible-string diff against the previously
published figures, so typography-only regeneration is auditable: no data
value changed.

## Anonymization

The published copy replaces hostnames, internal IPs and one stray public
IP with placeholders; `ANONYMIZATION.md` (shipped in the artifact) is the
redaction record. Source campaign data was not modified.

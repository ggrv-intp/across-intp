# sbac-results/ — published SBAC-PAD 2026 campaign artifact

This directory holds the result tree behind the SBAC-PAD 2026 paper: the
profiler TSVs, raw logs, and figures for the four reported variants —
**v0.2 (legacy-intp-baseline), v1.1 (stap-modern), v2 (C-ABI), v3.2 (eBPF-CORE)**.

It is the input consumed by the fragility extractor cited in the paper:

```bash
python3 bench/plot/extract-fragility.py sbac-results
```

which writes `fragility-summary.tsv` and `fragility-aggregated.tsv` here.

## Expected layout

The tree mirrors `run-intp-bench.sh` / `run-hibench-subset.sh` output, so the
in-repo tooling (`bench/plot/extract-fragility.py`, `bench/plot/*.py`)
reads it unchanged. It has two axes worth calling out:

- **6 HiBench workloads**: `bayes, dfsioe, kmeans, pagerank, terasort, wordcount`
- **7 co-runner profiles** (the `all-stress` sweep): `standard` (no antagonist)
  plus 6 `-extreme` stress-ng conditions — `cpu, mem, cache, disk, netp, nets`.
  These are a *separate* axis from the workloads: the HiBench campaign is
  7 profiles × 6 workloads × 12 reps.

```
sbac-results/
├── capabilities.env                     # host snapshot (seeded from first leg)
├── capabilities-<leg>.env               # per-leg snapshot: ub24 | ub22
│
├── bare/                                # stress-ng campaign (run-intp-bench.sh)
│   └── <variant>/                       # v0.2 | v1.1 | v2 | v3.2
│       └── <stage>/                     # solo | pairwise | timeseries
│           └── <workload>/              # app01_ml_llc, …
│               └── rep<R>/
│                   ├── profiler.tsv         # 7-metric profiler output
│                   ├── profiler.stap.log    # stap log (SystemTap variants)
│                   ├── groundtruth.tsv
│                   └── run.json             # per-run metadata
├── overhead/                            # stress-ng overhead stage
│   └── bare/<variant>/<ref_workload>/rep<R>/…
│
├── hibench/                             # HiBench campaign (run-hibench-subset.sh)
│   └── <profile>-<size>-<ts>/           # ONE run-dir per co-runner profile;
│       │                                # 7 in an all-stress campaign:
│       │                                #   standard, cpu-extreme, mem-extreme,
│       │                                #   cache-extreme, disk-extreme,
│       │                                #   netp-extreme, nets-extreme
│       └── bare/<variant>/hibench/
│           └── <workload>/              # the 6 workloads listed above
│               └── rep<R>/
│                   ├── profiler.tsv
│                   ├── run.json
│                   └── workload.log
│
├── aggregate-means.tsv                  # stress-ng + all 7 hibench profiles, merged
├── figures/<leg>/                       # rendered PDFs/PNGs for the paper
├── paper-tables/                        # §V correlation + overhead tables
│   │                                    # (bench/plot/cross-variant-correlation.py)
│   ├── correlation-4way-<env>.tsv       # 6 pairwise r (raw + z-scored)
│   ├── correlation-per-metric-<env>.tsv # 7 metrics × 6 pairs
│   ├── correlation-family-summary.tsv   # within-/cross-family roll-up
│   ├── correlation-per-metric-family.tsv# per-metric family roll-up (llcocc gap)
│   └── overhead-bounds.tsv              # throughput overhead % per variant×ref
└── logs/                                # per-leg campaign logs
```

Only `bare` was measured for the paper; the container/vm envs are wired in
the harness but were not run for this campaign.

## Published paper figures (`published/`)

A sibling **`published/`** directory ships alongside this payload (next to
`extra/`) with the figures actually used in the paper, rendered in the
reduced-variant views the SBAC-PAD camera-ready uses. v1.1 (stap-modern) is
excluded from the paper figures. In plot legends/axes the baseline is
abbreviated **`intp-baseline`** (the full name `legacy-intp-baseline` is used
in prose and this README) to avoid label overlap.

```
published/
├── baseline/   # v0.2 (intp-baseline) alone
├── new/        # v2 (C-ABI) + v3.2 (eBPF-CORE) together
└── merged/     # v0.2 + v2 + v3.2 together (v1.1 excluded)
```

Each subfolder holds the same 10 paper figures as PDF + PNG: `fig01b_per_variant_bars`,
`fig02_pca_dendro`, `fig04_overhead_throughput`, `fig04b_overhead_cpu_jiffies`,
`fig04c_overhead_sched_switch`, `fig05_fidelity_matrix`, `fig07_pairwise_heatmap_bare`,
`fig10_variant_resource_heatmap`, `fig11_idi_bars`, `fig13_iada_segmented`.
They are regenerated from the same data via the plotters' `--variants` flag, e.g.:

```bash
# baseline / new / merged (repeat per variant subset)
python3 bench/plot/plot-intp-bench.py sbac-results --variants v0.2          --out /tmp/baseline
python3 bench/plot/plot-intp-bench.py sbac-results --variants v2,v3.2       --out /tmp/new
python3 bench/plot/plot-intp-bench.py sbac-results --variants v0.2,v2,v3.2  --out /tmp/merged
# fig02 via plot_pca_dendro.py <aggregate-means.csv> <out> <variants>;
# fig10 via plot-hibench.py sbac-results/hibench --variants <subset> --out <out>
```

## Data-quality / sample loss

`extract-fragility.py` writes one row per discovered `run.json` to
`fragility-summary.tsv` and a per-`(env, variant)` roll-up to
`fragility-aggregated.tsv`. Sample loss is the fraction of expected profiler
ticks that never landed, and the single extractor now handles both campaigns:

- **stress-ng (`env=bare`)** records a fixed `--duration` in `run.json`, so

  ```text
  expected      = duration_target_s / interval          (interval = 1 s)
  sample_loss_% = max(0, (expected - actual_samples) / expected * 100)
  ```

- **HiBench (`env=hibench`)** has no fixed window — the profiler runs as long as
  the Spark job — so loss is derived from the profiler's own `ts` column
  instead: within the first..last span, every missing interval tick is a dropped
  sample.

  ```text
  expected_ticks = round((ts[-1] - ts[0]) / interval) + 1
  sample_loss_%  = max(0, (expected_ticks - actual_samples) / expected_ticks * 100)
  ```

  This needs no recorded target, so it runs unchanged on older result trees and
  matches the stress-ng definition in spirit.

So `extract-fragility.py` emits real `env=hibench` rows (the timestamp-gap path
is taken whenever `run.json` carries no `duration_target_s`), and
`bench/plot/hibench-sample-loss.py` is a standalone backfill that writes
`fragility-hibench-samples.tsv` (per rep) and `fragility-hibench-aggregated.tsv`
(per variant) for any tree. Measured HiBench sample loss: **legacy-intp-baseline mean 3.03% /
max 55.0% (68 of 504 reps > 5%), stap-modern mean 4.39% / max 73.08% (100 of 504 reps
> 5%), C-ABI and eBPF-CORE ~0% (max < 2.4%)** — the same SystemTap-vs-modern split seen
on stress-ng. (`fragility-hibench-aggregated.tsv` holds these per-rep figures;
the unified extractor's `env=hibench` means read marginally lower, ~4.05%,
because that pass also walks the 0-loss per-workload aggregate `run.json` files.)

Going forward, HiBench runs are self-describing: `run-hibench-subset.sh` records
`sample_interval_s` (and `env`) in each per-rep `run.json`, so the extractor
honors a non-default `--interval` with no implicit `= 1` assumption; older trees
without the field fall back to the same path-inferred `env=hibench` and a 1 s
interval.

`hibench-sample-loss.py` only writes the `fragility-hibench-*.tsv` files, so it
is safe to re-run on this published tree. `extract-fragility.py`, by contrast,
rewrites `fragility-summary.tsv` / `fragility-aggregated.tsv` — do not run it
against this published tree, per the legacy-intp-baseline stall-count caveat under
**Anonymization** below.

## How this tree is produced

The payload is generated by the two one-command per-OS campaign scripts in
the repo root — each runs veth setup → stress-ng → Hadoop/Spark/HiBench →
HiBench → publish:

```bash
sudo bash ub24run.sh      # Ubuntu 24.04 leg → v1.1, v2, v3.2
sudo bash ub22run.sh      # Ubuntu 22.04 leg → v0.2
```

Each leg runs on its own host and calls `bench/publish-sbac-results.sh`,
which copies that leg's profiler tree + figures here and dedup-merges the
shared `aggregate-means.tsv`. The two legs touch disjoint `<variant>/`
subtrees, so running both (in either order) assembles the full four-variant
artifact. Per-leg host snapshots land as `capabilities-ub24.env` /
`capabilities-ub22.env`; figures under `figures/<leg>/`. See
`bench/setup/REPRODUCTION.md` §9b.

> The result payload is added separately by the maintainers; this README is
> the scaffold describing the layout evaluators should expect.

## Anonymization (public artifact)

The published payload is anonymized for release: host identifiers are replaced
with generic placeholders (hostnames → `anon-host`, internal IPs → `10.0.0.x`,
build paths → `/path/to/across-intp`). See `ANONYMIZATION.md` in the payload for
the full redaction record.

The legacy-intp-baseline `stall-monitor/` raw kernel/journal dumps are **omitted from
this payload** (they captured system journald output, including host auth logs).
The stall evidence is retained as counts in the shipped `fragility-summary.tsv` /
`fragility-aggregated.tsv` — do **not** regenerate these with
`extract-fragility.py` against this tree, since the raw dumps needed to recount
stalls are absent here.

Since 2026-08-06 the release also ships **`consolidation-raw.tar.gz`**: the
pre-anonymization source campaigns, the Fig. 6 auxiliary reruns and the fusion
trees, including the `stall-monitor/` dumps with their auth-log content
redacted (see `ANONYMIZATION.md` in the payload for the exact policy). The
fragility tables in this payload remain the canonical stall counts. The full
provenance chain is documented in `PROVENANCE.md` next to this file.

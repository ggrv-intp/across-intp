# bench/plot -- Plotting and post-processing scripts

Standalone Python scripts that consume the artefacts produced by
`bench/run-intp-bench.sh`, `bench/run-big-batch.sh`, and
`bench/hibench/run-hibench-subset.sh`. Use them when you want to
re-plot an existing campaign without re-running the workload — for
example when iterating on figure styling, regenerating a single panel,
or analysing an archived `results/` snapshot from another host.

The big-batch driver invokes every script automatically. This guide
covers the **standalone** invocation flow.

## Contents

| Script | Input | Output | Use when |
|---|---|---|---|
| `plot-intp-bench.py`        | a `bench-full/` directory (one campaign) | `<input>/plots/{png,pdf}/fig*.{png,pdf}` + `aggregate-means.csv` | re-rendering the cross-variant figure set (fig00 - fig14, plus fig01b / fig04b / fig04c) from solo / pairwise / overhead / timeseries data |
| `plot-hibench.py`           | a `hibench/` directory (one or more workload sweeps) | `<input>/plots/fig*.png` | rendering the HiBench-specific resource-family figures |
| `plot-pca-correlation-circle.py` | an `aggregate-means.{tsv,csv}` from a single campaign | `fig_pca_correlation_circle.png` | publication-grade single-figure biplot for the SBAC-PAD short paper |
| `extract-fragility.py`      | a `bench-full/` directory (SystemTap stap.log per run) | `<input>/fragility-summary.tsv` and `fragility-aggregated.tsv` | quantifying probe skips, overload, sample loss for the stap-2022 / stap-nollc / stap-nohelper / stap-modern stap variants |
| `plot-cross-environment.py` | a `bench-full/` directory containing `aggregate-means.tsv` (>= 2 envs) | `<input>/cross-env/{summary,availability,stats}.tsv` + `plots/<variant>/<workload>.png` | comparing bare vs container vs vm under the same workload using Kruskal-Wallis + Mann-Whitney (Bonferroni) + Cliff's delta |
| `cross-variant-correlation.py` | a campaign tree (publication or fused layout) | `--out` dir: `correlation-{4way,per-metric}-<env>.tsv`, `correlation-{family-summary,per-metric-family}.tsv`, `overhead-bounds.tsv` | reproducing the paper's §V cross-variant fingerprint correlations (per-metric + per-family, raw and z-scored) and per-variant throughput-overhead bounds from the merged `aggregate-means.tsv` + overhead `throughput.tsv` |
| `render-paper-figures.py`   | a published campaign tree | `--out` dir: `figures/` (paper filenames), `published/<subset>/`, per-subset `{pdf,png}/` | regenerating the eleven SBAC-PAD camera-ready figures at their exact printed size |
| `qa_fig_fonts.py`           | a directory of paper-named PDFs | `QA-FIGS.md` + `qa/` contact sheet | gating the camera-ready set on page width and minimum font size, and diffing content against the previously published render |
| `paper_style.py`            | (imported, not run) | — | the shared camera-ready typography, page geometry and per-figure size table |

## Dependencies

```bash
pip install --user matplotlib pandas numpy scikit-learn
```

`scikit-learn` is needed by `plot-intp-bench.py` (PCA / KMeans figure
fig02) and by `plot-pca-correlation-circle.py`. `plot-hibench.py`
warns and skips the PCA panel if it is missing.

`extract-fragility.py` has no external dependencies (stdlib only).

## Expected input layout

The plot scripts read the directory tree produced by the bench
runners:

```
results/<campaign>/bench-full/
├── aggregate-means.tsv              # produced by run-big-batch.sh
├── metadata.txt
├── variants.manifest
├── bare/                            # one subtree per env (bare | container | vm)
│   └── <variant>/                   # v0 | v0.1 | v1 | v1.1 | v2 | v3 | v3.1
│       ├── solo/<workload>/rep<R>/profiler.tsv
│       ├── pairwise/<a>__vs__<b>/rep<R>/profiler.tsv
│       └── timeseries/<workload>/rep<R>/profiler.tsv
└── overhead/
    └── bare/<variant>/<workload>/rep<R>/{profiler.tsv,run.json,stress-ng.log}

results/<campaign>/hibench/
└── <profile>-<scale>/aggregate-means.tsv     # one per profile sweep
    └── <variant>/<workload>/rep<R>/profiler.tsv
```

Variant directories use the **current** naming
(`v0`, `v0.1`, `v1`, `v1.1`, `v2`, `v3`, `v3.1`); see
[../../VERSIONS.md](../../VERSIONS.md) for the legacy↔current map if
you are replaying a pre-2026-05-05 snapshot.

## Running each script

### plot-intp-bench.py — full bench figure set

```bash
# 14-figure render against an existing campaign
python3 bench/plot/plot-intp-bench.py results/<campaign>/bench-full

# Custom output directory
python3 bench/plot/plot-intp-bench.py results/<campaign>/bench-full \
    --out /tmp/fig-iteration
```

Produces `fig00_*` … `fig14_*` plus the b-suffixed siblings
(`fig01b_per_variant_bars`, `fig04b_overhead_cpu_jiffies`,
`fig04c_overhead_sched_switch`), each emitted as both PNG (under
`plots/png/`) and PDF (under `plots/pdf/`), and also `aggregate-means.csv`.
Every figure is auto-skipped when its required input subtree is empty
(e.g. no `timeseries/` data → no fig03), so it is safe to point at a
partial run.

### plot-hibench.py — HiBench resource-family figures

```bash
python3 bench/plot/plot-hibench.py results/<campaign>/hibench
python3 bench/plot/plot-hibench.py results/<campaign>/hibench --out /tmp/hb
```

Iterates over each `<profile>-<scale>/` subdirectory containing a
`aggregate-means.tsv` and emits the canonical IntP Fig. 4 panel
(`fig00_canonical_intp_fig4.png`), the IntP Fig. 8 resource-family
trace (`fig09_resource_timeseries.png`), and a variants × resources
heatmap.

### plot-pca-correlation-circle.py — single biplot

```bash
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv

# Filter to a subset of variants, drop sparse rows
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv \
    --variants v1.1,v2,v3,v3.1 --min-samples 30

# Override the feature set
python3 bench/plot/plot-pca-correlation-circle.py \
    results/<campaign>/bench-full/aggregate-means.tsv \
    --features cpu,mbw,llcocc,llcmr
```

Available knobs: `--env`, `--variants`, `--min-samples`,
`--features`, `--no-polygons`, `--output`. Run with `--help` for the
full list. By default the figure lands at
`<input-dir>/plots/fig_pca_correlation_circle.png`.

### extract-fragility.py — SystemTap reliability metrics

```bash
python3 bench/plot/extract-fragility.py results/<campaign>/bench-full
```

Walks every `rep<R>/` under the campaign, parses
`profiler.stap.log` (only emitted by stap-2022/stap-nollc/stap-nohelper/stap-modern) and the
sibling `run.json`, and writes:

- `fragility-summary.tsv` — one row per
  `(env, variant, stage, workload, rep)` with skip counts, error
  counts, sample-loss percent.
- `fragility-aggregated.tsv` — `(env, variant)` rollup with means
  and standard deviations.

Console output prints a per-variant ranking of mean sample loss for
the bare-metal env, useful for the dissertation's reliability tables.

If your campaign was run with a non-default sampling interval, set
`INTP_INTERVAL` so `expected_samples` is computed correctly:

```bash
INTP_INTERVAL=0.5 python3 bench/plot/extract-fragility.py \
    results/<campaign>/bench-full
```

### cross-variant-correlation.py — §V correlation + overhead tables

```bash
python3 bench/plot/cross-variant-correlation.py \
    --campaign results/<campaign> --out paper-tables/ [--verify] [--plot]
```

Reproduces the numbers the paper cites in §V: how strongly the four
profiler endpoints agree on their per-application interference
fingerprints, and the per-variant throughput-overhead bounds. No other
plotter computes these. It reads the merged wide-format
`aggregate-means.tsv` (locating it under the campaign root or
`bench-full/` + per-profile `hibench/`) and the overhead
`throughput.tsv` files — no re-capture.

Two analysis envs: `bare` = the stress-ng layer (`stage == solo`),
`hibench` = the HiBench layer (`stage` like `hibench-<profile>`). The
"application" a fingerprint is built over is a stress-ng solo workload
(17) or a `(profile, workload)` pair (42). Correlation is Pearson on
the flattened `[application × metric]` fingerprint (raw and
per-metric-z-scored) and per single metric across applications. The
family roll-up splits the endpoints into the SystemTap pair
`{legacy-intp-baseline, stap-modern}` and the production-grade pair `{C-ABI, eBPF-CORE}`; the
**cross-family** rows are where the `llcocc` capability gap and the
legacy-intp-baseline overhead surface. Outputs (to `--out`, default `paper-tables/`):

- `correlation-4way-<env>.tsv` — the 6 pairwise r (raw + z-scored).
- `correlation-per-metric-<env>.tsv` — 7 metrics × 6 pairs.
- `correlation-family-summary.tsv` — the headline roll-up.
- `correlation-per-metric-family.tsv` — per-metric family roll-up.
- `overhead-bounds.tsv` — throughput overhead % per `(variant, ref_load)`,
  per-variant baseline (`_baseline.<variant>` overrides `_baseline`).
- `correlation-heatmap-<env>.pdf` — only with `--plot` (a debug sanity
  check, not a paper figure).

`--verify` checks the produced tables against `EXPECTED_VALUES` (the
exact numbers the paper cites, with provenance noted in the script) and
**exits non-zero on any mismatch**, so the artifact and the text cannot
silently drift. Run it against the canonical fused tree:

```bash
python3 bench/plot/cross-variant-correlation.py \
    --campaign results/ub22-and-24-full --out paper-tables/ --verify
```

`run-big-batch.sh` invokes the script (without `--verify`) in its plot
segment, writing `<campaign>/paper-tables/`.

### render-paper-figures.py — SBAC-PAD camera-ready figure set

```bash
python3 bench/plot/render-paper-figures.py sbac-results --out /tmp/camera-ready
python3 bench/plot/qa_fig_fonts.py /tmp/camera-ready/figures \
    --out /tmp/camera-ready --compare-to <payload>/published
```

Regenerates the eleven figures the paper includes, each rendered at its
**exact printed size** (`paper_style.py` holds the width/height table and the
IEEEtran page geometry), so `\includegraphics` embeds them at scale 1.0 and a
7 pt label is a printed 7 pt. Writes them twice — under the paper's filenames
in `figures/` and in the artifact's `published/<subset>/` layout — plus
`qa/pearson_ground_truth.tsv`, the nine profiler-vs-ground-truth Pearson r
values as data rather than as a picture.

The three plotters take `--camera-ready --paper-subset {baseline,new,merged}`
individually; the driver just sequences them. **Without those flags nothing
changes**, so the exploratory figure sets are unaffected.

Nine of the eleven PDFs are placed in the paper; two —
`baseline-fig01b_per_variant_bars.pdf` and `merged-fig05_fidelity_matrix.pdf`
— are rendered as *alternatives* to floats that were consolidated away, so
the author can put either back. `paper_style.FLOATS` records which PDFs make
up which float and what each costs.

`qa_fig_fonts.py` is the gate: it re-opens each PDF, asserts the page width
against the target, the 6.5 pt floor against the embedded text spans, and
that no text runs off the page box; diffs every visible string against the
previous render; reports each float's cost in points of column-space against
the consolidation budget; writes `QA-FIGS.md` plus a 300-dpi contact sheet
under `qa/`; and exits nonzero on any violation. It needs `pymupdf` in
addition to the dependencies above.

The off-the-page-box check exists because a figure can be shrunk until
matplotlib centres a y-axis label — which is as tall as it is long — on an
axes too short to hold it, and the ends fall outside the page. The page is
still the right width and the fonts are still the right size, so nothing else
in the gate notices that the label lost its last three characters. The fix is
a shorter label or a taller figure, never a smaller font.

## Output sizing

All `plot-*.py` scripts cap PNG output at ~2600 px per side and render
at 160 DPI. Re-style the figures by editing the constants at the top
of each script (`MAX_PIXELS`, `SAVE_DPI`, `setup_style()`). The
companion PDF (vector) export bypasses the pixel cap.

## Replaying an archived campaign

Untar the result snapshot somewhere outside the repo and point the
scripts at the extracted root:

```bash
tar -xzf results/big-batch-stress-rep4-failhibench.tar.gz -C /tmp
python3 bench/plot/plot-intp-bench.py /tmp/bench-full
```

The plots write into the snapshot, not into the working tree, so
parallel re-renders against different snapshots do not collide.

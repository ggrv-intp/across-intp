#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-cross-environment.py — Cross-environment statistical comparison.
#
# Consumes the canonical aggregate-means.tsv produced by stage_report() in
# bench/run-intp-bench.sh:
#
#   env  variant  stage  workload  rep  netp  nets  blk  mbw  llcmr  llcocc  cpu
#   ----------------------------------------------------------------------------
#   Separator: TAB.  Header line present.  Missing values marked as "--".
#   One row per (env, variant, stage, workload, rep); values are the per-rep
#   mean of the underlying profiler.tsv samples.
#
# For each (variant, workload, metric) the script:
#
#   1. Gathers the per-rep mean across envs (one numeric sample per rep per env).
#   2. If at least 2 envs have n >= 2 samples, runs Kruskal-Wallis as the
#      omnibus test.
#   3. If the KW p-value < alpha, runs Mann-Whitney U pairwise for every env
#      pair, Bonferroni-adjusts the threshold (alpha / num_pairs), and
#      computes Cliff's delta as a non-parametric effect size with the
#      Vargha-Delaney magnitude classification.
#   4. Writes summary.tsv, stats.tsv, availability.tsv, and one PNG per
#      (variant, workload) with 7 panels (boxplots, one panel per metric).
#
# Why non-parametric: profiler metrics are skewed (saturable, event counts)
# and reps are small; the normality assumption underpinning ANOVA is not
# defensible. KW + MW pairs preserve interpretability under those conditions.
#
# Run:
#   python3 plot-cross-environment.py /path/to/<campaign>/bench-full
#   python3 plot-cross-environment.py /path/to/<campaign>/bench-full \
#       --variants v2,v3.1 --envs bare,container,vm-guest \
#       --metrics cpu,mbw,llcocc --stage solo
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import itertools
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

try:
    import numpy as np
    import pandas as pd
except ImportError:
    sys.exit("numpy + pandas required: pip install numpy pandas")

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib required: pip install matplotlib")

try:
    from scipy.stats import kruskal, mannwhitneyu
except ImportError:
    sys.exit(
        "scipy is required for cross-env statistics (Kruskal-Wallis, "
        "Mann-Whitney U). Install with: pip install scipy"
    )

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
MISSING_TOKEN = "--"
MAX_PIXELS = 1900
SAVE_DPI = 130
FORMATS: list[str] = ["png", "pdf"]


# Descriptive, paper-facing variant names. Figures show these instead of the
# bare vN tags so a reader need not consult the variant table to know what a
# panel measures. Canonical map: VERSIONS.md. The four measured versions are
# intp-baseline (v0.2), stap-modern (v1.1), C-ABI (v2) and eBPF-CORE (v3.2).
VARIANT_LABELS = {
    "v0":   "stap-2022",
    "v0.1": "stap-nollc",
    "v0.2": "intp-baseline",
    "v1":   "stap-nohelper",
    "v1.1": "stap-modern",
    "v2":   "C-ABI",
    "v2.1": "cgroup-native",
    "v3":   "ebpf-ring",
    "v3.1": "bpftrace",
    "v3.2": "eBPF-CORE",
    "v3.3": "ebpf-cgroup",
}


def variant_label(v):
    """Paper-facing descriptive name for a dataset variant tag."""
    return VARIANT_LABELS.get(str(v), str(v))


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_aggregate_means(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, sep="\t", dtype=str, keep_default_na=False)
    expected = ["env", "variant", "stage", "workload", "rep"] + METRICS
    missing = [c for c in expected if c not in df.columns]
    if missing:
        sys.exit(
            f"aggregate-means.tsv missing expected columns {missing}; "
            f"got {list(df.columns)}"
        )
    for m in METRICS:
        df[m] = pd.to_numeric(df[m].replace(MISSING_TOKEN, np.nan), errors="coerce")
    df["rep"] = pd.to_numeric(df["rep"], errors="coerce").astype("Int64")
    return df


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def cliffs_delta(a: Sequence[float], b: Sequence[float]) -> Tuple[float, str]:
    """Return (delta, magnitude).  Magnitude uses Vargha-Delaney thresholds:
       |d| < 0.147 = negligible, < 0.33 = small, < 0.474 = medium, else large.
    """
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    if a.size == 0 or b.size == 0:
        return float("nan"), "n/a"
    gt = 0
    lt = 0
    for x in a:
        gt += int(np.sum(b < x))
        lt += int(np.sum(b > x))
    n = a.size * b.size
    d = (gt - lt) / n
    ad = abs(d)
    if ad < 0.147:
        mag = "negligible"
    elif ad < 0.33:
        mag = "small"
    elif ad < 0.474:
        mag = "medium"
    else:
        mag = "large"
    return d, mag


def signif_marker(p: float, threshold: float) -> str:
    if not np.isfinite(p):
        return "n/a"
    if p < threshold / 50:
        return "***"
    if p < threshold / 5:
        return "**"
    if p < threshold:
        return "*"
    return "n.s."


# ---------------------------------------------------------------------------
# Plot helpers
# ---------------------------------------------------------------------------

def _clamp_figsize(width: float, height: float) -> Tuple[float, float]:
    max_in = MAX_PIXELS / SAVE_DPI
    scale = min(1.0, max_in / max(width, 1e-9), max_in / max(height, 1e-9))
    return width * scale, height * scale


def _setup_style() -> None:
    plt.rcParams.update({
        "pdf.fonttype":       42,
        "ps.fonttype":        42,
        "figure.dpi":         110,
        "savefig.dpi":        SAVE_DPI,
        "font.family":        "DejaVu Sans",
        "font.size":          9,
        "axes.titlesize":     10,
        "axes.labelsize":     9,
        "axes.spines.top":    False,
        "axes.spines.right":  False,
        "axes.grid":          True,
        "grid.linestyle":     ":",
        "grid.alpha":         0.4,
        "legend.fontsize":    8,
        "legend.frameon":     False,
        "xtick.labelsize":    8,
        "ytick.labelsize":    8,
    })


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def _samples_by_env(
    df: pd.DataFrame, variant: str, workload: str, metric: str,
    envs: Sequence[str],
) -> Dict[str, List[float]]:
    samples: Dict[str, List[float]] = {}
    for env in envs:
        sub = df[(df["env"] == env)
                 & (df["variant"] == variant)
                 & (df["workload"] == workload)]
        if sub.empty:
            continue
        vals = sub[metric].dropna().tolist()
        if vals:
            samples[env] = vals
    return samples


def build_summary(
    df: pd.DataFrame, variants: Sequence[str], envs: Sequence[str],
    workloads: Sequence[str], metrics: Sequence[str],
) -> pd.DataFrame:
    rows = []
    for variant in variants:
        for workload in workloads:
            for metric in metrics:
                for env in envs:
                    sub = df[(df["env"] == env)
                             & (df["variant"] == variant)
                             & (df["workload"] == workload)]
                    n_rows = len(sub)
                    if n_rows == 0:
                        continue
                    vals = sub[metric].dropna().to_numpy(dtype=float)
                    n = vals.size
                    missing_pct = 100.0 * (n_rows - n) / max(1, n_rows)
                    if n == 0:
                        rows.append({
                            "env": env, "variant": variant, "workload": workload,
                            "metric": metric, "n": 0,
                            "mean": float("nan"), "stdev": float("nan"),
                            "median": float("nan"), "q25": float("nan"),
                            "q75": float("nan"), "missing_pct": missing_pct,
                        })
                        continue
                    rows.append({
                        "env": env, "variant": variant, "workload": workload,
                        "metric": metric, "n": n,
                        "mean": float(np.mean(vals)),
                        "stdev": float(np.std(vals, ddof=1)) if n > 1 else 0.0,
                        "median": float(np.median(vals)),
                        "q25": float(np.percentile(vals, 25)),
                        "q75": float(np.percentile(vals, 75)),
                        "missing_pct": missing_pct,
                    })
    return pd.DataFrame(rows)


def build_availability(
    df: pd.DataFrame, variants: Sequence[str], envs: Sequence[str],
    workloads: Sequence[str], metrics: Sequence[str],
) -> pd.DataFrame:
    rows = []
    for env in envs:
        for variant in variants:
            for workload in workloads:
                for metric in metrics:
                    sub = df[(df["env"] == env)
                             & (df["variant"] == variant)
                             & (df["workload"] == workload)]
                    n_samples = int(sub[metric].dropna().size)
                    status = "OK" if n_samples >= 1 else "missing"
                    rows.append({
                        "env": env, "variant": variant, "workload": workload,
                        "metric": metric, "n_samples": n_samples,
                        "status": status,
                    })
    return pd.DataFrame(rows)


def build_stats(
    df: pd.DataFrame, variants: Sequence[str], envs: Sequence[str],
    workloads: Sequence[str], metrics: Sequence[str], alpha: float,
) -> pd.DataFrame:
    rows = []
    for variant in variants:
        for workload in workloads:
            for metric in metrics:
                samples = _samples_by_env(df, variant, workload, metric, envs)
                usable = {e: v for e, v in samples.items() if len(v) >= 2}
                if len(usable) < 2:
                    rows.append({
                        "variant": variant, "workload": workload, "metric": metric,
                        "n_envs": len(usable),
                        "kw_stat": float("nan"), "kw_p": float("nan"),
                        "kw_signif": "n/a",
                    })
                    continue
                env_order = [e for e in envs if e in usable]
                vectors = [np.asarray(usable[e], dtype=float) for e in env_order]
                try:
                    kw_stat, kw_p = kruskal(*vectors)
                except ValueError:
                    kw_stat, kw_p = float("nan"), float("nan")
                row = {
                    "variant": variant, "workload": workload, "metric": metric,
                    "n_envs": len(env_order),
                    "kw_stat": float(kw_stat), "kw_p": float(kw_p),
                    "kw_signif": signif_marker(kw_p, alpha),
                }
                pairs = list(itertools.combinations(env_order, 2))
                bonf_threshold = alpha / max(1, len(pairs)) if pairs else alpha
                run_pairwise = np.isfinite(kw_p) and kw_p < alpha
                for a, b in pairs:
                    key = f"{a}_vs_{b}"
                    if run_pairwise:
                        try:
                            mw_stat, mw_p = mannwhitneyu(
                                usable[a], usable[b], alternative="two-sided"
                            )
                        except ValueError:
                            mw_stat, mw_p = float("nan"), float("nan")
                        delta, mag = cliffs_delta(usable[a], usable[b])
                        row[f"mw_stat_{key}"] = float(mw_stat)
                        row[f"mw_p_{key}"] = float(mw_p)
                        row[f"mw_signif_{key}"] = signif_marker(mw_p, bonf_threshold)
                        row[f"cliffs_delta_{key}"] = float(delta)
                        row[f"cliffs_mag_{key}"] = mag
                    else:
                        row[f"mw_stat_{key}"] = float("nan")
                        row[f"mw_p_{key}"] = float("nan")
                        row[f"mw_signif_{key}"] = "skip"
                        row[f"cliffs_delta_{key}"] = float("nan")
                        row[f"cliffs_mag_{key}"] = "skip"
                rows.append(row)
    return pd.DataFrame(rows)


def render_panels(
    df: pd.DataFrame, variant: str, workload: str, envs: Sequence[str],
    metrics: Sequence[str], stats_df: pd.DataFrame, alpha: float,
    outpath: Path,
) -> bool:
    """Render one PNG for (variant, workload) with one panel per metric.
       Returns False if no env had data for any metric (caller may skip)."""
    n = len(metrics)
    ncols = min(4, n)
    nrows = int(np.ceil(n / ncols))
    w, h = _clamp_figsize(3.4 * ncols, 2.6 * nrows + 0.6)
    fig, axes = plt.subplots(nrows, ncols, figsize=(w, h), squeeze=False)
    any_data = False
    for i, metric in enumerate(metrics):
        ax = axes[i // ncols][i % ncols]
        samples = _samples_by_env(df, variant, workload, metric, envs)
        present_envs = [e for e in envs if e in samples and len(samples[e]) > 0]
        if not present_envs:
            ax.set_title(f"{metric} (no data)", fontsize=9)
            ax.set_xticks([])
            ax.set_yticks([])
            continue
        any_data = True
        data = [samples[e] for e in present_envs]
        bp = ax.boxplot(
            data, vert=False, showfliers=False, patch_artist=True,
        )
        ax.set_yticks(list(range(1, len(present_envs) + 1)))
        ax.set_yticklabels(present_envs)
        for patch in bp["boxes"]:
            patch.set_facecolor("#cfd8dc")
            patch.set_alpha(0.7)
        row = stats_df[(stats_df["variant"] == variant)
                       & (stats_df["workload"] == workload)
                       & (stats_df["metric"] == metric)]
        sig = row["kw_signif"].iloc[0] if not row.empty else "n/a"
        kw_p = row["kw_p"].iloc[0] if not row.empty else float("nan")
        title = f"{metric}  KW {sig}"
        if np.isfinite(kw_p):
            title += f"  (p={kw_p:.3g})"
        ax.set_title(title, fontsize=9)
        ax.set_xlabel("value")
    # Hide unused axes
    for j in range(n, nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")
    fig.suptitle(f"{variant_label(variant)} · {workload}", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    if not any_data:
        plt.close(fig)
        return False
    # outpath is conventionally <plots_dir>/<variant>/<stem>.png. We split
    # the format prefix in so the caller-side caller stays unchanged but
    # we emit one file per configured FORMATS entry under
    # <plots_dir>/<format>/<variant>/<stem>.<format>.
    plots_dir = outpath.parent.parent
    variant_sub = outpath.parent.name
    stem = outpath.stem
    for fmt in FORMATS:
        fmt_dir = plots_dir / fmt / variant_sub
        fmt_dir.mkdir(parents=True, exist_ok=True)
        fig.savefig(fmt_dir / f"{stem}.{fmt}", bbox_inches="tight")
    plt.close(fig)
    return True


# ---------------------------------------------------------------------------
# README
# ---------------------------------------------------------------------------

README_TEMPLATE = """# cross-env comparison

Generated by `bench/plot/plot-cross-environment.py` from
`aggregate-means.tsv` produced by `bench/run-intp-bench.sh`.

## Files

- `summary.tsv` — per (env, variant, workload, metric) descriptive stats
  (n, mean, stdev, median, q25, q75, missing_pct). `missing_pct` is the
  share of reps for this (env, variant, workload) where the metric column
  was `--` in `aggregate-means.tsv`.
- `availability.tsv` — same key but lighter: status is `OK` if the metric
  has at least one numeric sample across all reps of that
  (env, variant, workload), else `missing`. Use this to identify cells the
  profiler couldn't capture in a given env (e.g. RDT metrics inside a
  guest without vRDT pass-through).
- `stats.tsv` — for each (variant, workload, metric):
  - `kw_stat`, `kw_p`, `kw_signif`: Kruskal-Wallis omnibus across envs
    with n>=2. `kw_signif` annotates the p-value against alpha={alpha}:
    `*` < alpha, `**` < alpha/5, `***` < alpha/50.
  - For each pair `(a, b)` of envs:
    - `mw_stat_a_vs_b`, `mw_p_a_vs_b`, `mw_signif_a_vs_b`: Mann-Whitney U
      two-sided. Significance is Bonferroni-corrected: alpha_pair =
      alpha / num_pairs. Pairwise tests are run only when the KW omnibus
      is significant; otherwise the field is `skip`.
    - `cliffs_delta_a_vs_b`, `cliffs_mag_a_vs_b`: Cliff's delta with the
      Vargha-Delaney magnitude classification (negligible <0.147,
      small <0.33, medium <0.474, large >=0.474).
- `plots/<variant>/<workload>.png` — one figure per (variant, workload)
  with one panel per metric. Each panel is a horizontal boxplot, one box
  per env, with the KW significance code in the panel title.

## Method

Non-parametric: profiler metrics are skewed (saturable, event counts)
and per-rep n is small; the normality assumption that underpins ANOVA
is not defensible here. Kruskal-Wallis followed by Mann-Whitney pairs
preserves interpretability without assuming a distribution. Cliff's
delta provides an effect size that is also distribution-free.

Bonferroni correction (alpha/num_pairs) is the conservative choice and
matches the small number of envs we compare here. For larger env sets
consider switching to Holm-Bonferroni or BH-FDR upstream.
"""


# ---------------------------------------------------------------------------
# CLI / driver
# ---------------------------------------------------------------------------

def parse_csv_arg(value: str | None) -> List[str] | None:
    if value is None:
        return None
    return [v.strip() for v in value.split(",") if v.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Cross-environment statistical comparison from "
                    "aggregate-means.tsv.",
    )
    ap.add_argument("campaign_dir", type=Path,
                    help="Campaign directory containing bench-full/aggregate-means.tsv")
    ap.add_argument("--variants", type=str, default=None,
                    help="CSV of variants to compare (default: all in TSV)")
    ap.add_argument("--envs", type=str, default=None,
                    help="CSV of envs to compare (default: all in TSV)")
    ap.add_argument("--workloads", type=str, default=None,
                    help="CSV of workloads to compare (default: all in TSV)")
    ap.add_argument("--metrics", type=str, default=None,
                    help=f"CSV of metrics (default: {','.join(METRICS)})")
    ap.add_argument("--stage", type=str, default="solo",
                    help="Stage to filter on (default: solo)")
    ap.add_argument("--alpha", type=float, default=0.05,
                    help="Significance threshold (default: 0.05)")
    ap.add_argument("--output-subdir", type=str, default="cross-env",
                    help="Output subdirectory under bench-full/ (default: cross-env)")
    ap.add_argument("--formats", type=str, default="png,pdf",
                    help="Comma-separated output formats (default: png,pdf). "
                         "Each format is written under plots/<format>/<variant>/.")
    args = ap.parse_args()
    global FORMATS
    FORMATS = [f.strip() for f in args.formats.split(",") if f.strip()] or ["png"]

    camp = args.campaign_dir.resolve()
    if not camp.exists():
        sys.exit(f"campaign-dir does not exist: {camp}")

    # Accept either the campaign root or the bench-full subdir directly.
    bench_full = camp if (camp / "aggregate-means.tsv").exists() else (camp / "bench-full")
    agg = bench_full / "aggregate-means.tsv"
    if not agg.exists():
        sys.exit(
            f"aggregate-means.tsv not found at {agg}; "
            f"run bench/run-intp-bench.sh ... --stage report first"
        )

    df = load_aggregate_means(agg)
    if args.stage:
        df = df[df["stage"] == args.stage]
    if df.empty:
        sys.exit(f"no rows in aggregate-means.tsv for stage={args.stage!r}")

    envs = parse_csv_arg(args.envs) or sorted(df["env"].unique().tolist())
    variants = parse_csv_arg(args.variants) or sorted(df["variant"].unique().tolist())
    workloads = parse_csv_arg(args.workloads) or sorted(df["workload"].unique().tolist())
    metrics = parse_csv_arg(args.metrics) or list(METRICS)
    bad_metrics = [m for m in metrics if m not in METRICS]
    if bad_metrics:
        sys.exit(f"unknown metrics: {bad_metrics}; supported: {METRICS}")

    outdir = bench_full / args.output_subdir
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"[cross-env] envs={envs} variants={variants} "
          f"workloads={len(workloads)} metrics={metrics} stage={args.stage}")

    summary = build_summary(df, variants, envs, workloads, metrics)
    summary.to_csv(outdir / "summary.tsv", sep="\t", index=False,
                   float_format="%.6g")
    print(f"[cross-env] wrote {outdir / 'summary.tsv'} ({len(summary)} rows)")

    availability = build_availability(df, variants, envs, workloads, metrics)
    availability.to_csv(outdir / "availability.tsv", sep="\t", index=False)
    print(f"[cross-env] wrote {outdir / 'availability.tsv'} "
          f"({len(availability)} rows)")

    stats_df = build_stats(df, variants, envs, workloads, metrics, args.alpha)
    stats_df.to_csv(outdir / "stats.tsv", sep="\t", index=False,
                    float_format="%.6g")
    print(f"[cross-env] wrote {outdir / 'stats.tsv'} ({len(stats_df)} rows)")

    _setup_style()
    plots_dir = outdir / "plots"
    n_png = 0
    for variant in variants:
        for workload in workloads:
            png = plots_dir / variant / f"{workload}.png"
            if render_panels(df, variant, workload, envs, metrics, stats_df,
                             args.alpha, png):
                n_png += 1
    print(f"[cross-env] wrote {n_png} figures × {len(FORMATS)} formats "
          f"({','.join(FORMATS)}) under {plots_dir}")

    readme = outdir / "README.md"
    readme.write_text(README_TEMPLATE.format(alpha=args.alpha))
    print(f"[cross-env] wrote {readme}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

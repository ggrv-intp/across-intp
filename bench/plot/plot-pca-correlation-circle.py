#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-pca-correlation-circle.py — PCA biplot for the IntP variant comparison.
#
# Single-figure output with two panels:
#   (A) Correlation circle — each metric is drawn as an arrow on the unit
#       circle. Arrow coordinates are the Pearson correlations with PC1/PC2,
#       so collinear arrows expose feature redundancy (e.g., llcocc vs mbw).
#   (B) Individuals (scores) factor map — every (variant, workload, stage)
#       centroid projected onto PC1/PC2 and coloured by variant. Optional
#       polygons connect the variant centroids belonging to the same
#       workload×stage so that variant convergence is visible per workload:
#       a tight polygon = the variants agree, a sprawled polygon = they
#       disagree on that workload.
#
# Why a single figure: this is meant as one publication-grade figure for the
# SBAC-PAD short paper, defending two simultaneous claims —
#   (1) the IntP variants converge in metric space (instrumentation choice
#       is not the dominant signal); and
#   (2) the seven metrics are not orthogonal (Meyer-style redundancy between
#       cache occupancy and memory bandwidth, etc.).
#
# Generic by design — reads any aggregate-means.{tsv,csv} produced by
# bench/run-big-batch.sh regardless of which variants/envs are present.
#
# Run:
#   python3 plot-pca-correlation-circle.py \
#       /path/to/results/<campaign>/bench-full/aggregate-means.tsv
#
# Common knobs:
#   --env bare              env to filter on (default: bare)
#   --variants v0,v1,v2,v3  restrict to a subset (default: all available)
#   --min-samples 20        drop variants with fewer rows than this
#   --features cpu,mbw,...  override the default 7-metric set
#   --no-polygons           disable per-workload convergence polygons
#   --output FIG.png        custom output path (default: alongside input)
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Circle
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas scikit-learn")

try:
    from sklearn.decomposition import PCA
    from sklearn.preprocessing import StandardScaler
except ImportError:
    sys.exit("scikit-learn is required: pip install scikit-learn")


# Default 7-metric set used by run-big-batch.sh / plot-intp-bench.py.
DEFAULT_METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]

# Resource-family colours kept in sync with plot-intp-bench.py so that the
# SBAC-PAD figures are visually coherent.
METRIC_COLORS = {
    "netp":   "#e377c2",
    "nets":   "#9467bd",
    "blk":    "#2ca02c",
    "mbw":    "#1f77b4",
    "llcmr":  "#d62728",
    "llcocc": "#ff7f0e",
    "cpu":    "#000000",
}
METRIC_LABEL = {
    "netp":   "netp (net phys.)",
    "nets":   "nets (net stack)",
    "blk":    "blk (disk)",
    "mbw":    "mbw (memory)",
    "llcmr":  "llcmr (LLC miss)",
    "llcocc": "llcocc (cache)",
    "cpu":    "cpu",
}

VARIANT_ORDER = ["v0", "v0.1", "v0.2", "v1", "v1.1", "v2", "v3.1", "v3", "v3.2"]
VARIANT_COLORS = {
    "v0":   "#7f7f7f",
    "v0.1": "#bcbd22",
    "v0.2": "#707070",  # medium-strong gray
    "v1":   "#17becf",
    "v1.1": "#9467bd",  # purple (distinct from v2 blue)
    "v2":   "#1f77b4",
    "v3.1": "#ff7f0e",
    "v3":   "#2ca02c",
    "v3.2": "#d62728",
}

# Descriptive, paper-facing variant names. Figures show these instead of the
# bare vN tags so a reader need not consult the variant table to know what a
# panel measures. Canonical map: VERSIONS.md. The four measured versions are
# stap-legacy (v0.2), stap-modern (v1.1), hybrid-c (v2) and ebpf-agg (v3.2).
VARIANT_LABELS = {
    "v0":   "stap-2022",
    "v0.1": "stap-nollc",
    "v0.2": "stap-legacy",
    "v1":   "stap-nohelper",
    "v1.1": "stap-modern",
    "v2":   "hybrid-c",
    "v2.1": "cgroup-native",
    "v3":   "ebpf-ring",
    "v3.1": "bpftrace",
    "v3.2": "ebpf-agg",
    "v3.3": "ebpf-cgroup",
}


def variant_label(v):
    """Paper-facing descriptive name for a dataset variant tag."""
    return VARIANT_LABELS.get(str(v), str(v))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", type=Path,
                   help="Path to aggregate-means.tsv (or .csv) from a campaign.")
    p.add_argument("--env", default="bare",
                   help="env value to keep (default: bare). Pass 'all' to keep every env.")
    p.add_argument("--variants", default=None,
                   help="Comma-separated variant whitelist (post-rename names). "
                        "Default: every variant present.")
    p.add_argument("--min-samples", type=int, default=20,
                   help="Drop variants with fewer than this many rows after filtering "
                        "(default: 20). Protects against variants with too few valid "
                        "rows to support a meaningful projection.")
    p.add_argument("--features", default=",".join(DEFAULT_METRICS),
                   help="Comma-separated metric column whitelist.")
    p.add_argument("--no-polygons", action="store_true",
                   help="Disable per-workload convergence polygons on panel B.")
    p.add_argument("--output", type=Path, default=None,
                   help="Output path stem. Default: <input-dir>/plots/fig_pca_correlation_circle "
                        "(extension is taken from --formats; emitted under plots/<format>/).")
    p.add_argument("--formats", type=str, default="png,pdf",
                   help="Comma-separated output formats (default: png,pdf). "
                        "Each format is written under the parent dir's <format>/ subdir.")
    return p.parse_args()


def load_aggregate(path: Path) -> pd.DataFrame:
    """Load aggregate-means.{tsv,csv}."""
    sep = "\t" if path.suffix.lower() == ".tsv" else ","
    df = pd.read_csv(path, sep=sep, na_values=["--", "NA", ""])
    required = {"env", "variant", "stage", "workload"}
    missing = required - set(df.columns)
    if missing:
        sys.exit(f"input is missing required columns: {sorted(missing)}")
    return df


def filter_data(df: pd.DataFrame, env: str, variants: list[str] | None,
                min_samples: int, features: list[str]) -> pd.DataFrame:
    """Keep only the rows useful for PCA: chosen env, instrumented variants,
    no missing values in the feature set."""
    if env != "all":
        df = df[df["env"] == env]
    # The 'bare' label inside the variant column means "no instrumentation
    # active" — it is a reference, not a variant being characterised.
    df = df[df["variant"] != "bare"]
    if variants:
        df = df[df["variant"].isin(variants)]
    df = df.dropna(subset=features)
    counts = df["variant"].value_counts()
    keep = counts[counts >= min_samples].index.tolist()
    dropped = sorted(set(counts.index) - set(keep))
    if dropped:
        print(f"[filter] dropping sparse variants {dropped} "
              f"(<{min_samples} rows): counts={counts[dropped].to_dict()}")
    df = df[df["variant"].isin(keep)]
    if df.empty:
        sys.exit("no rows left after filtering — check --env/--variants/--min-samples")
    return df


def aggregate_centroids(df: pd.DataFrame, features: list[str]) -> pd.DataFrame:
    """Mean per (variant, workload, stage) over reps. One centroid per
    instrumentation variant per workload×stage cell."""
    return (df.groupby(["variant", "workload", "stage"])[features]
              .mean()
              .reset_index())


def fit_pca(centroids: pd.DataFrame, features: list[str]):
    """Standardise features and fit a 2-component PCA. Returns the fitted
    scaler, PCA, and the projected scores (n × 2)."""
    X = centroids[features].to_numpy()
    scaler = StandardScaler()
    Xs = scaler.fit_transform(X)
    pca = PCA(n_components=2)
    scores = pca.fit_transform(Xs)
    return scaler, pca, scores


def feature_correlations(pca: PCA, features: list[str]) -> np.ndarray:
    """Pearson correlations of each feature with PC1, PC2. For a PCA fit on
    z-scored data, this is components_ × sqrt(eigenvalues)."""
    eigvals = pca.explained_variance_  # variance of each PC
    return (pca.components_.T * np.sqrt(eigvals))  # (n_features, 2)


def convergence_metric(centroids: pd.DataFrame, scores: np.ndarray) -> float:
    """Mean per-workload variant spread divided by the global spread, in
    PC1/PC2 space. Closer to 0 means the variants agree per workload, ~1
    means variant choice dominates the workload signal."""
    df = centroids.copy()
    df["pc1"] = scores[:, 0]
    df["pc2"] = scores[:, 1]
    per_cell = df.groupby(["workload", "stage"])
    intra = per_cell[["pc1", "pc2"]].apply(
        lambda g: float(np.linalg.norm(g.std(ddof=0).fillna(0)))
    )
    global_spread = float(np.linalg.norm(df[["pc1", "pc2"]].std(ddof=0)))
    if global_spread <= 0:
        return float("nan")
    return float(intra.mean() / global_spread)


def setup_style() -> None:
    plt.rcParams.update({
        "figure.dpi":         110,
        "savefig.dpi":        130,
        "font.family":        "DejaVu Sans",
        "font.size":          9.5,
        "axes.titlesize":     10.5,
        "axes.labelsize":     9.5,
        "axes.spines.top":    False,
        "axes.spines.right":  False,
        "axes.grid":          True,
        "grid.linestyle":     ":",
        "grid.alpha":         0.4,
        "legend.fontsize":    8,
        "legend.frameon":     False,
    })


def plot_correlation_circle(ax, corr: np.ndarray, features: list[str],
                             evr: np.ndarray) -> None:
    ax.add_patch(Circle((0, 0), 1.0, fill=False, edgecolor="#444", lw=1.0))
    ax.add_patch(Circle((0, 0), 0.5, fill=False, edgecolor="#bbb", lw=0.6,
                        linestyle=":"))
    for i, feat in enumerate(features):
        x, y = corr[i, 0], corr[i, 1]
        color = METRIC_COLORS.get(feat, "#333333")
        ax.annotate("", xy=(x, y), xytext=(0, 0),
                    arrowprops=dict(arrowstyle="-|>", color=color, lw=1.6,
                                    shrinkA=0, shrinkB=0))
        # Place the label slightly past the arrowhead.
        norm = np.hypot(x, y)
        offset = 0.08 if norm > 0.05 else 0.0
        lx = x * (1 + offset / max(norm, 1e-3))
        ly = y * (1 + offset / max(norm, 1e-3))
        ha = "left" if x >= 0 else "right"
        va = "bottom" if y >= 0 else "top"
        ax.text(lx, ly, METRIC_LABEL.get(feat, feat),
                color=color, ha=ha, va=va, fontsize=8.5,
                fontweight="bold")
    ax.axhline(0, color="gray", lw=0.5, linestyle=":")
    ax.axvline(0, color="gray", lw=0.5, linestyle=":")
    ax.set_xlim(-1.15, 1.15)
    ax.set_ylim(-1.15, 1.15)
    ax.set_aspect("equal")
    ax.set_xlabel(f"PC1 ({evr[0]*100:.1f}%)")
    ax.set_ylabel(f"PC2 ({evr[1]*100:.1f}%)")
    ax.set_title("(A) Correlation circle — feature loadings")


def plot_scores(ax, centroids: pd.DataFrame, scores: np.ndarray,
                evr: np.ndarray, draw_polygons: bool, conv: float) -> None:
    df = centroids.copy()
    df["pc1"] = scores[:, 0]
    df["pc2"] = scores[:, 1]
    variants_present = [v for v in VARIANT_ORDER if v in df["variant"].unique()]
    variants_present += sorted(set(df["variant"]) - set(variants_present))

    if draw_polygons:
        for (_, _), cell in df.groupby(["workload", "stage"]):
            if len(cell) < 2:
                continue
            pts = cell[["pc1", "pc2"]].to_numpy()
            # Order by polar angle around the centroid so the polygon edges
            # don't self-cross when ≥3 variants are present.
            ctr = pts.mean(axis=0)
            order = np.argsort(np.arctan2(pts[:, 1] - ctr[1],
                                          pts[:, 0] - ctr[0]))
            ordered = pts[order]
            poly = np.vstack([ordered, ordered[:1]])
            ax.plot(poly[:, 0], poly[:, 1],
                    color="#888888", lw=0.4, alpha=0.4, zorder=1)

    for variant in variants_present:
        sub = df[df["variant"] == variant]
        color = VARIANT_COLORS.get(variant, "#333333")
        ax.scatter(sub["pc1"], sub["pc2"],
                   s=42, color=color, edgecolor="black", lw=0.4,
                   alpha=0.85, label=f"{variant_label(variant)}  (n={len(sub)})",
                   zorder=2)

    ax.axhline(0, color="gray", lw=0.5, linestyle=":")
    ax.axvline(0, color="gray", lw=0.5, linestyle=":")
    ax.set_xlabel(f"PC1 ({evr[0]*100:.1f}%)")
    ax.set_ylabel(f"PC2 ({evr[1]*100:.1f}%)")
    title = "(B) Variant centroids per workload×stage"
    if not np.isnan(conv):
        title += f"\nintra-workload spread / global spread = {conv:.3f}"
    ax.set_title(title)
    ax.legend(loc="best", title="Variant", fontsize=8, title_fontsize=9)


def main() -> None:
    args = parse_args()
    setup_style()

    features = [f.strip() for f in args.features.split(",") if f.strip()]
    variants = ([v.strip() for v in args.variants.split(",") if v.strip()]
                if args.variants else None)

    df = load_aggregate(args.input)
    df = filter_data(df, args.env, variants, args.min_samples, features)
    centroids = aggregate_centroids(df, features)
    print(f"[pca] fitting on {len(centroids)} centroids "
          f"({df['variant'].nunique()} variants × "
          f"{centroids[['workload','stage']].drop_duplicates().shape[0]} workload×stage cells)")

    _, pca, scores = fit_pca(centroids, features)
    corr = feature_correlations(pca, features)
    conv = convergence_metric(centroids, scores)
    evr = pca.explained_variance_ratio_
    print(f"[pca] explained variance: PC1={evr[0]*100:.2f}%  PC2={evr[1]*100:.2f}%  "
          f"sum={evr.sum()*100:.2f}%")
    print(f"[pca] convergence metric (intra-workload / global) = {conv:.3f}")

    fig, (axA, axB) = plt.subplots(1, 2, figsize=(13.0, 5.6))
    plot_correlation_circle(axA, corr, features, evr)
    plot_scores(axB, centroids, scores, evr,
                draw_polygons=not args.no_polygons, conv=conv)
    fig.suptitle("PCA of IntP variants in metric space  "
                 f"(env={args.env}, {len(features)} metrics)",
                 y=1.02, fontsize=11.5)
    fig.tight_layout()

    formats = [f.strip() for f in args.formats.split(",") if f.strip()] or ["png"]
    out = args.output
    if out is None:
        plots_dir = args.input.parent / "plots"
        out = plots_dir / "fig_pca_correlation_circle.png"
    base_dir = out.parent
    stem = out.stem
    written = []
    for fmt in formats:
        sub = base_dir / fmt
        sub.mkdir(parents=True, exist_ok=True)
        path = sub / f"{stem}.{fmt}"
        fig.savefig(path, bbox_inches="tight")
        written.append(str(path))
    plt.close(fig)
    print("[done] " + "  ".join(written))


if __name__ == "__main__":
    main()

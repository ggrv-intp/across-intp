#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-hibench.py — Compare IntP variants across HiBench Spark workloads.
#
# Reproduces the visual structure of the original IntP paper (Xavier et al.,
# 2022) and the IADA paper (Meyer et al., 2022) for the new HiBench
# experiment context, where the comparison axis is variant × profile.
#
# Inputs:  a directory containing one or more hibench run subdirs, each with
#          metadata.env, aggregate-means.tsv, and per-rep profiler.tsv files.
#
# Figures (paper reference in parens):
#   fig00_canonical_intp_fig4_<P>.png (IntP Fig. 4 canonical) one PNG per
#                                              profile, variants side-by-side
#   fig01_fingerprint_<P>.png    one PNG per profile, variants side-by-side
#   fig02_sensitivity_<P>.png    Δ(<P> − standard) per variant; one PNG per
#                                non-standard profile present (under the
#                                all-stress sweep this emits one per pressure
#                                profile: cpu/mem/cache/disk/netp/nets-extreme)
#   fig03_metric_compare_<M>.png one PNG per metric, profiles side-by-side
#   fig04_per_workload_bars.png  (IntP Fig. 4)  one panel per workload, bars =
#                                              variants × metrics
#   fig05_radar_fingerprint.png  (IntP Fig. 4 alt) per-workload radar
#   fig06_pca_workloads.png      (IntP Fig. 5)  PCA of workloads per profile
#   fig07_timeseries.png         (IntP Fig. 3 / IADA Fig. 5) smoothed traces
#   fig08_hibench_coverage.png   (paper Fig. 6) per-variant normalized
#                                metric coverage heatmap
#   fig08_idi_bars.png           (IADA Fig. 6) Δ resource per profile
#   fig09_resource_timeseries.png (IntP Fig. 8) resource-family lines
#   fig10_variant_resource_heatmap.png (new)   variants × resources summary
#   fig11_metric_availability.png (new) binary ✓/— availability per (variant,metric)
#   fig12_workload_clustermap.png (new) Ward-linkage workload clustermap
#
# All output PNGs are sized so neither side exceeds ~1900 px (downstream
# image readers reject ≥ 2000 px assets).
#
# Run:
#   python3 bench/plot/plot-hibench.py results/<batch>/hibench
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas scikit-learn")

try:
    from sklearn.decomposition import PCA
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    warnings.warn("scikit-learn not installed — PCA figure will be skipped")

try:
    from scipy.cluster.hierarchy import leaves_list, linkage
    from matplotlib.colors import ListedColormap
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
    warnings.warn("scipy not installed — workload clustermap will be skipped")

# ---------------------------------------------------------------------------
# Constants — palette aligned with IntP/IADA paper conventions
# ---------------------------------------------------------------------------

VARIANT_ORDER = ["v0", "v0.1", "v0.2", "v1", "v1.1", "v2", "v3.1", "v3", "v3.2"]
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
# Profiles accepted by run-hibench-subset.sh. Keep "standard" first (it is the
# baseline reference for the sensitivity figure); the rest are co-runner
# pressure variants the all-stress sweep emits.
PROFILE_ORDER = [
    "standard",
    "cpu-extreme", "mem-extreme", "cache-extreme",
    "disk-extreme", "netp-extreme", "nets-extreme",
]
PROFILE_LABEL = {p: p for p in PROFILE_ORDER}
WORKLOAD_ORDER = ["kmeans", "bayes", "pagerank", "terasort", "wordcount",
                  "sql", "join", "scan", "aggregation", "lr", "rf"]
METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
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
    "netp":   "netp", "nets":   "nets", "blk":    "blk",
    "mbw":    "mbw",  "llcmr":  "llcmr", "llcocc": "llcocc", "cpu":    "cpu",
}
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
PROFILE_HATCH = {
    "standard":      "",
    "cpu-extreme":   "..",
    "mem-extreme":   "xx",
    "cache-extreme": "++",
    "disk-extreme":  "\\\\",
    "netp-extreme":  "//",
    "nets-extreme":  "--",
}

# Logical resource families used by IntP Fig. 8 / IADA Fig. 5 / Fig. 6
RESOURCE_FAMILY = {
    "cache":   ["llcocc", "llcmr"],
    "cpu":     ["cpu"],
    "disk":    ["blk"],
    "memory":  ["mbw"],
    "network": ["netp", "nets"],
}
RESOURCE_COLORS = {
    "cache":   "#ff7f0e",
    "cpu":     "#000000",
    "disk":    "#2ca02c",
    "memory":  "#1f77b4",
    "network": "#e377c2",
}


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

# Raised together so the inch-clamp keeps the same figure proportions while
# every raster gets ~1.4x more pixels (matches plot-intp-bench.py).
MAX_PIXELS = 3600
SAVE_DPI = 220


def _clamp_figsize(width: float, height: float) -> tuple[float, float]:
    max_in = MAX_PIXELS / SAVE_DPI
    scale = min(1.0, max_in / max(width, 1e-9), max_in / max(height, 1e-9))
    return width * scale, height * scale


def _rglob_profiler(run_dir: Path):
    """rglob('profiler.tsv') that follows symlinked variant dirs.

    Python 3.13+ supports the recurse_symlinks kwarg; older versions need
    an os.walk-based fallback so merged dirs (where bare/<variant> is a
    symlink to another run's tree) still surface their profiler.tsv files."""
    try:
        return run_dir.rglob("profiler.tsv", recurse_symlinks=True)
    except TypeError:
        import os
        out = []
        for root, _, files in os.walk(run_dir, followlinks=True):
            for f in files:
                if f == "profiler.tsv":
                    out.append(Path(root) / f)
        return out


def setup_style() -> None:
    plt.rcParams.update({
        "figure.dpi":         110,
        "savefig.dpi":        SAVE_DPI,
        "font.family":        "DejaVu Sans",
        "font.size":          9.5,
        "axes.titlesize":     10,
        "axes.labelsize":     9.5,
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


FORMATS: list[str] = ["png", "pdf"]


def _save(fig, path: Path, label: str) -> None:
    """Save figure to each configured format under <path.parent>/<format>/.

    See plot-intp-bench._save for the contract — same multi-format scheme
    so paper-bound PDFs and README-friendly PNGs coexist."""
    base_dir = path.parent
    stem = path.stem
    written = []
    for fmt in FORMATS:
        sub = base_dir / fmt
        sub.mkdir(parents=True, exist_ok=True)
        out = sub / f"{stem}.{fmt}"
        fig.savefig(out, bbox_inches="tight")
        written.append(f"{fmt}/{out.name}")
    plt.close(fig)
    print(f"[{label}] " + "  ".join(written))


def _ordered_variants(values) -> list[str]:
    present = set(values)
    return [v for v in VARIANT_ORDER if v in present]


def _ordered_workloads(values) -> list[str]:
    present = set(values)
    canonical = [w for w in WORKLOAD_ORDER if w in present]
    extra = sorted(present - set(canonical))
    return canonical + extra


def _grid_dims(n: int) -> tuple[int, int]:
    # Prefer square at n=4 (2x2 instead of 1x3 + stranded last row).
    if n <= 0: return (1, 1)
    if n == 1: return (1, 1)
    if n == 2: return (1, 2)
    if n == 3: return (1, 3)
    if n == 4: return (2, 2)
    cols = 5 if n >= 10 else 3
    rows = (n + cols - 1) // cols
    return (rows, cols)


def _make_axes_grid(fig, n: int, sharey: bool = False, polar: bool = False,
                    wspace: float = 0.9,
                    hspace: float = 0.6) -> tuple[list, int, int]:
    """Place n axes via gridspec; if the last row is partial, center it."""
    nrows, ncols = _grid_dims(n)
    gs = fig.add_gridspec(nrows, 2 * ncols, wspace=wspace, hspace=hspace)
    axes: list = []
    base_y = None
    for i in range(n):
        r = i // ncols
        c_in_row = i % ncols
        last_row_n = n - r * ncols
        if r == nrows - 1 and last_row_n < ncols:
            offset = ncols - last_row_n
            col_start = offset + c_in_row * 2
        else:
            col_start = c_in_row * 2
        kw: dict = {}
        if polar:
            kw["projection"] = "polar"
        if sharey and base_y is not None:
            kw["sharey"] = base_y
        ax = fig.add_subplot(gs[r, col_start:col_start + 2], **kw)
        if sharey and base_y is None:
            base_y = ax
        axes.append(ax)
    return axes, nrows, ncols


def _centered_suptitle(fig, axes, text, fontsize: float = 11,
                       gap_pixels: float = 12,
                       extra_artists=(),
                       **kwargs) -> None:
    """Centered, tight-gap suptitle. See `plot-intp-bench.py` for the full
    contract — same implementation, duplicated here because the two plot
    scripts are independent entry points. Pass `extra_artists` (e.g. a
    `fig.legend` strip placed above the panels) so the suptitle clears
    them too."""
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    visible = [ax for ax in axes if ax.get_visible()]
    if not visible:
        fig.suptitle(text, fontsize=fontsize, **kwargs)
        return
    pos = [ax.get_position() for ax in visible]
    x_mid = (min(p.x0 for p in pos) + max(p.x1 for p in pos)) / 2
    inv = fig.transFigure.inverted()
    bboxes = [ax.get_tightbbox(renderer) for ax in visible]
    bboxes += [a.get_window_extent(renderer) for a in extra_artists]
    bboxes = [b for b in bboxes if b is not None]
    top_frac = max(inv.transform((0, b.y1))[1] for b in bboxes)
    gap_frac = (inv.transform((0, gap_pixels))[1]
                - inv.transform((0, 0))[1])
    y = min(0.995, top_frac + gap_frac)
    fig.suptitle(text, x=x_mid, y=y, fontsize=fontsize, ha="center",
                 va="bottom", **kwargs)


def _legend_above_axes(fig, axes, handles, labels, *, ncol,
                       fontsize: float = 9, gap_pixels: float = 8,
                       title_reserve_pixels: float = 55,
                       **kwargs):
    """Place a horizontal legend strip directly above the tight bbox of
    `axes` (i.e. above per-panel subplot titles), centered on the axes'
    x-range. Automatically calls `subplots_adjust(top=…)` to push the
    panels down enough to fit the legend plus `title_reserve_pixels` of
    extra headroom for a suptitle. Returns the legend so the caller can
    pass it to `_centered_suptitle(..., extra_artists=[leg])`. Call
    after `fig.tight_layout()`."""
    # Estimate legend block height from font metrics rather than placing
    # the legend, measuring, and re-anchoring — Legend.set_loc lands
    # awkwardly on polar axes and older matplotlib lacks the API
    # entirely. fontsize ≈ pt; 1pt ≈ 1.333px at 96 DPI scales linearly
    # with the figure's save DPI. We use the figure's actual dpi here.
    n_lines = 2 if kwargs.get("title") else 1
    leg_h_pixels = n_lines * fontsize * (fig.dpi / 72.0) * 1.5 + 10
    fig_h_px = fig.get_size_inches()[1] * fig.dpi
    leg_h_frac = leg_h_pixels / fig_h_px
    gap_frac = gap_pixels / fig_h_px
    title_reserve_frac = title_reserve_pixels / fig_h_px
    reserve = leg_h_frac + gap_frac + title_reserve_frac
    current_top = fig.subplotpars.top
    new_top = max(0.55, min(current_top, 1.0 - reserve))
    fig.subplots_adjust(top=new_top)
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    inv = fig.transFigure.inverted()
    visible = [ax for ax in axes if ax.get_visible()]
    pos = [ax.get_position() for ax in visible]
    x_mid = (min(p.x0 for p in pos) + max(p.x1 for p in pos)) / 2
    tb = [ax.get_tightbbox(renderer) for ax in visible]
    top_frac = max(inv.transform((0, b.y1))[1]
                   for b in tb if b is not None)
    gap = inv.transform((0, gap_pixels))[1] - inv.transform((0, 0))[1]
    return fig.legend(handles, labels, loc="lower center",
                      bbox_to_anchor=(x_mid, top_frac + gap),
                      ncol=ncol, frameon=False, fontsize=fontsize,
                      **kwargs)


def _ordered_profiles(values) -> list[str]:
    present = set(values)
    return [p for p in PROFILE_ORDER if p in present]


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def _read_metadata(run_dir: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    mf = run_dir / "metadata.env"
    if mf.exists():
        for line in mf.read_text().splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                meta[k.strip()] = v.strip()
    return meta


def load_hibench_dir(hibench_dir: Path) -> tuple[pd.DataFrame, list[Path]]:
    """Collect all aggregate-means.tsv files. Also returns the list of run
    directories so callers can locate per-rep profiler.tsv traces."""
    frames: list[pd.DataFrame] = []
    run_dirs: list[Path] = []
    for subdir in sorted(hibench_dir.iterdir()):
        tsv = subdir / "aggregate-means.tsv"
        if not subdir.is_dir() or not tsv.exists():
            continue
        meta = _read_metadata(subdir)
        profile = meta.get("profile", subdir.name.split("-large-")[0])
        df = pd.read_csv(tsv, sep="\t")
        df["profile"] = profile
        frames.append(df)
        run_dirs.append(subdir)
    if not frames:
        sys.exit(f"No aggregate-means.tsv found under {hibench_dir}")
    merged = pd.concat(frames, ignore_index=True)
    merged = merged[merged["profile"].isin(PROFILE_ORDER)]
    for col in METRICS:
        if col in merged.columns:
            merged[col] = pd.to_numeric(merged[col], errors="coerce")
    return merged.reset_index(drop=True), run_dirs


def load_profiler_tsv(path: Path) -> pd.DataFrame:
    rows = []
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("ts") or line.startswith("netp"):
                continue
            parts = line.split()
            # 9 cols = ts + time_ms + 7 metrics (v1.1 leaks its internal time_ms
            # past the runner's awk wrapper); drop the time_ms column.
            if len(parts) == 9:
                ts = parts[0]; vals = parts[2:]
            elif len(parts) == 8:
                ts = parts[0]; vals = parts[1:]
            elif len(parts) == 7:
                ts = None; vals = parts
            else:
                continue
            rec = {"ts": float(ts) if ts else np.nan}
            for k, v in zip(METRICS, vals):
                try:
                    rec[k] = float(v)
                except (ValueError, TypeError):
                    rec[k] = np.nan
            rows.append(rec)
    return pd.DataFrame(rows)


def _smooth(arr: np.ndarray, window: int = 9) -> np.ndarray:
    if len(arr) < window:
        return arr
    kernel = np.ones(window) / window
    return np.convolve(arr, kernel, mode="same")


# ---------------------------------------------------------------------------
# Fig 01 — Fingerprint per (profile,variant)
# ---------------------------------------------------------------------------

def fig_fingerprint(df: pd.DataFrame, outdir: Path) -> None:
    """One figure per profile so each panel has room for readable labels.
    Earlier revision crammed profiles × variants into a single dense grid;
    that produced overlapping x-tick labels with 6+ workloads per axis."""
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    bar_w = 0.11
    x = np.arange(len(workloads))
    n = len(variants)
    for profile in profiles:
        nrows, ncols = _grid_dims(n)
        fig = plt.figure(figsize=_clamp_figsize(4.6 * ncols, 3.6 * nrows))
        axes_flat, _, _ = _make_axes_grid(fig, n, sharey=True)
        for ci, variant in enumerate(variants):
            ax = axes_flat[ci]
            sub = (df[(df["profile"] == profile) & (df["variant"] == variant)]
                   .set_index("workload").reindex(workloads))
            for mi, m in enumerate(METRICS):
                offset = (mi - (len(METRICS) - 1) / 2) * bar_w
                vals = sub[m].fillna(0).values
                ax.bar(x + offset, vals, width=bar_w,
                       label=METRIC_LABEL[m], color=METRIC_COLORS[m], alpha=0.92)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=35, ha="right", fontsize=8.5)
            ax.set_title(VARIANT_LABELS.get(variant, variant), fontsize=10)
            if ci % ncols == 0:
                ax.set_ylabel("metric value (%)")
            ymax = sub[METRICS].max().max() if not sub.empty else 1.0
            ax.set_ylim(0, max(1.0, ymax * 1.18))
        handles, labels = axes_flat[0].get_legend_handles_labels()
        fig.tight_layout()
        leg = _legend_above_axes(fig, axes_flat, handles, labels,
                                 ncol=len(METRICS), fontsize=9)
        _centered_suptitle(fig, axes_flat,
                           f"HiBench: IntP metric fingerprint — profile={profile}",
                           fontsize=11.5, extra_artists=[leg])
        _save(fig, outdir / f"fig01_fingerprint_{profile}.png",
              f"fig01[{profile}]")
        plt.close(fig)
    return

# ---------------------------------------------------------------------------
# Fig 02 — Sensitivity Δ(<pressure-profile> − standard) per variant
#
# Emits one PNG per non-standard profile present in the run. Each PNG shows
# one row per variant; bars are per metric and per workload, computed as
# (profile − standard) so positive bars mean the profile pushed the metric up.
# ---------------------------------------------------------------------------

def fig_sensitivity(df: pd.DataFrame, outdir: Path) -> None:
    profiles_present = set(df["profile"].unique())
    if "standard" not in profiles_present:
        print("[fig02] no 'standard' profile rows; cannot compute sensitivity — skip")
        return
    targets = [p for p in PROFILE_ORDER if p != "standard" and p in profiles_present]
    if not targets:
        print("[fig02] only 'standard' profile present — skip")
        return

    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    std_df = (df[df["profile"] == "standard"]
              .set_index(["variant", "workload"])[METRICS])

    for target in targets:
        cmp_df = (df[df["profile"] == target]
                  .set_index(["variant", "workload"])[METRICS])
        if cmp_df.empty:
            continue
        delta = (cmp_df - std_df).reset_index()

        nrows = len(variants)
        fig, axes = plt.subplots(nrows, 1,
                                 figsize=_clamp_figsize(8.5, 2.7 * nrows),
                                 squeeze=False, sharex=True)
        bar_w = 0.11
        x = np.arange(len(workloads))
        for ri, variant in enumerate(variants):
            ax = axes[ri][0]
            sub = (delta[delta["variant"] == variant]
                   .set_index("workload").reindex(workloads))
            for mi, m in enumerate(METRICS):
                offset = (mi - (len(METRICS) - 1) / 2) * bar_w
                vals = sub[m].fillna(0).values
                ax.bar(x + offset, vals, width=bar_w,
                       label=METRIC_LABEL[m], color=METRIC_COLORS[m], alpha=0.92)
            ax.axhline(0, color="black", linewidth=0.6, linestyle="--")
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=20, ha="right", fontsize=8)
            ax.set_title(f"{VARIANT_LABELS.get(variant, variant)} — "
                         f"Δ({target} − standard)", fontsize=9)
            ax.set_ylabel("Δ metric value")
        handles, labels = axes[0][0].get_legend_handles_labels()
        fig.tight_layout()
        flat = [a for r in axes for a in r]
        leg = _legend_above_axes(fig, flat, handles, labels,
                                 ncol=len(METRICS), fontsize=8.5)
        _centered_suptitle(fig, flat,
                           f"HiBench: sensitivity to '{target}' co-runner pressure",
                           fontsize=11, extra_artists=[leg])
        # Sanitise profile name for filename ("netp-extreme" -> "netp_extreme")
        slug = target.replace("-", "_")
        _save(fig, outdir / f"fig02_sensitivity_{slug}.png", f"fig02[{target}]")


# ---------------------------------------------------------------------------
# Fig 03 — Per-metric variant comparison
# ---------------------------------------------------------------------------

def fig_metric_compare(df: pd.DataFrame, outdir: Path) -> None:
    """One PNG per metric. Earlier revision packed metrics × profiles into
    a single 7×7 grid; the per-panel area was too small for legible labels."""
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    bar_w = 0.8 / max(1, len(variants))
    x = np.arange(len(workloads))
    for metric in METRICS:
        ymax_row = df[metric].max() if metric in df.columns else 1.0
        ncols = len(profiles)
        fig, axes = plt.subplots(1, ncols,
                                 figsize=_clamp_figsize(4.0 * ncols, 3.4),
                                 squeeze=False, sharey=True)
        for ci, profile in enumerate(profiles):
            ax = axes[0][ci]
            for vi, variant in enumerate(variants):
                sub = (df[(df["profile"] == profile) & (df["variant"] == variant)]
                       .set_index("workload").reindex(workloads))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, sub[metric].fillna(0).values,
                       width=bar_w,
                       label=VARIANT_LABELS.get(variant, variant),
                       color=VARIANT_COLORS.get(variant, f"C{vi}"), alpha=0.92)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=35, ha="right", fontsize=8.5)
            ax.set_title(profile, fontsize=10)
            if ci == 0:
                ax.set_ylabel(f"{metric} (%)")
            ax.set_ylim(0, max(0.5, ymax_row * 1.15))
        handles, labels = axes[0][0].get_legend_handles_labels()
        fig.tight_layout()
        flat = [a for r in axes for a in r]
        leg = _legend_above_axes(fig, flat, handles, labels,
                                 ncol=len(variants), fontsize=9)
        _centered_suptitle(fig, flat,
                           f"HiBench: per-profile variant comparison — metric={metric}",
                           fontsize=11.5, extra_artists=[leg])
        _save(fig, outdir / f"fig03_metric_compare_{metric}.png",
              f"fig03[{metric}]")
        plt.close(fig)


# ---------------------------------------------------------------------------
# Fig 04 — IntP Fig. 4 reproduction: per-workload, bars = variant × metric
# ---------------------------------------------------------------------------

def fig_per_workload_bars(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    for profile in profiles:
        sub_p = df[df.profile == profile]
        n = len(workloads)
        nrows, ncols = _grid_dims(n)
        fig = plt.figure(figsize=_clamp_figsize(2.7 * ncols, 2.0 * nrows))
        axes_flat, _, _ = _make_axes_grid(fig, n, sharey=True)
        x = np.arange(len(METRICS))
        bar_w = 0.8 / max(1, len(variants))
        for i, wl in enumerate(workloads):
            ax = axes_flat[i]
            for vi, variant in enumerate(variants):
                row = sub_p[(sub_p.workload == wl) & (sub_p.variant == variant)]
                vals = (row[METRICS].iloc[0].values if not row.empty
                        else np.full(len(METRICS), np.nan))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, np.nan_to_num(vals), width=bar_w,
                       color=VARIANT_COLORS.get(variant, f"C{vi}"),
                       edgecolor="white", linewidth=0.3,
                       label=variant_label(variant) if i == 0 else None)
            ax.set_xticks(x)
            ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
            ax.set_title(wl, fontsize=8.5)
            ymax = sub_p[METRICS].max().max()
            ax.set_ylim(0, max(1.0, float(ymax) * 1.10))
            ax.tick_params(axis="y", labelsize=7)
            if i % ncols == 0:
                ax.set_ylabel("metric value (%)", fontsize=8)
        handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
                   for v in variants]
        fig.tight_layout()
        leg = _legend_above_axes(fig, axes_flat, handles,
                                 [variant_label(v) for v in variants],
                                 ncol=len(variants), fontsize=8.5,
                                 title="variant", title_fontsize=8.5)
        _centered_suptitle(fig, axes_flat,
                           f"Per-workload variant fingerprint — profile={profile}",
                           fontsize=11, extra_artists=[leg])
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig04_per_workload_bars{suffix}.png", f"fig04-{profile}")
        plt.close(fig)


# ---------------------------------------------------------------------------
# Fig 05 — Radar fingerprint (one polygon per variant per workload)
# ---------------------------------------------------------------------------

def fig_radar(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    # Normalise per metric over the entire dataset so shapes are comparable
    norms = {m: max(1e-9, df[m].max()) for m in METRICS}
    profile = "standard" if "standard" in profiles else profiles[0]
    sub_p = df[df.profile == profile]
    n = len(workloads)
    nrows, ncols = _grid_dims(n)
    fig = plt.figure(figsize=_clamp_figsize(3.2 * ncols, 3.0 * nrows))
    axes_flat, _, _ = _make_axes_grid(fig, n, polar=True)
    angles = np.linspace(0, 2 * np.pi, len(METRICS), endpoint=False).tolist()
    angles += angles[:1]
    for i, wl in enumerate(workloads):
        ax = axes_flat[i]
        for variant in variants:
            row = sub_p[(sub_p.workload == wl) & (sub_p.variant == variant)]
            if row.empty: continue
            vals = [row[m].iloc[0] / norms[m] for m in METRICS]
            vals += vals[:1]
            color = VARIANT_COLORS.get(variant, "C0")
            ax.plot(angles, vals, color=color, linewidth=1.9, alpha=0.95,
                    label=variant_label(variant))
            ax.fill(angles, vals, color=color, alpha=0.06)
        ax.set_xticks(angles[:-1])
        ax.set_xticklabels(METRICS, fontsize=7.5)
        ax.set_yticks([0.25, 0.5, 0.75, 1.0])
        if i == 0:
            ax.set_yticklabels(["0.25", "0.50", "0.75", "1.00"], fontsize=6,
                               color="#555")
        else:
            ax.set_yticklabels(["", "", "", ""])
        ax.set_ylim(0, 1.05)
        ax.set_title(wl, fontsize=9, pad=10)
        ax.grid(linewidth=0.4, alpha=0.5)
    handles = [plt.Line2D([0], [0], color=VARIANT_COLORS.get(v, "C0"),
                          linewidth=2.4, label=variant_label(v)) for v in variants]
    fig.tight_layout()
    leg = _legend_above_axes(fig, axes_flat, handles,
                             [variant_label(v) for v in variants],
                             ncol=len(variants), fontsize=9.5,
                             title="variant", title_fontsize=9.5)
    _centered_suptitle(fig, axes_flat,
                       f"HiBench: per-workload radar fingerprint — profile={profile}  "
                       f"(metrics scaled to per-metric maximum)",
                       fontsize=10.5, extra_artists=[leg])
    _save(fig, outdir / "fig05_radar_fingerprint.png", "fig05")


# ---------------------------------------------------------------------------
# Fig 06 — IntP Fig. 5: PCA of HiBench workloads (per profile × variant)
# ---------------------------------------------------------------------------

def fig_pca(df: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SKLEARN:
        return
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    pairs = [(p, v) for p in profiles for v in variants]
    n = len(pairs)
    if n == 0:
        return
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=_clamp_figsize(5 * cols, 4 * rows), squeeze=False)
    last = -1
    for idx, (profile, variant) in enumerate(pairs):
        last = idx
        ax = axes[idx // cols][idx % cols]
        sub = (df[(df.profile == profile) & (df.variant == variant)]
               .groupby("workload")[METRICS].mean().fillna(0))
        if len(sub) < 3:
            ax.set_title(f"{profile}/{variant}: too few"); ax.axis("off"); continue
        try:
            pca = PCA(n_components=2)
            Y = pca.fit_transform(sub.values)
        except Exception as e:
            ax.set_title(f"{profile}/{variant}: PCA failed"); ax.axis("off"); continue
        ax.scatter(Y[:, 0], Y[:, 1], s=120, alpha=0.78,
                   color=VARIANT_COLORS.get(variant, "C0"),
                   edgecolor="black", linewidth=0.4)
        for i, label in enumerate(sub.index):
            ax.annotate(label, (Y[i, 0], Y[i, 1]),
                        fontsize=7, alpha=0.85,
                        xytext=(4, 4), textcoords="offset points")
        ax.axhline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.axvline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.set_title(f"{variant_label(variant)} / {profile}\n"
                     f"PC1={pca.explained_variance_ratio_[0]*100:.1f}%  "
                     f"PC2={pca.explained_variance_ratio_[1]*100:.1f}%", fontsize=9.5)
        ax.set_xlabel("PC1"); ax.set_ylabel("PC2")
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    fig.tight_layout()
    _centered_suptitle(fig, axes.ravel().tolist(),
                       "HiBench workloads in PCA space")
    _save(fig, outdir / "fig06_pca_workloads.png", "fig06")


# ---------------------------------------------------------------------------
# Fig 07 — IntP Fig. 3 / IADA Fig. 5: smoothed trace per (variant,workload)
# ---------------------------------------------------------------------------

def fig_timeseries(run_dirs: list[Path], outdir: Path) -> None:
    """Pick one representative rep per (profile,variant,workload) and plot
    a multi-metric smoothed trace."""
    traces = []  # list of (profile, variant, workload, df)
    for run_dir in run_dirs:
        meta = _read_metadata(run_dir)
        profile = meta.get("profile", run_dir.name.split("-large-")[0])
        for prof_path in _rglob_profiler(run_dir):
            parts = prof_path.parts
            try:
                variant = parts[-5]; workload = parts[-3]
            except IndexError:
                continue
            df_t = load_profiler_tsv(prof_path)
            if df_t.empty: continue
            traces.append((profile, variant, workload, prof_path, df_t))
    if not traces:
        print("[fig07] no profiler.tsv traces — skip")
        return

    # Choose: one trace per (profile,variant,workload), prefer rep1
    chosen: dict[tuple, tuple] = {}
    for profile, variant, workload, path, df_t in traces:
        key = (profile, variant, workload)
        is_rep1 = path.parts[-2] == "rep1"
        if key not in chosen or (is_rep1 and chosen[key][0].parts[-2] != "rep1"):
            chosen[key] = (path, df_t)

    profiles = _ordered_profiles({k[0] for k in chosen})
    variants = _ordered_variants({k[1] for k in chosen})
    workloads = _ordered_workloads({k[2] for k in chosen})
    if not workloads or not variants:
        return

    # One figure per profile: rows = variants, cols = workloads
    for profile in profiles:
        nrows = len(variants); ncols = len(workloads)
        fig, axes = plt.subplots(nrows, ncols,
                                 figsize=_clamp_figsize(2.6 * ncols, 1.7 * nrows),
                                 squeeze=False, sharex=False, sharey=True)
        for ri, variant in enumerate(variants):
            for ci, wl in enumerate(workloads):
                ax = axes[ri][ci]
                key = (profile, variant, wl)
                if key not in chosen:
                    ax.axis("off"); continue
                _, df_t = chosen[key]
                if "ts" in df_t and df_t["ts"].notna().any():
                    t = df_t["ts"] - df_t["ts"].min()
                else:
                    t = np.arange(len(df_t))
                for m in METRICS:
                    if m in df_t.columns:
                        y = _smooth(df_t[m].fillna(0).values, window=15)
                        ax.plot(t, y, color=METRIC_COLORS[m],
                                linewidth=1.0, alpha=0.92, label=METRIC_LABEL[m])
                if ri == 0:
                    ax.set_title(wl, fontsize=8.5)
                if ci == 0:
                    ax.set_ylabel(f"{variant_label(variant)}\nlevel", fontsize=8)
                if ri == nrows - 1:
                    ax.set_xlabel("time (s)", fontsize=8)
                ax.tick_params(labelsize=7)
        handles, labels = [], []
        for r in range(nrows):
            for c in range(ncols):
                hh, ll = axes[r][c].get_legend_handles_labels()
                if hh:
                    handles, labels = hh, ll; break
            if handles: break
        fig.tight_layout()
        flat = [a for r in axes for a in r]
        extras = []
        if handles:
            extras.append(_legend_above_axes(
                fig, flat, handles, labels,
                ncol=len(METRICS), fontsize=8.5))
        _centered_suptitle(fig, flat,
                           f"HiBench timeseries — profile={profile}",
                           fontsize=11, extra_artists=extras)
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig07_timeseries{suffix}.png", f"fig07-{profile}")


# ---------------------------------------------------------------------------
# Fig 08 — IADA Fig. 6: Δ resource (netp-extreme − standard) per variant
# ---------------------------------------------------------------------------

def fig_idi_bars(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    if "standard" not in profiles or "netp-extreme" not in profiles:
        print("[fig08] need both profiles — skip")
        return
    variants = _ordered_variants(df["variant"].unique())
    rows = []
    for variant in variants:
        s = df[(df.variant == variant) & (df.profile == "standard")]
        p = df[(df.variant == variant) & (df.profile == "netp-extreme")]
        if s.empty or p.empty: continue
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            s_v = s[members].mean().mean()
            p_v = p[members].mean().mean()
            if pd.isna(s_v) or pd.isna(p_v): continue
            rows.append(dict(variant=variant, resource=fam,
                             standard=s_v, netp_extreme=p_v,
                             delta=p_v - s_v))
    if not rows:
        return
    rdf = pd.DataFrame(rows)
    rdf.to_csv(outdir / "idi_resource.csv", index=False)
    resources = list(RESOURCE_FAMILY.keys())
    fig, ax = plt.subplots(figsize=_clamp_figsize(7.4, 3.6))
    x = np.arange(len(resources))
    bar_w = 0.8 / max(1, len(variants))
    for vi, variant in enumerate(variants):
        offsets = (vi - (len(variants) - 1) / 2) * bar_w
        vals = [rdf[(rdf.variant == variant) & (rdf.resource == r)]["delta"].mean()
                for r in resources]
        ax.bar(x + offsets, vals, width=bar_w,
               color=VARIANT_COLORS.get(variant, f"C{vi}"),
               edgecolor="white", linewidth=0.4,
               label=VARIANT_LABELS.get(variant, variant))
    ax.set_xticks(x); ax.set_xticklabels(resources)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_ylabel("Δ interference (netp-extreme − standard, %)")
    ax.set_title("Resource-level sensitivity to network interference profile",
                 fontsize=10)
    ax.legend(ncol=len(variants), fontsize=8.5,
              loc="upper center", bbox_to_anchor=(0.5, -0.13))
    fig.tight_layout()
    _save(fig, outdir / "fig08_idi_bars.png", "fig08")


# ---------------------------------------------------------------------------
# Fig 00 — Canonical IntP Fig. 4 (single panel per (profile,variant)).
# Bars grouped per workload, colored by metric using the original IntP paper
# caption: cache=red, cpu=brown, disk=green, memory=blue, network=pink.
# ---------------------------------------------------------------------------

CANONICAL_METRIC_COLORS = {
    "llcocc": "#d62728",  # cache — red
    "llcmr":  "#ff9896",  # cache miss — light red
    "cpu":    "#8c564b",  # cpu — brown
    "blk":    "#2ca02c",  # disk — green
    "mbw":    "#1f77b4",  # memory bus — blue
    "nets":   "#e377c2",  # network stack — pink
    "netp":   "#c4448a",  # network phys — darker pink
}


def fig_canonical_intp_fig4(df: pd.DataFrame, outdir: Path) -> None:
    """One PNG per profile (variants laid out in a row), so each panel has
    enough horizontal space for the workload tick labels not to overlap."""
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    x = np.arange(len(workloads))
    bar_w = 0.8 / max(1, len(METRICS))
    n = len(variants)
    for profile in profiles:
        nrows, ncols = _grid_dims(n)
        fig = plt.figure(figsize=_clamp_figsize(5.4 * ncols, 3.6 * nrows))
        axes_flat, _, _ = _make_axes_grid(fig, n, sharey=True)
        for ci, variant in enumerate(variants):
            ax = axes_flat[ci]
            sub = (df[(df.profile == profile) & (df.variant == variant)]
                   .set_index("workload").reindex(workloads))
            for mi, m in enumerate(METRICS):
                offset = (mi - (len(METRICS) - 1) / 2) * bar_w
                vals = sub[m].fillna(0).values
                ax.bar(x + offset, vals, width=bar_w,
                       color=CANONICAL_METRIC_COLORS.get(m, METRIC_COLORS[m]),
                       edgecolor="white", linewidth=0.25,
                       label=METRIC_LABEL[m] if ci == 0 else None)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=35, ha="right", fontsize=8.5)
            ax.set_title(VARIANT_LABELS.get(variant, variant), fontsize=10)
            if ci % ncols == 0:
                ax.set_ylabel("interference (%)")
        handles, labels = axes_flat[0].get_legend_handles_labels()
        fig.tight_layout()
        extras = []
        if handles:
            extras.append(_legend_above_axes(
                fig, axes_flat, handles, labels,
                ncol=len(METRICS), fontsize=9))
        _centered_suptitle(fig, axes_flat,
                           f"HiBench: interference ratios per "
                           f"workload  (profile={profile})",
                           fontsize=11.5, extra_artists=extras)
        _save(fig, outdir / f"fig00_canonical_intp_fig4_{profile}.png",
              f"fig00[{profile}]")
        plt.close(fig)


# ---------------------------------------------------------------------------
# Fig 09 — IntP Fig. 8 reproduction: resource-family time series.
# Per (profile,variant,workload) trace, overlaying mean of each resource
# family (cache/cpu/disk/memory/network) with smoothed lines. Mirrors the
# 4-line interference time series of IntP Fig. 8.
# ---------------------------------------------------------------------------

def fig_resource_timeseries(run_dirs: list[Path], outdir: Path) -> None:
    traces: list[tuple] = []
    for run_dir in run_dirs:
        meta = _read_metadata(run_dir)
        profile = meta.get("profile", run_dir.name.split("-large-")[0])
        for prof_path in _rglob_profiler(run_dir):
            parts = prof_path.parts
            try:
                variant = parts[-5]; workload = parts[-3]
            except IndexError:
                continue
            df_t = load_profiler_tsv(prof_path)
            if df_t.empty: continue
            traces.append((profile, variant, workload, prof_path, df_t))
    if not traces:
        print("[fig09] no profiler.tsv traces — skip")
        return
    chosen: dict[tuple, tuple] = {}
    for profile, variant, workload, path, df_t in traces:
        key = (profile, variant, workload)
        is_rep1 = path.parts[-2] == "rep1"
        if key not in chosen or (is_rep1 and chosen[key][0].parts[-2] != "rep1"):
            chosen[key] = (path, df_t)
    profiles = _ordered_profiles({k[0] for k in chosen})
    variants = _ordered_variants({k[1] for k in chosen})
    workloads = _ordered_workloads({k[2] for k in chosen})
    if not workloads or not variants:
        return
    for profile in profiles:
        nrows = len(variants); ncols = len(workloads)
        fig, axes = plt.subplots(
            nrows, ncols,
            figsize=_clamp_figsize(2.2 * ncols, 1.7 * nrows),
            squeeze=False, sharex=False, sharey=True,
        )
        for ri, variant in enumerate(variants):
            for ci, wl in enumerate(workloads):
                ax = axes[ri][ci]
                key = (profile, variant, wl)
                if key not in chosen:
                    ax.axis("off"); continue
                _, df_t = chosen[key]
                if "ts" in df_t and df_t["ts"].notna().any():
                    t = (df_t["ts"] - df_t["ts"].min()).values
                else:
                    t = np.arange(len(df_t), dtype=float)
                for fam, members in RESOURCE_FAMILY.items():
                    members = [m for m in members if m in df_t.columns]
                    if not members: continue
                    series = df_t[members].mean(axis=1).fillna(0).values
                    y = _smooth(series, window=21)
                    ax.plot(t, y, color=RESOURCE_COLORS[fam], linewidth=1.2,
                            alpha=0.95, label=fam.capitalize())
                ax.set_ylim(-2, 105)
                if ri == 0:
                    ax.set_title(wl, fontsize=8.5)
                if ci == 0:
                    ax.set_ylabel(f"{variant_label(variant)}\nlevel (%)", fontsize=8)
                if ri == nrows - 1:
                    ax.set_xlabel("time (s)", fontsize=8)
                ax.tick_params(labelsize=7)
        handles, labels = [], []
        for r in range(nrows):
            for c in range(ncols):
                hh, ll = axes[r][c].get_legend_handles_labels()
                if hh:
                    handles, labels = hh, ll; break
            if handles: break
        fig.tight_layout()
        flat = [a for r in axes for a in r]
        extras = []
        if handles:
            extras.append(_legend_above_axes(
                fig, flat, handles, labels,
                ncol=len(handles), fontsize=9))
        _centered_suptitle(fig, flat,
                           f"HiBench resource-family timeseries — profile={profile}",
                           fontsize=11, extra_artists=extras)
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig09_resource_timeseries{suffix}.png",
              f"fig09-{profile}")


# ---------------------------------------------------------------------------
# Fig 10 — Variant × resource summary (NEW visualisation).
# Compact heatmap suitable for the ever-growing experiment matrix.
# ---------------------------------------------------------------------------

def fig_variant_resource_heatmap(df: pd.DataFrame, outdir: Path) -> None:
    if df.empty:
        return
    rows: list[dict] = []
    for profile in _ordered_profiles(df["profile"].unique()):
        sub_p = df[df.profile == profile]
        for variant in _ordered_variants(sub_p["variant"].unique()):
            sub = sub_p[sub_p.variant == variant]
            for fam, members in RESOURCE_FAMILY.items():
                members = [m for m in members if m in sub.columns]
                if not members: continue
                v = sub[members].mean(axis=1).mean()
                if pd.isna(v):
                    continue
                rows.append(dict(profile=profile, variant=variant,
                                 resource=fam, mean=float(v)))
    if not rows:
        return
    rdf = pd.DataFrame(rows)
    rdf.to_csv(outdir / "variant_resource_summary.csv", index=False)
    profiles = _ordered_profiles(rdf["profile"].unique())
    n_p = len(profiles)
    n_v = rdf["variant"].nunique()
    resources = list(RESOURCE_FAMILY.keys())

    # Stacked-rows layout: at n=7 profiles _grid_dims returns 3×3 and
    # centres the partial last row. Earlier 1×7 layout cramped the
    # x-axis labels (cache, cpu, disk, memory, network) into overlap.
    nrows, ncols = _grid_dims(n_p)
    panel_w = 2.4 + 0.6 * len(resources)            # wide enough for x labels
    panel_h = 0.55 * n_v + 1.4                      # room for variant rows + title
    fig = plt.figure(figsize=_clamp_figsize(panel_w * ncols, panel_h * nrows))
    axes_flat, _, _ = _make_axes_grid(fig, n_p, wspace=1.1, hspace=0.45)

    cmap = plt.get_cmap("Blues").copy()
    cmap.set_bad(color="#cccccc")
    im = None
    for i, profile in enumerate(profiles):
        ax = axes_flat[i]
        sub = rdf[rdf.profile == profile]
        pivot = sub.pivot_table(index="variant", columns="resource", values="mean")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index), columns=resources)
        masked = np.ma.masked_invalid(pivot.values)
        im = ax.imshow(masked, cmap=cmap, vmin=0, vmax=100, aspect="auto",
                       interpolation="none")
        ax.set_xticks(range(len(resources)))
        ax.set_xticklabels(resources, fontsize=8.5)
        ax.set_yticks(range(len(pivot.index)))
        ax.set_yticklabels([variant_label(v) for v in pivot.index], fontsize=8.5)
        ax.set_title(f"profile={profile}", fontsize=10)
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.0f}", ha="center", va="center",
                        fontsize=8.5, fontweight="bold",
                        color="white" if v > 50 else "black")
        ax.grid(False)
    if im is not None:
        fig.colorbar(im, ax=axes_flat, fraction=0.035, shrink=0.7,
                     label="mean interference (%)")
    _centered_suptitle(fig, axes_flat,
                       "HiBench variant × resource family — mean interference",
                       fontsize=12)
    _save(fig, outdir / "fig10_variant_resource_heatmap.png", "fig10")


# ---------------------------------------------------------------------------
# Fig 08 — HiBench coverage: normalized metric signal per variant.
# Reproduces the paper draft's fig08_hibench_coverage. For each
# (workload, metric), the reference value is the max across variants
# (within the chosen profile). Each variant's cell renders that variant's
# value divided by the reference, so 1.0 means "captures the strongest
# signal seen", 0.0 means "did not surface this metric on this workload",
# and intermediate values show degraded but non-zero capture. Layout:
# one panel per variant; rows = workloads, cols = metrics.
# ---------------------------------------------------------------------------

def fig_hibench_coverage(df: pd.DataFrame, outdir: Path) -> None:
    if df.empty:
        return
    profiles = _ordered_profiles(df["profile"].unique())
    if not profiles:
        return
    profile = "standard" if "standard" in profiles else profiles[0]
    sub = df[df.profile == profile]
    variants = _ordered_variants(sub["variant"].unique())
    workloads = _ordered_workloads(sub["workload"].unique())
    if not (variants and workloads):
        return

    # Reference per (workload, metric): max across variants.
    ref = (sub.groupby("workload")[METRICS].max()
              .reindex(workloads).fillna(0))
    rows: list[dict] = []
    for variant in variants:
        v_df = (sub[sub.variant == variant]
                .set_index("workload")[METRICS]
                .reindex(workloads).fillna(0))
        for wl in workloads:
            for m in METRICS:
                r = ref.loc[wl, m]
                v = v_df.loc[wl, m]
                cov = (v / r) if r > 1e-9 else (1.0 if v > 1e-9 else np.nan)
                rows.append(dict(variant=variant, workload=wl, metric=m,
                                 value=float(v), reference=float(r),
                                 coverage=cov))
    cov_df = pd.DataFrame(rows)
    cov_df.to_csv(outdir / "hibench_coverage.csv", index=False)

    ncols = len(variants)
    fig, axes = plt.subplots(1, ncols,
                             figsize=_clamp_figsize(3.0 + 2.6 * ncols,
                                                    0.5 * len(workloads) + 1.6),
                             squeeze=False, sharey=True)
    cmap = plt.get_cmap("Blues").copy()
    cmap.set_bad(color="#cccccc")
    im = None
    for ci, variant in enumerate(variants):
        ax = axes[0][ci]
        pivot = (cov_df[cov_df.variant == variant]
                 .pivot_table(index="workload", columns="metric",
                              values="coverage")
                 .reindex(index=workloads, columns=METRICS))
        masked = np.ma.masked_invalid(pivot.values)
        im = ax.imshow(masked, cmap=cmap, vmin=0, vmax=1, aspect="auto",
                       interpolation="none")
        ax.set_xticks(range(len(METRICS)))
        ax.set_xticklabels(METRICS, rotation=40, ha="right", fontsize=8.5)
        if ci == 0:
            ax.set_yticks(range(len(workloads)))
            ax.set_yticklabels(workloads, fontsize=8.5)
        ax.set_title(VARIANT_LABELS.get(variant, variant), fontsize=10)
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if np.isnan(v):
                ax.text(xi, yi, "—", ha="center", va="center",
                        fontsize=8.5, color="#666")
            elif v >= 0.995:
                # cells at the reference don't need a label; the bright
                # color already says "this is the best capture seen".
                continue
            else:
                # Blues: low=light, high=dark; flip text accordingly.
                ax.text(xi, yi, f"{v:.2f}", ha="center", va="center",
                        fontsize=8, color="black" if v < 0.5 else "white")
        ax.grid(False)
    if im is not None:
        fig.colorbar(im, ax=axes.ravel().tolist(), fraction=0.04, shrink=0.85,
                     label="coverage = value / max(value across variants)")
    _centered_suptitle(fig, axes.ravel().tolist(),
                       f"HiBench Spark workloads — metric coverage per variant  "
                       f"(profile={profile})", fontsize=11.5)
    _save(fig, outdir / "fig08_hibench_coverage.png", "fig08")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Fig 11 — Metric availability per variant (binary).
# Quick-scan companion to fig08: any non-zero reading anywhere in the
# (variant, metric) slice across all profiles + workloads.
# ---------------------------------------------------------------------------

def fig_metric_availability(df: pd.DataFrame, outdir: Path) -> None:
    if df.empty:
        return
    avail_rows = []
    for variant in _ordered_variants(df["variant"].unique()):
        sub = df[df.variant == variant]
        for m in METRICS:
            ok = sub[m].notna().any() and (sub[m].fillna(0).abs().sum() > 0)
            avail_rows.append(dict(variant=variant, metric=m,
                                   available=int(ok)))
    avail_df = pd.DataFrame(avail_rows)
    avail_df.to_csv(outdir / "metric_availability.csv", index=False)
    pivot = (avail_df.pivot_table(index="variant", columns="metric",
                                  values="available")
             .reindex(index=_ordered_variants(avail_df["variant"].unique()),
                      columns=METRICS))
    fig, ax = plt.subplots(
        figsize=_clamp_figsize(6.4, 0.55 * len(pivot) + 1.4))
    cmap = ListedColormap(["#f4f4f4", "#2ca02c"])
    ax.imshow(pivot.values, cmap=cmap, vmin=0, vmax=1, aspect="auto",
              interpolation="none")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels([variant_label(v) for v in pivot.index])
    for (yi, xi), v in np.ndenumerate(pivot.values):
        ax.text(xi, yi, "✓" if v else "—", ha="center", va="center",
                fontsize=11, color="white" if v else "#666")
    ax.set_title("HiBench: metric availability per variant "
                 "(any non-zero reading)")
    ax.grid(False)
    fig.tight_layout()
    _save(fig, outdir / "fig11_metric_availability.png", "fig11")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Fig 12 — Workload clustermap (Ward linkage), standard profile.
# Mirrors plot-intp-bench.py fig10. Shows whether variants cluster
# workloads similarly.
# ---------------------------------------------------------------------------

def fig_workload_clustermap(df: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SCIPY or df.empty:
        return
    profiles = _ordered_profiles(df["profile"].unique())
    if not profiles:
        return
    profile = "standard" if "standard" in profiles else profiles[0]
    sub = df[df.profile == profile]
    variants = _ordered_variants(sub["variant"].unique())
    if not variants:
        return
    n = len(variants)
    nrows, ncols = _grid_dims(n)
    fig = plt.figure(figsize=_clamp_figsize(
        4.6 * ncols, 0.34 * sub["workload"].nunique() + 1.6))
    axes_flat, _, _ = _make_axes_grid(fig, n)
    im = None
    for idx, variant in enumerate(variants):
        ax = axes_flat[idx]
        m = (sub[sub.variant == variant]
             .groupby("workload")[METRICS].mean().fillna(0))
        if m.shape[0] < 2:
            ax.set_title(f"{variant} — too few workloads")
            ax.axis("off")
            continue
        try:
            Z = linkage(m.values, method="ward")
            order = leaves_list(Z)
        except Exception:
            order = np.arange(len(m))
        m = m.iloc[order]
        im = ax.imshow(m.values, aspect="auto", cmap="Blues",
                       vmin=0, vmax=100, interpolation="none")
        ax.set_xticks(range(len(METRICS)))
        ax.set_xticklabels(METRICS, rotation=40, ha="right", fontsize=8)
        ax.set_yticks(range(len(m.index)))
        ax.set_yticklabels(m.index, fontsize=8)
        ax.set_title(f"{VARIANT_LABELS.get(variant, variant)}  (Ward linkage)",
                     fontsize=9.5)
        ax.grid(False)
    if im is None:
        plt.close(fig)
        return
    fig.colorbar(im, ax=axes_flat, shrink=0.7,
                 label="metric value (%)")
    _centered_suptitle(fig, axes_flat,
                       f"HiBench: hierarchical workload clustermap — "
                       f"profile={profile}")
    _save(fig, outdir / "fig12_workload_clustermap.png", "fig12")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description="Plot HiBench IntP results")
    p.add_argument("hibench_dir", type=Path,
                   help="Directory containing hibench run subdirs")
    p.add_argument("--out", type=Path, default=None,
                   help="Output directory (default: <hibench_dir>/plots)")
    p.add_argument("--formats", type=str, default="png,pdf",
                   help="Comma-separated output formats (default: png,pdf). "
                        "Each format is written under <out>/<format>/.")
    args = p.parse_args()

    hdir = args.hibench_dir
    if (hdir / "hibench").is_dir():
        hdir = hdir / "hibench"
    if not hdir.is_dir():
        sys.exit(f"Not a directory: {hdir}")

    outdir = args.out or (hdir / "plots")
    outdir.mkdir(parents=True, exist_ok=True)
    global FORMATS
    FORMATS = [f.strip() for f in args.formats.split(",") if f.strip()] or ["png"]

    setup_style()

    print(f"Loading hibench results from {hdir}")
    df, run_dirs = load_hibench_dir(hdir)
    # aggregate-means.tsv has one row per rep; collapse to per-(profile,variant,
    # workload) means so the figure functions can index on workload alone.
    df = (df.groupby(["profile", "variant", "workload"], as_index=False)[METRICS]
            .mean())
    print(f"  variants : {sorted(df['variant'].unique())}")
    print(f"  profiles : {sorted(df['profile'].unique())}")
    print(f"  workloads: {sorted(df['workload'].unique())}")
    df.to_csv(outdir / "combined-means.csv", index=False)

    fig_canonical_intp_fig4(df, outdir)        # fig00  IntP Fig.4 canonical (per profile)
    fig_fingerprint(df, outdir)                # fig01  (per profile)
    fig_sensitivity(df, outdir)                # fig02
    fig_metric_compare(df, outdir)             # fig03  (per metric)
    fig_per_workload_bars(df, outdir)          # fig04  IntP Fig.4 panels
    fig_radar(df, outdir)                      # fig05  IntP Fig.4 alt
    fig_pca(df, outdir)                        # fig06  IntP Fig.5
    fig_timeseries(run_dirs, outdir)           # fig07  IntP Fig.3 / IADA Fig.5
    fig_hibench_coverage(df, outdir)           # fig08  paper Fig.6 (coverage)
    fig_idi_bars(df, outdir)                   # fig09a IADA Fig.6 (renamed)
    fig_resource_timeseries(run_dirs, outdir)  # fig09  IntP Fig.8
    fig_variant_resource_heatmap(df, outdir)   # fig10  new summary
    fig_metric_availability(df, outdir)        # fig11  binary availability
    fig_workload_clustermap(df, outdir)        # fig12  Ward linkage clustermap

    print(f"Done. Figures in {outdir}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-intp-bench.py — Publication-style figures from intp-bench results.
#
# The figure set reproduces the structure of the original IntP paper
# (Xavier et al., 2022, SBAC-PAD) and the IADA paper (Meyer et al., 2022, JSS),
# adapted to the new IntP context where multiple *variants* of the profiler
# are compared across multiple *environments* (bare/container/vm) and the
# stress-ng / app01..app15 workload set.
#
# Figures (paper reference in parens):
#   fig01_per_workload_bars.png  (IntP Fig. 4)  one panel per workload,
#                                              bars = variants × metrics
#   fig01b_per_variant_bars.png  (IntP Fig. 4 dual view) one panel per
#                                              (env,variant), bars = workloads
#   fig02_pca_kmeans.png         (IntP Fig. 5)  PCA + k-means per (env,variant)
#   fig03_timeseries.png         (IntP Fig. 3)  long mixed-load trace
#   fig04_overhead_throughput.png  (A) bogo-ops/s slowdown per variant
#   fig04b_overhead_cpu_jiffies.png (B) extra system-wide CPU jiffies per variant
#   fig04c_overhead_sched_switch.png (C, opt) Δ sched:sched_switch per variant
#   fig05_fidelity_matrix.png    (extended)     Pearson r vs ground truth
#   fig06_env_heatmap.png        (extended)     env degradation ratio
#   fig07_pairwise_heatmap.png   (extended)     pair × metric per variant
#   fig08_metric_availability.png (extended)    metric coverage map
#   fig09_radar_fingerprint.png  (IntP Fig. 4 alt) per-workload radar
#   fig10_workload_clustermap.png (new)          hierarchical workload cluster
#   fig11_idi_bars.png           (IADA Fig. 6)  Δ pairwise − solo per resource
#   fig12_pairwise_timeseries.png (IntP Fig. 8) multi-metric trace per pair
#   fig13_iada_segmented.png     (IADA Fig. 5)  Loess-smoothed segmented trace
#   fig14_variant_resource_heatmap.png (new)    variants × resources summary
#   fig00_canonical_intp_fig4.png (IntP Fig. 4 canonical) single panel,
#                                              x = workload, grouped bars per metric
#
# All output figures are sized so neither dimension exceeds ~1900px (compatible
# with downstream image reviewers that reject ≥2000px assets).
#
# Run:   python3 plot-intp-bench.py /path/to/results/<bench-full>
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import re
import sys
import warnings
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import ListedColormap
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas scikit-learn scipy")

try:
    from sklearn.decomposition import PCA
    from sklearn.cluster import KMeans
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    warnings.warn("scikit-learn not installed — PCA/k-means figure will be skipped")

try:
    from scipy.cluster.hierarchy import linkage, leaves_list
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False

# ---------------------------------------------------------------------------
# Constants — palette aligned with IntP Fig. 8 / IADA Fig. 5 conventions:
#   Cache = orange, CPU = black/dark, Disk = green, Memory = blue, Network = pink.
# ---------------------------------------------------------------------------

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_COLORS = {
    "netp":   "#e377c2",   # network physical — pink
    "nets":   "#9467bd",   # network stack — purple
    "blk":    "#2ca02c",   # block / disk — green
    "mbw":    "#1f77b4",   # memory bandwidth — blue
    "llcmr":  "#d62728",   # LLC miss rate — red
    "llcocc": "#ff7f0e",   # LLC occupancy — orange (Cache in paper)
    "cpu":    "#000000",   # cpu — black (CPU in paper)
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
# Logical resource families used by IntP Fig. 8 (4 lines: Cache/CPU/Disk/Memory)
RESOURCE_FAMILY = {
    "cache":   ["llcocc", "llcmr"],
    "cpu":     ["cpu"],
    "disk":    ["blk"],
    "memory":  ["mbw"],
    "network": ["netp", "nets"],
}
RESOURCE_COLORS = {
    "cache":   "#ff7f0e",  # orange
    "cpu":     "#000000",  # black
    "disk":    "#2ca02c",  # green
    "memory":  "#1f77b4",  # blue
    "network": "#e377c2",  # pink
}

VARIANT_ORDER = ["v0", "v0.1", "v0.2", "v1", "v1.1", "v2", "v3.1", "v3", "v3.2"]
VARIANT_COLORS = {
    "v0":   "#7f7f7f",  # gray
    "v0.1": "#bcbd22",  # olive
    "v0.2": "#c7c7c7",  # light gray
    "v1":   "#17becf",  # cyan
    "v1.1": "#aec7e8",  # light blue
    "v2":   "#1f77b4",  # blue
    "v3":   "#2ca02c",  # green
    "v3.1": "#ff7f0e",  # orange
    "v3.2": "#d62728",  # red
}
# Article-facing labels for variants whose dataset directory name differs
# from the name used in the paper. The v3 eBPF ring-buffer profiler is
# stored in results as "v3" but presented as v3.2 in the article. The
# marker lookup stays keyed on the dataset value, so renaming the label
# preserves the existing marker (v3 → triangle "^").
VARIANT_DISPLAY = {"v3": "v3.2"}


def _variant_label(v: str) -> str:
    """Article-facing label for a dataset variant value."""
    return VARIANT_DISPLAY.get(v, v)


# Default plotted-variant set — the 4 variants that go into the article:
# v0.2 (recalibrated stap baseline), v1.1, v2, v3.2. The 2x2 panel grid
# in _grid_dims expects 4. If <results_dir>/variants.manifest exists, it
# overrides this default (one variant per line, '#' comments allowed).
DEFAULT_PLOTTED_VARIANTS = ["v0.2", "v1.1", "v2", "v3.2"]


def _load_plotted_variants(results_dir) -> list[str]:
    from pathlib import Path as _P
    manifest = _P(results_dir) / "variants.manifest"
    if manifest.exists():
        out: list[str] = []
        for line in manifest.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            tok = line.split()[0]
            if tok == "variant":
                continue
            out.append(tok)
        if out:
            return out
    return list(DEFAULT_PLOTTED_VARIANTS)
ENV_ORDER = [
    "bare",
    "container", "container-guest", "container-full",
    "vm", "vm-guest", "vm-full",
]

# ---------------------------------------------------------------------------
# Style
# ---------------------------------------------------------------------------

# Hard cap on output PNG dimensions (pixels). Set well clear of the legacy
# ≥ 2000-px threshold but still comfortable for paper viewers and embedded
# document workflows.
MAX_PIXELS = 2600
SAVE_DPI = 160


def setup_style() -> None:
    """Publication-friendly defaults. Call once at the start of main()."""
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


def _clamp_figsize(width: float, height: float) -> tuple[float, float]:
    """Scale (width, height) so neither side exceeds MAX_PIXELS at SAVE_DPI."""
    max_in = MAX_PIXELS / SAVE_DPI
    scale = min(1.0, max_in / max(width, 1e-9), max_in / max(height, 1e-9))
    return width * scale, height * scale


FORMATS: list[str] = ["png", "pdf"]


def _save(fig, path: Path, label: str) -> None:
    """Save figure to each configured format under <path.parent>/<format>/.

    The `path` argument carries the legacy .png filename for backwards
    compat with callers; the stem is reused for every format and the
    extension is replaced. With matplotlib defaults, PDFs are pure vector
    (scatter/line/bar/pcolormesh all draw as vector primitives) — paper-
    grade quality without an Inkscape round-trip."""
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


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_profiler_tsv(path: Path) -> pd.DataFrame:
    """Load one profiler.tsv. Returns DataFrame with columns ts + 7 metrics."""
    rows = []
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("ts") or line.startswith("netp"):
                continue
            parts = line.split()
            # Schema: ts netp nets blk mbw llcmr llcocc cpu  (8 cols)
            # or:     netp nets blk mbw llcmr llcocc cpu     (7 cols)
            # or:     ts time_ms netp nets blk mbw llcmr llcocc cpu  (9 cols, v1.1)
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


def collect_means(results_dir: Path) -> pd.DataFrame:
    """Load every profiler.tsv and return per-run mean per metric."""
    rows = []
    for f in results_dir.rglob("profiler.tsv"):
        parts = f.parts
        try:
            env = parts[-6]; variant = parts[-5]; stage = parts[-4]
            wl = parts[-3]; rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        if stage not in ("solo", "pairwise", "timeseries"):
            continue
        df = load_profiler_tsv(f)
        if df.empty:
            continue
        rec = dict(env=env, variant=variant, stage=stage, workload=wl,
                   rep=rep, samples=len(df))
        for m in METRICS:
            rec[m] = df[m].mean(skipna=True)
        rows.append(rec)
    return pd.DataFrame(rows)


def _ordered_variants(values) -> list[str]:
    present = set(values)
    return [v for v in VARIANT_ORDER if v in present]


def _ordered_envs(values) -> list[str]:
    present = set(values)
    return [e for e in ENV_ORDER if e in present]


def _grid_dims(n: int) -> tuple[int, int]:
    # Prefer square at n=4 (2x2 instead of 1x3 with a stranded last row)
    # and avoid wide-strip layouts on small panel counts.
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
    """Place n axes via gridspec; if the last row is partial, center it.
    Returns (flat_axes, nrows, ncols). Use index = i directly to address
    the i-th panel (no nested [r][c] indexing). wspace/hspace are gridspec
    spacing in fractions of axis width/height; increase to give tick
    labels in adjacent panels room."""
    nrows, ncols = _grid_dims(n)
    gs = fig.add_gridspec(nrows, 2 * ncols, wspace=wspace, hspace=hspace)
    axes: list = []
    base_y = None
    for i in range(n):
        r = i // ncols
        c_in_row = i % ncols
        last_row_n = n - r * ncols
        if r == nrows - 1 and last_row_n < ncols:
            offset = ncols - last_row_n  # pad both sides equally on 2x grid
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
                       gap_pixels: float = 12, **kwargs) -> None:
    """Place a suptitle centered horizontally on the bounding box of `axes`
    and `gap_pixels` above the tallest panel-with-title in pixel space.

    Two problems are solved at once:
    - When a colorbar is attached on the right via `fig.colorbar(im,
      ax=axes_flat, ...)`, the panel grid is shifted left and a default
      `x=0.5` suptitle appears visually off-center. We center on the
      panel-grid bbox instead.
    - The previous convention of `y=1.02` placed the suptitle outside
      the figure; with `bbox_inches="tight"` the saved image grew up to
      include it, leaving a blank band between title and first row. We
      measure the pixel top of each axis's *tight* bbox (which already
      includes the per-panel subplot title) and place the suptitle a
      fixed pixel gap above that — uniform visual spacing across
      figures of different physical sizes.

    Call after the colorbar is attached so axis positions reflect the
    final layout."""
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    visible = [ax for ax in axes if ax.get_visible()]
    if not visible:
        fig.suptitle(text, fontsize=fontsize, **kwargs)
        return
    pos = [ax.get_position() for ax in visible]
    x_mid = (min(p.x0 for p in pos) + max(p.x1 for p in pos)) / 2
    inv = fig.transFigure.inverted()
    tb_px = [ax.get_tightbbox(renderer) for ax in visible]
    top_frac = max(inv.transform((0, b.y1))[1]
                   for b in tb_px if b is not None)
    gap_frac = (inv.transform((0, gap_pixels))[1]
                - inv.transform((0, 0))[1])
    y = min(0.995, top_frac + gap_frac)
    fig.suptitle(text, x=x_mid, y=y, fontsize=fontsize, ha="center",
                 va="bottom", **kwargs)


# ---------------------------------------------------------------------------
# Fig 01 — IntP Fig. 4: per-workload panel grid, variants compared
# ---------------------------------------------------------------------------

def fig_per_workload_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Reproduces IntP paper Fig. 4. One small-multiple per workload.

    Within each panel: x-axis = metric, grouped bars = variant.
    A separate file is produced per environment so that variants are compared
    against each other (the new context: one tool, many variants).
    """
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[per_workload] no solo data — skip")
        return
    envs = _ordered_envs(solo["env"].unique())
    variants = _ordered_variants(solo["variant"].unique())
    workloads = sorted(solo["workload"].unique())
    if not (envs and variants and workloads):
        return

    grouped = (solo.groupby(["env", "variant", "workload"])[METRICS]
               .mean().reset_index())

    for env in envs:
        sub_env = grouped[grouped.env == env]
        if sub_env.empty:
            continue
        n = len(workloads)
        nrows, ncols = _grid_dims(n)
        fig = plt.figure(figsize=_clamp_figsize(2.6 * ncols, 2.0 * nrows))
        axes_flat, _, _ = _make_axes_grid(fig, n, sharey=True)
        x = np.arange(len(METRICS))
        bar_w = 0.8 / max(1, len(variants))
        for i, wl in enumerate(workloads):
            ax = axes_flat[i]
            for vi, variant in enumerate(variants):
                row = sub_env[(sub_env.variant == variant) & (sub_env.workload == wl)]
                vals = (row[METRICS].iloc[0].values if not row.empty
                        else np.full(len(METRICS), np.nan))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, np.nan_to_num(vals), width=bar_w,
                       color=VARIANT_COLORS.get(variant, f"C{vi}"),
                       edgecolor="white", linewidth=0.3,
                       label=variant if i == 0 else None)
            ax.set_xticks(x)
            ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
            ax.set_title(wl, fontsize=8.5)
            ymax = sub_env[METRICS].max().max()
            ax.set_ylim(0, max(1.0, float(ymax) * 1.10))
            ax.tick_params(axis="y", labelsize=7)
            if i % ncols == 0:
                ax.set_ylabel("interference (%)", fontsize=8)
        handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
                   for v in variants]
        fig.legend(handles, variants, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02 if nrows < 4 else 1.005),
                   ncol=len(variants), frameon=False, fontsize=8.5,
                   title="variant", title_fontsize=8.5)
        fig.suptitle(f"Per-workload variant fingerprint — env={env}  "
                     f"(IntP Fig. 4 reproduction)", y=1.04, fontsize=11)
        fig.tight_layout()
        suffix = f"_{env}" if len(envs) > 1 else ""
        _save(fig, outdir / f"fig01_per_workload_bars{suffix}.png", "fig01")


def fig_per_variant_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Per-(env,variant) workload×metric heatmap.

    Earlier versions of this script rendered grouped bars (18 workloads ×
    7 metrics per panel), which produced unreadable label density at
    two-column print width. The current layout encodes interference (%)
    as cell colour: rows = workloads (alphabetical, identical order across
    panels so the eye can track a workload row-by-row across variants),
    columns = metrics. One panel per (env, variant). Filename retained for
    paper-LaTeX compatibility."""
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    grouped = solo.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    pairs = grouped[["env", "variant"]].drop_duplicates().values.tolist()
    n = len(pairs)
    if n == 0:
        return
    workloads = sorted(grouped["workload"].unique())
    nrows, ncols = _grid_dims(n)
    panel_h = 0.26 * len(workloads) + 1.4   # per-panel target height in inches
    # Widen the per-panel slot enough that the right-column panels'
    # y-tick labels (the longest are app08/09_classification and
    # app15_query_inerge — ~19 chars at 7-pt) sit fully in the inter-panel
    # gutter without crossing into the adjacent panel's heatmap.
    fig = plt.figure(figsize=_clamp_figsize(5.6 * ncols, panel_h * nrows))
    axes_flat, _, _ = _make_axes_grid(fig, n, wspace=3.2, hspace=0.30)
    im = None
    for idx, (env, variant) in enumerate(pairs):
        ax = axes_flat[idx]
        sub = (grouped[(grouped.env == env) & (grouped.variant == variant)]
               .set_index("workload")
               .reindex(workloads)[METRICS]
               .fillna(0))
        im = ax.imshow(sub.values, aspect="auto", cmap="Blues",
                       vmin=0, vmax=100)
        # Per-cell numeric overlay so each workload's seven values are
        # readable directly without colour-to-percentage translation.
        # Text colour flips at the colormap midpoint for contrast; cells
        # at exactly zero are left blank to reduce visual noise.
        for i in range(sub.values.shape[0]):
            for j in range(sub.values.shape[1]):
                val = sub.values[i, j]
                if not np.isfinite(val) or val < 0.5:
                    continue
                txt_color = "black" if val < 55 else "white"
                ax.text(j, i, f"{val:.0f}", ha="center", va="center",
                        color=txt_color, fontsize=5.8)
        # Thin row separators help the eye tell adjacent workloads apart
        # (especially the app01/02/03_ml_llc-style sibling triplets).
        for i in range(1, len(workloads)):
            ax.axhline(i - 0.5, color="white", linewidth=0.45, alpha=0.55)
        ax.set_xticks(range(len(METRICS)))
        ax.set_xticklabels([METRIC_LABEL[m] for m in METRICS],
                           rotation=45, ha="right", fontsize=7)
        ax.set_yticks(range(len(workloads)))
        ax.set_yticklabels(workloads, fontsize=7)
        ax.set_title(f"{env} / {variant}", fontsize=9.5)
        ax.grid(False)
    if im is not None:
        fig.colorbar(im, ax=axes_flat, shrink=0.6, label="interference (%)")
    _centered_suptitle(fig, axes_flat,
                       "Per (env, variant) workload fingerprint")
    _save(fig, outdir / "fig01b_per_variant_bars.png", "fig01b")


# ---------------------------------------------------------------------------
# Fig 02 — IntP Fig. 5: PCA + k-means
# ---------------------------------------------------------------------------

def fig_pca_kmeans(means: pd.DataFrame, outdir: Path) -> None:
    """Joint PCA over (workload, variant) rows; variants overlaid in one panel.

    Earlier four-panel layout produced one PCA per variant with 18 labelled
    workloads each, which crowded labels into unreadable clumps. The
    current layout fits a single PCA on the concatenated per-(workload,
    variant) mean matrix, plots one marker per (workload, variant) pair
    (colour = workload-cluster from k-means on the per-workload mean,
    marker = variant), connects the variants of each workload with a
    faint polygon to make per-workload spread visible, and prints each
    workload label once at the centroid. The cross-variant agreement
    claim is then visually direct: tight polygons = agreement."""
    if not HAS_SKLEARN:
        return
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[pca] no solo data — skip")
        return
    env = "bare" if "bare" in solo["env"].values else solo["env"].iloc[0]
    sub = solo[solo.env == env]
    variants = _ordered_variants(sub["variant"].unique())
    workloads = sorted(sub["workload"].unique())
    if not variants or len(workloads) < 4:
        print("[pca] too few variants/workloads — skip")
        return

    # Long-form: one row per (workload, variant), columns = METRICS.
    g = (sub.groupby(["workload", "variant"])[METRICS].mean().fillna(0))
    try:
        pca = PCA(n_components=2)
        Y = pca.fit_transform(g.values)
    except Exception as e:
        print(f"[pca] joint PCA failed: {e}")
        return
    coords = pd.DataFrame(Y, index=g.index, columns=["PC1", "PC2"])

    # k-means on the per-workload mean across variants — gives one cluster
    # label per workload (colour stays consistent across the variants of
    # the same workload).
    means_per_wl = g.groupby("workload").mean().reindex(workloads)
    k = min(4, len(means_per_wl))
    km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(means_per_wl.values)
    cluster_of = dict(zip(means_per_wl.index, km.labels_))

    # Map each workload to a short metric-profile family inferred from its
    # name (appNN[a-z]*_<family>), then map family → canonical profile
    # token (net, streaming, query, …). The cluster label is built from
    # the distinct profiles present in the cluster, joined with "/", so
    # readers see "net" / "streaming/io" instead of opaque "cluster 1".
    def _workload_family(wl: str) -> str:
        m = re.match(r"app\d+[a-z]*_(.*)", wl)
        return m.group(1) if m else wl

    family_to_profile = {
        "ml_llc":         "cache",
        "streaming":      "streaming",
        "ordering":       "ordering",
        "classification": "classification",
        "search":         "search",
        "sort_net":       "sort/net",
        "tcp_veth":       "veth",
        "udp_veth":       "veth",
        "query_scan":     "query",
        "query_join":     "query",
        "query_inerge":   "query",
        "query_merge":    "query",
    }
    profile_of = {wl: family_to_profile.get(_workload_family(wl),
                                            _workload_family(wl))
                  for wl in workloads}

    def _cluster_label(members: list[str]) -> str:
        cnt = Counter(profile_of[m] for m in members)
        # Keep profiles in descending count order; ties broken by first
        # appearance. Show up to two profiles to keep labels short.
        ordered = [p for p, _ in cnt.most_common()]
        # Show up to three profiles joined with "/": enough to name the
        # dominant workload families in full and stay legible, without
        # the truncating ellipsis that produced unreadable labels such
        # as "cache/ordering/…".
        return "/".join(ordered[:3])

    cluster_members = {c: [wl for wl in workloads if cluster_of[wl] == c]
                       for c in range(k)}
    cluster_label_of = {c: _cluster_label(cluster_members[c]) for c in range(k)}

    cluster_palette = plt.get_cmap("Set2")
    variant_markers = {
        "v0": "X", "v0.1": "x", "v0.2": "P",
        "v1": "v", "v1.1": "o", "v2": "s",
        "v3": "^", "v3.1": "D", "v3.2": "*",
    }

    # Two-panel layout: scatter on the left, cluster→workload lookup on
    # the right. Per-workload labels were removed because at 18 workloads
    # × 4 variants the label density was unreadable in the dense regions
    # (app13–15 query family, app08/09 classification, app04/05
    # streaming). The cross-variant agreement claim now reads as
    # "markers of different shapes share the same colour-cluster"; the
    # sidebar resolves marker → workload identity.
    fig, (ax, side) = plt.subplots(
        1, 2, figsize=_clamp_figsize(11.4, 7.4),
        gridspec_kw={"width_ratios": [3.2, 1.0]},
    )

    # Per-workload centroids drive the connector polygons.
    centroids = (coords.groupby(level="workload")[["PC1", "PC2"]].mean()
                       .reindex(workloads))

    for wl in workloads:
        c = cluster_of[wl]
        face = cluster_palette(c)
        wl_pts = coords.xs(wl, level="workload")
        # faint connector polygon: shows per-workload variant spread
        if len(wl_pts) >= 2:
            xs = wl_pts["PC1"].values
            ys = wl_pts["PC2"].values
            ax.plot(np.append(xs, xs[0]), np.append(ys, ys[0]),
                    color=face, alpha=0.28, linewidth=0.6, zorder=1)
        # one marker per variant
        for v in variants:
            if (wl, v) not in coords.index:
                continue
            pc1, pc2 = coords.loc[(wl, v)]
            ax.scatter(pc1, pc2, s=72, color=face, alpha=0.85,
                       edgecolor="black", linewidth=0.5,
                       marker=variant_markers.get(v, "o"), zorder=3)

    ax.axhline(0, color="gray", linewidth=0.5, linestyle=":")
    ax.axvline(0, color="gray", linewidth=0.5, linestyle=":")
    ax.set_xlabel(f"PC1 ({pca.explained_variance_ratio_[0]*100:.1f}%)")
    ax.set_ylabel(f"PC2 ({pca.explained_variance_ratio_[1]*100:.1f}%)")

    # In-axes legend: variant (marker) only. The workload-cluster colour key is
    # already given by the "Workloads by cluster" sidebar, so the redundant
    # lower-left cluster legend is omitted.
    from matplotlib.lines import Line2D
    var_handles = [Line2D([0], [0], marker=variant_markers.get(v, "o"),
                          color="w", markerfacecolor="lightgray",
                          markeredgecolor="black", markersize=8,
                          label=_variant_label(v))
                   for v in variants]
    ax.legend(handles=var_handles, loc="upper left",
              title="variant", fontsize=8, title_fontsize=8.5)

    # Sidebar: workloads grouped by cluster, with the cluster's colour
    # swatch in front of each block. Replaces per-marker labelling.
    side.axis("off")
    side.set_xlim(0, 1); side.set_ylim(0, 1)
    side.text(0.0, 0.99, "Workloads by cluster", fontsize=10,
              fontweight="bold", va="top")
    y_cur = 0.93
    line_h = 0.034
    for c in range(k):
        members = cluster_members[c]
        if not members:
            continue
        side.text(0.0, y_cur, "■", color=cluster_palette(c),
                  fontsize=14, va="top")
        header = cluster_label_of[c] or f"cluster {c+1}"
        side.text(0.10, y_cur - 0.005, header,
                  fontsize=9, fontweight="bold", va="top")
        y_cur -= line_h
        for wl in members:
            side.text(0.10, y_cur, wl, fontsize=8, va="top",
                      family="DejaVu Sans Mono")
            y_cur -= line_h * 0.85
        y_cur -= line_h * 0.4

    fig.tight_layout()
    _centered_suptitle(fig, [ax, side],
                       f"PCA + k-means clustering of workloads — env={env} "
                       f"(joint fit, variants overlaid)",
                       fontsize=10.5)
    _save(fig, outdir / "fig02_pca_kmeans.png", "fig02")


# ---------------------------------------------------------------------------
# Fig 03 — IntP Fig. 3: long mixed-load trace
# ---------------------------------------------------------------------------

def _smooth(arr: np.ndarray, window: int = 9) -> np.ndarray:
    if len(arr) < window:
        return arr
    kernel = np.ones(window) / window
    return np.convolve(arr, kernel, mode="same")


def fig_timeseries(results_dir: Path, outdir: Path) -> None:
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        print("[timeseries] no timeseries data — skip")
        return
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(8 * cols, 3.4 * rows),
                             squeeze=False, sharex=False)
    last_idx = -1
    for idx, f in enumerate(sorted(files)):
        last_idx = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = df["ts"] - df["ts"].min()
        else:
            t = np.arange(len(df))
        for m in METRICS:
            if m in df.columns:
                y = _smooth(df[m].fillna(0).values, window=7)
                ax.plot(t, y, label=METRIC_LABEL[m],
                        color=METRIC_COLORS[m], linewidth=1.1, alpha=0.9)
        ax.set_title(f"{env} / {variant} — mixed_long")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference level")
        ax.set_ylim(-2, 105)
    for j in range(last_idx + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(METRICS), frameon=False, fontsize=8)
    fig.suptitle("Long-trace interference profile (IntP Fig. 3 reproduction)",
                 y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig03_timeseries.png", "fig03")


# ---------------------------------------------------------------------------
# Fig 04 — Profiler overhead, three layers
#
#   (A) workload throughput slowdown:   throughput.tsv (bogo_ops_per_s_real)
#   (B) extra system-wide CPU jiffies:  cpu_stat.tsv (busy delta over window)
#   (C) Volpert scheduler perturbation: perf_stat.csv (Δ sched_switch, opt-in)
#
# Each figure shows arms grouped by ref (x), one panel per env (rows). Bars
# are arm−baseline; positive = profiler was costly. Std-error bars come from
# the per-rep variance.
# ---------------------------------------------------------------------------


def _read_kv_tsv(path: Path) -> dict[str, float]:
    """Read a 2-column TSV (header `metric\\tvalue`). Returns {metric: float}.
    Non-numeric values become NaN; missing files return {}."""
    out: dict[str, float] = {}
    try:
        with path.open() as f:
            f.readline()  # header
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                k = parts[0]
                try:
                    out[k] = float(parts[1])
                except ValueError:
                    out[k] = float("nan")
    except OSError:
        pass
    return out


def _read_perf_stat_csv(path: Path) -> dict[str, float]:
    """Parse `perf stat -x ,` output. Returns {event: count}."""
    out: dict[str, float] = {}
    try:
        with path.open() as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(",")
                # Format: <count>,<unit>,<event>,<run_time>,<percent_run>,...
                if len(parts) < 3:
                    continue
                try:
                    val = float(parts[0])
                except ValueError:
                    continue
                event = parts[2]
                if event:
                    out[event] = val
    except OSError:
        pass
    return out


def _collect_overhead_rows(results_dir: Path) -> pd.DataFrame:
    """Walk results_dir/overhead, gather per-(env,variant,ref,rep) metrics."""
    rows: list[dict] = []
    overhead_root = results_dir / "overhead"
    if not overhead_root.is_dir():
        return pd.DataFrame()
    for elapsed_file in overhead_root.rglob("elapsed_s"):
        rep_dir = elapsed_file.parent
        parts = elapsed_file.parts
        try:
            env = parts[-5]; variant = parts[-4]; refid = parts[-3]
            rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        try:
            elapsed = float(elapsed_file.read_text().strip())
        except (ValueError, OSError):
            elapsed = float("nan")
        thr  = _read_kv_tsv(rep_dir / "throughput.tsv")
        cpu  = _read_kv_tsv(rep_dir / "cpu_stat.tsv")
        cgcp = _read_kv_tsv(rep_dir / "cgroup_cpu_stat.tsv")
        perf = _read_perf_stat_csv(rep_dir / "perf_stat.csv")
        rows.append(dict(
            env=env, variant=variant, ref=refid, rep=rep,
            elapsed=elapsed,
            bogo_ops_per_s=thr.get("bogo_ops_per_s_real", float("nan")),
            cpu_busy_jiffies=cpu.get("busy", float("nan")),
            cpu_total_jiffies=cpu.get("total", float("nan")),
            cgroup_usage_usec=cgcp.get("usage_usec", float("nan")),
            cs=perf.get("context-switches", float("nan")),
            mig=perf.get("cpu-migrations", float("nan")),
            sched_switch=perf.get("sched:sched_switch", float("nan")),
            sched_wakeup=perf.get("sched:sched_wakeup", float("nan")),
        ))
    return pd.DataFrame(rows)


def _render_overhead_bars(summary: pd.DataFrame, mean_col: str, std_col: str | None,
                          ylabel: str, path: Path, label: str, *, title: str) -> None:
    """Per-(env) panel grid: x=ref, grouped bars=variant, y=mean (± std)."""
    if mean_col not in summary.columns or summary[mean_col].dropna().empty:
        print(f"[{label}] no data for {mean_col} — skip")
        return
    refs = sorted(summary["ref"].unique())
    envs = _ordered_envs(summary["env"].unique())
    fig, axes = plt.subplots(len(envs), 1,
                             figsize=_clamp_figsize(7.5, 2.8 * len(envs) + 0.4),
                             squeeze=False, sharey=True)
    all_variants: list[str] = []
    for i, env in enumerate(envs):
        ax = axes[i][0]
        sub = summary[summary.env == env]
        variants_present = _ordered_variants(sub["variant"].unique())
        for v in variants_present:
            if v not in all_variants:
                all_variants.append(v)
        x = np.arange(len(refs))
        width = 0.8 / max(1, len(variants_present))
        for j, v in enumerate(variants_present):
            row = sub[sub.variant == v].set_index("ref").reindex(refs)
            errs = None
            if std_col and std_col in row.columns:
                errs = row[std_col].fillna(0).values
            ax.bar(x + (j - (len(variants_present) - 1) / 2) * width,
                   row[mean_col].values,
                   yerr=errs, width=width,
                   color=VARIANT_COLORS.get(v, f"C{j}"),
                   label=v if i == 0 else None, capsize=2)
        ax.set_xticks(x); ax.set_xticklabels(refs, rotation=15)
        ax.set_ylabel(ylabel); ax.set_title(f"env={env}")
        ax.axhline(0, color="black", linewidth=0.5)
    handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
               for v in all_variants]
    fig.legend(handles, all_variants, loc="upper center",
               bbox_to_anchor=(0.5, 1.04),
               ncol=max(1, len(all_variants)), frameon=False, fontsize=9,
               title="variant", title_fontsize=9)
    fig.suptitle(title, y=1.10)
    fig.tight_layout()
    _save(fig, path, label)


def fig_overhead_bars(results_dir: Path, outdir: Path) -> None:
    df = _collect_overhead_rows(results_dir)
    if df.empty:
        print("[overhead] no overhead data — skip")
        return
    df.to_csv(outdir / "overhead_raw.csv", index=False)

    # Baselines: a campaign normally measures one shared "_baseline" in the same
    # session as its arms, so a single (env, ref) reference is correct. When
    # variants are fused from different sessions (e.g. a v3.2 re-run on a clean
    # host), each arm MUST be divided by the baseline from ITS OWN session — the
    # no-profiler reference drifts across runs (the disk subsystem especially),
    # so a cross-session ratio fabricates overhead that is pure baseline drift.
    # Convention: a per-variant directory "_baseline.<variant>" overrides the
    # shared "_baseline" for that variant; absent it, the shared baseline is
    # used (backward-compatible with single-session campaigns).
    is_base = df.variant.str.startswith("_baseline")
    base_all = (df[is_base]
                .groupby(["variant", "env", "ref"])
                .agg(base_bogo=("bogo_ops_per_s",     "mean"),
                     base_busy=("cpu_busy_jiffies",   "mean"),
                     base_cs  =("cs",                 "mean"),
                     base_mig =("mig",                "mean"),
                     base_ss  =("sched_switch",       "mean"),
                     base_sw  =("sched_wakeup",       "mean"))
                .reset_index())
    if base_all.empty:
        print("[overhead] no _baseline rows; cannot compute deltas — skip")
        return

    available_base = set(base_all["variant"])
    def _baseline_for(variant: str) -> str:
        specific = f"_baseline.{variant}"
        return specific if specific in available_base else "_baseline"

    arms = df[~is_base].copy()
    arms["base_variant"] = arms["variant"].map(_baseline_for)
    arms = arms.merge(base_all.rename(columns={"variant": "base_variant"}),
                      on=["base_variant", "env", "ref"], how="left")

    # (A) Throughput overhead %: positive = workload got slower.
    arms["throughput_overhead_pct"] = (
        (arms["base_bogo"] - arms["bogo_ops_per_s"]) / arms["base_bogo"] * 100.0
    )
    # (B) System-wide busy CPU jiffies, arm − baseline.
    arms["cpu_extra_jiffies"] = arms["cpu_busy_jiffies"] - arms["base_busy"]
    # (C) Volpert deltas — NaN when --overhead-volpert was off.
    arms["delta_cs"]  = arms["cs"]           - arms["base_cs"]
    arms["delta_mig"] = arms["mig"]          - arms["base_mig"]
    arms["delta_ss"]  = arms["sched_switch"] - arms["base_ss"]
    arms["delta_sw"]  = arms["sched_wakeup"] - arms["base_sw"]

    metric_cols = ["throughput_overhead_pct", "cpu_extra_jiffies",
                   "delta_cs", "delta_mig", "delta_ss", "delta_sw"]
    summary = (arms.groupby(["env", "variant", "ref"])[metric_cols]
               .agg(["mean", "std"]))
    summary.columns = [f"{m}_{stat}" for m, stat in summary.columns]
    summary = summary.reset_index()
    summary.to_csv(outdir / "overhead_summary.csv", index=False)

    # (A) Throughput slowdown
    _render_overhead_bars(
        summary,
        "throughput_overhead_pct_mean", "throughput_overhead_pct_std",
        "throughput overhead (%)",
        outdir / "fig04_overhead_throughput.png", "fig04",
        title="Profiler-induced workload slowdown\n"
              "(baseline − with-profiler) / baseline of stress-ng bogo ops/s")

    # (B) Extra system-wide CPU jiffies
    _render_overhead_bars(
        summary,
        "cpu_extra_jiffies_mean", "cpu_extra_jiffies_std",
        "Δ busy jiffies (arm − baseline)",
        outdir / "fig04b_overhead_cpu_jiffies.png", "fig04b",
        title="Extra system-wide CPU induced by the profiler\n"
              "/proc/stat busy jiffies over the steady-state window")

    # (C) Volpert flavour: scheduler perturbation
    if summary.get("delta_ss_mean", pd.Series(dtype=float)).notna().any():
        _render_overhead_bars(
            summary,
            "delta_ss_mean", "delta_ss_std",
            "Δ sched:sched_switch events",
            outdir / "fig04c_overhead_sched_switch.png", "fig04c",
            title="Volpert-flavoured scheduler perturbation\n"
                  "Δ sched:sched_switch over the steady-state window "
                  "(perf stat -a)")
    else:
        print("[fig04c] no perf_stat.csv data (run with --overhead-volpert) — skip")


# ---------------------------------------------------------------------------
# Fig 05 — Fidelity (profiler vs ground-truth)
# ---------------------------------------------------------------------------

def fig_fidelity_matrix(results_dir: Path, outdir: Path) -> None:
    pair_map = {
        "cpu":    "cpu_busy_pct",
        "mbw":    "resctrl_mbw_bps",
        "llcocc": "resctrl_llcocc_bytes",
        "blk":    "disk_total_mb",
        "netp":   "net_total_mb",
    }
    rows = []
    for prof_path in results_dir.rglob("solo/**/profiler.tsv"):
        gt_path = prof_path.parent / "groundtruth.tsv"
        if not gt_path.exists(): continue
        try:
            prof = load_profiler_tsv(prof_path)
            gt = pd.read_csv(gt_path, sep="\t")
        except Exception:
            continue
        if prof.empty or gt.empty or "ts" not in prof or "ts" not in gt: continue
        for c in ("disk_read_mb", "disk_write_mb", "net_rx_mb", "net_tx_mb"):
            if c in gt: gt[c] = pd.to_numeric(gt[c], errors="coerce").fillna(0)
        gt["disk_total_mb"] = gt.get("disk_read_mb", 0) + gt.get("disk_write_mb", 0)
        gt["net_total_mb"]  = gt.get("net_rx_mb", 0)   + gt.get("net_tx_mb", 0)
        # Align by wall-clock timestamp, NOT row index. The profiler starts
        # after the workload warm-up (~5-13 s here) and drops samples on read
        # timeouts, so the i-th profiler row is not the i-th ground-truth row;
        # index alignment (the previous method) shears the two series apart and
        # collapses the correlation toward zero. Drop the first few ground-truth
        # rows to shed the counter-startup spike (e.g. a ~900 GB disk_write_mb
        # delta in row 0), then pair each profiler sample to the nearest
        # ground-truth sample within 0.75 s.
        prof = prof.copy(); gt = gt.iloc[3:].copy()
        prof["ts"] = pd.to_numeric(prof["ts"], errors="coerce")
        gt["ts"]   = pd.to_numeric(gt["ts"], errors="coerce")
        prof = prof.dropna(subset=["ts"]).sort_values("ts")
        gt   = gt.dropna(subset=["ts"]).sort_values("ts")
        if len(prof) < 5 or len(gt) < 5: continue
        gt_cols = [c for c in dict.fromkeys(pair_map.values()) if c in gt.columns]
        merged = pd.merge_asof(prof, gt[["ts"] + gt_cols], on="ts",
                               direction="nearest", tolerance=0.75)
        env = prof_path.parts[-6]; variant = prof_path.parts[-5]
        for metric, gt_col in pair_map.items():
            if metric not in merged or gt_col not in merged: continue
            a = pd.to_numeric(merged[metric], errors="coerce")
            b = pd.to_numeric(merged[gt_col], errors="coerce")
            mask = a.notna() & b.notna()
            if mask.sum() < 5 or a[mask].std() == 0 or b[mask].std() == 0: continue
            r = float(np.corrcoef(a[mask], b[mask])[0, 1])
            rows.append(dict(env=env, variant=variant, metric=metric, r=r))
    if not rows:
        print("[fidelity] no fidelity data — skip")
        return
    df = pd.DataFrame(rows)
    df = df.groupby(["env", "variant", "metric"])["r"].mean().reset_index()
    df.to_csv(outdir / "fidelity_matrix.csv", index=False)

    pivot = df.pivot_table(index="variant", columns="metric", values="r", aggfunc="mean")
    pivot = pivot.reindex(index=_ordered_variants(pivot.index),
                          columns=[m for m in pair_map if m in pivot.columns])
    fig, ax = plt.subplots(figsize=_clamp_figsize(6.5, 0.7 * len(pivot) + 1.4))
    masked = np.ma.masked_invalid(pivot.values)
    cmap = plt.get_cmap("RdBu_r").copy()
    cmap.set_bad(color="#dddddd")
    im = ax.imshow(masked, vmin=-1, vmax=1, cmap=cmap, aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        if np.isnan(v):
            ax.text(j, i, "n/a", ha="center", va="center", fontsize=8, color="#666")
        else:
            ax.text(j, i, f"{v:+.2f}", ha="center", va="center",
                    fontsize=8, color="black" if abs(v) < 0.5 else "white")
    ax.set_title("Profiler vs ground-truth Pearson r (solo)")
    cbar = fig.colorbar(im, ax=ax, fraction=0.04, label="Pearson r")
    cbar.ax.tick_params(labelsize=7)
    ax.grid(False)
    fig.tight_layout()
    _save(fig, outdir / "fig05_fidelity_matrix.png", "fig05")


# ---------------------------------------------------------------------------
# Fig 06 — Env degradation ratio heatmap
# ---------------------------------------------------------------------------

def fig_env_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    solo = means[means.stage == "solo"]
    if solo.empty or solo["env"].nunique() < 2:
        print("[env_heatmap] need ≥2 envs — skip")
        return
    g = solo.groupby(["env", "variant"])[METRICS].mean().reset_index()
    bare = g[g.env == "bare"].set_index("variant")
    out_rows = []
    for env in [e for e in ENV_ORDER if e in g["env"].values and e != "bare"]:
        sub = g[g.env == env].set_index("variant")
        for variant in sub.index:
            if variant not in bare.index: continue
            for m in METRICS:
                b = bare.loc[variant, m]; o = sub.loc[variant, m]
                if pd.isna(b) or b == 0: continue
                out_rows.append(dict(env=env, variant=variant, metric=m, ratio=o / b))
    if not out_rows:
        return
    df = pd.DataFrame(out_rows)
    df.to_csv(outdir / "env_ratio.csv", index=False)
    envs_present = _ordered_envs(df["env"].unique())
    fig, axes = plt.subplots(1, len(envs_present),
                             figsize=_clamp_figsize(5.4 * len(envs_present), 3.4),
                             squeeze=False)
    for i, env in enumerate(envs_present):
        ax = axes[0][i]
        sub = df[df.env == env]
        pivot = sub.pivot_table(index="variant", columns="metric", values="ratio")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index))
        im = ax.imshow(pivot.values, cmap="PiYG", vmin=0, vmax=2, aspect="auto")
        ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
        ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
        ax.set_title(f"{env} / bare")
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.2f}", ha="center", va="center", fontsize=7)
        ax.grid(False)
        fig.colorbar(im, ax=ax, fraction=0.04)
    fig.suptitle("Metric ratio across execution environments (1.0 = matches bare)", y=1.02)
    fig.tight_layout()
    _save(fig, outdir / "fig06_env_heatmap.png", "fig06")


# ---------------------------------------------------------------------------
# Fig 07 — Pairwise heatmap, per-variant panel of (workload-pair × metric)
# ---------------------------------------------------------------------------

def fig_pairwise_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    pair = means[means.stage == "pairwise"]
    if pair.empty:
        print("[pairwise] no pairwise data — skip")
        return
    g = pair.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    g.to_csv(outdir / "pairwise_means.csv", index=False)
    envs = _ordered_envs(g["env"].unique())
    workloads = sorted(g["workload"].unique())
    for env in envs:
        sub_env = g[g.env == env]
        if sub_env.empty: continue
        variants = _ordered_variants(sub_env["variant"].unique())
        nv = len(variants)
        nrows, ncols = _grid_dims(nv)
        fig = plt.figure(figsize=_clamp_figsize(
            5.2 * ncols, (0.30 * len(workloads) + 1.4) * nrows))
        # Long workload names ("cpu_v_cache", "tcp_v_tcp_veth") need extra
        # horizontal gap to keep y-labels out of the adjacent panel.
        axes_flat, _, _ = _make_axes_grid(fig, nv, sharey=True, wspace=1.4,
                                          hspace=0.30)
        im = None
        for idx, variant in enumerate(variants):
            ax = axes_flat[idx]
            data = np.zeros((len(workloads), len(METRICS)))
            for wi, w in enumerate(workloads):
                row = sub_env[(sub_env.variant == variant) & (sub_env.workload == w)]
                if not row.empty:
                    data[wi] = row[METRICS].iloc[0].values
                else:
                    data[wi] = np.nan
            masked = np.ma.masked_invalid(data)
            cmap = plt.get_cmap("Blues").copy()
            cmap.set_bad(color="#cccccc")
            im = ax.imshow(masked, cmap=cmap, aspect="auto", vmin=0, vmax=100)
            ax.set_xticks(range(len(METRICS))); ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
            ax.set_yticks(range(len(workloads))); ax.set_yticklabels(workloads, fontsize=7)
            ax.set_title(f"variant={variant}", fontsize=9)
            ax.grid(False)
        if im is not None:
            fig.colorbar(im, ax=axes_flat, shrink=0.8, label="interference (%)")
        _centered_suptitle(fig, axes_flat,
                           f"Pairwise interference signal — env={env}")
        _save(fig, outdir / f"fig07_pairwise_heatmap_{env}.png", f"fig07-{env}")


# ---------------------------------------------------------------------------
# Fig 08 — Metric availability
# ---------------------------------------------------------------------------

def fig_metric_availability(means: pd.DataFrame, outdir: Path) -> None:
    if means.empty: return
    avail_rows = []
    for variant in _ordered_variants(means["variant"].unique()):
        sub = means[means.variant == variant]
        for m in METRICS:
            ok = sub[m].notna().any() and (sub[m].fillna(0).abs().sum() > 0)
            avail_rows.append(dict(variant=variant, metric=m, available=int(ok)))
    df = pd.DataFrame(avail_rows)
    df.to_csv(outdir / "metric_availability.csv", index=False)
    pivot = df.pivot_table(index="variant", columns="metric", values="available")
    pivot = pivot.reindex(index=_ordered_variants(pivot.index),
                          columns=METRICS)
    fig, ax = plt.subplots(figsize=_clamp_figsize(6.2, 0.5 * len(pivot) + 1.2))
    cmap = ListedColormap(["#f4f4f4", "#2ca02c"])
    im = ax.imshow(pivot.values, cmap=cmap, vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        ax.text(j, i, "✓" if v else "—", ha="center", va="center",
                fontsize=10, color="white" if v else "#666")
    ax.set_title("Metric availability per variant (any non-zero reading)")
    ax.grid(False)
    fig.tight_layout()
    _save(fig, outdir / "fig08_metric_availability.png", "fig08")


# ---------------------------------------------------------------------------
# Fig 09 — Radar fingerprint per workload (variants overlaid)
# ---------------------------------------------------------------------------

def fig_radar_fingerprint(means: pd.DataFrame, outdir: Path) -> None:
    """Per-workload radar chart, one polygon per variant.

    Inspired by IntP Fig. 4 but emphasising shape comparison rather than bar
    height. Uses the bare environment when available.
    """
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    env = "bare" if "bare" in solo["env"].values else solo["env"].iloc[0]
    sub = solo[solo.env == env]
    workloads = sorted(sub["workload"].unique())
    variants = _ordered_variants(sub["variant"].unique())
    if not workloads or not variants:
        return
    # Normalise each metric across all (workload,variant) so radar shapes are
    # comparable. Avoid division by zero.
    grouped = sub.groupby(["workload", "variant"])[METRICS].mean().reset_index()
    norms = {m: max(1e-9, grouped[m].max()) for m in METRICS}

    n = len(workloads)
    nrows, ncols = _grid_dims(n)
    fig = plt.figure(figsize=_clamp_figsize(3.2 * ncols, 3.0 * nrows))
    axes_flat, _, _ = _make_axes_grid(fig, n, polar=True)
    angles = np.linspace(0, 2 * np.pi, len(METRICS), endpoint=False).tolist()
    angles += angles[:1]
    for i, wl in enumerate(workloads):
        ax = axes_flat[i]
        for variant in variants:
            row = grouped[(grouped.workload == wl) & (grouped.variant == variant)]
            if row.empty: continue
            vals = [row[m].iloc[0] / norms[m] for m in METRICS]
            vals += vals[:1]
            color = VARIANT_COLORS.get(variant, "C0")
            ax.plot(angles, vals, color=color, linewidth=1.9, alpha=0.95,
                    label=variant)
            ax.fill(angles, vals, color=color, alpha=0.06)
        ax.set_xticks(angles[:-1])
        ax.set_xticklabels(METRICS, fontsize=7.5)
        ax.set_yticks([0.25, 0.5, 0.75, 1.0])
        # Show ring values only on the first panel to keep others uncluttered.
        if i == 0:
            ax.set_yticklabels(["0.25", "0.50", "0.75", "1.00"], fontsize=6,
                               color="#555")
        else:
            ax.set_yticklabels(["", "", "", ""])
        ax.set_ylim(0, 1.05)
        ax.set_title(wl, fontsize=9, pad=10)
        ax.tick_params(axis="x", pad=2)
        ax.grid(linewidth=0.4, alpha=0.5)
    handles = [plt.Line2D([0], [0], color=VARIANT_COLORS.get(v, "C0"),
                          linewidth=2.4, label=v) for v in variants]
    fig.legend(handles=handles, loc="upper center",
               bbox_to_anchor=(0.5, 1.02),
               ncol=len(variants), frameon=False, fontsize=9.5,
               title="variant", title_fontsize=9.5)
    fig.suptitle(f"Per-workload radar fingerprint — env={env}  "
                 f"(metrics scaled to per-metric maximum)",
                 y=1.06, fontsize=10.5)
    fig.tight_layout()
    _save(fig, outdir / "fig09_radar_fingerprint.png", "fig09")


# ---------------------------------------------------------------------------
# Fig 10 — Workload clustermap (hierarchical) per variant
# ---------------------------------------------------------------------------

def fig_workload_clustermap(means: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SCIPY:
        return
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    env = "bare" if "bare" in solo["env"].values else solo["env"].iloc[0]
    sub = solo[solo.env == env]
    variants = _ordered_variants(sub["variant"].unique())
    if not variants:
        return
    n = len(variants)
    nrows, ncols = _grid_dims(n)
    fig = plt.figure(figsize=_clamp_figsize(5.4 * ncols,
                                            0.32 * sub["workload"].nunique() + 1.4))
    # Wide wspace: stress-ng workload labels are 12-18 chars and must not
    # bleed into the adjacent panel's plot area.
    axes_flat, _, _ = _make_axes_grid(fig, n, wspace=1.6, hspace=0.30)
    im = None
    for idx, variant in enumerate(variants):
        ax = axes_flat[idx]
        m = (sub[sub.variant == variant]
             .groupby("workload")[METRICS].mean().fillna(0))
        if m.shape[0] < 2:
            ax.set_title(f"variant={variant} — too few"); ax.axis("off"); continue
        try:
            Z = linkage(m.values, method="ward")
            order = leaves_list(Z)
        except Exception:
            order = np.arange(len(m))
        m = m.iloc[order]
        im = ax.imshow(m.values, aspect="auto", cmap="Blues", vmin=0, vmax=100)
        ax.set_xticks(range(len(METRICS))); ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
        ax.set_yticks(range(len(m.index))); ax.set_yticklabels(m.index, fontsize=7)
        ax.set_title(f"variant={variant} (Ward linkage)", fontsize=9)
        ax.grid(False)
    if im is None:
        print("[fig10] no variant had ≥2 workloads — skip clustermap")
        plt.close(fig)
        return
    fig.colorbar(im, ax=axes_flat, shrink=0.7, label="interference (%)")
    _centered_suptitle(fig, axes_flat,
                       f"Hierarchical workload clustermap — env={env}")
    _save(fig, outdir / "fig10_workload_clustermap.png", "fig10")


# ---------------------------------------------------------------------------
# Fig 11 — IADA Fig. 6 inspired: Δ pairwise − solo per resource
# ---------------------------------------------------------------------------

def fig_idi_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Resource-level interference degradation: (pairwise mean) − (solo mean).

    Mirrors IADA Fig. 6 where each resource has bars per intensity level. Here
    the levels are the variants, and the resource families are the IntP groups
    {cpu, memory, disk, cache, network}.
    """
    if {"solo", "pairwise"} - set(means["stage"].unique()):
        print("[idi] need both solo and pairwise — skip")
        return
    env = "bare" if "bare" in means["env"].values else means["env"].iloc[0]
    sub = means[means.env == env]
    variants = _ordered_variants(sub["variant"].unique())
    if not variants:
        return
    rows = []
    for variant in variants:
        s = sub[(sub.variant == variant) & (sub.stage == "solo")]
        p = sub[(sub.variant == variant) & (sub.stage == "pairwise")]
        if s.empty or p.empty: continue
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in s.columns]
            if not members: continue
            s_v = s[members].mean().mean()
            p_v = p[members].mean().mean()
            if pd.isna(s_v) or pd.isna(p_v): continue
            rows.append(dict(variant=variant, resource=fam,
                             solo=s_v, pair=p_v, delta=p_v - s_v))
    if not rows:
        return
    df = pd.DataFrame(rows)
    df.to_csv(outdir / "idi_resource.csv", index=False)
    resources = list(RESOURCE_FAMILY.keys())
    fig, ax = plt.subplots(figsize=_clamp_figsize(7.2, 3.6))
    x = np.arange(len(resources))
    width = 0.8 / max(1, len(variants))
    for vi, variant in enumerate(variants):
        offsets = (vi - (len(variants) - 1) / 2) * width
        vals = [df[(df.variant == variant) & (df.resource == r)]["delta"].mean()
                for r in resources]
        ax.bar(x + offsets, vals, width=width,
               color=VARIANT_COLORS.get(variant, f"C{vi}"),
               edgecolor="white", linewidth=0.4, label=variant)
    ax.set_xticks(x); ax.set_xticklabels(resources)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_ylabel("Δ interference (pairwise − solo, %)")
    ax.set_title(f"Interference degradation by resource — env={env}\n"
                 f"(IADA Fig. 6 reproduction)", fontsize=10)
    ax.legend(ncol=len(variants), fontsize=8.5, loc="upper center",
              bbox_to_anchor=(0.5, -0.12))
    fig.tight_layout()
    _save(fig, outdir / "fig11_idi_bars.png", "fig11")


# ---------------------------------------------------------------------------
# Fig 12 — IntP Fig. 8 style multi-resource trace per pair (timeseries)
# ---------------------------------------------------------------------------

def fig_pairwise_timeseries(results_dir: Path, outdir: Path) -> None:
    """For each (env, variant) overlay 4 resource-family lines (Cache/CPU/
    Disk/Memory) over the long mixed-load trace. Reproduces the look of
    IntP Fig. 8 (4-line interference levels per node)."""
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        return
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(8 * cols, 3.4 * rows),
                             squeeze=False, sharex=False)
    last = -1
    for idx, f in enumerate(sorted(files)):
        last = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = df["ts"] - df["ts"].min()
        else:
            t = np.arange(len(df))
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            mean_series = df[members].mean(axis=1).fillna(0).values
            y = _smooth(mean_series, window=11)
            ax.plot(t, y, color=RESOURCE_COLORS[fam], linewidth=1.3,
                    label=fam.capitalize(), alpha=0.95)
        ax.set_title(f"{env} / {variant}")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference (%)")
        ax.set_ylim(-2, 105)
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(handles), frameon=False, fontsize=9)
    fig.suptitle("Resource-family trace over the mixed-load timeseries "
                 "(IntP Fig. 8 reproduction)", y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig12_pairwise_timeseries.png", "fig12")


# ---------------------------------------------------------------------------
# Fig 13 — IADA Fig. 5 reproduction: Loess-smoothed segmented timeseries.
# Splits each (env,variant) trace into N equal segments and overlays the
# resource-family interference levels (Cache/CPU/Disk/Memory/Network) with
# vertical phase markers — same visual idiom as IADA Fig. 5 (segmented
# TPC-H interference classification with smoothed lines per resource).
# ---------------------------------------------------------------------------

def _loess_smooth(y: np.ndarray, frac: float = 0.20) -> np.ndarray:
    """Cheap 1-D loess substitute: rolling window mean. Avoids the statsmodels
    dependency. ``frac`` is the window fraction relative to len(y)."""
    n = len(y)
    if n < 5:
        return y
    win = max(5, int(n * frac))
    if win % 2 == 0:
        win += 1
    pad = win // 2
    padded = np.pad(y, pad, mode="edge")
    kernel = np.ones(win) / win
    return np.convolve(padded, kernel, mode="valid")


def fig_iada_segmented(results_dir: Path, outdir: Path, n_segments: int = 4) -> None:
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        print("[iada_segmented] no timeseries data — skip")
        return
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(7.6 * cols, 3.0 * rows),
                             squeeze=False, sharex=False)
    last = -1
    for idx, f in enumerate(sorted(files)):
        last = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = (df["ts"] - df["ts"].min()).values
        else:
            t = np.arange(len(df), dtype=float)
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            mean_series = df[members].mean(axis=1).fillna(0).values
            ys = _loess_smooth(mean_series, frac=0.18)
            ax.plot(t, ys, color=RESOURCE_COLORS[fam], linewidth=1.5,
                    label=fam.capitalize(), alpha=0.95)
        # Segment dividers
        if len(t) > 1:
            tmax = float(t[-1])
            for s in range(1, n_segments):
                ax.axvline(tmax * s / n_segments, color="#444", linewidth=0.7,
                           linestyle="--", alpha=0.55)
            # Segment labels (top)
            for s in range(n_segments):
                xpos = tmax * (s + 0.5) / n_segments
                ax.text(xpos, 102, f"seg {s+1}", ha="center", va="bottom",
                        fontsize=7, color="#333")
        ax.set_title(f"{env} / {variant}")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference (%)")
        ax.set_ylim(-2, 110)
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(handles), frameon=False, fontsize=9)
    fig.suptitle("Segmented Loess-smoothed interference trace "
                 "(IADA Fig. 5 reproduction)", y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig13_iada_segmented.png", "fig13")


# ---------------------------------------------------------------------------
# Fig 14 — Variant × resource summary (NEW visualisation).
# A single compact heatmap making it easy to compare which variants surface
# which resource families. Useful when the experimental matrix grows.
# ---------------------------------------------------------------------------

def fig_variant_resource_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    if means.empty:
        return
    rows: list[dict] = []
    for env in _ordered_envs(means["env"].unique()):
        sub_e = means[means.env == env]
        for variant in _ordered_variants(sub_e["variant"].unique()):
            sub = sub_e[sub_e.variant == variant]
            for fam, members in RESOURCE_FAMILY.items():
                members = [m for m in members if m in sub.columns]
                if not members: continue
                v = sub[members].mean(axis=1).mean()
                if pd.isna(v):
                    continue
                rows.append(dict(env=env, variant=variant,
                                 resource=fam, mean=float(v)))
    if not rows:
        return
    df = pd.DataFrame(rows)
    df.to_csv(outdir / "variant_resource_summary.csv", index=False)
    envs = _ordered_envs(df["env"].unique())
    fig, axes = plt.subplots(
        1, len(envs),
        figsize=_clamp_figsize(3.0 + 2.6 * len(envs), 0.42 * df["variant"].nunique() + 1.7),
        squeeze=False, sharey=True,
    )
    resources = list(RESOURCE_FAMILY.keys())
    for i, env in enumerate(envs):
        ax = axes[0][i]
        sub = df[df.env == env]
        pivot = sub.pivot_table(index="variant", columns="resource", values="mean")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index), columns=resources)
        masked = np.ma.masked_invalid(pivot.values)
        cmap = plt.get_cmap("Blues").copy()
        cmap.set_bad(color="#cccccc")
        im = ax.imshow(masked, cmap=cmap, vmin=0, vmax=100, aspect="auto")
        ax.set_xticks(range(len(resources))); ax.set_xticklabels(resources)
        ax.set_yticks(range(len(pivot.index))); ax.set_yticklabels(pivot.index)
        ax.set_title(f"env={env}", fontsize=9.5)
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.0f}", ha="center", va="center",
                        fontsize=7,
                        color="white" if v > 50 else "black")
        ax.grid(False)
    fig.colorbar(im, ax=axes.ravel().tolist(), fraction=0.04, shrink=0.8,
                 label="mean interference (%)")
    fig.suptitle("Variant × resource family — solo+pairwise mean interference",
                 y=1.02, fontsize=11)
    _save(fig, outdir / "fig14_variant_resource_heatmap.png", "fig14")


# ---------------------------------------------------------------------------
# Fig 00 — Canonical IntP Fig. 4 reproduction.
# A single chart per (env,variant): x-axis = workloads, grouped bars per
# metric (5–7 bars per workload). Color scheme matches the original IntP
# paper caption: cache=red, cpu=brown, disk=green, memory=blue, network=pink.
# ---------------------------------------------------------------------------

CANONICAL_METRIC_COLORS = {
    "llcocc": "#d62728",  # cache — red (IntP Fig. 4)
    "llcmr":  "#ff9896",  # cache miss — light red
    "cpu":    "#8c564b",  # cpu — brown
    "blk":    "#2ca02c",  # disk — green
    "mbw":    "#1f77b4",  # memory bus — blue
    "nets":   "#e377c2",  # network stack — pink
    "netp":   "#c4448a",  # network phys — darker pink
}


def fig_canonical_intp_fig4(means: pd.DataFrame, outdir: Path) -> None:
    """Canonical IntP Fig. 4 reproduction: one panel per (env,variant), bars
    grouped by workload with the original paper color caption."""
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    grouped = solo.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    pairs = grouped[["env", "variant"]].drop_duplicates().values.tolist()
    if not pairs:
        return
    n = len(pairs)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(7.5 * cols, 3.4 * rows),
                             squeeze=False, sharey=True)
    last = -1
    for idx, (env, variant) in enumerate(pairs):
        last = idx
        ax = axes[idx // cols][idx % cols]
        sub = (grouped[(grouped.env == env) & (grouped.variant == variant)]
               .sort_values("workload"))
        x = np.arange(len(sub))
        bar_w = 0.8 / max(1, len(METRICS))
        for mi, m in enumerate(METRICS):
            offset = (mi - (len(METRICS) - 1) / 2) * bar_w
            vals = sub[m].fillna(0).values
            ax.bar(x + offset, vals, width=bar_w,
                   color=CANONICAL_METRIC_COLORS.get(m, METRIC_COLORS[m]),
                   edgecolor="white", linewidth=0.25,
                   label=METRIC_LABEL[m] if idx == 0 else None)
        ax.set_xticks(x)
        ax.set_xticklabels(sub["workload"].values, rotation=35, ha="right",
                           fontsize=7)
        ax.set_title(f"env={env} · variant={variant}", fontsize=9.5)
        ax.set_ylabel("interference (%)")
        ax.set_ylim(0, max(1.0, sub[METRICS].max().max() * 1.10))
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(METRICS), frameon=False, fontsize=8.5)
    fig.suptitle("IntP Fig. 4 (canonical view) — per-application interference "
                 "ratios", y=1.06, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig00_canonical_intp_fig4.png", "fig00")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description="Plot intp-bench results")
    p.add_argument("results_dir", type=Path)
    p.add_argument("--out", type=Path, default=None,
                   help="Output directory (default: <results_dir>/plots)")
    p.add_argument("--variants", type=str, default=None,
                   help="Comma-separated variant list to plot (overrides "
                        "variants.manifest and DEFAULT_PLOTTED_VARIANTS). "
                        "Example: --variants v0.2,v1.1,v2,v3")
    p.add_argument("--formats", type=str, default="png,pdf",
                   help="Comma-separated output formats (default: png,pdf). "
                        "Each format is written under <out>/<format>/.")
    args = p.parse_args()
    if not args.results_dir.exists():
        sys.exit(f"results_dir does not exist: {args.results_dir}")
    outdir = args.out or (args.results_dir / "plots")
    outdir.mkdir(parents=True, exist_ok=True)
    global FORMATS
    FORMATS = [f.strip() for f in args.formats.split(",") if f.strip()] or ["png"]

    setup_style()

    print(f"Loading runs from {args.results_dir}")
    means = collect_means(args.results_dir)
    if means.empty:
        sys.exit("No profiler.tsv files found.")
    if args.variants:
        plotted = [v.strip() for v in args.variants.split(",") if v.strip()]
        print(f"Plotted-variants source: --variants CLI flag")
    else:
        plotted = _load_plotted_variants(args.results_dir)
    pre = len(means)
    means = means[means["variant"].isin(plotted)].copy()
    if means.empty:
        sys.exit(f"No runs match plotted variants {plotted}. "
                 f"Place variants.manifest in results_dir to override.")
    print(f"Plotted-variants filter: keeping {plotted} "
          f"({len(means)}/{pre} rows after filter)")
    means.to_csv(outdir / "aggregate-means.csv", index=False)
    print(f"Loaded {len(means)} runs across "
          f"{means['env'].nunique()} envs, {means['variant'].nunique()} variants, "
          f"{means['stage'].nunique()} stages")

    fig_canonical_intp_fig4(means, outdir)       # fig00  IntP Fig.4 canonical
    fig_per_workload_bars(means, outdir)         # fig01  IntP Fig.4 panel grid
    fig_per_variant_bars(means, outdir)          # fig01b dual view
    fig_pca_kmeans(means, outdir)                # fig02  IntP Fig.5
    fig_timeseries(args.results_dir, outdir)     # fig03  IntP Fig.3
    fig_overhead_bars(args.results_dir, outdir)  # fig04
    fig_fidelity_matrix(args.results_dir, outdir)  # fig05
    fig_env_heatmap(means, outdir)               # fig06
    fig_pairwise_heatmap(means, outdir)          # fig07
    fig_metric_availability(means, outdir)       # fig08
    fig_radar_fingerprint(means, outdir)         # fig09  new
    fig_workload_clustermap(means, outdir)       # fig10  new
    fig_idi_bars(means, outdir)                  # fig11  IADA Fig.6
    fig_pairwise_timeseries(args.results_dir, outdir)  # fig12 IntP Fig.8
    fig_iada_segmented(args.results_dir, outdir)       # fig13 IADA Fig.5
    fig_variant_resource_heatmap(means, outdir)        # fig14 new summary

    # Best-effort: chain the cross-env statistical comparison if the campaign
    # has >=2 envs in aggregate-means.tsv. Failure here is non-fatal — the
    # bench figure set is the authoritative output of this script.
    try:
        n_envs = means["env"].nunique()
    except Exception:
        n_envs = 0
    if n_envs >= 2:
        import subprocess
        cross_script = Path(__file__).parent / "plot-cross-environment.py"
        if cross_script.exists():
            print(f"[cross-env] chaining {cross_script.name} ({n_envs} envs)")
            try:
                subprocess.run(
                    [sys.executable, str(cross_script), str(args.results_dir)],
                    check=False,
                )
            except Exception as e:
                warnings.warn(f"cross-env chain failed: {e}")

    print(f"All figures written to {outdir}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
plot_pca_dendro.py -- Generate the PCA + Ward-dendrogram figure used as Fig. 2
of the SBAC-PAD paper. Reproduces the two-panel layout of Xavier's thesis
Fig. 4.5 on the modernized data.

Inputs:
  aggregate-means.csv  (one row per (env, variant, stage, workload, rep);
                        columns include the seven canonical metrics)

Outputs:
  fig02_pca_dendro.pdf (and .png)

Usage:
  python3 plot_pca_dendro.py [<aggregate-means.csv>] [<outdir>]
  defaults: ./aggregate-means.csv, ./out

Cluster labels are derived from the *dominant interference resource* of
each cluster (the metric whose per-cluster mean is highest), not from
workload-name suffixes. This produces single-resource labels (cache,
memory, network, disk) that match the five resource families used in
the HiBench heatmap of the same paper.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
# Embed TrueType (type 42) rather than matplotlib's default Type 3 fonts, so
# the PDF figures render crisply in PDF viewers and LaTeX (avoids the "strange
# PDF" look).
plt.rcParams["pdf.fonttype"] = 42
plt.rcParams["ps.fonttype"] = 42
from matplotlib import gridspec
from matplotlib.lines import Line2D
from matplotlib.patches import Patch
from sklearn.decomposition import PCA
from sklearn.cluster import KMeans
from scipy.cluster.hierarchy import linkage, dendrogram, set_link_color_palette

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paper_style  # noqa: E402  (shared camera-ready typography)

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
VARIANT_ORDER = ["v0.2", "v1.1", "v2", "v3.2"]
VARIANT_MARKERS = {"v0.2": "P", "v1.1": "o", "v2": "s", "v3.2": "*"}

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

# Map a metric to the resource-family label used elsewhere in the paper.
# Used to label K-means clusters by their dominant metric.
METRIC_TO_FAMILY = {
    "llcocc": "cache",
    "llcmr":  "memory",   # llcmr-dominant = workload thrashes cache, hits DRAM
    "mbw":    "memory",
    "netp":   "network",
    "nets":   "network",
    "blk":    "disk",
    "cpu":    "cpu",
}


def load_solo_bare(csv_path):
    # Canonical campaign data ships as tab-separated `aggregate-means.tsv`
    # (with "--" for missing metrics); the plots/ copies are comma-separated
    # `aggregate-means.csv`. Detect the separator from the suffix and treat
    # "--" as NaN either way.
    csv_path = Path(csv_path)
    sep = "\t" if csv_path.suffix.lower() in (".tsv", ".tab") else ","
    df = pd.read_csv(csv_path, sep=sep, na_values=["--"])
    df = df[(df.stage == "solo") & (df.env == "bare")].copy()
    return df


def per_workload_variant_means(df):
    return df.groupby(["workload", "variant"])[METRICS].mean().fillna(0)


def main(csv_path, outdir, variants=None, camera_ready=False,
         paper_subset="merged"):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    # Camera-ready: render at the exact printed width so LaTeX includes the
    # PDF at scale 1.0. The dendrogram leaf labels are the reason this figure
    # was flagged — at the old 9.5 in render scaled to 5.87 in they printed at
    # ~4.3 pt. Same data, same clusters, same colours and markers.
    spec = (paper_style.spec_for(paper_subset, "fig02_pca_dendro")
            if camera_ready else None)
    if spec is not None:
        paper_style.apply()

    def _cr(camera_value, default):
        """Pick the camera-ready value when rendering for the paper."""
        return camera_value if spec is not None else default

    # Optional subset (e.g. "v0.2" or "v2,v3.2") for the per-paper published/
    # figures; default plots the full VARIANT_ORDER set present in the data.
    if variants:
        sel = {v.strip() for v in variants.split(",") if v.strip()}
        vorder = [v for v in VARIANT_ORDER if v in sel]
    else:
        vorder = list(VARIANT_ORDER)

    df = load_solo_bare(csv_path)
    if variants:
        df = df[df["variant"].isin(vorder)].copy()
    g = per_workload_variant_means(df)

    workloads = sorted(g.index.get_level_values(0).unique())
    means_per_wl = g.groupby("workload").mean().reindex(workloads)

    # K-means at K=4 (matches Xavier 2022 / Xavier thesis 2019).
    k = 4
    km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(means_per_wl.values)
    cluster_of = dict(zip(means_per_wl.index, km.labels_))

    # Per-cluster mean vector; the dominant metric labels the cluster.
    cluster_members = {c: [] for c in range(k)}
    for wl, c in cluster_of.items():
        cluster_members[c].append(wl)

    cluster_label_of = {}
    for c, members in cluster_members.items():
        if not members:
            cluster_label_of[c] = f"cluster {c+1}"
            continue
        per_cluster_mean = means_per_wl.loc[members].mean()
        dominant_metric = per_cluster_mean.idxmax()
        cluster_label_of[c] = METRIC_TO_FAMILY.get(dominant_metric, dominant_metric)

    # Color palette: index by cluster id, stable across runs.
    cluster_palette = plt.cm.Set2
    cluster_color = {c: cluster_palette(c) for c in range(k)}

    # Joint PCA over (workload, variant) rows.
    pca = PCA(n_components=2)
    Y = pca.fit_transform(g.values)
    coords = pd.DataFrame(Y, index=g.index, columns=["PC1", "PC2"])
    pc1_var, pc2_var = pca.explained_variance_ratio_[:2] * 100

    # Ward-linkage on per-workload mean vectors. optimal_ordering rotates the
    # tree's branches to minimise the distance between adjacent leaves — it
    # tidies the leaf layout without altering the cluster structure or which
    # branch a workload falls in.
    Z = linkage(means_per_wl.values, method="ward", optimal_ordering=True)

    # Dendrogram link colors mirror the K-means cluster colors. We translate
    # each tuple from cluster_color into the hex string scipy expects.
    set_link_color_palette([
        "#" + "".join(f"{int(v * 255):02x}" for v in cluster_color[c][:3])
        for c in range(k)
    ])

    if spec is not None:
        fig = plt.figure(figsize=(spec.width, spec.height), layout="constrained")
        gs = gridspec.GridSpec(1, 2, width_ratios=[1.55, 1.0], figure=fig)
    else:
        fig = plt.figure(figsize=(10.0, 4.0))
        gs = gridspec.GridSpec(1, 2, width_ratios=[1.55, 1.0], wspace=0.15)

    # --- Panel A: PCA scatter ---
    ax_pca = fig.add_subplot(gs[0, 0])
    for wl in workloads:
        for variant in vorder:
            try:
                p = coords.loc[(wl, variant)]
            except KeyError:
                continue
            ax_pca.scatter(
                p["PC1"], p["PC2"],
                marker=VARIANT_MARKERS.get(variant, "o"),
                facecolor=cluster_color[cluster_of[wl]],
                edgecolor="black", linewidth=_cr(0.35, 0.45),
                s=_cr(20, 55), alpha=0.95, zorder=3,
            )
        # thin polygon connecting variants of the same workload
        pts = []
        for variant in vorder:
            try:
                p = coords.loc[(wl, variant)]
                pts.append((p["PC1"], p["PC2"]))
            except KeyError:
                continue
        if len(pts) >= 2:
            xs, ys = zip(*pts)
            ax_pca.plot(
                list(xs) + [xs[0]], list(ys) + [ys[0]],
                color=cluster_color[cluster_of[wl]],
                linewidth=_cr(0.35, 0.45), alpha=0.35, zorder=1,
            )

    ax_pca.axhline(0, color="#cccccc", linewidth=0.5, zorder=0)
    ax_pca.axvline(0, color="#cccccc", linewidth=0.5, zorder=0)
    ax_pca.set_xlabel(f"PC1 ({pc1_var:.1f}%)", fontsize=_cr(paper_style.BODY, 9))
    ax_pca.set_ylabel(f"PC2 ({pc2_var:.1f}%)", fontsize=_cr(paper_style.BODY, 9))
    ax_pca.set_title("(A) PCA + K-means (K=4)",
                     fontsize=_cr(paper_style.TITLE, 10))
    ax_pca.grid(True, linestyle=":", alpha=0.4)
    ax_pca.tick_params(labelsize=_cr(paper_style.BODY, 8))

    # Add top headroom so the in-panel legends sit in an empty band above the
    # scatter. The descriptive variant names (legacy-intp-baseline, eBPF-CORE, ...) are
    # wider/taller than the old vN tags, so without this the upper-left
    # "variant" legend overlaps the top points.
    y0, y1 = ax_pca.get_ylim()
    ax_pca.set_ylim(y0, y1 + 0.46 * (y1 - y0))

    # Two-column in-panel legend: variant markers on the left,
    # cluster colors as patches on the right.
    var_handles = [
        Line2D([0], [0], marker=VARIANT_MARKERS[v], color="w",
               markerfacecolor="lightgray", markeredgecolor="black",
               markersize=_cr(4.5, 7), label=variant_label(v))
        for v in vorder
    ]
    cluster_handles = [
        Patch(facecolor=cluster_color[c], edgecolor="black",
              linewidth=0.4, label=cluster_label_of[c])
        for c in sorted(cluster_members.keys()) if cluster_members[c]
    ]
    # Variant markers stay in the top-left corner (their original spot, clear
    # of data); only the cluster colour key moves to the top-right corner, so
    # neither legend covers the scatter.
    _leg_kw = dict(
        fontsize=_cr(paper_style.LEGEND, 7),
        title_fontsize=_cr(paper_style.LEGEND, 7.5),
        frameon=True,
        handlelength=_cr(1.0, 2.0), handletextpad=_cr(0.35, 0.8),
        labelspacing=_cr(0.25, 0.5), borderpad=_cr(0.25, 0.4),
    )
    leg_var = ax_pca.legend(
        handles=var_handles, loc="upper left", title="variant", **_leg_kw,
    )
    ax_pca.add_artist(leg_var)
    ax_pca.legend(
        handles=cluster_handles, loc="upper right",
        title="cluster (dominant resource)", **_leg_kw,
    )

    # --- Panel B: Ward dendrogram ---
    ax_dn = fig.add_subplot(gs[0, 1])
    # orientation="left": leaves (and their labels) sit on the right edge of
    # the panel while the tree opens leftward toward the root. Combined with
    # tick_right() below, the workload labels live on the figure's outer edge
    # and can never overlap Panel A's frame.
    dendrogram(
        Z,
        labels=workloads,
        orientation="left",
        ax=ax_dn,
        color_threshold=0,
        above_threshold_color="#666666",
        # 7 pt is a true printed 7 pt now that the figure is rendered at its
        # final width; previously it was scaled down to ~4.3 pt.
        leaf_font_size=_cr(paper_style.BODY, 7),
    )
    ax_dn.set_title("(B) Ward-linkage dendrogram",
                    fontsize=_cr(paper_style.TITLE, 10))
    ax_dn.set_xlabel("distance", fontsize=_cr(paper_style.BODY, 8))
    ax_dn.tick_params(axis="x", labelsize=_cr(paper_style.BODY, 7))
    # Move the leaf labels to the outer (right) side, away from Panel A, and
    # drop the tick marks so only the colored names remain.
    ax_dn.yaxis.tick_right()
    ax_dn.yaxis.set_label_position("right")
    ax_dn.tick_params(axis="y", length=0)
    ax_dn.spines["top"].set_visible(False)
    ax_dn.spines["left"].set_visible(False)
    ax_dn.spines["right"].set_visible(False)

    # Color each leaf label by its K-means cluster color.
    for tick in ax_dn.get_yticklabels():
        wl = tick.get_text()
        if wl in cluster_of:
            tick.set_color(cluster_color[cluster_of[wl]])

    if spec is None:
        fig.suptitle(
            "PCA + K-means + Ward dendrogram (env=bare, joint fit over per-(workload, variant) rows)",
            fontsize=10, y=1.005,
        )

    # Mirror plot-intp-bench.py's layout: <outdir>/pdf/ and <outdir>/png/,
    # so this figure lands beside fig02_pca_kmeans in the same plots/ tree.
    stem = "fig02_pca_dendro"
    pdf_dir = outdir / "pdf"
    png_dir = outdir / "png"
    pdf_dir.mkdir(parents=True, exist_ok=True)
    png_dir.mkdir(parents=True, exist_ok=True)
    pdf_path = pdf_dir / f"{stem}.pdf"
    png_path = png_dir / f"{stem}.png"
    if spec is not None:
        w, h = paper_style.save(fig, pdf_path, spec)
        paper_style.save(fig, png_path, spec)
        print(f"wrote {pdf_path}  [{w:.2f}x{h:.2f}in target {spec.width:.2f}in]")
        print(f"wrote {png_path}")
    else:
        fig.savefig(pdf_path, bbox_inches="tight")
        fig.savefig(png_path, bbox_inches="tight", dpi=220)
        print(f"wrote {pdf_path}")
        print(f"wrote {png_path}")
    print(f"PC1={pc1_var:.2f}%  PC2={pc2_var:.2f}%  K-means(k={k})")
    for c in sorted(cluster_members.keys()):
        if cluster_members[c]:
            print(f"  cluster {c} [{cluster_label_of[c]}]: {cluster_members[c]}")


if __name__ == "__main__":
    # Positional, backward-compatible: <csv> [<outdir>] [<variants>]
    # <variants> is an optional comma-separated subset (e.g. "v0.2" or
    # "v2,v3.2") used to render the per-paper published/ figures.
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    variants = None
    camera_ready = False
    paper_subset = "merged"
    for a in sys.argv[1:]:
        if a.startswith("--variants="):
            variants = a.split("=", 1)[1]
        elif a == "--camera-ready":
            camera_ready = True
        elif a.startswith("--paper-subset="):
            paper_subset = a.split("=", 1)[1]
    csv_path = Path(args[0]) if len(args) > 0 else Path("aggregate-means.csv")
    outdir = Path(args[1]) if len(args) > 1 else Path("out")
    if variants is None and len(args) > 2:
        variants = args[2]
    main(csv_path, outdir, variants, camera_ready=camera_ready,
         paper_subset=paper_subset)

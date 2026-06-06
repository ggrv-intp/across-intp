#!/usr/bin/env python3
"""
plot-iada.py — Modality-aware figure renderer for IADA campaign manifests.

Reads the manifest.tsv produced by `run-iada-campaign.sh` (driven by
`run-iada-from-bench.sh`) and emits figures sized to the campaign's
*modality*:

    M1 (IADA-aligned, 1 env): variant-only views
      fig_iada_variant_ranking.png
      fig_iada_migrations_vs_idi.png
      fig_iada_wallclock.png

    M2 (cross-domain transfer, >1 env): adds env-aware views
      fig_iada_transfer_heatmap.png
      fig_iada_transfer_degradation.png

    --fragility-tsv FILE: adds, in any modality
      fig_iada_fragility_vs_idi.png

Modality detection is by `--modality {M1,M2,auto}` (default auto:
inferred from the number of distinct envs in the manifest).

Side outputs:
    summary.tsv  — per-(variant[, env]) aggregates and ranks
    README.md    — figure legend + methodological reminder
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
# Embed TrueType (type 42) rather than matplotlib's default Type 3 fonts, so
# the PDF figures render crisply in PDF viewers and LaTeX (avoids the "strange
# PDF" look).
plt.rcParams["pdf.fonttype"] = 42
plt.rcParams["ps.fonttype"] = 42

try:
    from scipy.stats import spearmanr  # noqa: F401  (used opportunistically)
    HAVE_SCIPY = True
except ImportError:
    HAVE_SCIPY = False


VARIANT_ORDER = ["v0", "v0.1", "v0.2", "v1", "v1.1", "v2", "v3", "v3.1", "v3.2"]

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


ENV_ORDER = [
    "bare",
    "container", "container-guest", "container-full",
    "vm", "vm-guest", "vm-full",
]
ALIGNED_ENV = "container"


def load_manifest(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, sep="\t")
    if "idi_avg" not in df.columns or "variant" not in df.columns:
        sys.exit(f"manifest missing required columns variant/idi_avg: {path}")
    df["variant"] = pd.Categorical(
        df["variant"],
        categories=[v for v in VARIANT_ORDER if v in df["variant"].unique()],
        ordered=True,
    )
    if "env" in df.columns:
        df["env"] = pd.Categorical(
            df["env"],
            categories=[e for e in ENV_ORDER if e in df["env"].unique()],
            ordered=True,
        )
    return df


def detect_modality(df: pd.DataFrame, requested: str) -> str:
    if requested in ("M1", "M2"):
        return requested
    n_envs = df["env"].nunique() if "env" in df.columns else 1
    return "M2" if n_envs > 1 else "M1"


def pick_baseline(df: pd.DataFrame, requested: str | None) -> tuple[str, float]:
    """Return (variant_name, idi_avg) used as M1 reference line."""
    means = df.groupby("variant", observed=True)["idi_avg"].mean()
    if requested and requested in means.index:
        return requested, float(means.loc[requested])
    if "v0" in means.index:
        return "v0", float(means.loc["v0"])
    best = means.idxmin()
    return str(best), float(means.loc[best])


# ─── M1 figures ──────────────────────────────────────────────────────────────
def fig_variant_ranking(df: pd.DataFrame, baseline: tuple[str, float], out: Path) -> None:
    name, value = baseline
    grouped = df.groupby("variant", observed=True)["idi_avg"].agg(["mean", "sem", "count"])
    grouped = grouped.sort_values("mean")
    fig, ax = plt.subplots(figsize=(7, 4))
    y = np.arange(len(grouped))
    ax.barh(y, grouped["mean"], xerr=grouped["sem"].fillna(0),
            capsize=4, color="#3a7", edgecolor="black")
    ax.axvline(value, color="#c33", linestyle="--", linewidth=1.5,
               label=f"baseline: {variant_label(name)} ({value:.1f})")
    ax.set_yticks(y)
    ax.set_yticklabels([variant_label(v) for v in grouped.index])
    ax.invert_yaxis()
    ax.set_xlabel("IDI (avg per simulation, lower = better)")
    ax.set_title("Variant ranking — IDI mean ± stderr")
    for i, n in enumerate(grouped["count"]):
        ax.text(grouped["mean"].iloc[i], i, f" n={int(n)}",
                va="center", fontsize=8)
    ax.legend(loc="lower right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_migrations_vs_idi(df: pd.DataFrame, out: Path) -> None:
    if "migrations_total" not in df.columns:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    for v in df["variant"].cat.categories:
        sub = df[df["variant"] == v]
        if sub.empty:
            continue
        ax.scatter(sub["migrations_total"], sub["idi_avg"],
                   label=variant_label(v), alpha=0.7, s=44)
    ax.set_xlabel("Total migrations")
    ax.set_ylabel("IDI (avg)")
    ax.set_title("Migrations vs IDI — trade-off per variant")
    ax.grid(alpha=0.3)
    ax.legend(title="variant", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_wallclock(df: pd.DataFrame, out: Path) -> None:
    col = "sim_wallclock_min" if "sim_wallclock_min" in df.columns else None
    if col is None:
        return
    g = df.groupby("variant", observed=True)[col].agg(["mean", "sem", "count"])
    fig, ax = plt.subplots(figsize=(7, 4))
    x = np.arange(len(g))
    ax.bar(x, g["mean"], yerr=g["sem"].fillna(0), capsize=4,
           color="#69c", edgecolor="black")
    ax.set_xticks(x)
    ax.set_xticklabels([variant_label(v) for v in g.index])
    ax.set_ylabel("Wallclock (min)")
    ax.set_title("Simulation wallclock per variant")
    for i, n in enumerate(g["count"]):
        ax.text(i, g["mean"].iloc[i], f"n={int(n)}",
                ha="center", va="bottom", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


# ─── M2 figures ──────────────────────────────────────────────────────────────
def fig_transfer_heatmap(df: pd.DataFrame, out: Path) -> None:
    pivot = df.pivot_table(
        index="variant", columns="env",
        values="idi_avg", aggfunc="mean", observed=True,
    )
    if pivot.empty or ALIGNED_ENV not in pivot.columns:
        return
    # Ratio vs the aligned env (container) for each variant.
    baseline_col = pivot[ALIGNED_ENV]
    ratio = pivot.div(baseline_col, axis=0)

    fig, ax = plt.subplots(figsize=(8, 5))
    vmax = float(np.nanmax(np.abs(ratio.values - 1.0)))
    vmax = max(vmax, 0.10)
    im = ax.imshow(
        ratio.values, aspect="auto",
        cmap="RdBu_r", vmin=1 - vmax, vmax=1 + vmax, interpolation="nearest"
    )
    ax.set_xticks(range(len(ratio.columns)))
    ax.set_xticklabels(ratio.columns)
    ax.set_yticks(range(len(ratio.index)))
    ax.set_yticklabels([variant_label(v) for v in ratio.index])
    ax.set_title(
        "IDI ratio vs aligned env (container=1.0)\n"
        "container = aligned (training-domain) — bare/vm = domain transfer"
    )
    for i in range(ratio.shape[0]):
        for j in range(ratio.shape[1]):
            v = ratio.values[i, j]
            ax.text(j, i, f"{v:.2f}" if np.isfinite(v) else "n/a",
                    ha="center", va="center",
                    color="white" if abs(v - 1) > vmax * 0.6 else "black",
                    fontsize=9)
    fig.colorbar(im, ax=ax, label="ratio (1.0 = aligned-env IDI)")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_transfer_degradation(df: pd.DataFrame, out: Path) -> None:
    pivot = df.pivot_table(
        index="variant", columns="env",
        values="idi_avg", aggfunc="mean", observed=True,
    )
    if pivot.empty or ALIGNED_ENV not in pivot.columns:
        return
    baseline_col = pivot[ALIGNED_ENV]
    ratio = pivot.div(baseline_col, axis=0)

    other_envs = [c for c in ratio.columns if c != ALIGNED_ENV]
    if not other_envs:
        return
    fig, ax = plt.subplots(figsize=(8, 4.5))
    x = np.arange(len(ratio.index))
    width = 0.8 / max(len(other_envs), 1)
    for i, e in enumerate(other_envs):
        ax.bar(x + i * width, ratio[e].values, width=width,
               label=str(e), edgecolor="black")
    ax.axhline(1.0, color="#888", linewidth=1, linestyle="--",
               label="aligned (container)")
    ax.set_xticks(x + (len(other_envs) - 1) * width / 2)
    ax.set_xticklabels([variant_label(v) for v in ratio.index])
    ax.set_ylabel("IDI ratio (env / container)")
    ax.set_title("Transfer degradation: IDI ratio bar by env")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


# ─── Fragility cross-plot ────────────────────────────────────────────────────
def fig_fragility_vs_idi(df: pd.DataFrame, fragility_tsv: Path, out: Path) -> None:
    try:
        frag = pd.read_csv(fragility_tsv, sep="\t")
    except Exception as e:
        print(f"WARN: could not read fragility TSV {fragility_tsv}: {e}", file=sys.stderr)
        return
    if "variant" not in frag.columns:
        return
    score_col = next((c for c in ("fragility", "fragility_score", "stall_rate") if c in frag.columns), None)
    if score_col is None:
        return
    agg = df.groupby("variant", observed=True)["idi_avg"].mean().reset_index()
    merged = agg.merge(frag[["variant", score_col]], on="variant", how="inner")
    if merged.empty:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.scatter(merged[score_col], merged["idi_avg"], s=60,
               color="#a35", edgecolor="black")
    for _, r in merged.iterrows():
        ax.annotate(variant_label(r["variant"]),
                    (r[score_col], r["idi_avg"]),
                    fontsize=8, xytext=(4, 4), textcoords="offset points")
    ax.set_xlabel(score_col)
    ax.set_ylabel("IDI (avg)")
    ax.set_title("Variant fragility vs IDI")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


# ─── Side outputs ────────────────────────────────────────────────────────────
def write_summary(df: pd.DataFrame, modality: str, out: Path) -> None:
    group_cols = ["variant"]
    if modality == "M2" and "env" in df.columns:
        group_cols.append("env")
    agg = df.groupby(group_cols, observed=True).agg(
        idi_avg_mean=("idi_avg", "mean"),
        idi_avg_sem=("idi_avg", "sem"),
        n_runs=("idi_avg", "count"),
    ).reset_index()
    if modality == "M1":
        agg = agg.sort_values("idi_avg_mean")
    agg.to_csv(out, sep="\t", index=False)


def write_readme(modality: str, baseline: tuple[str, float] | None,
                 outdir: Path, files_written: list[str]) -> None:
    name, value = baseline if baseline else ("n/a", float("nan"))
    text = [
        f"# IADA figures ({modality})",
        "",
        f"Modality: **{modality}** "
        + ("(IADA-aligned, container only)" if modality == "M1"
           else "(cross-domain transfer; container=aligned, bare/vm=transfer)"),
        "",
        f"Baseline variant for M1 reference line: **{name}** (mean IDI={value:.2f})"
        if modality == "M1" else
        "M2 baseline column: **container** (each variant's container-env IDI is the per-row reference).",
        "",
        "## Figures",
        "",
    ]
    for f in files_written:
        text.append(f"- `{f}`")
    text += [
        "",
        "## Methodological note",
        "",
        "The shipped IADA classifier was trained on profiles collected in LXC",
        "containers under Node-Tiers synthetic stressors (Meyer 2021). M1 reports",
        "values within that training domain. M2 reports cross-domain transfer:",
        "bare/vm rows reflect classifier behaviour outside its training",
        "distribution, and degradation in those rows conflates 'the variant",
        "produces low-quality profiles' with 'the classifier doesn't generalise",
        "to this domain'. Retrain the classifier (R/retrain.R in the",
        "CloudSimInterference fork, branch retrain-pipeline) on a domain-matched",
        "dataset to separate the two effects.",
        "",
        "See `bench/iada/docs/iada-campaign.md` §'Methodological framing'.",
        "",
    ]
    (outdir / "README.md").write_text("\n".join(text))


# ─── Driver ──────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest", type=Path,
                    help="manifest.tsv from run-iada-campaign.sh")
    ap.add_argument("--out-dir", type=Path, default=None,
                    help="output dir (default: <manifest_parent>/figures)")
    ap.add_argument("--modality", choices=("M1", "M2", "auto"), default="auto")
    ap.add_argument("--baseline-variant", default=None,
                    help="variant name used as M1 reference line (default: v0 if present, else lowest IDI)")
    ap.add_argument("--fragility-tsv", type=Path, default=None,
                    help="optional TSV with per-variant fragility column")
    args = ap.parse_args()

    if not args.manifest.exists():
        sys.exit(f"manifest not found: {args.manifest}")
    out_dir = args.out_dir or args.manifest.parent / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    df = load_manifest(args.manifest)
    modality = detect_modality(df, args.modality)
    n_envs = df["env"].nunique() if "env" in df.columns else 1
    print(f"loaded n={len(df)} rows  variants={list(df['variant'].cat.categories)}  "
          f"envs={n_envs}  modality={modality}")

    written: list[str] = []
    baseline = None
    if modality == "M1":
        baseline = pick_baseline(df, args.baseline_variant)
        fig_variant_ranking(df, baseline, out_dir / "fig_iada_variant_ranking.png")
        written.append("fig_iada_variant_ranking.png")
        fig_migrations_vs_idi(df, out_dir / "fig_iada_migrations_vs_idi.png")
        if "migrations_total" in df.columns:
            written.append("fig_iada_migrations_vs_idi.png")
        fig_wallclock(df, out_dir / "fig_iada_wallclock.png")
        if "sim_wallclock_min" in df.columns:
            written.append("fig_iada_wallclock.png")
    else:  # M2
        baseline = pick_baseline(df, args.baseline_variant)
        fig_variant_ranking(df, baseline, out_dir / "fig_iada_variant_ranking.png")
        written.append("fig_iada_variant_ranking.png")
        fig_migrations_vs_idi(df, out_dir / "fig_iada_migrations_vs_idi.png")
        if "migrations_total" in df.columns:
            written.append("fig_iada_migrations_vs_idi.png")
        fig_wallclock(df, out_dir / "fig_iada_wallclock.png")
        if "sim_wallclock_min" in df.columns:
            written.append("fig_iada_wallclock.png")
        fig_transfer_heatmap(df, out_dir / "fig_iada_transfer_heatmap.png")
        written.append("fig_iada_transfer_heatmap.png")
        fig_transfer_degradation(df, out_dir / "fig_iada_transfer_degradation.png")
        written.append("fig_iada_transfer_degradation.png")

    if args.fragility_tsv is not None:
        fig_fragility_vs_idi(df, args.fragility_tsv, out_dir / "fig_iada_fragility_vs_idi.png")
        written.append("fig_iada_fragility_vs_idi.png")

    write_summary(df, modality, out_dir / "summary.tsv")
    written.append("summary.tsv")
    write_readme(modality, baseline, out_dir, [w for w in written if w != "summary.tsv"])

    print(f"wrote {len(written)} outputs to {out_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

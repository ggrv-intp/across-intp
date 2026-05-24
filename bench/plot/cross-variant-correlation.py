#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# cross-variant-correlation.py — reproduce the §V correlation / overhead numbers.
#
# The SBAC-PAD paper claims (a) how strongly the four profiler endpoints agree
# on their per-application interference fingerprints, and (b) that throughput
# overhead stays within a stated bound. Those numbers were computed ad-hoc
# during analysis; no other script in bench/plot/ regenerates them. This one
# does, so a reviewer recomputing from the published results tree lands on the
# same figures.
#
# It reads the existing wide-format `aggregate-means.tsv` (env, variant, stage,
# workload, rep, then the 7 metric columns) plus the overhead `throughput.tsv`
# files — no new capture, no upstream re-aggregation.
#
# Two analysis "envs" (the paper's synthetic vs real-world halves):
#   bare    → stress-ng layer   = rows with stage == "solo"
#   hibench → HiBench layer      = rows with stage like "hibench-<profile>"
# The "application" is the unit a fingerprint is built over: a stress-ng solo
# workload (bare, 17 of them) or a (profile, workload) pair (hibench, 42).
#
# Correlation is Pearson on the per-(env,variant) fingerprint — the flattened
# [application × metric] matrix (raw and per-metric-z-scored), and per single
# metric across applications. Family roll-ups split the four endpoints into the
# SystemTap pair {v0.2, v1.1} and the production-grade pair {v2, v3.2}; the
# cross-family pairs are where the llcocc capability gap surfaces.
#
# Run:
#   python3 cross-variant-correlation.py --campaign results/<tree> [--verify] [--plot]
#
# --verify checks the produced tables against EXPECTED_VALUES (the numbers the
# paper cites) and exits non-zero on mismatch, so it can gate CI.
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import sys
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
MEASURED_VARIANTS = ["v0.2", "v1.1", "v2", "v3.2"]
METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
ENVS = ["bare", "hibench"]
REF_LOADS = ["ref_cpu", "ref_disk", "ref_stream"]

# Endpoint families. The two SystemTap-based endpoints share an instrumentation
# path; the two C/eBPF endpoints share another. Cross-family pairs are the
# interesting ones (capability gaps live there).
SYSTEMTAP_VARIANTS = {"v0.2", "v1.1"}
MODERN_VARIANTS = {"v2", "v3.2"}


def family_pairs(variants: list[str]) -> dict[str, list[tuple[str, str]]]:
    """Map family name -> list of unordered variant pairs, for the active set."""
    pairs = list(combinations(variants, 2))
    st = SYSTEMTAP_VARIANTS & set(variants)
    md = MODERN_VARIANTS & set(variants)
    fam: dict[str, list[tuple[str, str]]] = {
        "within_systemtap": [p for p in pairs if set(p) <= st],
        "within_modern":    [p for p in pairs if set(p) <= md],
        "cross_family":     [p for p in pairs if len(set(p) & st) == 1 and len(set(p) & md) == 1],
        "four_way_all":     pairs,
    }
    return {k: v for k, v in fam.items() if v}


# ----------------------------------------------------------------------------
# Expected values (--verify). These are the numbers the paper cites; the script
# asserts them so the artifact and the text cannot silently drift apart.
#
# Each entry: (file, selector dict, column, check). check is one of
#   ("approx", value, tol)  ("range", lo, hi)  ("le", value)  ("ge", value)
# Provenance: computed from results/ub22-and-24-full (the fused 4-variant tree).
# NOTE: within_systemtap == 0.93 is a HiBENCH number; on the bare layer the
# same pair is ~0.88. The original plan mislabeled it as bare — corrected here.
# ----------------------------------------------------------------------------
EXPECTED_VALUES = [
    ("correlation-family-summary.tsv",
     dict(env="hibench", scope="raw", family="within_systemtap"), "mean_r", ("approx", 0.93, 0.03)),
    ("correlation-family-summary.tsv",
     dict(env="bare", scope="raw", family="within_modern"), "mean_r", ("approx", 0.91, 0.03)),
    ("correlation-family-summary.tsv",
     dict(env="hibench", scope="raw", family="within_modern"), "mean_r", ("approx", 0.98, 0.02)),
    ("correlation-family-summary.tsv",
     dict(env="bare", scope="raw", family="four_way_all"), "mean_r", ("approx", 0.78, 0.04)),
    ("correlation-family-summary.tsv",
     dict(env="hibench", scope="raw", family="four_way_all"), "mean_r", ("approx", 0.33, 0.06)),
    ("correlation-family-summary.tsv",
     dict(env="hibench", scope="zscored", family="four_way_all"), "mean_r", ("approx", 0.43, 0.06)),
    ("correlation-per-metric-family.tsv",
     dict(env="bare", metric="blk", family="four_way_all"), "mean_r", ("range", 0.90, 1.00)),
    ("correlation-per-metric-family.tsv",
     dict(env="bare", metric="mbw", family="four_way_all"), "mean_r", ("range", 0.90, 1.00)),
    ("correlation-per-metric-family.tsv",
     dict(env="hibench", metric="llcocc", family="cross_family"), "mean_r", ("le", 0.20)),
    ("correlation-per-metric-family.tsv",
     dict(env="hibench", metric="llcocc", family="within_modern"), "mean_r", ("ge", 0.90)),
    ("overhead-bounds.tsv",
     dict(variant="v0.2", ref_load="ref_cpu"), "throughput_delta_pct_mean", ("approx", 4.3, 0.6)),
    ("overhead-bounds.tsv",
     dict(variant="v2", ref_load="ref_cpu"), "throughput_delta_pct_mean", ("range", -2.0, 2.0)),
    ("overhead-bounds.tsv",
     dict(variant="v3.2", ref_load="ref_cpu"), "throughput_delta_pct_mean", ("range", -2.0, 2.0)),
]


def log(msg: str) -> None:
    print(msg, flush=True)


# ----------------------------------------------------------------------------
# Loading
# ----------------------------------------------------------------------------
def load_means(campaign: Path) -> pd.DataFrame:
    """Load the merged wide-format aggregate-means rows for a campaign tree.

    Handles two on-disk layouts:
      - publication tree: one <campaign>/aggregate-means.tsv with everything;
      - fused tree: <campaign>/bench-full/aggregate-means.tsv (stress-ng) plus
        per-profile <campaign>/hibench/*/aggregate-means.tsv.
    Rows are deduped on (env, variant, stage, workload, rep) so a merged file
    plus stray per-profile files cannot double-count.
    """
    frames: list[pd.DataFrame] = []
    root_file = campaign / "aggregate-means.tsv"
    bench_file = campaign / "bench-full" / "aggregate-means.tsv"

    def _read(p: Path) -> pd.DataFrame | None:
        try:
            return pd.read_csv(p, sep="\t")
        except Exception as e:  # noqa: BLE001
            log(f"[load] WARN cannot read {p}: {e}")
            return None

    if root_file.is_file():
        df = _read(root_file)
        if df is not None:
            frames.append(df)
        # If the root file lacks hibench rows, fold in any per-profile files.
        has_hibench = df is not None and df["stage"].astype(str).str.startswith("hibench-").any()
        if not has_hibench:
            for p in sorted(campaign.glob("hibench/*/aggregate-means.tsv")):
                d = _read(p)
                if d is not None:
                    frames.append(d)
    else:
        if bench_file.is_file():
            d = _read(bench_file)
            if d is not None:
                frames.append(d)
        else:
            log(f"[load] WARN no aggregate-means.tsv at {root_file} or {bench_file}")
        for p in sorted(campaign.glob("hibench/*/aggregate-means.tsv")):
            d = _read(p)
            if d is not None:
                frames.append(d)

    if not frames:
        raise SystemExit(f"[load] FATAL no aggregate-means.tsv found under {campaign}")

    df = pd.concat(frames, ignore_index=True)
    key = ["env", "variant", "stage", "workload", "rep"]
    before = len(df)
    df = df.drop_duplicates(subset=key)
    if len(df) != before:
        log(f"[load] deduped {before - len(df)} duplicate rows on {key}")
    for m in METRICS:
        df[m] = pd.to_numeric(df[m], errors="coerce")
    return df


def env_slice(df: pd.DataFrame, env: str) -> pd.DataFrame:
    """Rows + an 'app' key for one analysis env."""
    if env == "bare":
        d = df[(df["env"] == "bare") & (df["stage"] == "solo")].copy()
        d["app"] = d["workload"].astype(str)
    elif env == "hibench":
        d = df[df["stage"].astype(str).str.startswith("hibench-")].copy()
        d["app"] = d["stage"].astype(str) + "/" + d["workload"].astype(str)
    else:
        raise ValueError(f"unknown env {env}")
    return d


def find_overhead_root(campaign: Path) -> Path | None:
    """Dir whose child overhead/ holds <env>/<variant>/<ref>/rep<R>/throughput.tsv."""
    for cand in (campaign, campaign / "bench-full"):
        if (cand / "overhead").is_dir():
            return cand
    return None


# ----------------------------------------------------------------------------
# Fingerprints + correlation
# ----------------------------------------------------------------------------
def fingerprints(d: pd.DataFrame, variants: list[str]):
    """Per-variant [app × metric] mean matrix, aligned on the common app set."""
    sig = d.groupby(["variant", "app"])[METRICS].mean().reset_index()
    have = [v for v in variants if v in set(sig["variant"])]
    if len(have) < 2:
        return {}, []
    common = sorted(set.intersection(*[set(sig[sig.variant == v]["app"]) for v in have]))
    mats = {
        v: sig[(sig.variant == v) & (sig.app.isin(common))]
        .set_index("app").reindex(common)[METRICS]
        for v in have
    }
    return mats, common


def zscore_per_metric(mats: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    """Z-score each metric column across the pooled (variant × app) values.

    Pooling all variants keeps a single shared scale per metric so the flattened
    fingerprint correlation reflects pattern agreement, not absolute level. A
    metric with zero pooled variance is dropped (logged) rather than div-by-zero.
    """
    pooled = pd.concat(mats.values())
    mu = pooled.mean()
    sd = pooled.std(ddof=0)
    keep = [m for m in METRICS if sd.get(m, 0) and not np.isclose(sd[m], 0.0)]
    dropped = [m for m in METRICS if m not in keep]
    if dropped:
        log(f"[zscore] dropping zero-variance metric(s): {dropped}")
    return {v: (mats[v][keep] - mu[keep]) / sd[keep] for v in mats}


def _pearson(x: np.ndarray, y: np.ndarray) -> tuple[float, int]:
    mask = ~(np.isnan(x) | np.isnan(y))
    n = int(mask.sum())
    if n < 3 or np.nanstd(x[mask]) == 0 or np.nanstd(y[mask]) == 0:
        return float("nan"), n
    return float(np.corrcoef(x[mask], y[mask])[0, 1]), n


def fourway_table(mats, mats_z, variants, env) -> pd.DataFrame:
    rows = []
    for a, b in combinations([v for v in variants if v in mats], 2):
        r_raw, nfeat = _pearson(mats[a].values.flatten(), mats[b].values.flatten())
        r_z, _ = _pearson(mats_z[a].values.flatten(), mats_z[b].values.flatten())
        rows.append(dict(env=env, variant_a=a, variant_b=b,
                         r_raw=round(r_raw, 4), r_zscored=round(r_z, 4),
                         n_features=nfeat))
    return pd.DataFrame(rows)


def per_metric_table(mats, variants, env) -> pd.DataFrame:
    rows = []
    have = [v for v in variants if v in mats]
    for m in METRICS:
        for a, b in combinations(have, 2):
            if m not in mats[a] or m not in mats[b]:
                continue
            r, n = _pearson(mats[a][m].values, mats[b][m].values)
            rows.append(dict(env=env, metric=m, variant_a=a, variant_b=b,
                             r=round(r, 4), n_workloads=n))
    return pd.DataFrame(rows)


def family_summary(fourway: pd.DataFrame, variants: list[str]) -> pd.DataFrame:
    """Roll the 4×4 pair matrix up into family means, raw and z-scored."""
    fams = family_pairs(variants)
    rows = []
    for env, g in fourway.groupby("env"):
        pmap = {(r.variant_a, r.variant_b): r for r in g.itertuples()}
        for scope, col in (("raw", "r_raw"), ("zscored", "r_zscored")):
            for fam, pairs in fams.items():
                vals = [getattr(pmap[p], col) for p in pairs
                        if p in pmap and not np.isnan(getattr(pmap[p], col))]
                if not vals:
                    continue
                rows.append(dict(env=env, scope=scope, family=fam, n_pairs=len(vals),
                                 mean_r=round(float(np.mean(vals)), 4),
                                 min_r=round(float(np.min(vals)), 4),
                                 max_r=round(float(np.max(vals)), 4)))
    return pd.DataFrame(rows)


def per_metric_family(permetric: pd.DataFrame, variants: list[str]) -> pd.DataFrame:
    """Per-metric family roll-up — surfaces the llcocc capability gap."""
    fams = family_pairs(variants)
    rows = []
    for (env, metric), g in permetric.groupby(["env", "metric"]):
        pmap = {(r.variant_a, r.variant_b): r.r for r in g.itertuples()}
        for fam, pairs in fams.items():
            vals = [pmap[p] for p in pairs if p in pmap and not np.isnan(pmap[p])]
            if not vals:
                continue
            rows.append(dict(env=env, metric=metric, family=fam, n_pairs=len(vals),
                             mean_r=round(float(np.mean(vals)), 4),
                             min_r=round(float(np.min(vals)), 4),
                             max_r=round(float(np.max(vals)), 4)))
    return pd.DataFrame(rows)


# ----------------------------------------------------------------------------
# Overhead
# ----------------------------------------------------------------------------
def _read_bogo(path: Path) -> float:
    """bogo_ops_per_s_real from a 2-column throughput.tsv; NaN if absent."""
    try:
        for line in path.read_text().splitlines():
            k, _, v = line.partition("\t")
            if k == "bogo_ops_per_s_real":
                return float(v)
    except (OSError, ValueError):
        pass
    return float("nan")


def overhead_bounds(overhead_root: Path, variants: list[str]) -> pd.DataFrame:
    """Throughput overhead %, per (variant, ref_load), with per-variant baseline.

    overhead = (baseline_bogo − arm_bogo) / baseline_bogo × 100, positive =
    slower. Each arm divides by the baseline from ITS OWN session: a per-variant
    `_baseline.<variant>` dir overrides the shared `_baseline` when present (the
    no-profiler reference drifts across fused sessions/hosts, so a cross-session
    ratio would fabricate overhead). Mirrors plot-intp-bench.py::fig_overhead_bars.
    """
    base = overhead_root / "overhead"
    rows = []
    for tsv in base.rglob("throughput.tsv"):
        parts = tsv.parts
        try:
            env, variant, ref = parts[-5], parts[-4], parts[-3]
            rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        rows.append(dict(env=env, variant=variant, ref=ref, rep=rep,
                         bogo=_read_bogo(tsv)))
    df = pd.DataFrame(rows)
    if df.empty:
        log("[overhead] no throughput.tsv rows found")
        return pd.DataFrame()

    is_base = df.variant.str.startswith("_baseline")
    base_means = (df[is_base].groupby(["variant", "env", "ref"])["bogo"]
                  .mean().rename("base_bogo").reset_index())
    available = set(base_means["variant"])

    def base_for(v: str) -> str:
        return f"_baseline.{v}" if f"_baseline.{v}" in available else "_baseline"

    arms = df[~is_base].copy()
    arms["base_variant"] = arms["variant"].map(base_for)
    arms = arms.merge(base_means.rename(columns={"variant": "base_variant"}),
                      on=["base_variant", "env", "ref"], how="left")
    arms["delta_pct"] = (arms["base_bogo"] - arms["bogo"]) / arms["base_bogo"] * 100.0

    out = (arms[arms.variant.isin(variants)]
           .groupby(["variant", "ref"])["delta_pct"]
           .agg(throughput_delta_pct_mean="mean",
                throughput_delta_pct_std="std", n="count")
           .reset_index().rename(columns={"ref": "ref_load"}))
    for c in ("throughput_delta_pct_mean", "throughput_delta_pct_std"):
        out[c] = out[c].round(3)
    return out.sort_values(["variant", "ref_load"]).reset_index(drop=True)


# ----------------------------------------------------------------------------
# Verify
# ----------------------------------------------------------------------------
def _select(df: pd.DataFrame, sel: dict) -> pd.DataFrame:
    m = pd.Series(True, index=df.index)
    for k, v in sel.items():
        m &= (df[k] == v)
    return df[m]


def verify(out_dir: Path) -> int:
    log("\n=== verify: paper-cited values ===")
    cache: dict[str, pd.DataFrame] = {}
    passed = failed = 0
    fmt = "{:4s}  {:34s}  {:46s}  {:>9s}  {}"
    log(fmt.format("", "file", "selector", "actual", "check"))
    for fname, sel, col, check in EXPECTED_VALUES:
        if fname not in cache:
            p = out_dir / fname
            cache[fname] = pd.read_csv(p, sep="\t") if p.is_file() else pd.DataFrame()
        sub = _select(cache[fname], sel)
        sel_s = ",".join(f"{k}={v}" for k, v in sel.items())
        if sub.empty or col not in sub.columns:
            log(fmt.format("FAIL", fname, sel_s, "MISSING", str(check)))
            failed += 1
            continue
        actual = float(sub.iloc[0][col])
        kind = check[0]
        if kind == "approx":
            ok = abs(actual - check[1]) <= check[2]
        elif kind == "range":
            ok = check[1] <= actual <= check[2]
        elif kind == "le":
            ok = actual <= check[1]
        elif kind == "ge":
            ok = actual >= check[1]
        else:
            ok = False
        log(fmt.format("PASS" if ok else "FAIL", fname, sel_s, f"{actual:+.3f}", str(check)))
        passed += ok
        failed += (not ok)
    log(f"--- {passed} passed, {failed} failed ---")
    return 0 if failed == 0 else 1


# ----------------------------------------------------------------------------
# Optional debug heatmap
# ----------------------------------------------------------------------------
def plot_heatmaps(fourway: pd.DataFrame, variants: list[str], out_dir: Path) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:  # noqa: BLE001
        log(f"[plot] matplotlib unavailable ({e}); skipping heatmaps")
        return
    have = variants
    for env, g in fourway.groupby("env"):
        fig, axes = plt.subplots(1, 2, figsize=(9, 4))
        for ax, col, title in zip(axes, ("r_raw", "r_zscored"), ("raw", "z-scored")):
            M = np.full((len(have), len(have)), np.nan)
            for i, a in enumerate(have):
                M[i, i] = 1.0
                for j, b in enumerate(have):
                    if j <= i:
                        continue
                    row = g[(g.variant_a == a) & (g.variant_b == b)]
                    if not row.empty:
                        M[i, j] = M[j, i] = row.iloc[0][col]
            im = ax.imshow(M, vmin=-1, vmax=1, cmap="RdBu_r")
            ax.set_xticks(range(len(have))); ax.set_xticklabels(have, rotation=45)
            ax.set_yticks(range(len(have))); ax.set_yticklabels(have)
            for (i, j), v in np.ndenumerate(M):
                if not np.isnan(v):
                    ax.text(j, i, f"{v:+.2f}", ha="center", va="center", fontsize=8)
            ax.set_title(f"{env} — {title}")
            fig.colorbar(im, ax=ax, fraction=0.046)
        fig.tight_layout()
        out = out_dir / f"correlation-heatmap-{env}.pdf"
        fig.savefig(out); plt.close(fig)
        log(f"[plot] {out}")


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--campaign", required=True, type=Path,
                    help="campaign tree (publication or fused layout)")
    ap.add_argument("--out", type=Path, default=Path("paper-tables"),
                    help="output directory (default: paper-tables/)")
    ap.add_argument("--variants", default=",".join(MEASURED_VARIANTS),
                    help="comma-separated variant subset")
    ap.add_argument("--envs", default=",".join(ENVS),
                    help="comma-separated analysis envs (bare,hibench)")
    ap.add_argument("--verify", action="store_true",
                    help="check outputs against EXPECTED_VALUES; exit 1 on mismatch")
    ap.add_argument("--plot", action="store_true", help="also write debug heatmaps")
    args = ap.parse_args()

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    envs = [e.strip() for e in args.envs.split(",") if e.strip()]
    args.out.mkdir(parents=True, exist_ok=True)

    log(f"[load] campaign = {args.campaign}")
    df = load_means(args.campaign)
    log(f"[load] {len(df)} rows; variants present = {sorted(set(df.variant) & set(variants))}")

    fourway_all, permetric_all = [], []
    for env in envs:
        d = env_slice(df, env)
        mats, common = fingerprints(d, variants)
        if not mats:
            log(f"[{env}] <2 variants with data — skip")
            continue
        mats_z = zscore_per_metric(mats)
        fw = fourway_table(mats, mats_z, variants, env)
        pm = per_metric_table(mats, variants, env)
        fw.to_csv(args.out / f"correlation-4way-{env}.tsv", sep="\t", index=False)
        pm.to_csv(args.out / f"correlation-per-metric-{env}.tsv", sep="\t", index=False)
        log(f"[{env}] {len(common)} apps, {len(common)*len(METRICS)} features → "
            f"correlation-4way-{env}.tsv, correlation-per-metric-{env}.tsv")
        fourway_all.append(fw)
        permetric_all.append(pm)

    if fourway_all:
        fw_all = pd.concat(fourway_all, ignore_index=True)
        pm_all = pd.concat(permetric_all, ignore_index=True)
        fs = family_summary(fw_all, variants)
        pmf = per_metric_family(pm_all, variants)
        fs.to_csv(args.out / "correlation-family-summary.tsv", sep="\t", index=False)
        pmf.to_csv(args.out / "correlation-per-metric-family.tsv", sep="\t", index=False)
        log(f"[rollup] correlation-family-summary.tsv ({len(fs)} rows), "
            f"correlation-per-metric-family.tsv ({len(pmf)} rows)")

    oroot = find_overhead_root(args.campaign)
    if oroot is not None:
        ob = overhead_bounds(oroot, variants)
        if not ob.empty:
            ob.to_csv(args.out / "overhead-bounds.tsv", sep="\t", index=False)
            log(f"[overhead] overhead-bounds.tsv ({len(ob)} rows) from {oroot}/overhead")
    else:
        log("[overhead] no overhead/ dir found — skipping overhead-bounds.tsv")

    if args.plot and fourway_all:
        plot_heatmaps(fw_all, [v for v in variants if v in set(fw_all.variant_a) | set(fw_all.variant_b)], args.out)

    if args.verify:
        return verify(args.out)
    log(f"\n[done] tables written to {args.out}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())

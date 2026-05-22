#!/usr/bin/env python3
"""Per-workload data-quality flags for an IntP campaign.

Reads ``fragility-summary.tsv`` (sample loss) and ``aggregate-means.tsv``
(per-rep metric means) from a campaign ``bench-full`` directory and emits
``plots/quality-flags.tsv`` marking workloads whose per-rep aggregate should
be read with care:

* ``LOW_SAMPLE``    — mean sample loss over the reps exceeds --loss-threshold
                      (default 25%); the per-rep means rest on few samples.
* ``BIMODAL:<m>``   — metric ``m`` splits across reps into a near-zero cluster
                      and a substantial cluster (both non-trivial); the mean is
                      not representative of either mode.
* ``REGIME_SHIFT``  — for a bimodal metric, ``cpu`` also differs between the two
                      clusters → the workload genuinely ran in two regimes
                      (e.g. page-cache warm/cold), not just a probe dropout.
* ``PROBE_DROPOUT:<m>`` — bimodal metric with ``cpu`` stable across clusters →
                      the probe intermittently read zero while the workload was
                      unchanged.

``recommended_estimator`` is ``median`` for any flagged workload, else ``mean``.
This is advisory metadata; it does not rewrite the aggregate tables.

Usage:  quality-flags.py <results_dir>   # results_dir contains the *.tsv files
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import numpy as np
import pandas as pd

CORE_METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
# Metrics whose zero/non-zero split is meaningful to test for bimodality.
BIMODAL_CANDIDATES = ["llcmr", "llcocc", "mbw", "blk", "netp", "nets"]


def detect_bimodal(vals: pd.Series, *, zero_eps=0.5, nonzero_min=10.0,
                   min_cluster=2, lo=0.2, hi=0.8):
    """Return (is_bimodal, frac_zero, median_nonzero) for a per-rep metric."""
    v = pd.to_numeric(vals, errors="coerce").dropna()
    if len(v) < 4:
        return False, np.nan, np.nan
    zero = v < zero_eps
    nz = v[~zero]
    frac_zero = float(zero.mean())
    med_nz = float(nz.median()) if len(nz) else 0.0
    is_bi = (lo <= frac_zero <= hi
             and zero.sum() >= min_cluster and (~zero).sum() >= min_cluster
             and med_nz > nonzero_min)
    return is_bi, frac_zero, med_nz


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_dir", type=Path,
                    help="Campaign dir holding fragility-summary.tsv & aggregate-means.tsv")
    ap.add_argument("--out", type=Path, default=None,
                    help="Output TSV (default: <results_dir>/plots/quality-flags.tsv)")
    ap.add_argument("--loss-threshold", type=float, default=25.0,
                    help="Mean sample-loss %% above which a workload is LOW_SAMPLE")
    ap.add_argument("--regime-cpu-reldiff", type=float, default=0.30,
                    help="Relative cpu difference between clusters to call REGIME_SHIFT")
    args = ap.parse_args()

    rd = args.results_dir
    frag_p = rd / "fragility-summary.tsv"
    am_p = rd / "aggregate-means.tsv"
    if not am_p.exists():
        print(f"[quality-flags] no aggregate-means.tsv in {rd} — skip", file=sys.stderr)
        return 0

    am = pd.read_csv(am_p, sep="\t")
    for m in CORE_METRICS:
        if m in am:
            am[m] = pd.to_numeric(am[m], errors="coerce")
    frag = pd.read_csv(frag_p, sep="\t") if frag_p.exists() else pd.DataFrame()

    # Mean/max sample loss per (env,variant,stage,workload).
    key = ["env", "variant", "stage", "workload"]
    if not frag.empty:
        loss = (frag.groupby(key)
                .agg(sample_loss_mean_pct=("sample_loss_pct", "mean"),
                     sample_loss_max_pct=("sample_loss_pct", "max"),
                     min_actual_samples=("actual_samples", "min"))
                .reset_index())
    else:
        loss = pd.DataFrame(columns=key + ["sample_loss_mean_pct",
                                           "sample_loss_max_pct", "min_actual_samples"])

    rows = []
    for k, g in am.groupby(key):
        env, variant, stage, workload = k
        flags: list[str] = []

        lrow = loss[(loss[key] == pd.Series(k, index=key)).all(axis=1)] if not loss.empty else loss
        sl_mean = float(lrow["sample_loss_mean_pct"].iloc[0]) if len(lrow) else np.nan
        sl_max = float(lrow["sample_loss_max_pct"].iloc[0]) if len(lrow) else np.nan
        min_samp = float(lrow["min_actual_samples"].iloc[0]) if len(lrow) else np.nan
        if not np.isnan(sl_mean) and sl_mean > args.loss_threshold:
            flags.append("LOW_SAMPLE")

        for m in BIMODAL_CANDIDATES:
            if m not in g:
                continue
            is_bi, fz, mednz = detect_bimodal(g[m])
            if not is_bi:
                continue
            flags.append(f"BIMODAL:{m}")
            # Regime shift vs probe dropout: does cpu also split with this metric?
            cpu = pd.to_numeric(g["cpu"], errors="coerce")
            mvals = pd.to_numeric(g[m], errors="coerce")
            cpu_zero = cpu[mvals < 0.5].median()
            cpu_nz = cpu[mvals >= 0.5].median()
            denom = max(abs(cpu_nz), 1e-9)
            if pd.notna(cpu_zero) and pd.notna(cpu_nz) and \
               abs(cpu_nz - cpu_zero) / denom > args.regime_cpu_reldiff:
                if "REGIME_SHIFT" not in flags:
                    flags.append("REGIME_SHIFT")
            else:
                flags.append(f"PROBE_DROPOUT:{m}")

        rows.append(dict(
            env=env, variant=variant, stage=stage, workload=workload,
            n_reps=int(len(g)),
            sample_loss_mean_pct=round(sl_mean, 2) if not np.isnan(sl_mean) else "",
            sample_loss_max_pct=round(sl_max, 2) if not np.isnan(sl_max) else "",
            min_actual_samples=int(min_samp) if not np.isnan(min_samp) else "",
            flags=";".join(flags) if flags else "OK",
            recommended_estimator="median" if flags else "mean",
        ))

    out_df = pd.DataFrame(rows).sort_values(
        ["env", "variant", "stage", "workload"]).reset_index(drop=True)
    out = args.out or (rd / "plots" / "quality-flags.tsv")
    out.parent.mkdir(parents=True, exist_ok=True)
    out_df.to_csv(out, sep="\t", index=False)

    flagged = out_df[out_df["flags"] != "OK"]
    print(f"[quality-flags] {len(out_df)} workload-groups, {len(flagged)} flagged "
          f"-> {out}")
    if len(flagged):
        cols = ["stage", "workload", "sample_loss_mean_pct", "min_actual_samples",
                "flags", "recommended_estimator"]
        print(flagged[cols].to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# hibench-sample-loss.py -- timestamp-gap sample loss for HiBench profiler runs.
#
# The HiBench runner (bench/hibench/run-hibench-subset.sh) records elapsed_s +
# samples in run.json but NO duration_target_s: the profiler window is bounded
# by the Spark job, not a fixed --duration, and run.json's elapsed_s is
# wall-clock that includes profiler teardown (so samples can exceed elapsed_s).
# extract-fragility.py therefore reports 0 loss for every HiBench run.
#
# This computes loss directly from the profiler's own `ts` column instead of an
# external target: within the profiler's first..last span, every missing
# interval tick is a dropped sample. This needs no recorded target, so it works
# on OLD result trees unchanged, and it matches the stress-ng definition in
# spirit (fraction of expected ticks that never landed).
#
#   loss% = max(0, (expected_ticks - actual_samples) / expected_ticks * 100)
#   expected_ticks = round((ts[-1] - ts[0]) / interval) + 1
#
# Usage:
#   python3 hibench-sample-loss.py <results_root> [--interval S] [--out-dir DIR]
#
# Writes, next to <results_root> (or --out-dir):
#   fragility-hibench-samples.tsv      one row per HiBench rep
#   fragility-hibench-aggregated.tsv   one row per (env,variant)

import argparse
import glob
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PER_REP_GLOB = "hibench/*/bare/*/hibench/*/rep*/profiler.tsv"


def ticks_from_tsv(tsv: Path, interval: float):
    """Return (expected_ticks, actual_samples, span_s) from the ts column."""
    ts = []
    try:
        with tsv.open() as fh:
            for ln in fh:
                if ln[:1].isdigit():
                    try:
                        ts.append(float(ln.split("\t", 1)[0]))
                    except (ValueError, IndexError):
                        pass
    except OSError:
        return None
    if len(ts) < 2:
        return (len(ts), len(ts), 0.0)
    span = ts[-1] - ts[0]
    expected = round(span / interval) + 1
    return (expected, len(ts), round(span, 3))


def parse_rep_path(tsv: Path):
    """.../hibench/<leg>/bare/<variant>/hibench/<workload>/rep<R>/profiler.tsv"""
    parts = tsv.parts
    i = parts.index("hibench")           # first 'hibench' = campaign dir
    leg = parts[i + 1]
    variant = parts[i + 3]
    workload = parts[i + 5]
    rep = re.sub(r"\D", "", parts[i + 6]) or "0"
    profile = leg.split("-")[0]
    return profile, leg, variant, workload, int(rep)


def load_status(run_json: Path):
    try:
        d = json.loads(run_json.read_text())
        return d.get("status", ""), d.get("elapsed_s", ""), d.get("samples", "")
    except (OSError, json.JSONDecodeError):
        return "", "", ""


def main(argv=None):
    ap = argparse.ArgumentParser(description="HiBench timestamp-gap sample loss")
    ap.add_argument("results_root", type=Path)
    ap.add_argument("--interval", type=float,
                    default=float(os.environ.get("INTP_INTERVAL", "1")),
                    help="Profiler sampling interval in seconds (default 1)")
    ap.add_argument("--out-dir", type=Path, default=None,
                    help="Where to write the TSVs (default: results_root)")
    args = ap.parse_args(argv)

    root = args.results_root.resolve()
    out_dir = (args.out_dir or root).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for tsv in glob.glob(str(root / PER_REP_GLOB)):
        tsv = Path(tsv)
        t = ticks_from_tsv(tsv, args.interval)
        if t is None:
            continue
        expected, actual, span = t
        loss = max(0.0, (expected - actual) / expected * 100.0) if expected > 0 else 0.0
        profile, leg, variant, workload, rep = parse_rep_path(tsv)
        status, elapsed_s, samples_json = load_status(tsv.with_name("run.json"))
        rows.append(dict(
            env="hibench", profile=profile, leg=leg, variant=variant,
            workload=workload, rep=rep, interval_s=args.interval,
            span_s=span, expected_ticks=expected, actual_samples=actual,
            sample_loss_pct=round(loss, 2),
            run_elapsed_s=elapsed_s, status=status,
        ))

    if not rows:
        print(f"no HiBench profiler.tsv under {root}", file=sys.stderr)
        return 1

    rows.sort(key=lambda r: (r["profile"], r["variant"], r["workload"], r["rep"]))
    cols = ["env", "profile", "leg", "variant", "workload", "rep", "interval_s",
            "span_s", "expected_ticks", "actual_samples", "sample_loss_pct",
            "run_elapsed_s", "status"]
    sp = out_dir / "fragility-hibench-samples.tsv"
    with sp.open("w") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            fh.write("\t".join(str(r[c]) for c in cols) + "\n")

    agg = defaultdict(list)
    for r in rows:
        agg[r["variant"]].append(r)
    acols = ["env", "variant", "n_reps", "ok_reps",
             "mean_sample_loss_pct", "std_sample_loss_pct", "max_sample_loss_pct",
             "reps_with_loss_gt_5pct",
             "samples_mean", "samples_min", "samples_max"]
    ap_ = out_dir / "fragility-hibench-aggregated.tsv"
    with ap_.open("w") as fh:
        fh.write("\t".join(acols) + "\n")
        for v in sorted(agg):
            it = agg[v]
            L = [x["sample_loss_pct"] for x in it]
            smp = [x["actual_samples"] for x in it]
            fh.write("\t".join(str(x) for x in [
                "hibench", v, len(it), sum(1 for x in it if x["status"] == "ok"),
                round(statistics.mean(L), 2),
                round(statistics.pstdev(L), 2) if len(L) > 1 else 0,
                round(max(L), 2), sum(1 for x in L if x > 5),
                round(statistics.mean(smp), 1), min(smp), max(smp),
            ]) + "\n")

    print(f"wrote {sp}  ({len(rows)} HiBench reps)")
    print(f"wrote {ap_}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

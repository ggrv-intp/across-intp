#!/usr/bin/env python3
# Tests for bench/plot/cross-variant-correlation.py.
#
# Builds a synthetic campaign tree in a tmpdir and drives the script against it.
# The fixture is constructed to exercise the parts that are easy to get wrong:
#   (a) shared metrics identical across all four variants  -> per-metric r == 1
#       for every pair, four_way_all n_pairs == 6.
#   (b) a capability-gap metric (llcocc): the "modern" pair {v2, v3.2} carries a
#       pattern, the "systemtap" pair {v0.2, v1.1} is flat/constant. Constant
#       series -> Pearson undefined -> those pairs must be EXCLUDED (NaN), so
#       within_modern survives but cross_family / within_systemtap drop out.
#   (c) per-variant overhead baseline: v0.2 divides by _baseline.v0.2, the others
#       by the shared _baseline; the resulting throughput deltas are exact.
#   (d) both analysis envs (bare = solo, hibench = hibench-<profile>) are emitted.
#
# Run:  python3 -m unittest bench/plot/tests/test_cross_variant_correlation.py

from __future__ import annotations

import csv
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
SCRIPT = THIS_DIR.parent / "cross-variant-correlation.py"

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
VARIANTS = ["v0.2", "v1.1", "v2", "v3.2"]
MODERN = {"v2", "v3.2"}


def _read_tsv(path: Path) -> list[dict]:
    with path.open() as f:
        return list(csv.DictReader(f, delimiter="\t"))


def _means_rows() -> list[dict]:
    """Synthetic aggregate-means rows for bare (solo) + hibench (standard)."""
    rows: list[dict] = []

    def add(env, variant, stage, workload, rep, vals):
        row = dict(env=env, variant=variant, stage=stage, workload=workload, rep=rep)
        row.update({m: vals[m] for m in METRICS})
        rows.append(row)

    # 6 bare-solo workloads, 2 reps each (means over reps = the target).
    bare_workloads = [f"w{i}" for i in range(1, 7)]
    for wi, w in enumerate(bare_workloads):
        shared = 10.0 * (wi + 1)          # monotone pattern, identical across variants
        modern_llcocc = 5.0 * (wi + 1)    # only v2/v3.2 instrument llcocc
        for v in VARIANTS:
            vals = {m: shared + {"netp": 0, "nets": 1, "blk": 2, "mbw": 3,
                                 "llcmr": 4, "cpu": 6}.get(m, 0) for m in METRICS}
            vals["llcocc"] = modern_llcocc if v in MODERN else 0.0
            for rep in (1, 2):
                add("bare", v, "solo", w, rep, vals)

    # 3 hibench workloads under one profile, so the hibench env is produced too.
    for wi, w in enumerate(["bayes", "kmeans", "terasort"]):
        shared = 7.0 * (wi + 1)
        for v in VARIANTS:
            vals = {m: shared for m in METRICS}
            vals["llcocc"] = (4.0 * (wi + 1)) if v in MODERN else 0.0
            for rep in (1, 2):
                add("bare", v, "hibench-standard", w, rep, vals)
    return rows


def _write_means(path: Path, rows: list[dict]) -> None:
    cols = ["env", "variant", "stage", "workload", "rep"] + METRICS
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, delimiter="\t")
        w.writeheader()
        w.writerows(rows)


def _write_overhead(root: Path) -> None:
    """overhead/<env>/<variant>/<ref>/rep<R>/throughput.tsv with known bogo ops.

    _baseline = 100, _baseline.v0.2 = 200 (v0.2's own session). Arms chosen so:
      v0.2 = 190 / 200  -> +5.0 %   (uses the per-variant baseline)
      v1.1 =  98 / 100  -> +2.0 %
      v2   = 100 / 100  ->  0.0 %
      v3.2 =  99 / 100  -> +1.0 %
    """
    bogo = {"_baseline": 100.0, "_baseline.v0.2": 200.0,
            "v0.2": 190.0, "v1.1": 98.0, "v2": 100.0, "v3.2": 99.0}
    for variant, val in bogo.items():
        for rep in (1, 2):
            d = root / "overhead" / "bare" / variant / "ref_cpu" / f"rep{rep}"
            d.mkdir(parents=True, exist_ok=True)
            (d / "throughput.tsv").write_text(
                "metric\tvalue\n"
                "bogo_ops_total\t1000\n"
                "real_time_s\t100.000\n"
                f"bogo_ops_per_s_real\t{val}\n")


class CrossVariantCorrelationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="xvar-corr-test-"))
        bench_full = cls.tmp / "bench-full"
        bench_full.mkdir()
        _write_means(bench_full / "aggregate-means.tsv", _means_rows())
        _write_overhead(bench_full)
        cls.out = cls.tmp / "out"
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--campaign", str(cls.tmp),
             "--out", str(cls.out)],
            capture_output=True, text=True, check=False)
        cls.proc = proc
        if proc.returncode != 0:
            raise RuntimeError(
                f"cross-variant-correlation.py failed (rc={proc.returncode})\n"
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_outputs_exist(self) -> None:
        for name in ("correlation-4way-bare.tsv", "correlation-4way-hibench.tsv",
                     "correlation-per-metric-bare.tsv", "correlation-family-summary.tsv",
                     "correlation-per-metric-family.tsv", "overhead-bounds.tsv"):
            with self.subTest(name=name):
                self.assertTrue((self.out / name).exists(), f"missing {name}")

    def test_four_way_has_six_pairs(self) -> None:
        rows = _read_tsv(self.out / "correlation-4way-bare.tsv")
        self.assertEqual(len(rows), 6, "4 variants -> 6 unordered pairs")

    def test_family_rollup_pair_counts(self) -> None:
        rows = _read_tsv(self.out / "correlation-family-summary.tsv")
        bare_raw = {r["family"]: r for r in rows
                    if r["env"] == "bare" and r["scope"] == "raw"}
        self.assertEqual(bare_raw["four_way_all"]["n_pairs"], "6")
        self.assertEqual(bare_raw["within_modern"]["n_pairs"], "1")
        self.assertEqual(bare_raw["cross_family"]["n_pairs"], "4")

    def test_shared_metric_perfectly_correlated(self) -> None:
        # cpu is identical across all variants -> every pair r == 1.0
        rows = _read_tsv(self.out / "correlation-per-metric-family.tsv")
        cpu_fw = [r for r in rows if r["env"] == "bare"
                  and r["metric"] == "cpu" and r["family"] == "four_way_all"]
        self.assertEqual(len(cpu_fw), 1)
        self.assertAlmostEqual(float(cpu_fw[0]["mean_r"]), 1.0, places=3)
        self.assertEqual(cpu_fw[0]["n_pairs"], "6")

    def test_llcocc_capability_gap(self) -> None:
        rows = _read_tsv(self.out / "correlation-per-metric-family.tsv")
        bare = {r["family"]: r for r in rows
                if r["env"] == "bare" and r["metric"] == "llcocc"}
        # modern pair carries the pattern -> correlated and present
        self.assertIn("within_modern", bare)
        self.assertAlmostEqual(float(bare["within_modern"]["mean_r"]), 1.0, places=3)
        # systemtap pair is constant (0) -> Pearson undefined -> pair excluded
        self.assertNotIn("within_systemtap", bare,
                         "constant llcocc series must be dropped, not counted")
        # cross-family also pairs a constant series -> excluded entirely
        self.assertNotIn("cross_family", bare)

    def test_overhead_per_variant_baseline(self) -> None:
        rows = {(r["variant"], r["ref_load"]): r
                for r in _read_tsv(self.out / "overhead-bounds.tsv")}
        # v0.2 divides by _baseline.v0.2 (200), not the shared _baseline (100):
        # (200-190)/200 = +5 %. A shared-baseline bug would give (100-190)/100 = -90 %.
        self.assertAlmostEqual(
            float(rows[("v0.2", "ref_cpu")]["throughput_delta_pct_mean"]), 5.0, places=2)
        self.assertAlmostEqual(
            float(rows[("v2", "ref_cpu")]["throughput_delta_pct_mean"]), 0.0, places=2)
        self.assertAlmostEqual(
            float(rows[("v3.2", "ref_cpu")]["throughput_delta_pct_mean"]), 1.0, places=2)


if __name__ == "__main__":
    unittest.main()

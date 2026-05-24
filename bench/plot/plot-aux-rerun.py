#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-aux-rerun.py — Figures from shared/intp-ebpf-checkout.sh runs.
#
# Inputs:  <run-dir> produced by shared/intp-ebpf-checkout.sh, containing
#          noise_floor/rep*/profiler.tsv and ringbuf_pidstat/<ref>/<arm>/rep*/.
#
# Outputs (in <run-dir>/plots/):
#   noise-floor-distribution.{png,pdf}   per-metric distribution across 1080 samples
#   noise-floor-timeseries.{png,pdf}     rep01 1-Hz time series, 7 metrics
#   exp5-sched-switch.{png,pdf}          sched_switch baseline vs with-V3 (+ vmstat
#                                        ground-truth column if present)
#
# Pass one or more --compare-with <run-dir> to additionally emit a
# concatenated cross-run figure:
#   noise-floor-compare.{png,pdf}        per-metric noise floor, one sub-bar
#                                        per run (e.g. v3 vs v3.2)
# -----------------------------------------------------------------------------
import argparse
import csv
import glob
import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_LABEL = {
    "netp":   "netp (NIC tx)",
    "nets":   "nets (NAPI poll)",
    "blk":    "blk (block I/O)",
    "mbw":    "mbw (mem BW)",
    "llcmr":  "llcmr (LLC miss rate)",
    "llcocc": "llcocc (LLC occupancy)",
    "cpu":    "cpu (sched_switch)",
}


def read_profiler_tsv(path):
    """Return a dict {metric: list[float]} from one profiler.tsv (skips '# ...' lines)."""
    out = {m: [] for m in METRICS}
    with open(path) as f:
        data = [ln for ln in f if not ln.startswith("#") and ln.strip()]
    for row in csv.DictReader(data, delimiter="\t"):
        for m in METRICS:
            try:
                out[m].append(float(row.get(m, 0) or 0))
            except (ValueError, TypeError):
                pass
    return out


def collect_noise_floor(run_dir):
    """Return {metric: 1-D np.array of all samples across all reps}."""
    pooled = {m: [] for m in METRICS}
    for rep in sorted(glob.glob(str(run_dir / "noise_floor" / "rep*" / "profiler.tsv"))):
        d = read_profiler_tsv(rep)
        for m in METRICS:
            pooled[m].extend(d[m])
    return {m: np.asarray(v, dtype=float) for m, v in pooled.items()}


def parse_perf_one(path, event):
    try:
        text = Path(path).read_text(errors="ignore")
    except (FileNotFoundError, OSError):
        return None
    for line in text.splitlines():
        m = re.search(r"([\d,]+)\s+" + re.escape(event), line)
        if m:
            try:
                return int(m.group(1).replace(",", ""))
            except ValueError:
                return None
    return None


def parse_vmstat_cs(path):
    """Sum vmstat 'cs' column over the 90-s window; returns 0 if file missing/malformed."""
    try:
        text = Path(path).read_text(errors="ignore")
    except (FileNotFoundError, OSError):
        return 0
    rows = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 17 and parts[0].isdigit():
            try:
                rows.append(int(parts[11]))
            except (ValueError, IndexError):
                pass
    return sum(rows[1:]) if len(rows) > 1 else 0


# --- Figure 1: noise-floor distribution -------------------------------------

def plot_noise_floor_distribution(run_dir, out_dir, label="V3"):
    """Horizontal per-metric strip: one row per metric, full 0-100 axis.

    Earlier renderings (boxplot, then violin+jitter) tried to show seven
    distributions with very different magnitudes on the same y-scale; the
    five near-zero metrics collapsed to slivers and the reader could not
    distinguish 0 from 5. The current layout puts each metric on its own
    horizontal row, draws a coloured bar from 0 to the median, a thin
    p5–p95 whisker, the mean as a tick, and prints the median value
    inline. The two metrics that actually carry distribution shape (mbw
    saturation artifact, llcocc heap-footprint band) get a wider IQR
    block so their structure is still legible."""
    data = collect_noise_floor(run_dir)
    n_total = sum(len(v) for v in data.values()) // len(METRICS)

    palette = {
        "netp":   "#e377c2", "nets":   "#9467bd", "blk":    "#2ca02c",
        "mbw":    "#1f77b4", "llcmr":  "#d62728", "llcocc": "#ff7f0e",
        "cpu":    "#000000",
    }
    # Render top-to-bottom in canonical metric order (reversed for matplotlib
    # y-axis convention so netp ends up at the top).
    rows = list(reversed(METRICS))

    fig, ax = plt.subplots(figsize=(8.2, 0.55 * len(rows) + 1.2))
    for i, m in enumerate(rows):
        v = np.asarray(data[m], dtype=float)
        if v.size == 0:
            continue
        med = float(np.median(v))
        mean = float(np.mean(v))
        p5, p25, p75, p95 = (float(x) for x in np.percentile(v, [5, 25, 75, 95]))
        col = palette[m]
        # Display-clip every drawn coordinate to the 0-100 axis. A broken
        # normaliser (e.g. v3.2 mbw with mem_bw_max_bps=0) can push p75/p95
        # into the thousands; without clipping the IQR bar runs off-frame
        # and overprints the right-margin numeric table. The true (un-
        # clipped) values are still printed at the right, and a '»' marker
        # flags that the geometry was clipped.
        cmed, cmean = min(med, 100.0), min(mean, 100.0)
        cp5, cp25, cp75, cp95 = (min(x, 100.0) for x in (p5, p25, p75, p95))
        clipped = max(med, mean, p95) > 100.0

        # 0-100 light backdrop: signals "this is the full possible range"
        ax.barh(i, 100, height=0.78, color="#eeeeee", edgecolor="none",
                zorder=1)
        # p5-p95 whisker (thin)
        ax.hlines(i, cp5, cp95, color=col, alpha=0.55, linewidth=1.3,
                  zorder=2)
        # IQR (p25-p75) thick band — visually dominant for distributions
        # with shape (mbw, llcocc); near-zero for the floor metrics. A
        # display-clipped (off-scale) bar is hatched so it never reads as a
        # legitimate ~100% measurement.
        ax.barh(i, cp75 - cp25, left=cp25, height=0.46, color=col,
                alpha=0.85, edgecolor="black", linewidth=0.4, zorder=3,
                hatch="///" if clipped else None)
        # Median tick (white slot through the IQR for legibility)
        ax.vlines(cmed, i - 0.30, i + 0.30, color="white", linewidth=2.4,
                  zorder=4)
        ax.vlines(cmed, i - 0.30, i + 0.30, color="black", linewidth=1.0,
                  zorder=5)
        # Mean: small black diamond
        ax.scatter(cmean, i, marker="D", s=22, color="white",
                   edgecolor="black", linewidth=0.9, zorder=6)
        # Right-margin numeric column, built as ONE monospace string per row
        # so its fields cannot overprint each other — the previous multi-anchor
        # layout collided the median against the p5–p95 bracket once mbw's
        # broken normaliser pushed the value to four digits. A leading '»'
        # flags a display-clipped (off-scale) value; the true number follows.
        # The bracket is suppressed when there is no spread (p5 == p95), which
        # would otherwise just restate the median.
        mark = "» " if clipped else "  "
        s = f"{mark}{med:>7.1f}"
        if (p95 - p5) > 0.05:
            s += f"   [{p5:>6.1f}, {p95:>8.1f}]"
        ax.text(104, i, s, va="center", ha="left", fontsize=8.5,
                family="DejaVu Sans Mono", clip_on=False)

    # Annotate the two metrics whose magnitude needs context.
    for i, m in enumerate(rows):
        if m == "mbw":
            mbw_clipped = max(np.median(data["mbw"]),
                              np.percentile(data["mbw"], 95)) > 100.0
            note = ("normaliser ceiling unresolved (mem_bw_max_bps=0) — "
                    "raw % unbounded, not a real signal"
                    if mbw_clipped else
                    "saturation artifact of predecessor normaliser "
                    "(not a real signal)")
            ax.text(50, i - 0.42, note,
                    ha="center", va="top", fontsize=7.5, style="italic",
                    color="#444")
        if m == "llcocc":
            ax.text(50, i - 0.42, "≈ resident JVM heap footprint of "
                    "HiBench stack (NameNode/DataNode/Master/Worker)",
                    ha="center", va="top", fontsize=7.5, style="italic",
                    color="#444")

    # Header for the right-margin numeric column (aligned to the row format:
    # 2-char mark slot + 7-wide median, then the bracket).
    top_y = len(rows) - 0.45
    ax.text(104, top_y, f"{'median':>9s}     p5–p95", va="bottom",
            ha="left", fontsize=8, style="italic", color="#666",
            family="DejaVu Sans Mono")

    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([METRIC_LABEL[m] for m in rows], fontsize=9)
    ax.set_xlim(-1, 150)
    ax.set_xticks([0, 25, 50, 75, 100])
    ax.set_xlabel("Value (% scale, 0–100)")
    ax.grid(axis="x", alpha=0.30)
    ax.spines["right"].set_visible(False)
    ax.spines["top"].set_visible(False)
    fig.suptitle(
        f"{label} noise floor — HiBench stack UP and IDLE   "
        f"(n={n_total} = 12 reps × 90 s; bar = IQR, line = p5–p95, "
        f"|=median, ◇=mean)",
        fontsize=9.5, y=0.985,
    )
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"noise-floor-distribution.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


# --- Figure 2: noise-floor time series for rep01 -----------------------------

def plot_noise_floor_timeseries(run_dir, out_dir, label="V3"):
    rep1 = run_dir / "noise_floor" / "rep01" / "profiler.tsv"
    if not rep1.exists():
        print(f"  skip timeseries: {rep1} not found")
        return
    d = read_profiler_tsv(rep1)
    n = max(len(d[m]) for m in METRICS) or 0
    t = np.arange(n)

    fig, axes = plt.subplots(4, 2, figsize=(9.0, 7.0), sharex=True)
    axes = axes.ravel()
    for ax, m in zip(axes, METRICS):
        ax.plot(t, d[m][:n], lw=1.0)
        ax.set_title(METRIC_LABEL[m], fontsize=9)
        ax.set_ylim(-3, 105)
        ax.grid(alpha=0.3)
    # hide unused last subplot
    axes[-1].axis("off")
    axes[-1].text(
        0.05, 0.50,
        "Single rep (90 s @ 1 Hz)\n"
        "rep01 / noise_floor /\n"
        "profiler.tsv\n\n"
        "Stack: HiBench UP & IDLE\n"
        "(NN+DN+Master+Worker)",
        transform=axes[-1].transAxes, fontsize=9, va="center",
    )
    for ax in axes[-3:-1]:
        ax.set_xlabel("Sample (seconds)")
    fig.suptitle(f"{label} noise-floor time series (rep01)", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"noise-floor-timeseries.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


# --- Figure 2b: concatenated noise-floor comparison across runs -------------

def plot_noise_floor_compare(runs, out_dir):
    """Concatenated per-metric noise-floor comparison across >=2 runs.

    `runs` is a list of (label, run_dir) pairs. Re-uses the single-run
    distribution language (0-100 backdrop, 0->median bar, p5-p95 whisker,
    median tick, mean diamond) but groups one sub-bar per run inside each
    metric row, so v3 and v3.2 sit side by side on a shared axis. Values
    above 100 are display-clipped to the axis and flagged with a '>>'
    marker; the true median/p5-p95 are always printed in the right
    margin so the clip never hides a number."""
    collected = [(label, collect_noise_floor(rd)) for label, rd in runs]
    k = len(collected)
    # n per run (samples per metric).
    n_by_run = [sum(len(v) for v in d.values()) // len(METRICS)
                for _, d in collected]

    run_colors = ["#1f77b4", "#ff7f0e", "#2ca02c", "#9467bd", "#d62728"]
    rows = list(reversed(METRICS))
    # vertical sub-slot layout inside each unit-height metric row
    span = 0.74
    sub_h = span / k

    fig, ax = plt.subplots(figsize=(9.2, (0.42 * k + 0.35) * len(rows) + 1.4))
    for i, m in enumerate(rows):
        # 0-100 backdrop spanning the whole metric group
        ax.barh(i, 100, height=0.92, color="#f2f2f2", edgecolor="none",
                zorder=1)
        for j, (label, data) in enumerate(collected):
            v = np.asarray(data[m], dtype=float)
            if v.size == 0:
                continue
            # sub-slot centre: top run first
            y = i + span / 2 - sub_h / 2 - j * sub_h
            med = float(np.median(v))
            mean = float(np.mean(v))
            p5, p95 = (float(x) for x in np.percentile(v, [5, 95]))
            col = run_colors[j % len(run_colors)]
            cmed, cmean = min(med, 100.0), min(mean, 100.0)
            cp5, cp95 = min(p5, 100.0), min(p95, 100.0)
            clipped = med > 100.0 or p95 > 100.0

            ax.hlines(y, cp5, cp95, color=col, alpha=0.55, linewidth=1.4,
                      zorder=2)
            # Off-scale (display-clipped) bars are hatched so a value forced to
            # the 100 ceiling never reads as a legitimate ~100% measurement.
            ax.barh(y, cmed, height=sub_h * 0.78, left=0, color=col,
                    alpha=0.85, edgecolor="black", linewidth=0.4, zorder=3,
                    hatch="///" if clipped else None)
            ax.vlines(cmed, y - sub_h * 0.34, y + sub_h * 0.34,
                      color="white", linewidth=2.2, zorder=4)
            ax.vlines(cmed, y - sub_h * 0.34, y + sub_h * 0.34,
                      color="black", linewidth=0.9, zorder=5)
            ax.scatter(cmean, y, marker="D", s=18, color="white",
                       edgecolor="black", linewidth=0.8, zorder=6)
            # Right-margin numeric column as ONE monospace string per run, so
            # the label / median / p5–p95 fields can never overprint each other
            # (they collided once mbw's broken normaliser hit four digits — the
            # 9-wide median field overlapped the run label). '»' flags a
            # display-clipped value; the true number follows.
            mark = "»" if clipped else " "
            s = f"{label:>4s} {mark}{med:>8.1f}"
            if (p95 - p5) > 0.05:
                s += f"   [{p5:>6.1f}, {p95:>8.1f}]"
            ax.text(103, y, s, va="center", ha="left", fontsize=7.5,
                    color=col, family="DejaVu Sans Mono", clip_on=False)

        if m == "mbw":
            ax.text(50, i - 0.46, "mbw% INVALID in both runs — v3.2 ceiling "
                    "= 0 (raw, unbounded); v3 clipped/saturated at 100",
                    ha="center", va="top", fontsize=7.0, style="italic",
                    color="#a00")

    # Header aligned to the row format: 4-wide run + mark slot + 8-wide median.
    top_y = len(rows) - 0.40
    ax.text(103, top_y, f"{'run':>4s}  {'median':>8s}      p5–p95",
            va="bottom", ha="left", fontsize=8, style="italic", color="#666",
            family="DejaVu Sans Mono")

    # per-run legend
    handles = [plt.Rectangle((0, 0), 1, 1, color=run_colors[j % len(run_colors)],
                             alpha=0.85)
               for j in range(k)]
    leg_labels = [f"{label}  ({n} samples)"
                  for (label, _), n in zip(collected, n_by_run)]
    ax.legend(handles, leg_labels, fontsize=8, loc="lower left",
              bbox_to_anchor=(0.16, 0.0), framealpha=0.9)

    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([METRIC_LABEL[m] for m in rows], fontsize=9)
    ax.set_xlim(-1, 150)
    ax.set_xticks([0, 25, 50, 75, 100])
    ax.set_xlabel("Value (% scale, 0–100; » = clipped, true value at right)")
    ax.grid(axis="x", alpha=0.30)
    ax.spines["right"].set_visible(False)
    ax.spines["top"].set_visible(False)
    fig.suptitle(
        "Noise-floor comparison — HiBench stack UP and IDLE\n"
        "n = per-metric samples (12 reps × 90 s @ 1 Hz);  "
        "bar = 0→median, line = p5–p95, |=median, ◇=mean,  » = clipped",
        fontsize=9.5, y=0.995,
    )
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"noise-floor-compare.{ext}", dpi=200,
                    bbox_inches="tight")
    plt.close(fig)


# --- Figure 3: experiment-5 sched-switch comparison -------------------------

def plot_exp5_sched_switch(run_dir, out_dir, label="V3"):
    base = run_dir / "ringbuf_pidstat"
    if not base.exists():
        print("  skip exp5: no ringbuf_pidstat dir")
        return

    refs = ["ref_cpu", "ref_disk", "ref_stream"]
    perf_base, perf_v3, vm_base, vm_v3 = {}, {}, {}, {}
    have_vmstat = False
    for ref in refs:
        perf_base[ref] = [parse_perf_one(p, "sched:sched_switch")
                          for p in sorted(glob.glob(str(base / ref / "baseline" / "rep*" / "perf_system.txt")))]
        perf_v3[ref]   = [parse_perf_one(p, "sched:sched_switch")
                          for p in sorted(glob.glob(str(base / ref / "with_profiler" / "rep*" / "perf_system.txt")))]
        perf_base[ref] = [v for v in perf_base[ref] if v]
        perf_v3[ref]   = [v for v in perf_v3[ref]   if v]
        vb = [parse_vmstat_cs(p) for p in sorted(glob.glob(str(base / ref / "baseline" / "rep*" / "vmstat.txt")))]
        vw = [parse_vmstat_cs(p) for p in sorted(glob.glob(str(base / ref / "with_profiler" / "rep*" / "vmstat.txt")))]
        vm_base[ref] = [v for v in vb if v]
        vm_v3[ref]   = [v for v in vw if v]
        if vm_base[ref] or vm_v3[ref]:
            have_vmstat = True

    x = np.arange(len(refs))
    if have_vmstat:
        # 4 bars per ref: perf-base, perf-v3, vmstat-base, vmstat-v3
        w = 0.20
        fig, ax = plt.subplots(figsize=(8.5, 4.2))
        ax.bar(x - 1.5*w, [np.mean(perf_base[r]) if perf_base[r] else 0 for r in refs], w,
               yerr=[np.std(perf_base[r]) if len(perf_base[r])>1 else 0 for r in refs],
               capsize=3, label="perf  · baseline", color="#1f77b4")
        ax.bar(x - 0.5*w, [np.mean(perf_v3[r]) if perf_v3[r] else 0 for r in refs], w,
               yerr=[np.std(perf_v3[r]) if len(perf_v3[r])>1 else 0 for r in refs],
               capsize=3, label=f"perf  · with {label}", color="#1f77b4", alpha=0.55, hatch="//")
        ax.bar(x + 0.5*w, [np.mean(vm_base[r]) if vm_base[r] else 0 for r in refs], w,
               yerr=[np.std(vm_base[r]) if len(vm_base[r])>1 else 0 for r in refs],
               capsize=3, label="vmstat · baseline", color="#d62728")
        ax.bar(x + 1.5*w, [np.mean(vm_v3[r]) if vm_v3[r] else 0 for r in refs], w,
               yerr=[np.std(vm_v3[r]) if len(vm_v3[r])>1 else 0 for r in refs],
               capsize=3, label=f"vmstat · with {label}", color="#d62728", alpha=0.55, hatch="//")
        ax.set_title("ctx-switches over 90 s window — perf counter vs vmstat ground-truth", fontsize=10)
    else:
        w = 0.32
        fig, ax = plt.subplots(figsize=(7.5, 4.0))
        ax.bar(x - w/2, [np.mean(perf_base[r]) if perf_base[r] else 0 for r in refs], w,
               yerr=[np.std(perf_base[r]) if len(perf_base[r])>1 else 0 for r in refs],
               capsize=3, label="baseline", color="#1f77b4")
        ax.bar(x + w/2, [np.mean(perf_v3[r]) if perf_v3[r] else 0 for r in refs], w,
               yerr=[np.std(perf_v3[r]) if len(perf_v3[r])>1 else 0 for r in refs],
               capsize=3, label=f"with {label}", color="#1f77b4", alpha=0.55, hatch="//")
        ax.set_title(
            "sched:sched_switch over 90 s — perf counter only\n"
            "⚠ vmstat ground-truth not captured in this run; counter drop may be artifactual",
            fontsize=9.5)

    ax.set_xticks(x)
    ax.set_xticklabels(refs)
    ax.set_ylabel("Events (count over 90 s)")
    ax.set_yscale("log")
    ax.grid(axis="y", which="both", alpha=0.3)
    ax.legend(fontsize=8, loc="upper right")
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"exp5-sched-switch.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path, help="run dir produced by intp-ebpf-checkout.sh")
    ap.add_argument("--out", type=Path, default=None, help="output dir (default: <run_dir>/plots)")
    ap.add_argument("--variant", default=None,
                    help="variant label for figure titles (default: read "
                         "<run_dir>/variant.txt, fall back to v3)")
    ap.add_argument("--compare-with", type=Path, action="append", default=[],
                    metavar="RUN_DIR",
                    help="additional run dir(s) to fold into a concatenated "
                         "noise-floor-compare figure (repeatable)")
    args = ap.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        print(f"error: not a directory: {run_dir}", file=sys.stderr)
        sys.exit(2)
    out_dir = args.out or (run_dir / "plots")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Variant label: --variant wins, else the marker written by
    # intp-ebpf-checkout.sh, else the historical default (v3).
    variant = args.variant
    if not variant:
        marker = run_dir / "variant.txt"
        variant = marker.read_text().strip() if marker.exists() else "v3"
    label = variant.upper()

    print(f"run_dir: {run_dir}")
    print(f"out_dir: {out_dir}")
    print(f"variant: {variant} ({label})")
    plot_noise_floor_distribution(run_dir, out_dir, label)
    plot_noise_floor_timeseries(run_dir, out_dir, label)
    plot_exp5_sched_switch(run_dir, out_dir, label)

    if args.compare_with:
        def _label(rd):
            marker = rd / "variant.txt"
            return (marker.read_text().strip() if marker.exists()
                    else rd.name).upper()

        runs = [(label, run_dir)]
        for extra in args.compare_with:
            extra = extra.resolve()
            if not extra.is_dir():
                print(f"  skip compare: not a directory: {extra}",
                      file=sys.stderr)
                continue
            runs.append((_label(extra), extra))
        if len(runs) >= 2:
            print(f"compare: {', '.join(l for l, _ in runs)}")
            plot_noise_floor_compare(runs, out_dir)

    print("done.")
    for f in sorted(out_dir.iterdir()):
        print(f"  {f.relative_to(run_dir)}")


if __name__ == "__main__":
    main()

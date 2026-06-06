#!/usr/bin/env python3
"""compare-environments.py -- cross-environment V2 capture comparison.

Reads baremetal.tsv / container.tsv / vm.tsv (all optional) from a results
directory and produces a Markdown report on stdout with:

  1. Summary table (mean, stdev, n-samples) per metric per environment,
     flagging metrics whose environment-to-environment means differ by
     more than 10 percent.
  2. Backends table: which backend each environment selected for each
     metric, parsed from the "# v2 backends:" banner.
  3. Availability matrix: metrics reported OK vs DEGRADED/PROXY/UNAVAILABLE.
     Because TSV only carries "--" for unavailable, availability here means
     "samples present" vs "all samples were --".
  4. Optional per-metric time-series plots (one PNG per metric) written to
     the results directory if matplotlib is importable. The Markdown still
     works without it.

The TSV format expected:

    # v2 backends: netp=sysfs nets=procfs_softirq blk=diskstats ...
    netp    nets    blk     mbw     llcmr   llcocc  cpu
    0       0       0       --      --      --      12
    ...

Python 3.8+, standard library only (matplotlib optional).
"""

import os
import statistics
import sys

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
ENVS = ("baremetal", "container", "vm")
DISAGREE_PCT = 10.0


def parse_tsv(path):
    """Return (banner_dict, list of per-sample dicts keyed by metric)."""
    banner = {}
    samples = []
    if not os.path.exists(path):
        return banner, samples
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("# v2 backends:"):
                for token in line.split()[3:]:
                    if "=" in token:
                        k, v = token.split("=", 1)
                        banner[k] = v
                continue
            if line.startswith("#"):
                continue
            if line.startswith("netp\t") or line.startswith("netp "):
                continue  # column header line
            cols = line.split("\t") if "\t" in line else line.split()
            if len(cols) != len(METRICS):
                continue
            row = {}
            for i, m in enumerate(METRICS):
                c = cols[i].strip()
                row[m] = None if c == "--" else _safe_float(c)
            samples.append(row)
    return banner, samples


def _safe_float(s):
    try:
        return float(s)
    except ValueError:
        return None


def stats_of(values):
    nums = [v for v in values if v is not None]
    if not nums:
        return None, None, 0
    mean = statistics.mean(nums)
    stdev = statistics.stdev(nums) if len(nums) >= 2 else 0.0
    return mean, stdev, len(nums)


def disagrees(means):
    """Given a list of means (possibly with Nones), return True if the max
    and min differ by more than DISAGREE_PCT percent relative to the mean.
    With fewer than two non-None values, never disagree."""
    vs = [v for v in means if v is not None]
    if len(vs) < 2:
        return False
    lo, hi = min(vs), max(vs)
    ref = statistics.mean(vs)
    if ref == 0:
        return (hi - lo) > 0.01  # any non-zero spread when ref==0 is a flag
    return (hi - lo) / abs(ref) * 100.0 > DISAGREE_PCT


def print_summary(envs):
    print("## Summary\n")
    head = ["metric"]
    for name, _, _ in envs:
        head += [f"{name} mean", f"{name} stdev", f"{name} n"]
    head += [f"disagree>{int(DISAGREE_PCT)}%"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for m in METRICS:
        row = [m]
        means = []
        for _, _, samples in envs:
            mean, stdev, n = stats_of([s[m] for s in samples])
            if mean is None:
                row += ["N/A", "N/A", "0"]
                means.append(None)
            else:
                row += [f"{mean:.2f}", f"{stdev:.2f}", str(n)]
                means.append(mean)
        row += ["yes" if disagrees(means) else "no"]
        print("| " + " | ".join(row) + " |")
    print()


def print_backends(envs):
    print("## Backends selected\n")
    print("| environment | " + " | ".join(METRICS) + " |")
    print("|" + "---|" * (len(METRICS) + 1))
    for name, banner, _ in envs:
        row = [name] + [banner.get(m, "-") for m in METRICS]
        print("| " + " | ".join(row) + " |")
    print()


def print_availability(envs):
    print("## Availability matrix\n")
    print("(OK = at least one numeric sample; N/A = all samples were '--')\n")
    print("| environment | " + " | ".join(METRICS) + " |")
    print("|" + "---|" * (len(METRICS) + 1))
    for name, _, samples in envs:
        row = [name]
        for m in METRICS:
            has_any = any(s[m] is not None for s in samples)
            row.append("OK" if has_any else "N/A")
        print("| " + " | ".join(row) + " |")
    print()


def try_plots(envs, outdir):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    for m in METRICS:
        fig, ax = plt.subplots(figsize=(8, 3))
        drew = False
        for name, _, samples in envs:
            series = [s[m] for s in samples if s[m] is not None]
            if not series:
                continue
            ax.plot(range(len(series)), series, label=name)
            drew = True
        if not drew:
            plt.close(fig)
            continue
        ax.set_title(f"V2 {m}")
        ax.set_xlabel("sample")
        ax.set_ylabel(m)
        ax.legend()
        out_path = os.path.join(outdir, f"comparison_{m}.png")
        fig.tight_layout()
        fig.savefig(out_path)
        plt.close(fig)
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: compare-environments.py <results-dir>", file=sys.stderr)
        return 1
    d = sys.argv[1]
    envs = []
    for name in ENVS:
        path = os.path.join(d, f"{name}.tsv")
        banner, samples = parse_tsv(path)
        if banner or samples:
            envs.append((name, banner, samples))

    print(f"# IntP V2 cross-environment comparison\n")
    print(f"Results directory: `{d}`\n")
    if not envs:
        print("_No TSV input found in this directory._\n")
        return 0
    print(f"Environments compared: {', '.join(name for name, _, _ in envs)}\n")

    print_summary(envs)
    print_backends(envs)
    print_availability(envs)

    plotted = try_plots(envs, d)
    if plotted:
        print("## Plots\n")
        for m in METRICS:
            p = os.path.join(d, f"comparison_{m}.png")
            if os.path.exists(p):
                print(f"- ![{m}]({os.path.basename(p)})")
        print()
    else:
        print("## Plots\n")
        print("_matplotlib not installed; skipping PNG generation._\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

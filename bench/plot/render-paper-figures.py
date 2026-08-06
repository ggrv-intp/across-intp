#!/usr/bin/env python3
"""
render-paper-figures.py -- Regenerate the SBAC-PAD 2026 camera-ready figure set.

Drives the three plotters in camera-ready mode and collects their PDFs under
the filenames the paper's ``figures/`` directory uses, so the result is a
drop-in replacement for the Overleaf project:

    plot-intp-bench.py   fig01b, fig04{,b,c}, fig05, fig07, fig11, fig13
    plot_pca_dendro.py   fig02
    plot-hibench.py      fig10

Each figure is rendered at its exact printed width (see paper_style.py), so
LaTeX includes it at scale 1.0 and the point sizes in the file are the point
sizes on paper.

Usage:
    python3 bench/plot/render-paper-figures.py <campaign-dir> --out <dir>

<campaign-dir> is the published campaign tree -- the one holding bare/,
overhead/, hibench/ and aggregate-means.tsv. Nothing is written inside it.

Outputs:
    <out>/figures/            the paper-named PDFs (+ PNG siblings)
    <out>/<subset>/{pdf,png}/ the raw per-subset renders
    <out>/qa/pearson_ground_truth.tsv
                              the nine profiler-vs-ground-truth Pearson r
                              values, for inlining as a table or in running
                              text instead of as a float (Addendum B.2)

The run is deterministic: same inputs produce byte-identical layout, so the
pipeline can be re-run and diffed.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paper_style  # noqa: E402

HERE = Path(__file__).resolve().parent

# Variants behind each published subset. Mirrors the published/ layout in the
# campaign artifact; v1.1 (stap-modern) is excluded from the paper figures.
SUBSET_VARIANTS = {
    "baseline": "v0.2",
    "new": "v2,v3.2",
    "merged": "v0.2,v2,v3.2",
}

# Which plotter owns which figure stem.
PCA_STEM = "fig02_pca_dendro"
HIBENCH_STEM = "fig10_variant_resource_heatmap"


def run(cmd: list[str]) -> None:
    print("  $ " + " ".join(str(c) for c in cmd))
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        sys.exit(f"FAILED ({proc.returncode}): {' '.join(str(c) for c in cmd)}")
    for line in proc.stdout.splitlines():
        if line.startswith("[") or line.startswith("wrote "):
            print("    " + line)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("campaign", type=Path,
                    help="Published campaign tree (holds bare/, overhead/, "
                         "hibench/, aggregate-means.tsv)")
    ap.add_argument("--out", type=Path, required=True,
                    help="Output directory for the regenerated figures")
    args = ap.parse_args()

    campaign: Path = args.campaign
    if not campaign.is_dir():
        sys.exit(f"campaign tree does not exist: {campaign}")
    means = campaign / "aggregate-means.tsv"
    hibench = campaign / "hibench"
    missing = [str(p) for p in (means, hibench) if not p.exists()]
    if missing:
        sys.exit("required campaign inputs are missing: " + ", ".join(missing))

    out: Path = args.out
    figures = out / "figures"
    figures.mkdir(parents=True, exist_ok=True)

    # Which stems each subset must render, derived from the spec table so the
    # driver cannot drift from paper_style.PAPER_FIGURES.
    wanted: dict[str, set[str]] = {}
    for (subset, stem) in paper_style.PAPER_FIGURES:
        wanted.setdefault(subset, set()).add(stem)

    for subset in ("baseline", "new", "merged"):
        stems = wanted.get(subset, set())
        if not stems:
            continue
        variants = SUBSET_VARIANTS[subset]
        subdir = out / subset
        print(f"\n=== subset {subset} ({variants}) ===")

        if stems - {PCA_STEM, HIBENCH_STEM}:
            run([sys.executable, HERE / "plot-intp-bench.py", campaign,
                 "--variants", variants, "--out", subdir,
                 "--camera-ready", "--paper-subset", subset])
        if PCA_STEM in stems:
            run([sys.executable, HERE / "plot_pca_dendro.py", means, subdir,
                 f"--variants={variants}", "--camera-ready",
                 f"--paper-subset={subset}"])
        if HIBENCH_STEM in stems:
            run([sys.executable, HERE / "plot-hibench.py", hibench,
                 "--variants", variants, "--out", subdir,
                 "--camera-ready", "--paper-subset", subset])

    # Collect twice, under both names the project uses for these figures:
    #   figures/           the paper's names, a drop-in for the Overleaf project
    #   published/<subset>/ the campaign artifact's layout (see sbac-results/)
    published = out / "published"
    print(f"\n=== collecting into {figures} and {published} ===")
    collected = 0
    for (subset, stem), spec in sorted(paper_style.PAPER_FIGURES.items()):
        src = out / subset / "pdf" / f"{stem}.pdf"
        if not src.exists():
            sys.exit(f"expected render is missing: {src}")
        shutil.copyfile(src, figures / spec.out_name)
        (published / subset).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, published / subset / f"{stem}.pdf")
        png = out / subset / "png" / f"{stem}.png"
        if png.exists():
            shutil.copyfile(png, figures / (spec.out_name[:-4] + ".png"))
            shutil.copyfile(png, published / subset / f"{stem}.png")
        print(f"  {spec.out_name:46s} <- {subset}/pdf/{stem}.pdf")
        collected += 1

    # Addendum B.2 item 3 replaced the Pearson matrix float with nine numbers
    # the author inlines as a table or in running text, so the numbers have to
    # leave the pipeline as data, not only as a picture.
    pearson = out / "merged" / "pearson_ground_truth.tsv"
    if pearson.exists():
        (out / "qa").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(pearson, out / "qa" / "pearson_ground_truth.tsv")
        print(f"  {'qa/pearson_ground_truth.tsv':46s} <- "
              f"merged/pearson_ground_truth.tsv")
    else:
        sys.exit(f"expected ground-truth table is missing: {pearson}")

    print(f"\n{collected} paper figures written to {figures}")
    print("Next: python3 bench/plot/qa_fig_fonts.py "
          f"{figures} --out {out}")


if __name__ == "__main__":
    main()

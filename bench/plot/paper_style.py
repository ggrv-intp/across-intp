#!/usr/bin/env python3
"""
paper_style.py -- Shared camera-ready typography and sizing for the SBAC-PAD
2026 paper figures.

Reviewer 3 asked for the multi-panel figures to be resized so their labels stay
legible at printed size. The pre-camera-ready pipeline rendered every figure
large (7-15 in wide) and let ``\\includegraphics`` scale it down to the column
or text width, which multiplied every font size by the same factor: an 8 pt
tick label inside a 12 in figure placed at 3.45 in prints at 2.3 pt.

The fix implemented here is to render each figure at its *exact printed size*,
so a font size set in the script is a true printed point size and LaTeX
includes the PDF at scale 1.0. Two things follow from that:

* the point sizes below (7 pt body, 6.5 pt annotations) are what the reader
  actually sees, so they are floors, not suggestions; and
* the figure has far less canvas to spend, so the in-figure suptitles that
  duplicate the LaTeX captions are dropped (see ``SUPPRESSED_SUPTITLES`` in the
  plot scripts) and panel spacing is tightened.

IEEEtran conference geometry, used for the width targets:
    \\columnwidth = 3.45 in     \\textwidth = 7.16 in

Only size, layout and typography are affected. No figure's numeric content,
ordering, colour-to-variant mapping or panel composition is touched by this
module -- it deliberately exposes no data-shaping knobs.
"""

from __future__ import annotations

from dataclasses import dataclass

import matplotlib.pyplot as plt
from matplotlib.transforms import Bbox

# --------------------------------------------------------------------------
# Page geometry (IEEEtran, conference mode)
# --------------------------------------------------------------------------

COLUMN_WIDTH = 3.45   # inches, \columnwidth
TEXT_WIDTH = 7.16     # inches, \textwidth

# --------------------------------------------------------------------------
# Typography floors
#
# ANNOT_FLOOR is the absolute minimum for any glyph in any paper figure and is
# reserved for dense in-cell heatmap annotations. Everything structural -- axis
# labels, tick labels, legends, panel tags -- sits at or above AXIS_FLOOR.
# The QA gate (qa_fig_fonts.py) re-reads the produced PDFs and enforces
# ANNOT_FLOOR, so lowering these here without lowering it there fails the build.
# --------------------------------------------------------------------------

ANNOT_FLOOR = 6.5     # heatmap cell annotations, segment tags
AXIS_FLOOR = 7.0      # axis labels, ticks, panel titles, legends

BODY = 7.0            # font.size / axes.labelsize / tick label size
LEGEND = 6.5          # legend.fontsize
TITLE = 7.5           # axes.titlesize (panel tags such as "profile=cpu-extreme")
ANNOT = 6.5           # in-cell numeric overlays

# Padding added around the tight bounding box when saving, in inches.
PAD_INCHES = 0.02


def apply() -> None:
    """Install the camera-ready rcParams.

    Call *after* a script's own ``setup_style()`` so these win. Keeps
    ``pdf.fonttype = 42`` (TrueType) so the PDF stores real text runs -- the QA
    gate extracts span sizes from the PDF and would see nothing if text were
    rendered as Type 3 outlines or paths.
    """
    plt.rcParams.update({
        "pdf.fonttype":      42,
        "ps.fonttype":       42,
        "font.family":       "DejaVu Sans",
        "font.size":         BODY,
        "axes.titlesize":    TITLE,
        "axes.labelsize":    BODY,
        "xtick.labelsize":   BODY,
        "ytick.labelsize":   BODY,
        "legend.fontsize":   LEGEND,
        "legend.frameon":    False,
        "axes.spines.top":   False,
        "axes.spines.right": False,
        "axes.grid":         True,
        "grid.linestyle":    ":",
        "grid.alpha":        0.4,
        # Thinner furniture: at 7 pt the default 0.8 pt spines and 1.5 pt lines
        # look heavy relative to the glyphs.
        "axes.linewidth":    0.6,
        "grid.linewidth":    0.5,
        "xtick.major.width": 0.6,
        "ytick.major.width": 0.6,
        "xtick.major.size":  2.5,
        "ytick.major.size":  2.5,
        "xtick.major.pad":   1.5,
        "ytick.major.pad":   1.5,
        "axes.labelpad":     2.0,
        "axes.titlepad":     3.0,
        "lines.linewidth":   1.0,
        "legend.handlelength": 1.4,
        "legend.handletextpad": 0.5,
        "legend.columnspacing": 1.0,
        "legend.borderaxespad": 0.3,
        # NOT figure.constrained_layout.use: turning it on globally would
        # collide with the figures that still call fig.tight_layout()
        # ("Colorbar layout of new layout engine not compatible with old
        # engine"). Each camera-ready figure opts in with layout="constrained".
        "figure.constrained_layout.w_pad":  0.02,
        "figure.constrained_layout.h_pad":  0.02,
        "figure.constrained_layout.wspace": 0.02,
        "figure.constrained_layout.hspace": 0.02,
    })


# --------------------------------------------------------------------------
# Per-figure targets
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class FigSpec:
    """Printed geometry for one paper figure.

    width          exact printed width in inches; the PDF is emitted at this
                   width so LaTeX includes it at scale 1.0.
    height_budget  soft ceiling in inches. Legibility wins: a figure that
                   cannot fit at >= 7 pt exceeds the budget and is flagged by
                   the QA gate rather than shrinking its fonts.
    height         the height actually used for the render (tuned per figure).
    paper_fig      placement in the camera-ready, for the QA report.
    out_name       filename in the paper's figures/ directory.
    """
    width: float
    height_budget: float
    height: float
    paper_fig: str
    out_name: str


# Keyed by (variant-subset, figure stem). The subset is which variants the
# panel shows -- "baseline" = v0.2 alone, "new" = v2 + v3.2, "merged" =
# v0.2 + v2 + v3.2 -- matching the published/ layout in the campaign artifact.
PAPER_FIGURES: dict[tuple[str, str], FigSpec] = {
    ("baseline", "fig01b_per_variant_bars"): FigSpec(
        COLUMN_WIDTH, 4.2, 4.15, "Fig. 2 (single column)",
        "baseline-fig01b_per_variant_bars.pdf"),
    ("new", "fig01b_per_variant_bars"): FigSpec(
        6.44, 3.6, 3.55, "Fig. 3 (figure*, 0.9\\textwidth)",
        "new-fig01b_per_variant_bars.pdf"),
    ("merged", "fig02_pca_dendro"): FigSpec(
        5.87, 3.0, 3.00, "Fig. 4 (figure*, 0.82\\textwidth)",
        "merged-fig02_pca_dendro.pdf"),
    ("new", "fig13_iada_segmented"): FigSpec(
        TEXT_WIDTH, 2.2, 2.18, "Fig. 5 (figure*, \\textwidth)",
        "new-fig13_iada_segmented.pdf"),
    ("merged", "fig10_variant_resource_heatmap"): FigSpec(
        6.80, 3.4, 3.35, "Fig. 6 (figure*, 0.95\\textwidth)",
        "merged-fig10_variant_resource_heatmap.pdf"),
    ("merged", "fig04_overhead_throughput"): FigSpec(
        2.33, 2.0, 1.98, "Fig. 7 left (0.325\\linewidth)",
        "merged-fig04_overhead_throughput.pdf"),
    ("merged", "fig04b_overhead_cpu_jiffies"): FigSpec(
        2.33, 2.0, 1.98, "Fig. 7 center (0.325\\linewidth)",
        "merged-fig04b_overhead_cpu_jiffies.pdf"),
    ("merged", "fig04c_overhead_sched_switch"): FigSpec(
        2.33, 2.0, 1.98, "Fig. 7 right (0.325\\linewidth)",
        "merged-fig04c_overhead_sched_switch.pdf"),
    ("merged", "fig07_pairwise_heatmap_bare"): FigSpec(
        COLUMN_WIDTH, 2.4, 2.40, "Fig. 8 (single column)",
        "merged-fig07_pairwise_heatmap_bare.pdf"),
    ("merged", "fig11_idi_bars"): FigSpec(
        4.01, 2.4, 2.35, "Fig. 9 left (0.56\\linewidth of figure*)",
        "merged-fig11_rep_errorbars.pdf"),
    ("merged", "fig05_fidelity_matrix"): FigSpec(
        3.01, 2.4, 2.10, "Fig. 9 right (0.42\\linewidth of figure*)",
        "merged-fig05_fidelity_matrix.pdf"),
}

# The primary set Reviewer 3 named explicitly (new numbering Figs. 2-7).
# The rest are secondary and get the same treatment, primary first.
PRIMARY_STEMS = {
    "fig01b_per_variant_bars",
    "fig02_pca_dendro",
    "fig13_iada_segmented",
    "fig10_variant_resource_heatmap",
    "fig04_overhead_throughput",
    "fig04b_overhead_cpu_jiffies",
    "fig04c_overhead_sched_switch",
}


def spec_for(subset: str | None, stem: str) -> FigSpec | None:
    """Camera-ready spec for (subset, stem), or None if not a paper figure."""
    if not subset:
        return None
    return PAPER_FIGURES.get((subset, stem))


# --------------------------------------------------------------------------
# Saving
# --------------------------------------------------------------------------

def save(fig, path, spec: FigSpec) -> tuple[float, float]:
    """Write ``fig`` to ``path`` at exactly ``spec.width`` inches wide.

    ``bbox_inches="tight"`` alone would trim to whatever the artists happen to
    occupy, so the page width would drift a few hundredths of an inch off
    target and LaTeX would rescale (and so re-shrink the fonts) to compensate.
    Instead the tight bbox is computed, padded by ``PAD_INCHES``, then widened
    symmetrically to the exact target. The result keeps tight-bbox behaviour --
    no dead margins -- while guaranteeing the page width the QA gate asserts
    and the ``width=`` factor in main.tex assumes.

    Height is left at whatever the content needs; the caller sized the figure
    to aim at its budget, and the QA gate reports any overrun.

    Returns the written (width, height) in inches.
    """
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    bb = fig.get_tightbbox(renderer).padded(PAD_INCHES)
    dw = spec.width - bb.width
    if dw < -0.01:
        # Content is genuinely wider than the printed width. Widening the bbox
        # by a negative amount would silently crop it, so say so instead: the
        # figure needs a layout change (fewer legend columns, shorter tick
        # rotation), not a quieter save.
        import warnings
        warnings.warn(
            f"{path.name}: content is {bb.width:.2f} in wide but the target is "
            f"{spec.width:.2f} in — the saved page will clip. Adjust the "
            f"layout for this figure.", stacklevel=2)
    bb = Bbox.from_extents(bb.x0 - dw / 2.0, bb.y0, bb.x1 + dw / 2.0, bb.y1)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, bbox_inches=bb)
    return spec.width, bb.height


def compact_legend(ax_or_fig, handles, labels, **kwargs):
    """One-row legend tuned for camera-ready panels.

    Small multiples get a legend that is a single row directly above the axes,
    with the frame and padding stripped so it costs as little vertical space as
    possible while staying at >= ``LEGEND`` pt.
    """
    opts = dict(
        loc="lower center", bbox_to_anchor=(0.5, 1.0),
        ncol=max(1, len(handles)), frameon=False, fontsize=LEGEND,
        handlelength=1.2, handletextpad=0.4, columnspacing=0.8,
        borderaxespad=0.15, borderpad=0.0,
    )
    opts.update(kwargs)
    return ax_or_fig.legend(handles, labels, **opts)

#!/usr/bin/env python3
"""
paper_style.py -- Shared camera-ready typography and sizing for the SBAC-PAD
2026 paper figures.

Each figure is rendered at its *exact printed size*: LaTeX includes the PDF
at scale 1.0, so a font size set here is a true printed point size. The
7 pt body / 6.5 pt annotation sizes are floors, not suggestions. Width
targets use IEEEtran conference geometry (``\\columnwidth`` = 3.45 in,
``\\textwidth`` = 7.16 in).

``FLOATS`` records which PDFs compose which paper float and what each costs
in points of column-space, against its pre-consolidation cost -- the QA gate
(``qa_fig_fonts.py``) reports against it.

This module deliberately exposes no data-shaping knobs: only size, layout
and typography. Rationale and history of the camera-ready passes are in
``bench/plot/README.md``.
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
#
# Addendum B (float consolidation) reshaped this table: the paper is over the
# 10-page limit and the figure set costs about a quarter of it, so panels were
# merged and floats relocated. The two entries whose paper_fig reads
# "alternative" are still rendered -- they are the fallbacks the author can
# swap back in -- but they are not placed in the camera-ready, so they cost no
# column-space. See FLOATS below for the accounting.
PAPER_FIGURES: dict[tuple[str, str], FigSpec] = {
    # Addendum B.2 item 1: the legacy panel alone. Superseded by the merged
    # three-panel Fig. 3, kept so the author can revert to the 2-float layout.
    ("baseline", "fig01b_per_variant_bars"): FigSpec(
        COLUMN_WIDTH, 4.2, 4.15, "alternative (legacy panel, unplaced)",
        "baseline-fig01b_per_variant_bars.pdf"),
    # Addendum B.2 item 1: old Figs. 2+3 in one full-width, three-panel float.
    # Keeps the filename the old Fig. 3 used so main.tex's \includegraphics
    # line needs only its width= factor changed.
    ("merged", "fig01b_per_variant_bars"): FigSpec(
        TEXT_WIDTH, 3.30, 3.25, "Fig. 2 (figure*, \\textwidth)",
        "new-fig01b_per_variant_bars.pdf"),
    # Untouched by Addendum B: the dendrogram leaf labels were the worst
    # legibility offender and this height is what fixed them.
    ("merged", "fig02_pca_dendro"): FigSpec(
        5.87, 3.0, 3.00, "Fig. 3 (figure*, 0.82\\textwidth)",
        "merged-fig02_pca_dendro.pdf"),
    # Addendum B.2 item 4: compact full-width strip.
    ("new", "fig13_iada_segmented"): FigSpec(
        TEXT_WIDTH, 1.60, 1.58, "Fig. 4 (figure*, \\textwidth)",
        "new-fig13_iada_segmented.pdf"),
    # Addendum B.2 item 2: the 4x2 profile grid collapsed to one heatmap of
    # 21 (variant x profile) rows, which fits a single column.
    ("merged", "fig10_variant_resource_heatmap"): FigSpec(
        COLUMN_WIDTH, 3.05, 3.00, "Fig. 5 (single column)",
        "merged-fig10_variant_resource_heatmap.pdf"),
    # Addendum B.2 item 5: the left panel carries the shared legend, so it is
    # taller than the other two by exactly the legend strip. The three are
    # bottom-aligned in LaTeX, so their axes line up and the float's height is
    # the left panel's.
    ("merged", "fig04_overhead_throughput"): FigSpec(
        2.33, 1.75, 1.72, "Fig. 6 left (0.325\\linewidth, shared legend)",
        "merged-fig04_overhead_throughput.pdf"),
    ("merged", "fig04b_overhead_cpu_jiffies"): FigSpec(
        2.33, 1.50, 1.47, "Fig. 6 center (0.325\\linewidth)",
        "merged-fig04b_overhead_cpu_jiffies.pdf"),
    ("merged", "fig04c_overhead_sched_switch"): FigSpec(
        2.33, 1.50, 1.47, "Fig. 6 right (0.325\\linewidth)",
        "merged-fig04c_overhead_sched_switch.pdf"),
    # Addendum B.2 item 6: same layout, dead vertical margin removed.
    ("merged", "fig07_pairwise_heatmap_bare"): FigSpec(
        COLUMN_WIDTH, 1.95, 1.90, "Fig. 7 (single column)",
        "merged-fig07_pairwise_heatmap_bare.pdf"),
    # Addendum B.2 item 3: the IDI bars carry the argument and now stand alone
    # at column width.
    ("merged", "fig11_idi_bars"): FigSpec(
        COLUMN_WIDTH, 2.25, 2.20, "Fig. 8 (single column)",
        "merged-fig11_rep_errorbars.pdf"),
    # Addendum B.2 item 3: nine Pearson r values, now also emitted as
    # qa/pearson_ground_truth.tsv for inlining as a table or in running text.
    # Still rendered in case the author keeps the matrix.
    ("merged", "fig05_fidelity_matrix"): FigSpec(
        3.01, 2.4, 2.10, "alternative (Pearson matrix, unplaced)",
        "merged-fig05_fidelity_matrix.pdf"),
}


# --------------------------------------------------------------------------
# Float-cost accounting (Addendum B)
#
# What costs page space is not a PDF but a *float*: its drawing, its caption,
# and the separation LaTeX inserts around it -- and a figure* pays all of that
# twice, because it consumes both columns of the page. So the budget is
# measured in points of column-space:
#
#     cost = span x (72 * drawing_height_in + overhead_pt)
#
# with span = 2 for figure* and 1 for figure. ``overhead_pt`` is the caption
# plus float separation for that float, per column spanned; the values below
# are back-solved from the author's measurements on the pre-consolidation
# camera-ready PDF (Addendum B.1), so they carry that document's real caption
# lengths rather than a nominal constant. ``cost_before_pt`` is the author's
# measured cost for the same float, and is what the savings are quoted
# against.
#
# One float can own several PDFs (the three overhead panels are assembled side
# by side), so members are listed per float and the drawing height of the
# float is the tallest member's.
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class FloatSpec:
    """One LaTeX float in the camera-ready, and what it costs.

    was            the float's identity in the pre-consolidation paper.
    now            its identity after Addendum B, or "" if it is gone.
    members        (subset, stem) keys into PAPER_FIGURES that this one float
                   is assembled from, after consolidation.
    span           columns of page the float occupies: 2 = figure*, 1 = figure.
    overhead_pt    caption + float separation, per column spanned.
    cost_before_pt the author's measured cost, in points of column-space.
    dropped        members the float used to carry and no longer does. Still
                   rendered as alternatives; they cost nothing unless used.
    """
    was: str
    now: str
    members: tuple[tuple[str, str], ...]
    span: int
    overhead_pt: float
    cost_before_pt: float
    dropped: tuple[tuple[str, str], ...] = ()


# In the order the floats appear in the camera-ready. Fig. 1 (the TikZ
# architecture diagram, 248 pt) is not produced by this pipeline and is out of
# scope for Addendum B; it is excluded from both sides of the budget.
FLOATS: tuple[FloatSpec, ...] = (
    FloatSpec("Fig. 2", "", (("baseline", "fig01b_per_variant_bars"),),
              1, 38.0, 279.0),
    FloatSpec("Fig. 3", "Fig. 2", (("merged", "fig01b_per_variant_bars"),),
              2, 29.0, 568.0),
    # Untouched by this pass, so its overhead is pinned to the value that
    # reproduces the measured 489 pt from the measured 216 pt drawing -- the
    # author's table rounds that drawing to 215, and left un-pinned the
    # rounding would show up as a spurious 2 pt regression on a figure nothing
    # changed.
    FloatSpec("Fig. 4", "Fig. 3", (("merged", "fig02_pca_dendro"),),
              2, 28.5, 489.0),
    FloatSpec("Fig. 5", "Fig. 4", (("new", "fig13_iada_segmented"),),
              2, 38.0, 390.0),
    FloatSpec("Fig. 6", "Fig. 5", (("merged", "fig10_variant_resource_heatmap"),),
              1, 29.5, 541.0),
    FloatSpec("Fig. 7", "Fig. 6",
              (("merged", "fig04_overhead_throughput"),
               ("merged", "fig04b_overhead_cpu_jiffies"),
               ("merged", "fig04c_overhead_sched_switch")),
              2, 47.0, 380.0),
    FloatSpec("Fig. 8", "Fig. 7", (("merged", "fig07_pairwise_heatmap_bare"),),
              1, 38.0, 213.0),
    FloatSpec("Fig. 9", "Fig. 8",
              (("merged", "fig11_idi_bars"),), 1, 47.0, 432.0,
              dropped=(("merged", "fig05_fidelity_matrix"),)),
)


def unplaced() -> list[tuple[tuple[str, str], str]]:
    """(member, why) for every figure still rendered but no longer placed.

    These are the fallbacks the author can swap back in, so they are reported
    rather than silently dropped -- but they cost no column-space unless used,
    and the budget counts them as zero.
    """
    out = []
    for fl in FLOATS:
        if not fl.now:
            out += [(m, f"{fl.was} removed") for m in fl.members]
        out += [(m, f"dropped from {fl.was}") for m in fl.dropped]
    return out

# Points of column-space in one page: 2 columns x 684 pt.
PAGE_COLUMN_SPACE = 1368.0
# The saving Addendum B.2 asks this pass to find.
SAVING_TARGET_PT = 1200.0


# --------------------------------------------------------------------------
# What main.tex has to change
#
# This pipeline does not edit main.tex, but half of each saving is a LaTeX-side
# change -- a float that stops spanning, an \includegraphics that goes away, a
# width= factor that no longer matches the PDF. Recording them here rather than
# in a side note keeps them next to the spec change that caused them, and the
# QA gate prints them into the report the author actually reads.
#
# Keyed by the float's pre-consolidation name, so it lines up with the "was"
# column of the budget table.
# --------------------------------------------------------------------------

LATEX_CHANGES: dict[str, tuple[str, ...]] = {
    "Fig. 2": (
        "Delete the whole `figure` environment: its `\\includegraphics` of "
        "`baseline-fig01b_per_variant_bars.pdf`, its `\\caption` and its "
        "`\\label`.",
        "Repoint any `\\ref` to that label at the merged fingerprint figure.",
    ),
    "Fig. 3": (
        "Keep `figure*`; change `width=0.9\\textwidth` to "
        "`width=\\textwidth` -- the PDF is now 7.16 in wide, so at 0.9 it "
        "would be scaled to 0.9 and every 7 pt label would print at 6.3 pt.",
        "Rewrite the caption: the float now carries all three endpoints "
        "(intp-baseline, C-ABI, eBPF-CORE), not the modern pair, and it "
        "subsumes what the deleted figure's caption said about the legacy "
        "baseline.",
        "The panel titles are the variant names alone now, so the caption "
        "must state `env=bare`.",
    ),
    "Fig. 4": (
        "No change.",
    ),
    "Fig. 5": (
        "No change -- still `figure*` at `width=\\textwidth`; only the PDF "
        "got shorter.",
    ),
    "Fig. 6": (
        "Change `figure*` to `figure` -- this is the saving; the float stops "
        "consuming both columns.",
        "Change `width=0.95\\textwidth` to `width=\\columnwidth`.",
        "Rewrite the caption: rows are now (variant x co-runner profile) and "
        "columns are the five resource families, one heatmap instead of "
        "seven panels. The variant names label the three row blocks in the "
        "left gutter and the profile names label the rows.",
    ),
    "Fig. 7": (
        "No structural change: the three `\\includegraphics"
        "[width=0.325\\linewidth]` lines stay as they are.",
        "Do **not** add `[valign=t]`, `\\raisebox` or a `\\begin{minipage}"
        "[t]` around them. The left PDF is taller than the other two by "
        "exactly its legend strip, and the default baseline alignment is "
        "what makes the three plot areas line up; top-aligning them would "
        "hang the centre and right panels below the left one.",
        "The caption must absorb two axis-label qualifiers that no longer "
        "fit on the panels: the centre panel's y axis is busy jiffies of "
        "`arm - baseline`, and the right panel's is a count of "
        "`sched:sched_switch` events.",
        "The caption should also say the legend is shared, since the centre "
        "and right panels no longer carry one.",
    ),
    "Fig. 8": (
        "No change.",
    ),
    "Fig. 9": (
        "Change `figure*` to `figure` -- this is most of the saving.",
        "Delete the `\\includegraphics` line for "
        "`merged-fig05_fidelity_matrix.pdf`; change the surviving "
        "`width=0.56\\linewidth` to `width=\\columnwidth`.",
        "Drop the half of the caption that described the Pearson matrix.",
        "Set the nine Pearson r values from `qa/pearson_ground_truth.tsv` as "
        "a three-row table or in running text. The matrix PDF is still "
        "rendered if you would rather keep it as its own single-column "
        "float.",
    ),
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

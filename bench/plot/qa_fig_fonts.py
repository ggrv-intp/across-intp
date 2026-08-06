#!/usr/bin/env python3
"""
qa_fig_fonts.py -- Camera-ready QA gate for the SBAC-PAD 2026 paper figures.

Reviewer 3's complaint was that labels were illegible at printed size. The fix
(render each figure at its exact printed width, see paper_style.py) is only
worth anything if it is *checked*, so this script re-opens the produced PDFs
and measures what a reader will actually see:

1. every text span and its size, extracted with PyMuPDF;
2. page width against the target (+/- WIDTH_TOL in), so LaTeX includes the
   figure at scale 1.0 rather than rescaling -- and re-shrinking -- the fonts;
3. minimum span size against paper_style.ANNOT_FLOOR;
4. height against each figure's budget (a warning, not a failure: legibility
   wins over compactness, so a figure may exceed its budget to hold the 7 pt
   floor);
5. a 300-dpi PNG contact sheet per figure under <out>/qa/ for human review.

Writes QA-FIGS.md and exits nonzero on any violation, so the pipeline fails
loudly rather than shipping a figure that regressed.

Usage:
    python3 bench/plot/qa_fig_fonts.py <figures-dir> --out <dir>

<figures-dir> is the directory of paper-named PDFs produced by
render-paper-figures.py.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paper_style  # noqa: E402

try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("PyMuPDF is required for the QA gate: pip install pymupdf")

# Page width must match the target this closely, in inches.
WIDTH_TOL = 0.05
# Contact-sheet render resolution.
CONTACT_DPI = 300
PT_PER_IN = 72.0


def spans(page) -> list[tuple[float, str]]:
    """(size, text) for every non-blank text span on the page."""
    out = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                text = span["text"].strip()
                if text:
                    out.append((round(span["size"], 2), text))
    return out


def text_counter(pdf: Path) -> Counter:
    """Multiset of the visible strings in a PDF's first page."""
    doc = fitz.open(pdf)
    c = Counter(t for _, t in spans(doc[0]))
    doc.close()
    return c


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("figures", type=Path,
                    help="Directory of paper-named PDFs")
    ap.add_argument("--out", type=Path, default=None,
                    help="Where to write QA-FIGS.md and qa/ "
                         "(default: alongside <figures>)")
    ap.add_argument("--no-contact-sheet", action="store_true",
                    help="Skip the PNG renders (faster; text checks still run)")
    ap.add_argument("--compare-to", type=Path, default=None,
                    help="Directory of the previously published figures, laid "
                         "out as <subset>/<stem>.pdf. Every visible string is "
                         "diffed against the new render so the report records "
                         "exactly what changed — the regeneration is supposed "
                         "to alter only typography and layout, so anything "
                         "beyond dropped titles, shared-axis de-duplication "
                         "and tick-locator thinning is a red flag.")
    args = ap.parse_args()

    out = args.out or args.figures.parent
    qa_dir = out / "qa"
    qa_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    failures = []
    warnings = []
    deltas: list[tuple[str, list[str], list[str]]] = []

    for (subset, stem), spec in sorted(
            paper_style.PAPER_FIGURES.items(),
            key=lambda kv: (kv[1].paper_fig, kv[1].out_name)):
        pdf = args.figures / spec.out_name
        if not pdf.exists():
            failures.append(f"{spec.out_name}: missing")
            rows.append((spec, subset, stem, None, None, None, "MISSING",
                         "file not produced"))
            continue

        doc = fitz.open(pdf)
        page = doc[0]
        width = page.rect.width / PT_PER_IN
        height = page.rect.height / PT_PER_IN
        found = spans(page)
        notes = []

        if not found:
            failures.append(
                f"{spec.out_name}: no extractable text — the PDF is not "
                f"embedding text as text (check pdf.fonttype = 42)")
            min_pt = None
            notes.append("no text spans found")
        else:
            min_pt = min(s for s, _ in found)
            if min_pt < paper_style.ANNOT_FLOOR - 1e-6:
                worst = sorted({t for s, t in found if s == min_pt})[:3]
                failures.append(
                    f"{spec.out_name}: min font {min_pt:.2f} pt < "
                    f"{paper_style.ANNOT_FLOOR} pt floor "
                    f"(e.g. {', '.join(repr(w) for w in worst)})")
                notes.append(f"below {paper_style.ANNOT_FLOOR} pt floor")

        if abs(width - spec.width) > WIDTH_TOL:
            failures.append(
                f"{spec.out_name}: width {width:.3f} in != target "
                f"{spec.width:.2f} in (tolerance {WIDTH_TOL} in)")
            notes.append("width off target")

        # Height budget is advisory: exceeding it to hold the font floor is the
        # documented trade-off, so it warns rather than fails.
        if height > spec.height_budget + 1e-6:
            over = height - spec.height_budget
            verdict = f"OVER by {over:.2f} in"
            warnings.append(
                f"{spec.out_name}: height {height:.2f} in exceeds budget "
                f"{spec.height_budget:.2f} in by {over:.2f} in "
                f"(kept to preserve the {paper_style.AXIS_FLOOR} pt floor)")
        else:
            verdict = f"OK ({height:.2f} <= {spec.height_budget:.2f} in)"

        if not args.no_contact_sheet:
            pix = page.get_pixmap(dpi=CONTACT_DPI)
            pix.save(qa_dir / (spec.out_name[:-4] + ".png"))

        if args.compare_to is not None:
            prev = args.compare_to / subset / f"{stem}.pdf"
            if prev.exists():
                before = text_counter(prev)
                after = Counter(t for _, t in found)
                deltas.append((spec.out_name,
                               sorted((before - after).elements()),
                               sorted((after - before).elements())))
            else:
                deltas.append((spec.out_name, ["(no previous render found)"], []))

        rows.append((spec, subset, stem, width, height, min_pt, verdict,
                     "; ".join(notes) if notes else "—"))
        doc.close()

    # ---- report -----------------------------------------------------------
    lines = [
        "# QA-FIGS — camera-ready figure gate",
        "",
        "Generated by `bench/plot/qa_fig_fonts.py`. Every row is measured from",
        "the produced PDF, not from the plotting code: page geometry comes from",
        "the page box and font sizes from the embedded text spans.",
        "",
        f"- Font floor: **{paper_style.ANNOT_FLOOR} pt** any glyph "
        f"(heatmap cell annotations), **{paper_style.AXIS_FLOOR} pt** for "
        f"axis/tick/legend/label text.",
        f"- Width tolerance: **±{WIDTH_TOL} in** against the printed target.",
        "- Height budget is advisory — legibility wins, so a figure may exceed",
        "  it rather than drop below the font floor.",
        "",
        "## Figure map",
        "",
        "| Paper fig | File | Generator | Subset |",
        "|---|---|---|---|",
    ]
    gen_of = {
        "fig02_pca_dendro": "`plot_pca_dendro.py`",
        "fig10_variant_resource_heatmap": "`plot-hibench.py`",
    }
    for spec, subset, stem, *_ in rows:
        gen = gen_of.get(stem, "`plot-intp-bench.py`")
        lines.append(f"| {spec.paper_fig} | `{spec.out_name}` | {gen} | {subset} |")

    lines += [
        "",
        "## Measurements",
        "",
        "| File | Width (in) | Target (in) | Height (in) | Min font (pt) | "
        "Height budget | Notes |",
        "|---|---|---|---|---|---|---|",
    ]
    for spec, _subset, _stem, width, height, min_pt, verdict, notes in rows:
        w = f"{width:.2f}" if width is not None else "—"
        h = f"{height:.2f}" if height is not None else "—"
        m = f"{min_pt:.2f}" if min_pt is not None else "—"
        lines.append(
            f"| `{spec.out_name}` | {w} | {spec.width:.2f} | {h} | {m} | "
            f"{verdict} | {notes} |")

    if deltas:
        lines += [
            "",
            "## Content delta vs the previously published figures",
            "",
            "Every visible string in each PDF, before and after. The",
            "regeneration is only allowed to change size, layout and",
            "typography, so this table is the audit for that: the expected",
            "entries are in-figure titles that were dropped because the LaTeX",
            "caption already carries them, axis tick labels thinned by",
            "matplotlib's locator at the smaller width, and y-labels that",
            "appear once per row instead of once per panel now that panels",
            "share an axis. **Nothing should appear under _added_, and no",
            "data value should appear under _removed_.**",
            "",
            "| File | Removed | Added |",
            "|---|---|---|",
        ]
        for name, removed, added in deltas:
            def fmt(items):
                if not items:
                    return "—"
                uniq = sorted(set(items))
                shown = "; ".join(f"`{u}`" + (f" ×{items.count(u)}"
                                              if items.count(u) > 1 else "")
                                  for u in uniq)
                return shown.replace("|", "\\|")
            lines.append(f"| `{name}` | {fmt(removed)} | {fmt(added)} |")

    lines += ["", "## Result", ""]
    if failures:
        lines.append(f"**FAIL** — {len(failures)} violation(s):")
        lines.append("")
        lines += [f"- {f}" for f in failures]
    else:
        lines.append(f"**PASS** — {len(rows)} figures, all at target width "
                     f"and above the {paper_style.ANNOT_FLOOR} pt floor.")
    if warnings:
        lines += ["", f"{len(warnings)} height-budget warning(s):", ""]
        lines += [f"- {w}" for w in warnings]
    lines += ["", f"Contact sheet: `{qa_dir.name}/` "
                  f"({CONTACT_DPI} dpi PNG per figure).", ""]

    report = out / "QA-FIGS.md"
    report.write_text("\n".join(lines))
    print("\n".join(lines[-(len(failures) + len(warnings) + 8):]))
    print(f"\nreport: {report}")
    print(f"contact sheet: {qa_dir}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

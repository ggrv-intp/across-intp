# DECISIONS.md — HiBench sample-loss reproducibility

Implementation notes / deviations for the 4-phase HiBench timestamp-gap
sample-loss fix. One commit per phase on `main`.

## Conventions applied

- Branch `main`; one commit per phase, using the brief's stated commit messages.
- Commits **omit** the `Co-Authored-By` trailer (per user instruction, 2026-06-01).
- No unrelated reformatting.

## D1 — `extract-fragility.patched.py` is not a separate file

The brief names a provided `extract-fragility.patched.py` as the Phase-2 "source
of truth" to diff against. No such file exists in the working tree or the
provided artifact. Per the user (2026-06-01), that patched reference was folded
directly into the working-tree `bench/plot/extract-fragility.py` modifications.
Verified the edit against the brief's explicit 3-edit description instead
(`expected_from_timestamps()` added after `count_tsv_samples()`; per-run
`interval` + timestamp-gap fallback in `row_for()`; path-based `env` fallback) —
it matches.

## D2 — prior uncommitted pass left a stripped EOF newline

The working tree already held the Phase-1 file (untracked) and the Phase-2 edit
(unstaged). Both files had the trailing newline at EOF removed — a spurious diff
that violates "do not reformat untouched code". Fixed:

- `bench/plot/hibench-sample-loss.py`: restored to byte-verbatim by copying the
  pristine provided copy, then `chmod +x` (Phase 1).
- `bench/plot/extract-fragility.py`: trailing newline restored so the diff vs
  HEAD is only the intended insertions (Phase 2).

## D3 — acceptance tree location; no stall dumps present

Acceptance was run against the provided release tree, which the user relocated
into the repo at `results/across-intp-sbac-results-v0.1.0/sbac_results-publish/`
(`/results/` is gitignored, so it is never committed). This is the **redacted
public payload**: it contains no `stall-monitor/` dumps (`stall-dump-*` count =
0). The shipped `fragility-aggregated.tsv` still carries
`bare v0.2 sum_stalls_detected=148` from the full tree, so the extractor must
NOT overwrite the shipped file here (that would reset stalls to 0). See D5
(Phase-2 validation method) and the README do-not-regenerate caveat.

## D4 — Phase 1 validated

`python3 bench/plot/hibench-sample-loss.py <tree> --out-dir <tmp>` reproduces the
shipped `fragility-hibench-aggregated.tsv` exactly over 2016 HiBench reps
(4×504): v0.2 3.03% / max 55.0% (68 reps>5%), v1.1 4.39% / max 73.08%
(100 reps>5%), v2 0.0% (max 2.38), v3.2 0.01% (max 1.85).

## D5 — Phase 2 validated without clobbering the shipped artifact

Method: backed up `fragility-aggregated.tsv` + `fragility-summary.tsv`, ran
`python3 bench/plot/extract-fragility.py <tree>`, inspected the regenerated
output, then restored the backups (confirmed byte-identical; bare v0.2
`sum_stalls_detected=148`, `runs_with_stall_dump=28` intact). Results:

- **env=bare UNCHANGED**: v0.2 277 mean 6.38 / max 75.56; v1.1 277 mean 15.96 /
  max 98.89; v2/v3.2 zero. (Regenerating against this redacted tree reads stall
  counts as 0 — see D3 — which is exactly why the shipped file is preserved,
  not overwritten.)
- **env=hibench NEW (real loss)**: v1.1 mean 4.05 / max 73.08 / 100 runs>5%;
  v0.2 mean 2.8 / max 55.0 / 68>5%; v2/v3.2 ~0 (max <2.4). n_runs = 546 = 504
  per-rep + 42 workload-aggregate `run.json` rows (no profiler.tsv → 0 loss),
  which is why the per-variant mean is ~4.05 here vs the Phase-1 tool's 4.39
  (expected, per the brief).

## D6 — paper text predates this definition (flag for authors)

The paper prose ("67 of 277 reps above 5%, mean 15.19%") is not reproducible
from the release and predates the timestamp-gap definition; the regenerated
HiBench figures are v1.1 ~4.0–4.4% mean with 100-of-504 reps >5%. Flagged for
the authors to reconcile the prose with the regenerated
`fragility-hibench-aggregated.tsv`. The paper is **not** edited from this repo
task (out of scope).

## D7 — `samples > elapsed_s` in old run.json is expected

The profiler window spans more than the Spark job's own wall-clock `elapsed_s`,
so `samples` can exceed `elapsed_s`. The timestamp-gap method intentionally
ignores `elapsed_s` and derives the window from the profiler `ts` column.

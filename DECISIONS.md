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
`bare legacy-intp-baseline sum_stalls_detected=148` from the full tree, so the extractor must
NOT overwrite the shipped file here (that would reset stalls to 0). See D5
(Phase-2 validation method) and the README do-not-regenerate caveat.

## D4 — Phase 1 validated

`python3 bench/plot/hibench-sample-loss.py <tree> --out-dir <tmp>` reproduces the
shipped `fragility-hibench-aggregated.tsv` exactly over 2016 HiBench reps
(4×504): legacy-intp-baseline 3.03% / max 55.0% (68 reps>5%), stap-modern 4.39% / max 73.08%
(100 reps>5%), C-ABI 0.0% (max 2.38), eBPF-CORE 0.01% (max 1.85).

## D5 — Phase 2 validated without clobbering the shipped artifact

Method: backed up `fragility-aggregated.tsv` + `fragility-summary.tsv`, ran
`python3 bench/plot/extract-fragility.py <tree>`, inspected the regenerated
output, then restored the backups (confirmed byte-identical; bare legacy-intp-baseline
`sum_stalls_detected=148`, `runs_with_stall_dump=28` intact). Results:

- **env=bare UNCHANGED**: legacy-intp-baseline 277 mean 6.38 / max 75.56; stap-modern 277 mean 15.96 /
  max 98.89; C-ABI/eBPF-CORE zero. (Regenerating against this redacted tree reads stall
  counts as 0 — see D3 — which is exactly why the shipped file is preserved,
  not overwritten.)
- **env=hibench NEW (real loss)**: stap-modern mean 4.05 / max 73.08 / 100 runs>5%;
  legacy-intp-baseline mean 2.8 / max 55.0 / 68>5%; C-ABI/eBPF-CORE ~0 (max <2.4). n_runs = 546 = 504
  per-rep + 42 workload-aggregate `run.json` rows (no profiler.tsv → 0 loss),
  which is why the per-variant mean is ~4.05 here vs the Phase-1 tool's 4.39
  (expected, per the brief).

## D6 — paper text reconciled to the reproducible HiBench numbers

The paper (`main.tex`) has been updated to the reproducible timestamp-gap
figures — **stap-modern: 100 of 504 reps >5%, mean 4.39%, max 73.08%** — i.e. exactly
the `fragility-hibench-aggregated.tsv` values produced by `hibench-sample-loss.py`
(an earlier draft predated this definition). The repo task does not modify the
paper; `main.tex` is maintained separately and already compiles clean.
Reviewers regenerating via the unified `extract-fragility.py` see a marginally
lower per-variant mean (~4.05%) for `env=hibench`, because those rows also
include the 0-loss workload-aggregate `run.json` files; the canonical per-rep
figure is 4.39% (see D4/D5).

## D7 — `samples > elapsed_s` in old run.json is expected

The profiler window spans more than the Spark job's own wall-clock `elapsed_s`,
so `samples` can exceed `elapsed_s`. The timestamp-gap method intentionally
ignores `elapsed_s` and derives the window from the profiler `ts` column.

## D8 — Phase 3: env + sample_interval_s in both HiBench run.json writers

- Added `"sample_interval_s":$INTERVAL` (the required field) to **both** the
  per-rep writer (heredoc ~L1251) and the workload-aggregate writer (~L1301).
  Adding it to the aggregate was trivial, so it was not skipped.
- Also stamped `"env":"hibench"` into both writers (the brief's optional
  self-describing-env step), keeping the Phase-2 path-based fallback. Old trees
  (no field) and new trees (field present) therefore classify identically as
  `env=hibench` — extractor output is unchanged either way. Extended the stamp
  to the aggregate writer too (the brief mentioned per-rep) for symmetry.
- Safe: no consumer depends on `env` being absent from HiBench run.json — plot
  scripts/tests read the `env` column of derived TSVs (not run.json);
  `hibench-sample-loss.py` reads only status/elapsed/samples; the script's own
  `rep_is_complete()` resume check greps for `"status":"ok"` only.
- Left the rare `profiler_start_failed` per-rep writer (printf, ~L1143)
  untouched: no profiler.tsv → loss is N/A and the path fallback still
  classifies it (minimal-change).
- Validated: `bash -n` clean; both writers emit valid JSON; a synthetic tree
  proves `extract-fragility.py` honors a recorded `sample_interval_s`
  (interval=2 → loss 0 vs interval absent/=1 → loss 40 on the same 3-sample,
  4 s-span profiler.tsv).

## D9 — Phase 4: reader/reviewer-facing data-quality section

Added a "Data-quality / sample loss" section to the repo's tracked
`sbac-results/README.md` (the scaffold README had none; the detailed copy lives
only in the gitignored published payload). It gives the stress-ng and HiBench
loss formulas, states that `extract-fragility.py` now emits real `env=hibench`
rows, that `hibench-sample-loss.py` is the standalone backfill for old trees,
and that future runs record `sample_interval_s`. Written for readers/reviewers
with **no author-only notes** (per user guidance, 2026-06-01): it cites the
canonical `fragility-hibench-aggregated.tsv` figures (stap-modern 4.39% / max 73.08% /
100-of-504 reps>5%) and explains the unified extractor's ~4.05% nuance for
reviewers. The existing do-not-regenerate / legacy-intp-baseline-stalls-as-counts caveat (under
Anonymization) is left intact and cross-referenced rather than duplicated, plus
a note that `hibench-sample-loss.py` is safe to re-run on the published tree
(writes only `fragility-hibench-*.tsv`) whereas `extract-fragility.py` would
rewrite the stall-bearing tables.

## D10 — camera-ready release refresh: two assets, redacted raws, recreated tag

The camera-ready figure pipeline merged as `862dc6d` (no-ff, PR #1). The
release plan changed twice from the original "tag never moves, assets
clobbered in place" stance, both by author decision:

1. **The raw sources are now public.** `consolidation-raw.tar.gz` joins the
   anonymized artifact as a second release asset: the five source campaign
   sessions (two hosts), the Fig. 6 auxiliary reruns, and the fusion trees
   (`ub24-concat`, `ub22-and-24-full`) with their PROVENANCE records. The
   original privacy rationale had weakened — the rented testbed nodes are
   decommissioned and the hostname/IP mapping was already public in
   `ANONYMIZATION.md`.
2. **The tag is recreated, not preserved.** `v0.1.0` is deleted and re-cut
   at the final post-merge commit so the release's source snapshot matches
   the code that produced the camera-ready figures. Acceptable because the
   camera-ready (due 2026-09-05) is not yet submitted; the risk that a
   submission-phase evaluator pinned the old `9795c5b` hash is accepted.

One redaction was applied to the raws before publication, after an audit
found host auth-log content in `stall-monitor/`: the `journal tail` section
of every heartbeat (5,292 files) and the auth units (sshd, CRON, PAM,
systemd-logind) of every `stall-dump-*/journal.txt` (262 files, 1,454
lines) exposed login source IPs and an SSH key fingerprint. Kernel,
SystemTap and stress-ng journal lines — the stall evidence — are untouched;
each touched file carries a marker. A full-tree scan for auth patterns,
key material and platform tokens is clean. The published fragility tables
remain the canonical v0.2 stall counts; `ANONYMIZATION.md` in the payload
was rewritten to record both assets' policies.

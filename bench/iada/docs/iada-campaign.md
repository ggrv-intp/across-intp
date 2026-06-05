# IADA campaign — second-phase scheduling experiment

**Status:** scaffold ready, smoke test validated 2026-05-05; closed-loop
wrapper (Section V) added in `iada-closed-loop` branch.
**Host:** local (laptop) — CloudSim is a deterministic simulation
**Reference dataset validated:** 192 apps on 48 PMs, 24 intervals,
mean IDI 3476.2

---

## Methodological framing

The shipped IADA classifier (SVM + per-class K-Means) was trained by
Meyer (2021) on profiles collected in **LXC containers** under
**Node-Tiers** synthetic stressors. Our IntP campaign collects with
**`stress-ng`** workloads in **Docker** containers on Sapphire Rapids
hardware. That difference is a documented **distribution shift**, and
how big it is depends on which target environment a campaign claims
to compare against.

We split the IADA campaign into two named modalities so that the
methodologically tight question (M1) is not entangled with the
methodologically open one (M2):

### M1 — IADA-aligned (default, primary)

**Scope:** `ENVS=container` only. The IntP variant is the independent
variable; the deployment environment is held at the closest match to
the classifier's training domain.

**Shift relative to training data:** small-to-moderate. LXC → Docker
differs primarily in `netp`/`nets` (NAT bridge vs L2) and in
`cpu`/`mbw` (cgroup-v2 vs v1, plus the bench daemon overhead). The
paper itself acknowledges this kind of shift ("if we change the
training set, the correlation between resources probably will have
different behavior" — Meyer 2021 §5.2.1).

**What is interpretable from M1:** instrumentation-fidelity comparisons
between stap-2022…bpftrace with the scheduler held fixed. This is the contribution
that anchors Section V of the dissertation. Retraining is optional and
planned with Meyer's assistance.

### M2 — cross-domain transfer (opt-in, gated)

**Scope:** `ENVS=bare,container,vm-guest`. Adds bare-metal and VM-guest
profiles to the same scheduler-fixed comparison.

**Shift relative to training data:**

- *Container vs bare metal:* moderate. No cgroup floor → wider
  dynamic range on every metric, so the K-Means thresholds shipped
  with the classifier shift; samples the model would tag as `low`
  may straddle the next centroid.
- *Container vs VM-guest:* severe. The PMU and RDT counters are
  typically inaccessible to a guest, so `mbw` / `llcocc` / `llcmr`
  arrive as zero. The K-Means classifier reads "zero" as `low` /
  `absent`, but the truthful label is `unavailable`. The SVM
  collapses cases into CPU / disk / network categories that exist
  in its training labels.

**Hard-block.** `run-iada-from-bench.sh` refuses to run M2 unless
`IADA_M2_ACK_DOMAIN_TRANSFER=1` is exported, with a message that cites
Meyer 2021 §5.2.1 and Meyer 2022 §3.1.3 on classifier-data coupling
and points at the retrain pipeline.

**What is interpretable from M2 *without* retraining:** a
*domain-transfer ablation* — i.e. how much the numbers move when the
classifier sees out-of-domain features. This is **not** a scheduling-
quality comparison: degradation could be the variant's profile
quality or could be the classifier failing to generalise, and the
manifest alone cannot tell those apart.

**What is interpretable from M2 *after* domain-specific retraining:**
the scheduling-quality comparison. The fork
[ggrv-intp/CloudSimInterference](https://github.com/ggrv-intp/CloudSimInterference)
branch `retrain-pipeline` ships `R/retrain.R` for exactly this. See
[retraining](#retraining) below.

### Sanity check

`run-iada-from-bench.sh` step 3 invokes
`bench/iada/scripts/sanity-check-classifier.sh` for each
`(variant, env)` present in the IADA tree before running CloudSim.
For up to `SANITY_SAMPLES` randomly-drawn profiles per cell
(default 10, balanced across workloads), the script:

1. Reads the profile CSV and reorders columns to the at-inference
   layout MLClassifier.java uses (`nets, netp, blk, mbw, llcmr,
   llcocc, cpu`).
2. Runs SVM `predict()` and the per-class K-Means level mapping
   against the six shipped `.rda` artifacts.
3. Infers an *expected class* from the workload's directory name
   (`cpu_*` → `cpu`, `mem_*`/`stress_vm` → `mem`, etc.). Workloads
   that don't match any class are scored `plausibility=unknown` and
   are not counted toward mismatch.
4. Writes one row per sample to
   `<campaign-dir>/sanity/<variant>__<env>.tsv`:
   `workload  expected_class  predicted_class  predicted_level  plausibility`.

If the mismatch rate exceeds `SANITY_FAIL_THRESHOLD_PCT` (default 30%)
in any `(variant, env)`, the wrapper aborts with a pointer to the
offending TSV and a suggestion. Two failure modes are distinguishable:

- *Mismatch concentrated in `env=container`*: the variant likely
  produces low-quality profiles — an instrumentation-fidelity
  issue, fixable variant-side.
- *Mismatch only in `env=bare` or `env=vm-guest`*: the classifier
  is operating out of its training domain — fixable by retraining.

### Retraining

The fork ships `R/retrain.R` and `R/RETRAIN.md` on branch
`retrain-pipeline`. Drop-in: the six regenerated `.rda` files keep
the variable names (`modelo_svm`, `cl_cpu`, …), feature ordering, and
hyperparameters that `MLClassifier.java` expects, so no Java rebuild
is required.

```bash
cd "$CLOUDSIM_REPO"
Rscript R/retrain.R \
    --dataset-root <path-to-domain-dataset> \
    --output-dir   R/
# then re-run bench/iada/scripts/run-iada-from-bench.sh
```

The dataset root accepts either per-class subdirs (`cpu/`, `memory/`,
`disk/`, `network/`, `cache/`) or the legacy `forced/` flat layout.
Existing `.rda` files are backed up with a timestamp suffix before
being overwritten. See `R/RETRAIN.md` in the fork for the full
operating manual and metric reference (paper Meyer 2021 Table 3).

### Auxiliary repos

Single auxiliary repo:
[ggrv-intp/CloudSimInterference](https://github.com/ggrv-intp/CloudSimInterference)
— the CloudSim/IADA Java simulator with the IADA classifier embedded
in `R/`. `setup-iada.sh --auto-clone` clones it next to this repo by
default. There is **no** separate `interference-classifier` repo;
the classifier lives inside `CloudSimInterference/R/`.

---

## Background

The IntP dissertation is structured in two phases:

1. **Phase 1 (IntP):** seven instrumentation variants (v0 (stap-2022),
   v0.1 (stap-nollc), v1 (stap-nohelper), v1.1 (stap-modern),
   v2 (hybrid-c), v3 (ebpf-ring), v3.1 (bpftrace)) collect the same
   seven interference metrics
   under controlled workloads. Phase 1 quantifies how the
   *instrumentation choice* affects measurement fidelity, deployment
   complexity, and runtime overhead. Outputs land in
   `results/<campaign>/bench-full/`.

2. **Phase 2 (this directory):** feed the resulting interference
   profiles into IADA, the interference-aware cloud scheduler proposed
   by Meyer et al. (JSS 2022), and observe how scheduling-quality
   metrics change when the *only* thing that varies is which IntP
   variant produced the profiles. This isolates instrumentation
   fidelity as the independent variable while the scheduler logic
   stays fixed.

IADA combines an SAO scheduler, an SVM classifier, K-means clustering,
and Change-Point Detection (CPD), all implemented in R and embedded
into a Java CloudSim simulation through JRI. The classifier is
pre-trained on synthetic stressors (`forced/`) shipped with the
original IADA repo. The dissertation's primary contribution (M1) uses
the shipped classifier as-is, with the sanity check (above) guarding
against out-of-domain interpretation. The retrain path (M2) is wired
up and tested end-to-end but kept opt-in, gated by
`IADA_M2_ACK_DOMAIN_TRANSFER=1`.

---

## Scientific objective

Test the central hypothesis:

> **Do interference profiles collected with higher-fidelity
> instrumentation produce better scheduling decisions?**

The IntP campaign varies the *source* of the profiles (stap-2022–bpftrace ×
bare/container/vm). This campaign feeds each profile set into the
**same** scheduler (IADA SAO + SVM classifier trained on synthetic
stressors), isolating instrumentation fidelity as the independent
variable.

---

## Validated architecture

```
intp/results/big-batch-*/bench-full/<workload>/<env>/<variant>/solo/repN/profiler.tsv
                                              │
                                              ▼ convert-profiler-to-meyer.py
                                     <repN>.meyer.csv  (7-col integer, ;-sep)
                                              │
                                              ▼ generate-iada-tree.py
                          iada-tree/<variant>/<env>/source/<workload>/{inc,dec,osc,con}.csv
                                              │
                                              ▼ generate-iada-input.py
                                      input.txt (app + pm declarations)
                                              │
                                              ▼ symlink resources/workload/interference
                                              ▼ run-iada-experiment.sh
                              CloudSim (Java) ↔ JRI ↔ R (SVM + K-means + CPD)
                                              │
                                              ▼ parse-cloudsim-output.py
                                  metrics.tsv (idi, migrations, etc.)
```

See `bench/iada/scripts/` for every component. The two Python
helpers that bridge IntP output and IADA input
(`convert-profiler-to-meyer.py`, `generate-iada-tree.py`) live one
level up at `bench/`.

### Meyer profile format

`convert-profiler-to-meyer.py` converts the seven-column integer TSV
emitted by every IntP variant (`profiler.tsv`) into the
`;`-separated 7-column Meyer CSV expected by IADA, preserving the
metric order (`netp; nets; blk; mbw; llcmr; llcocc; cpu`). Each row
is one sampling interval; rows are integers in the [0, 100] range.

### IADA tree layout

`generate-iada-tree.py` then sorts those Meyer files into the four
behavioural classes IADA expects (`inc`, `dec`, `osc`, `con` —
increasing, decreasing, oscillating, constant) using the same
classifier rules from the IADA paper. The result is a directory tree
that CloudSim's `MLClassifier` can consume as an interference source:

```
iada-tree/<variant>/<env>/source/<workload>/{inc,dec,osc,con}.csv
```

The four files (one per class) are concatenated samples, used by
CloudSim to simulate cloudlets whose interference profile matches the
empirical IntP measurements.

---

## Environment configuration that matters

Validated in the smoke test, **mandatory** to avoid JRI segfaults:

| Var/Flag | Value | Why |
|---|---|---|
| `JAVA_HOME` | `/usr/lib/jvm/java-17-openjdk-amd64` | Java 25 works, but LTS 17 is the reference |
| `-DR_SignalHandlers=0` | mandatory | R 4.3 installs signal handlers that conflict with the JVM → segfault inside `library(caret)` |
| `LD_LIBRARY_PATH` | `<rJava/jri>:<R/lib>` | libjri.so + libR.so |
| `R_LIBS_USER` | `~/R/library` | Packages in user lib (not system) |
| `INTP_R_FOLDER` | path of `R/` in this checkout | replaces hostname-hardcoded paths in `MLClassifier.java` |
| `-XX:+UseSerialGC -Xss8m` | recommended | reduces threading interaction with native R |

`bench/iada/scripts/setup-iada.sh` installs the system dependencies
(R, rJava, libtirpc-dev, OpenJDK 17), provisions the user R library,
and writes a sourceable env file at `~/.iada-env`. After running it,
`source ~/.iada-env` before any campaign invocation.

---

## Extracted metrics (aligned with IADA paper Sec. V)

| Metric | Cardinality | Origin |
|---|---|---|
| `cloudletcost_avg/sum` | scalar / 192 | final placement table |
| `interference_avg/sum/max` | scalar / N intervals | `Algorithm: SAO` block |
| `migrations_total/avg` | scalar / N-1 | `Migrations:` block |
| **`idi_avg/sum/max`** | **scalar / N** | **`interf with mig:` block — the paper's primary metric** |
| `sim_wallclock_min` | scalar | wall-clock execution time |
| `classifier_calls` | scalar | classification overhead |

**`idi`** = TotalInterferenceCost + (migrations × migvalue). It is
the per-interval interference-degradation index *with* the migration
cost rolled in. Lower is better scheduling.

`parse-cloudsim-output.py` walks `cloudsim.log`, extracts these
fields, and writes one row per simulation into `metrics.tsv`. The
top-level `manifest.tsv` produced by `run-iada-campaign.sh`
concatenates every `metrics.tsv` across the (variant × env ×
workload_mix) sweep.

---

## Confirmed smoke test (original IADA paper dataset)

Using the dataset under
`src/resources/workload/interference/192_48/`
(192 synthetic cloudlets: cpu, memory, disk, network × stressors):

```
variant=ORIG env=paper workload_mix=192_48
  cloudlets=192  intervals=24  idi_avg=3476.2  migrations=84  wallclock=26min
```

Pipeline validated end-to-end. 26 minutes for 192 apps — a useful
yardstick for budgeting the full campaign. The raw smoke output
lives in `bench/iada/results/smoke-paper-original/metrics.tsv`.

### Reproducing the smoke

```bash
# 1) provision once
sudo bash bench/iada/scripts/setup-iada.sh \
    --cloudsim /opt/CloudSimInterference \
    --intp-r-folder "$PWD/R"
source ~/.iada-env

# 2) drive a single experiment against the paper-original tree
VARIANT=ORIG ENV=paper WORKLOAD_MIX=192_48 \
IADA_TREE_ROOT=/opt/CloudSimInterference/src/resources \
CLOUDSIM_REPO=/opt/CloudSimInterference \
OUT_DIR=$PWD/bench/iada/results/smoke-paper-original \
    bash bench/iada/scripts/run-iada-experiment.sh
```

---

## End-to-end (single command)

The wrapper `bench/iada/scripts/run-iada-from-bench.sh` chains
`convert-profiler-to-meyer.py` → `generate-iada-tree.py` →
`sanity-check-classifier.sh` → `run-iada-campaign.sh` → `plot-iada.py`
into one entry point that consumes a finished
`bench/cross-env-campaign` output directory and emits an IADA
campaign manifest plus figures. Modality is the primary switch:

```bash
sudo bash bench/iada/scripts/setup-iada.sh --auto-clone
source ~/.iada-env

# M1 (primary, default): IADA-aligned. ENVS=container, sanity-checked.
bash bench/iada/scripts/run-iada-from-bench.sh \
    results/cross-env-2026-05-XX

# M2 (cross-domain transfer): hard-blocked unless explicitly acknowledged.
IADA_M2_ACK_DOMAIN_TRANSFER=1 MODALITY=M2 \
    bash bench/iada/scripts/run-iada-from-bench.sh \
        results/cross-env-2026-05-XX
```

The wrapper's full env-var surface is documented inline (run with
no arguments to print usage). Notable defaults:

| Var                           | Default                          | Notes                                   |
| ----------------------------- | -------------------------------- | --------------------------------------- |
| `MODALITY`                    | `M1`                             | `M1` (aligned) or `M2` (transfer).      |
| `VARIANTS`                    | `v0,v0.1,v1,v1.1,v2,v3,v3.1`     | Comma-list filtered against the tree.   |
| `ENVS`                        | derived from `MODALITY`          | Override at your own risk (logged).     |
| `WORKLOAD_MIXES`              | `all`                            | Passed to `run-iada-campaign.sh`.       |
| `SANITY_SAMPLES`              | `10`                             | Profiles drawn per `(variant, env)`.    |
| `SANITY_FAIL_THRESHOLD_PCT`   | `30`                             | Hard-fail above this mismatch rate.     |
| `IADA_M2_ACK_DOMAIN_TRANSFER` | `0`                              | Must be `1` to bypass the M2 hard-block. |
| `RUN_PLOT`                    | `1`                              | `0` to skip `plot-iada.py`.             |
| `OUT_ROOT`                    | `<bench-campaign-dir>/iada`      | Tree + campaign manifests + figures.    |

`--dry-run` is honoured: every step is echoed but nothing runs.

---

## Campaign plan

### Phase 0 — Scaffold + smoke (completed 2026-05-05)
- [x] R + rJava + libtirpc-dev installed
- [x] CloudSim built with Java 17, existing classes work
- [x] `MLClassifier.java` patch — env vars
      `INTP_R_FOLDER` / `INTP_R_LIBPATHS`
- [x] Smoke test: 192 paper-original cloudlets
- [x] Scripts: `run-iada-experiment.sh`, `generate-iada-input.py`,
      `parse-cloudsim-output.py`, `run-iada-campaign.sh`

### Phase 1 — Cross-validation (next)
Once IntP Phase 2 has run HiBench on bpftrace / ebpf-ring and produced the first
real Meyer set:
- [ ] Run `generate-iada-tree.py` against `bench-full/`
- [ ] Run one smoke simulation:
      `run-iada-experiment.sh` with bpftrace / bare
- [ ] Confirm IDI and migrations are plausible vs. the paper baseline

### Phase 2 — Full campaign
After IntP plan Phases 3–5 finish:
- [ ] Run `run-iada-campaign.sh` for every available
      (variant × env) combination
- [ ] Generate consolidated `manifest.tsv`
- [ ] Per-variant IDI comparison plot (script TBD —
      `bench/iada/scripts/plot-iada.py` is the placeholder)

### Phase 3 — Analysis
- [ ] Rank variants by `idi_avg`
- [ ] Correlate IntP fragility (from `extract-fragility.py`) ↔ IDI
      degradation
- [ ] env-impact plot: bare vs container vs vm for the same variant

---

## Cost estimate

| Item | ETA |
|---|---|
| 1 simulation (192 apps, 48 PMs, 24 intervals) | ~26 min |
| **M1**: 7 variants × 1 env × 1 mix | 7 simulations ≈ 3 h |
| **M2** (post-retrain): 7 variants × 3 envs × 1 mix | 21 simulations ≈ 9 h |
| 7 variants × 3 envs × 5 mixes (future) | ~45 h |

All local. Does not contend with the Hetzner host. The M2 budget
listed above does **not** include the wallclock spent collecting a
domain-matched dataset and running `R/retrain.R` — neither of which
runs through this wrapper.

---

## Methodological decisions (recorded)

1. **M1 uses the shipped classifier; M2 needs retraining.** The
   default modality (M1, env=container) intentionally varies only
   the IntP variant, keeping the scheduler and classifier fixed so
   instrumentation fidelity is the lone independent variable. M2
   adds bare/vm-guest, which is a domain shift relative to the
   classifier's training data; the wrapper hard-blocks it unless
   the operator acknowledges that the numbers either need
   retraining-first or have to be reframed as a transfer ablation.
   See [Methodological framing](#methodological-framing).

2. **CloudSim runs locally.** The simulator is deterministic; there
   is no value in running it on different hardware. The Hetzner
   server stays dedicated to IntP instrumentation runs.

3. **The env varies in the *profiles*, not in the simulator.** When
   we say "run in different envs" we mean profiles collected under
   bare/container/vm (where instrumentation is genuinely affected by
   the env), not CloudSim itself.

4. **24 intervals is a CPD outcome, not a parameter.** Change-Point
   Detection in R determines how many intervals each simulation
   has. Different IntP variants may yield a different N.

---

## See also

- IADA paper: Meyer et al., *IADA: A dynamic interference-aware cloud
  scheduling architecture for latency-sensitive workloads*, JSS 194
  (2022) 111491. PUCRS.
- Top-level [README.md](../../../README.md) — dissertation overview
  and IntP variant matrix.
- [bench/OVERVIEW.md](../../OVERVIEW.md) — IntP campaign methodology.
- [bench/findings/](../../findings/) — reliability, portability, and
  hardware-limitation notes that constrain Phase 2 inputs.

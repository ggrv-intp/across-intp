# IntP Experimentation Overview

A self-contained explanation of the testbed, workloads, tools, and
integration between the IntP variants (V0-V3) and the benchmark suite.
Designed to be read top-down by the research team and later restructured into slides without losing the chain of evidence.

---

## 1. Goal of the experimentation phase

Validate, on the same modern host, that:

1. The 7 IntP interference metrics (`netp`, `nets`, `blk`, `mbw`, `llcmr`,
   `llcocc`, `cpu`) can be collected by every variant that is
   methodologically applicable on kernel 6.8.
2. Each metric is excited by at least two distinct workloads, and no
   single workload dominates all metrics (representativeness criterion).
3. The four modern variants (V1-V3) produce numerically comparable
   measurements under identical workload pressure.
4. Trade-offs between historical fidelity (stap-2022/stap-nohelper lineage) and operational
   reliability (hybrid-c/bpftrace/ebpf-ring) are made explicit with reproducible evidence.

Two categories of workload are used in combination:

- **Synthetic** via `stress-ng` (deterministic, surgical resource
  pressure, fast execution).
- **Application-realistic** via Spark/HiBench (representativeness on
  data-intensive workloads with shuffle, ML, graph, and SQL phases).

---

## 2. Testbed

| Component | Value |
| --- |---|
| Provider | Hetzner Server Auction (dedicated bare-metal) |
| Hostname | `intp-master` |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | 6.8.0-111-generic |
| CPU | Intel Xeon Gold 5412U (Sapphire Rapids), 1 socket, 24C/48T |
| LLC | 45 MiB (host-calibrated: `LLC_SIZE_KB=46080`) |
| Memory | 256 GB ECC |
| Memory bandwidth (theoretical) | 281,600 MB/s (host-calibrated) |
| Storage | 2 × 1.92 TB NVMe (system on `nvme1n1p4`) |
| RDT | CMT, MBM, CAT-L3, MBA available, `resctrl` mounted |
| BTF | Available (`/sys/kernel/btf/vmlinux`) |
| SystemTap | 5.2 (built from source, `/usr/local/bin/stap`) |
| bpftrace | system package |
| HiBench | `/opt/HiBench` + Spark 3.5.1 + Hadoop 3 |

The legacy stap-2022 baseline campaign was archived from a previous host
(`intp-v1-baseline`, kernel 6.5 HWE on Ubuntu 22.04) for documenting
**portability failure**, not performance. See
`bench/findings/v0-baseline-failure-diagnosis.md`.

---

## 3. Variants under comparison

Each variant collects the same 7-column TSV
(`netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu`) so cross-variant analysis is
direct.

| Var | Stack | Status on this host | Use in the comparison |
|---|---|---|---|
| V0 (stap-2022) | SystemTap, kernel <= 6.6 | Does not compile on kernel 6.8 (cqm_rmid removed) | Historical reference, archived evidence of ABI breakage |
| V0.1 (stap-nollc) | SystemTap, kernel 6.8 minimal patch | Compiles, `llcocc=0` | Bridge step in the historical narrative |
| V1 (stap-nohelper) | SystemTap, stap-native probes only | Works on 6.8; `mbw=0`, `llcocc=0` (no embedded I/O) | Reliability baseline for stap probes alone |
| V1.1 (stap-modern) | SystemTap + userspace helper | Works on 6.8 with full 7 metrics; helper owns RCU-unsafe ops | RCU-safe stap path with hardware metrics restored |
| V2 (hybrid-c) | Pure C: procfs / `perf_event_open` / resctrl | Stable, no kernel modules | Modern reliability baseline |
| V3.1 (bpftrace) | bpftrace + Python orchestrator + resctrl | Stable, BTF-driven | DSL-level eBPF baseline |
| V3 (ebpf-ring) | C/libbpf + CO-RE eBPF | Stable, single binary | Canonical eBPF endpoint |

Detailed rationale per variant: `docs/VARIANT-COMPARISON.md`. Findings
that ground the narrative: `bench/findings/`.

---

## 4. Workload catalog

### 4.1 Synthetic workloads (stress-ng) — main bench

Used by `bench/run-intp-bench.sh`. Targets follow IntP's nine application
profiles plus extras for network, search and disk to stress all 7
metrics.

| ID | Profile | stress-ng arguments |
|---|---|---|
| `app01_ml_llc` | LLC | `--cache 24 --cache-level 3` |
| `app02_ml_llc` | LLC | `--l1cache 24 --cache 12` |
| `app03_ml_llc` | LLC | `--matrix 12 --matrix-size 1024` |
| `app04_streaming` | LLC + memory | `--stream 12 --stream-madvise hugepage` |
| `app05_streaming` | LLC + memory | `--stream 8 --vm 4 --vm-bytes 16G` |
| `app06_ordering` | memory | `--qsort 16 --qsort-size 1048576` |
| `app07_ordering` | memory | `--malloc 8 --malloc-bytes 16G` |
| `app08_classification` | CPU + memory | `--vecmath 12 --vm 4 --vm-bytes 8G` |
| `app09_classification` | CPU + memory | `--cpu 12 --cpu-method fft --vm 4 --vm-bytes 16G` |
| `app10_search` | CPU | `--cpu 24 --cpu-method matrixprod` |
| `app11_sort_net` | network | `--sock 16 --sock-port 23420` |
| `app12_sort_net` | network | `--udp 16 --udp-port 23430` |
| `app13_query_scan` | disk | `--hdd 8 --hdd-bytes 4G --hdd-write-size 1M` |
| `app14_query_join` | disk | `--hdd 8 --hdd-bytes 2G --hdd-write-size 4K` |
| `app15_query_merge` | disk | `--iomix 8 --iomix-bytes 2G` |

Worker counts assume 24 physical cores; stream/matrix workers cap at 12
because each saturates a memory channel.

### 4.2 Pairwise interference matrix

Used to measure **interference**, not raw throughput, by running a
victim workload against an antagonist that saturates a known resource.

| Pair | Victim | Antagonist | Expected pressure |
|---|---|---|---|
| `cpu_v_cache` | `--cpu 8 --cpu-method matrixprod` | `--cache 16 --cache-level 3` | LLC |
| `stream_v_stream` | `--stream 6` | `--stream 12` | mbw |
| `disk_v_disk` | `--hdd 4 --hdd-bytes 2G --hdd-write-size 4K` | `--hdd 12 --hdd-bytes 4G --hdd-write-size 1M` | blk |
| `net_v_net` | `--sock 8 --sock-port 23440` | `--sock 16 --sock-port 23450` | netp |

### 4.4 Application-realistic workloads (HiBench Spark)

Used by `bench/hibench/run-hibench-subset.sh`. Single-node Spark on
Hadoop with HDFS, focused on representativeness of the 7 metrics.

| Workload | What it stresses |
|---|---|
| `terasort` | shuffle, mbw, blk |
| `wordcount` | scan + reduce, mbw, llcocc |
| `pagerank` | iterative graph, llcocc, mbw |
| `kmeans` | ML floating-point + cache, llcmr, llcocc |
| `bayes` | classification + I/O, blk, cpu |
| `sql_nweight` | SQL join/aggregation proxy, mbw, netp |

Two execution profiles are run:

- **standard**: 400 shuffle partitions, balanced executor sizing.
- **netp-extreme**: 1200 shuffle partitions and increased parallelism
  to raise local network/shuffle pressure (`netp`/`nets` signal).

Dataset size profile: `medium` maps to HiBench `small` scale (chosen
to fit single-node and complete within the campaign window).

Spark/HiBench pinning is done via `SPARK_LOCAL_DIRS` and
`SPARK_SUBMIT_OPTS`; HiBench `hibench.scale.profile` is rewritten by
the runner (`set_hibench_size`).

---

## 5. Experiment stages

`bench/run-intp-bench.sh` runs in stages. Each stage writes a
`profiler.tsv` and a `groundtruth.tsv` per (env, variant, workload, rep)
plus an `index.tsv` for indexing.

| Stage | What it does | Used for |
|---|---|---|
| `detect` | Probes RDT/CQM/BTF/resctrl/MSR/IMC and writes `capabilities.env` | Reproducibility envelope |
| `build` | Compiles hybrid-c/ebpf-ring if needed; checks stap-nohelper deps; checks bpftrace BTF | Pre-flight |
| `solo` | One workload at a time, N reps each (1-after-1 baseline) | Per-workload metric coverage |
| `pairwise` | Victim + antagonist concurrent, N reps each | Cross-application interference |
| `overhead` | Short bursts to estimate instrumentation overhead | Overhead bound per variant |
| `timeseries` | Long single trace per (variant, workload) | Stability and drift over time |
| `report` | Aggregates `index.tsv` and `aggregate-means.tsv` | Cross-variant comparison input |

For the campaign run on this host:
`DURATION=120s`, `REPS=5`, `INTERVAL=1s`, `WARMUP=15s`, `COOLDOWN=10s`,
`TIMESERIES_DURATION=600s`, `OVERHEAD_DURATION=60s`.

---

## 6. Tools and how they integrate with the variants

### 6.1 stress-ng

Selected because:

- Single binary, deterministic stressors per resource.
- Argument syntax stable across releases, so workload definitions are
  reusable.
- Metrics-brief output (`stress-ng --metrics-brief`) provides a
  workload-side signal to compare against IntP's metric output
  (groundtruth in the benchmark suite).

How variants observe stress-ng:

- **stap-2022/stap-nollc/stap-nohelper (SystemTap)** attach by command name (`stress-ng`). The
  bench launcher passes the comm of the spawned PID (resolved from
  `/proc/$pid/stat`) so the probe restricts collection to that
  process tree. stap-nohelper additionally activates `intp-resctrl-helper.sh`,
  which manages the `/sys/fs/resctrl/mon_groups/intp` lifecycle and
  exposes occupancy values to the SystemTap script via
  `/tmp/intp-resctrl-data` plus a PID enroll/unenroll channel
  (`/tmp/intp-resctrl-pids`).
- **hybrid-c (`intp-hybrid`)** is launched with either `--pids <PID>`,
  `--cgroup <path>`, or system-wide; backends are chosen by
  capabilities probing (procfs, `perf_event_open`, resctrl).
- **bpftrace** loads scripts that key on PID/comm; resctrl is
  mounted by the orchestrator; output is normalized to the 7-column
  TSV.
- **ebpf-ring (libbpf/CO-RE)** loads compiled eBPF objects, optionally
  filters by PID via map; ring buffer drains software metrics; LLC
  occupancy and bandwidth come from resctrl readers in user space.

The launcher snippet for stap-nohelper — kept consistent across `bench/` and
`shared/` after this campaign's iteration — passes the SystemTap
overload thresholds explicitly to avoid Pass 4 format errors and to
enable module-versioning compatibility:

```
stap --suppress-handler-errors -g \
     -B CONFIG_MODVERSIONS=y \
     -DMAXSKIPPED=1000000 \
     -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
     -DSTP_OVERLOAD_INTERVAL=1000000000LL \
     variants/v1-stap-nohelper/intp-resctrl.stp <comm>
```

### 6.2 HiBench (Spark)

Provisioning: `bench/hibench/setup-spark-hibench.sh`. Runner:
`bench/hibench/run-hibench-subset.sh`. Coverage validator:
`bench/hibench/validate-intp-coverage.py`.

Validation criterion (paper-level): every metric must vary by at least
20% between idle and at least one workload, no metric may saturate in
all workloads, ML/graph workloads must show consistent `llcocc`/`mbw`
response, and at least one shuffle-heavy workload must sustain the
`netp`/`nets` signal.

IntP capture during HiBench: the collector runs in parallel with Spark
on the same host; outputs are tagged with the same workload name as
HiBench (`terasort`, `wordcount`, `pagerank`, `kmeans`, `bayes`,
`sql_nweight`, `idle`) so the validator can map metric coverage by
workload.

### 6.3 Hardware-counter helpers per variant

Each variant that needs Intel RDT / resctrl carries its own integration
rather than sharing one. Quick map:

| Variant | Resctrl integration                                                                                                                |
|---------|------------------------------------------------------------------------------------------------------------------------------------|
| V1 (stap-nohelper)   | None (mbw and llcocc reported as 0)                                                                                                |
| V1.1 (stap-modern)   | `variants/v1.1-stap-modern/intp-helper` -- C daemon, opens uncore IMC events + creates `mon_groups/intp-<pid>/`, polls 1 s, writes `/tmp/intp-hw-data` |
| V2 (hybrid-c)        | In-process: C reader inside `intp-hybrid`                                                                                          |
| V3.1 (bpftrace)      | In-process: Python `resctrl_reader.py` orchestrated by the bpftrace runner                                                         |
| V3 (ebpf-ring)       | In-process: C code in `variants/v3-ebpf-ring/resctrl/`                                                                                    |

`shared/intp-resctrl-helper.sh` is preserved as a legacy artifact from
the pre-rename `v3-updated-resctrl` design. No current variant uses it
directly; it is kept for reproducing experiments against the
`pre-rename-2026-05-05` git tag.

### 6.4 Driver scripts

| Script | Purpose |
|---|---|
| `run-big-batch.sh` | One-shot driver: bench-full + HiBench + plots |
| `bench/run-intp-bench.sh` | Per-stage cross-variant runner |
| `bench/hibench/run-hibench-subset.sh` | Spark/HiBench runner |
| `shared/intp-detect.sh` | Capability probing (RDT, BTF, resctrl, IMC) |
| `bench/plot/plot-intp-bench.py` | Final figure generation |
| `cleanup-after-tests.sh` | Reset stress-ng/stap/cgroup/resctrl residue |

The campaign runs all of them inside `tmux` to survive SSH disconnects.

---

## 7. Output layout

```
results/<campaign>/
    bench-full/
        capabilities.env
        index.tsv                # one row per (env,variant,stage,workload,rep)
        bare/<variant>/<stage>/<workload>/rep<N>/
            profiler.tsv         # IntP samples
            profiler.tsv.samples # numeric sample count
            groundtruth.tsv      # stress-ng metrics-brief, mapped
            *.stap.log           # SystemTap log when applicable
        ...
    hibench/<profile>-<ts>/<workload>.log
    big-batch.log
```

Aggregation produces `aggregate-means.tsv` for cross-variant comparison
and feeds `validate-intp-coverage.py`.

---

## 8. Known limitations and operational notes

### 8.1 V0 (stap-2022) portability failure (documented in findings)

stap-2022 cannot compile on kernel >= 6.8 (and on the HWE 6.5 used in the
baseline host, the field `cqm_rmid` of `struct hw_perf_event` was
already refactored out). The failure is deterministic and is treated as
**evidence of portability degradation**, not as missing data. See
`bench/findings/v0-baseline-failure-diagnosis.md`.

### 8.2 V1 (stap-nohelper) operational fragility (documented in findings)

stap-nohelper works on 6.8 with calibrated constants (LLC, MBW, IMC types) and the
launcher flags above, but two effects remain:

1. Probe skip pressure under load (`skipped probes` non-zero in
   realistic runs).
2. Long batches of stap-nohelper reps eventually leave kernel state that
   destabilizes `systemd-logind` via DBus, causing `pam_systemd:
   Failed to create session` on subsequent SSH logins.

Mitigations applied in the launcher:

- After every rep, `pkill -9 stapio/staprun` + `rmmod stap_*` to ensure
  no kernel module remains loaded.
- Helper-side cleanup of the resctrl `intp` monitoring group between
  runs.

Where the mitigation is insufficient (long stap-nohelper campaigns), the campaign
is split into:

- A **hybrid-c/bpftrace/ebpf-ring full bench** (does not perturb systemd at all).
- A **shorter stap-nohelper campaign** focused on the apps not yet covered, with
  reduced `DURATION` and `REPS` so it fits within the stap-nohelper stability
  window.

This split is the operational expression of the dissertation's main
narrative point: stap-nohelper preserves historical comparability; hybrid-c/ebpf-ring are the
production-grade reliability endpoints.

### 8.3 Historical comparability note

The campaign keeps methodology continuity with the original IntP study,
but the active execution path is `run-big-batch.sh` +
`bench/run-intp-bench.sh` + HiBench.

---

## 9. Faithfulness to the original 2022 IntP paper

Reference: Xavier, Cano, Meyer, De Rose. *IntP: Quantifying
cross-application interference via system-level instrumentation.*
SBAC-PAD 2022, DOI 10.1109/SBAC-PAD55451.2022.00034. PDF in repo
root: `2022 - IntP_ Quantifying cross-application interference via
system-level instrumentation.pdf`.

The campaign is designed to be **as close as possible** to the
methodology of the original paper, while being explicit about what
cannot be reproduced because of changes in hardware, kernel, and
distributed-cluster availability.

### 9.1 Original 2022 setup vs current campaign

| Aspect | 2022 paper | Current campaign |
| --- | --- | --- |
| Hardware | 16 × Dell PowerEdge R810, 2× Xeon X-class (32 vCPUs each), 64 GB, 4× GbE, GbE switch | 1 × Hetzner bare-metal, Xeon Gold 5412U (Sapphire Rapids), 24C/48T, 256 GB, 10 GbE |
| OS / kernel | Ubuntu 16.04 (kernel 4.x era) | Ubuntu 24.04, kernel 6.8.0-111 |
| IntP variant runnable | stap-2022 (single SystemTap, all modules in kernel mode) | stap-2022 fails to compile (`cqm_rmid` removed); stap-nollc partial; stap-nohelper modernized; hybrid-c/bpftrace/ebpf-ring added |
| Workload catalog | 15 apps from HiBench mapped to resource intensities (Table II) | Same 15-app schema reproduced as `stress-ng` workloads (`app01_ml_llc` … `app15_query_merge`) plus a 6-workload Spark/HiBench subset |
| Profiling pattern | 1-after-1 individual runs | 1-after-1 (`solo` stage), plus pairwise, overhead, and timeseries stages |
| Output schema | 6 metrics: `netp`, `nets`, `blk`, `mbw`, `llocc`, `cpu` | 7 columns: paper's 6 plus `llcmr` (LLC miss ratio) for diagnostic detail |
| Use of metrics | Per-app interference vector → PCA → K-means (K=4) → scheduler integration in YARN | Per-app interference vector + cross-variant comparison + interference matrix + overhead bound |
| Validation outcome | Up to 35% scheduling improvement vs YARN Fair (case study A); 18-25% latency wins in case studies B/C | Validation of cross-variant numerical comparability and metric coverage; not a scheduling experiment |
| Distributed orchestration | Hadoop YARN, Spark, Storm; 10-in-10 dispatcher every 5s | Single-node Spark on HiBench; no Hadoop YARN multi-tenant scheduling |

### 9.2 What is preserved (methodology fidelity)

- **Metric definitions.** The IntP definitions in Section IV of the
  paper (block service-time delta, network back-pressure, CSW
  waiting time, IMC-based memory bandwidth, RMID-based LLC
  occupancy) are the same definitions that stap-2022/stap-nollc/stap-nohelper still implement
  in SystemTap, and that hybrid-c/bpftrace/ebpf-ring reimplement on top of stable
  Linux interfaces (perf_event, resctrl, eBPF, procfs).
- **Workload taxonomy.** The 15-app catalog of paper Table II is
  reproduced 1:1 in `bench/run-intp-bench.sh` (`WORKLOADS=(...)`)
  with `stress-ng` flags chosen to hit the same resource targets:
  ML/LLC, streaming/memory, ordering/memory, classification, search,
  sort/network, query/disk, query/merge.
- **HiBench layer.** The application-realistic part is still HiBench
  on Spark (`terasort`, `wordcount`, `pagerank`, `kmeans`, `bayes`,
  SQL proxy `sql_nweight`), preserving the choice of "data analytics
  representative" workloads from the paper's case study A.
- **Solo profiling pattern.** "1-after-1" execution per application
  for individual interference fingerprinting (Section V.A) is the
  default `solo` stage in this repo.
- **PID/comm-scoped probing.** The IntP guarantee that probes attach
  per task (paper's "thread-scoped" model) is preserved across
  variants: SystemTap by `comm`, hybrid-c by `--pids/--cgroup`, bpftrace/ebpf-ring by
  PID filter map.

### 9.3 What had to change (forced by the 2026 stack)

- **Kernel ABI drift.** `struct hw_perf_event::cqm_rmid` (used by stap-2022
  paper Section IV.E for RMID-MSR mapping) was removed in the kernel
  series shipped with Ubuntu 22.04 HWE and 24.04. stap-2022 cannot compile
  on this host. Documented in
  `bench/findings/v0-baseline-failure-diagnosis.md`.
- **Hardware constants.** The paper's stap-2022 has hard-coded calibrations
  (1 GbE NIC, 34 GB/s memory bandwidth, 34 MB LLC, IMC PMU type 14,
  CMT scale factor 49152) tuned for the 2022 dev machine. stap-nohelper
  recalibrates: `LLC_SIZE_KB=46080` (45 MiB), MBW max 281,600 MB/s,
  IMC PMU types in 78–89 for Sapphire Rapids.
- **Distributed cluster.** The 16-node R810 cluster is not
  available, so the **scheduling-outcome experiments of paper
  sections V.A, V.B, V.C cannot be re-run as-is**. The campaign
  reproduces only the **per-host instrumentation** part of the
  methodology, which is what IntP itself measures.
- **Variant family.** Adding hybrid-c/bpftrace/ebpf-ring is required to make the
  comparison feasible at all (stap-2022 does not run on the host that the
  modern Spark/HiBench/CO-RE-eBPF stack runs on).

### 9.4 What is added beyond the paper

- **`llcmr` column.** Paper Section IV.D explicitly considers
  `LLC_MISS × 64B` as a memory metric and rejects it in favour of
  IMC counters (because of prefetch). We keep the paper's definition
  for `mbw` (IMC-based) and add `llcmr` as an extra diagnostic
  column to make over-fetching visible without changing `mbw`. This
  is a non-destructive extension.
- **Pairwise interference matrix.** Victim+antagonist concurrent
  runs (`cpu_v_cache`, `stream_v_stream`, `disk_v_disk`,
  `net_v_net`) provide a direct, paper-style interference signal
  that does not require a full datacenter scheduler to be evaluated.
- **Overhead microbench.** `overhead` stage produces an empirical
  upper bound for the "very low overhead" claim of the paper, per
  variant.
- **Long-trace timeseries.** 600s single trace per (variant,
  workload) to evaluate stability and drift, not present in the
  paper.

### 9.5 What cannot be reproduced

- **+35% YARN scheduling improvement** (paper Section V.A,
  Figure 6). Requires a 16-node cluster, Hadoop YARN, the
  custom 10-in-10 dispatcher, and Hadoop/Spark/Storm jobs in
  parallel. Not run.
- **CIAPA multi-tier placement gain** (paper Section V.B,
  Ludwig 2019). Requires the CIAPA simulator and a multi-tier
  application set. Out of scope.
- **IADA dynamic rescheduling 25% response-time win**
  (paper Section V.C, Meyer 2022). Requires the IADA architecture
  and a latency-sensitive workload. Out of scope.

These are scheduling/architecture results that **build on top** of
IntP. Reproducing the per-application interference vector that
IntP outputs is necessary but not sufficient for them.

### 9.6 What is reproducible from this campaign

- **Per-application interference fingerprint** (paper Figure 4):
  generated by the `solo` stage for the 15-app catalog. The visual
  format (per-app stacked or grouped bars across the 6 metrics) is
  produced by `bench/plot/plot-intp-bench.py` from the campaign's
  `aggregate-means.tsv`.
- **Application similarity clustering** (paper Figure 5): PCA on
  the per-app interference vectors followed by K-means (K=4 in the
  paper). The PCA/K-means script is **not yet** in the repo, but
  the input (`aggregate-means.tsv` per `env+variant`) is. Adding
  this analysis is a natural follow-up.
- **Cross-variant comparability of the IntP signal.** This is the
  campaign-specific question: *do stap-nohelper, hybrid-c, bpftrace, ebpf-ring measure the same
  per-application interference vector for the same workload?* The
  paper does not address it because in 2022 there was only stap-2022.
- **Empirical overhead claim** for IntP: the paper says "very low
  overhead even with hundreds of running applications"; our
  `overhead` stage gives a per-variant numeric bound on this on
  the new hardware.

### 9.7 Mapping table — paper section to campaign artefact

| Paper section | What it does | Campaign artefact |
| --- | --- | --- |
| Section II | Background on contention sources (CPU, mem, LLC, blk, net) | Documented in `docs/METRICS-DEEP-DIVE.md` and reflected in IntP's metric set |
| Section III, Fig. 2 | IntP module architecture | `variants/v0-stap-2022/intp.stp` is the canonical implementation; V1-V3 README files describe each module's modern equivalent |
| Section IV.A (block) | `block_rq_complete`/`block_rq_issue` delta | Same probe in stap-2022/stap-nohelper; tracepoint `block_rq_complete` in bpftrace/ebpf-ring |
| Section IV.B (network) | `napi_complete_done`/`napi_schedule_irqoff` and xmit deltas | Same probes in stap-2022/stap-nohelper; kprobes/tracepoints equivalent in bpftrace/ebpf-ring; `/proc/net/dev` in hybrid-c |
| Section IV.C (CPU/CSW) | scheduler dispatcher waiting time | `scheduler.ctxswitch` in stap-nohelper; `sched:sched_switch` tracepoint in bpftrace/ebpf-ring |
| Section IV.D (memory) | IMC-based memory bandwidth (rejecting `LLC_MISS×64B`) | IMC PMU types recalibrated in stap-nohelper (78–89); `perf_event_open` in hybrid-c; resctrl MBM as primary in bpftrace/ebpf-ring |
| Section IV.E (LLC) | RMID/MSR-based occupancy via Intel CMT | Replaced by `/sys/fs/resctrl` reads in stap-nohelper (helper) and directly in hybrid-c/bpftrace/ebpf-ring |
| Section IV final list | 6-metric output schema | 7-column TSV with `llcmr` added; paper's 6 are unchanged |
| Section V.A, Fig. 4 | Per-app interference bars across 15 apps | `solo` stage output + `aggregate-means.tsv` + plotting script |
| Section V.A, Fig. 5 | PCA + K-means on per-app vectors | Reproducible from `aggregate-means.tsv`; PCA/K-means script not yet in repo (planned follow-up) |
| Section V.A, Fig. 6 | YARN vs interference-aware scheduler | NOT reproducible (no cluster). Out of scope. |
| Section V.B (CIAPA) | Multi-tier placement simulation | Out of scope. |
| Section V.C (IADA) | Dynamic rescheduling for SLA workloads | Out of scope. |
| Table II (15-app catalog) | Workload schema | `WORKLOADS=(...)` in `bench/run-intp-bench.sh` (1:1) |

---

## 10. Scheduler integration path

We integrate the campaign output with the scheduling toolchain that the
2021 ML-driven paper and the 2022 IADA paper already published. We
**do not** rebuild a scheduler; we feed the existing R + Java tooling
with the metric vectors collected by V1-V3 on this host.

### 10.1 Forks available locally

| Repository | Origin | Local clone |
| --- | --- | --- |
| `interference-classifier` | github.com/ggrv-intp/interference-classifier (fork of github.com/ViniciusMeyer/interference-classifier) | `../interference-classifier` |
| `CloudSimInterference` | github.com/ggrv-intp/CloudSimInterference (fork of github.com/ViniciusMeyer/CloudSimInterference) | `../CloudSimInterference` |

Forks belong to `ggrv-intp` so we can patch and avoid loss of upstream.

### 10.2 Input format expected by both projects

Confirmed by reading `interference-classifier/Classifier.R` and
`CloudSimInterference/R/input.R`. Both repos expect **the exact same
schema** as our profiler TSV:

| Property | Required value |
| --- | --- |
| File extension | `.csv` |
| Field separator | `;` (semicolon — `read.csv2` default in R) |
| Header row | none |
| Number of columns | 7 |
| Column order | `netp;nets;blk;mbw;llcmr;llcocc;cpu` |
| Value type | integer percentages, 0..100 |
| Row cadence | one row per second (interval=1s) |
| Trailing newline | required |

This column order matches our TSV header
(`netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu`) byte-for-byte. The only
mechanical changes needed are:

1. Drop any leading timestamp columns (the bench launcher prefixes
   one or two timestamps before the 7 metrics depending on the
   variant).
2. Drop the header line.
3. Change the field separator from `\t` to `;`.
4. Round each metric to integer.

The repository now ships an automated converter for this step:

```bash
python3 bench/convert-profiler-to-meyer.py results/intp-bench-<ts> --stage solo
```

Default behavior:

- recursively finds every `profiler.tsv` under the given directory,
- filters stages with `--stage` when requested,
- writes `profiler.meyer.csv` alongside each source file,
- optionally emits a manifest with `--manifest`.

Examples:

```bash
# convert just one run
python3 bench/convert-profiler-to-meyer.py \
  results/intp-bench-<ts>/bare/v2/solo/app10_search/rep1/profiler.tsv

# convert all solo runs and write a manifest
python3 bench/convert-profiler-to-meyer.py \
  results/intp-bench-<ts> \
  --stage solo \
  --manifest results/intp-bench-<ts>/meyer-manifest.tsv
```

A robust converter is one awk pass that keeps the **last 7 numeric
fields** of each data row:

```bash
awk -F'\t' '
    /^[0-9]/ {
        OFS=";"
        n = NF
        printf "%d;%d;%d;%d;%d;%d;%d\n", \
            $(n-6), $(n-5), $(n-4), $(n-3), $(n-2), $(n-1), $n
    }
' rep1/profiler.tsv > rep1/profiler.meyer.csv
```

This converts a per-rep TSV into a Meyer-format CSV in place, agnostic
to whether the launcher prepended one or two timestamp columns.

### 10.3 Path A: `interference-classifier` (fast, R-only)

Reproduces paper Meyer 2021 (JSA), Figures 4 and 7. Useful as the
"per-app dynamic interference classification" visualization the
research team expects to see first.

Workflow:

1. Convert one rep TSV per IntP variant to `.csv` (Section 10.2).
2. Place it under `interference-classifier/source/<app>/<pattern>.csv`
   following the project convention
   (`pattern in {inc, dec, osc, con}`).
3. In `Classifier.R`, set `app_tittle`, `period` (segmentation %),
   and `method = "L"` (level: absent/low/moderate/high).
4. Run R from the project root:

   ```bash
   cd ../interference-classifier
   Rscript Classifier.R
   ```

5. Output: `result.pdf` with the per-resource interference time-series
   and the segmented level labels per period.

Pre-trained models are not used here; the classifier retrains SVM and
K-Means from `training_dataset/` on every run. The training dataset
shipped with the repo is built from
`cache100.csv`, `cache_miss.csv`, `cpu100.csv`, `memory100.csv`,
`disk100.csv`, `net100.csv` — six canonical "stress at 100% on one
resource" traces. We can extend this dataset later with V1-V3
ground-truth runs if we want to retrain on Sapphire Rapids data.

### 10.4 Path B: `CloudSimInterference` (full IADA simulator)

Reproduces paper Meyer 2022 (JSS, IADA), Figures 9, 10, 12. Java +
R (via JRI/rJava). This is what the research team pointed to as the
target for IntP-driven scheduling claims.

Inputs:

- `R/input.txt` — datacenter description, one record per line:

  ```text
  Datacenter file configuration
  app 1 <absolute path to a 7-column ;-separated CSV>
  app 1 <absolute path to another CSV>
  ...
  pm <number_of_PMs> <PE_size>
  ```

  Example shipped with the repo:

  ```text
  app 1 ~/interference/r/linkbench/inc/source/inc.csv
  app 1 ~/interference/r/tpch/osc/source/mysql.csv
  app 1 ~/interference/r/bench4q/MYSQL/inc/source/inc_new.csv
  pm 12 100
  ```

- Each referenced CSV must follow the schema in Section 10.2.

Pre-existing trace assets shipped under
`src/resources/workload/interference/192_48/` (≈300 files):

- `cpu_<N>.csv`, `disk_<N>.csv`, `memory_<N>.csv` — synthetic
  variations of the four canonical workload patterns
  (`inc`/`dec`/`osc`/`con`).
- `cpu_wiki<N>.csv`, `disk_wiki<N>.csv`, `memory_wiki<N>.csv` —
  derived from the **Wikipedia** page-view trace (Jan 2021).
- `cpu_alibaba<N>.csv`, `disk_alibaba<N>.csv`,
  `memory_alibaba<N>.csv` — derived from the **Alibaba Open Cluster
  Trace v2018**.
- Older `nasa/` and `ab/` directories under `bin/resources/workload/`
  contain NASA 1998 World Cup and Apache Bench traces.

Pre-trained R model artefacts already present in `R/`:

- `svm_model.rda` — the multi-class SVM classifier.
- `cpuk.rda`, `memk.rda`, `diskk.rda`, `cachek.rda`, `netk.rda` —
  per-resource K-Means centroid models for the four levels (absent,
  low, moderate, high).

We can either reuse these models as-is to keep the comparison faithful
to the published IADA, **or** retrain them with a labelled dataset
collected from V1-V3 on Sapphire Rapids if we want to demonstrate
that the methodology adapts to the new hardware envelope.

Java entry point (informative): `src/cloudsim/interference/aaa/xxIntExample.java`.
The simulator emits per-run CSVs under `~/Results/`:

- `Results/NewlyCreatedVms/`
- `Results/ContainerMigration/`
- `Results/EnergyConsumption/`

Schedulers compared inside the simulator: **EVEN** (Apache Storm
round-robin baseline), **CIAPA** (Ludwig 2019, Simulated Annealing
with static thresholds), **Segmented** (Meyer 2021, four-segment
classification), **IADA** (Meyer 2022, OCPD + ML + modified SA).

Required R packages (per CloudSimInterference README):
`e1071`, `caret`, `stringr`, `dplyr`, `fossil`, `ipred`, `ocp`, `rJava`.

```R
install.packages(c("e1071","caret","stringr","dplyr","fossil","ipred","ocp","rJava"))
```

### 10.5 Concrete integration plan

| Step | Action | Output |
| --- | --- | --- |
| 1 | Finish current campaign (solo, pairwise, overhead, timeseries) for V1-V3 | `results/v456-big-<ts>/bench-full/` |
| 2 | Convert TSV→CSV with `bench/convert-profiler-to-meyer.py --manifest ...` | `*.meyer.csv` files + one conversion manifest TSV |
| 3 | Generate `source/<app>/<pattern>.csv` and `cloudsim-input.txt` with `bench/generate-iada-tree.py` from the manifest | IADA-ready tree per `(env,variant)` |
| 4 | Run `Classifier.R` per app; archive `result.pdf` | per-app classification figure (paper Meyer 2021 Fig. 4 / Fig. 7 reproduction) |
| 5 | Promote one generated `cloudsim-input.txt` to `../CloudSimInterference/R/input.txt` (or pass equivalent path in your launcher) | active simulator datacenter spec |
| 6 | Run `xxIntExample` (or its IADA-driven variant) to compare EVEN vs CIAPA vs Segmented vs IADA | scheduling outcome CSVs in `~/Results/` |
| 7 | Aggregate response-time and migration counts; compare against IADA paper Figs. 7, 9, 10, 12 | dissertation evidence |

Practical command chain:

```bash
python3 bench/convert-profiler-to-meyer.py \
  results/v456-big-<ts>/bench-full \
  --stage solo \
  --manifest results/v456-big-<ts>/bench-full/meyer-convert.tsv

python3 bench/generate-iada-tree.py \
  --manifest results/v456-big-<ts>/bench-full/meyer-convert.tsv \
  --out-root results/v456-big-<ts>/bench-full/iada-tree \
  --variant v2 --stage solo \
  --rep-pattern-map rep1=inc,rep2=dec,rep3=osc,rep4=con
```

What this gets us, in dissertation terms:

- The per-app interference fingerprint produced by **our** stap-nohelper, hybrid-c, bpftrace,
  ebpf-ring variants on Sapphire Rapids is fed into the **same** scheduling
  pipeline used by the original IADA paper. If the cross-variant
  signal is consistent, all four runs of the simulator will produce
  comparable scheduling decisions; if it diverges, the divergence
  itself is a finding.
- The simulator uses real-world traces (Wikipedia, Alibaba, NASA) that
  ship inside the repo, so we get application-realistic dynamic
  workloads without re-implementing trace replay.
- The result is "we reproduced IADA's scheduling evaluation with the
  IntP front-end re-implemented on a kernel where stap-2022 no longer runs"
  — exactly the line the research team pointed at.

What is **not** reproduced by this path:

- The real-cluster part of IADA paper Section 4.2 (Pantanal cluster,
  LXC/LXD live migration via CRIU, Artillery client-side load).
  That requires a multi-node testbed.
- Fine-grained scheduling decisions emitted in real time on a live
  Linux scheduler. The CloudSim path is **simulation**, consistent
  with §4.3 of the IADA paper.

---

### 10.6 What was and was not found in the public repositories

Repository inspection across the public repositories points to a clear split:

- `interference-classifier` and `pdp2020` are **offline R pipelines**
  for classifying an application's interference vector from CSV traces.
- `CloudSimInterference` is an **offline Java + R simulator** that
  consumes those traces through `R/input.txt` and evaluates EVEN,
  CIAPA, Segmented, and IADA inside CloudSim/ContainerCloudSim.
- `closer2019` is an elasticity artefact unrelated to IntP/IADA's
  interference loop.
- `wscad2018` is a simulator-comparison artefact unrelated to the
  IntP/IADA runtime path.

No published repository in that set exposes the **real-cluster runtime
coordinator** from IADA Section 4.2: no LXD/CRIU orchestration layer,
no Artillery-based live workload driver, no Kubernetes/YARN scheduler
plugin, and no always-on daemon that ingests IntP metrics and emits
placement decisions in real time.

The practical conclusion is important for scope control:

- The reproducible artefact that already exists and is available to us
  is the one described in this Section 10: **IntP traces -> classifier
  -> CloudSimInterference -> scheduler comparison**.
- Any live-cluster recreation beyond that must be treated as a **new
  engineering artefact**, not as hidden existing code we simply failed
  to wire up.

### 10.7 Minimal sketch for a future live coordinator

If the advisor later wants a real-time integration path, the cheapest
credible design is to keep the Section 10 offline path as the primary
evidence trail and build a thin online coordinator around the most
stable IntP front-end.

Recommended runtime stack:

| Layer | Minimal choice | Reason |
| --- | --- | --- |
| Node-side profiler | hybrid-c first, ebpf-ring second | hybrid-c is the most operationally stable on current host; ebpf-ring is the eBPF endpoint once the signal is validated |
| Scope key | cgroup/container ID | Matches scheduler objects better than raw PID |
| Export protocol | HTTP/JSON or line CSV at 1 Hz | Easy to debug and replay offline |
| Change-point detection | `ruptures` in Python or `ocp` via `rpy2` | Keeps parity with the IADA logic without forcing Java+R in the hot path |
| Classifier | reuse Meyer SVM/K-means logic | Preserves the same absent/low/moderate/high semantics |
| Placement policy | simplified IADA heuristic or port of simulated annealing | Enough to test whether IntP signals drive better co-location than FIFO/random |
| Actuation | advisory mode first; live migration only later | Lets us validate decisions before touching running jobs |

Minimal control loop:

1. Each node samples the current cgroups/containers every second with
   hybrid-c or ebpf-ring and emits the 7-value interference vector.
2. A central coordinator keeps a sliding window per workload and runs
   change-point detection when the vector shifts materially.
3. The current window is classified into interference levels using the
   same Meyer feature semantics used in the offline path.
4. A placement engine computes either:
   - an **advisory decision** (`keep`, `avoid host X`, `prefer host Y`), or
   - a **migration decision** once the advisory mode has been validated.
5. Decisions and input vectors are archived so every live action can be
   replayed later through the Section 10 offline simulator path.

Delivery order:

1. Keep the current Section 10 path as the dissertation baseline.
2. Add an **offline replay coordinator** that reads already collected
   TSVs and emits scheduling recommendations without moving anything.
3. Add an **online advisory mode** against containers/cgroups on a
   single host or small private cluster.
4. Only then consider real migrations through Incus/LXD or another
   orchestrator.

This keeps the research claim defensible:

- Section 10 provides a reproducible scheduler integration today.
- Section 10.7 defines the shortest path to a live coordinator if the
  project later gets access to Pantanal or another multi-node testbed.

### 10.8 Application strategy for the scheduling phase

Question: should scheduling use the exact same applications used during
profiling?

Short answer: **partly yes, partly no**.

- Use the same profiling workloads to build the interference fingerprints
  (the scheduler's feature vectors).
- Use a scheduling-phase workload set that is closer to real deployment
  behavior to test placement quality and latency impact.

Recommended split:

1. **Signal calibration set (same as profiling):**
   - `app01`..`app15` from `bench/run-intp-bench.sh`.
   - Purpose: preserve comparability across variants and verify that
     IntP still sees each resource dimension as expected.

2. **Scheduler evaluation set (application-like):**
   - HiBench subset (`terasort`, `wordcount`, `pagerank`, `kmeans`,
     `bayes`, `sql_nweight`) and/or Meyer-style traces.
   - Purpose: measure whether IADA/CIAPA/Segmented/EVEN decisions improve
     response-time/migration outcomes under realistic multi-phase load.

3. **Bridge policy:**
   - Start with a direct mapping from repeated solo reps to canonical
     patterns (`rep1->inc`, `rep2->dec`, `rep3->osc`, `rep4->con`) using
     `generate-iada-tree.py`.
   - If stronger methodological fidelity is needed, run dedicated
     envelope replays to produce explicit `inc/dec/osc/con` traces per app.

Why this split is technically cleaner:

- Reusing profiling workloads alone can overfit the scheduler to
  synthetic stressors.
- Reusing only application-like workloads can hide whether the IntP
  front-end itself is still calibrated per resource.
- The two-stage design keeps both claims auditable: instrumentation
  validity and scheduling utility.

---

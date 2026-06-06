# Host Reproduction — `intp-master`

End-to-end recipe to reproduce the IntP campaign host. Everything in
**Sections 1-7** is whole-machine setup that applies to **stress-ng,
profilers (stap-modern/C-ABI/ebpf-ring/bpftrace), CloudSim/IADA, and any other workload**.
Section 8 is HiBench/Hadoop-specific and is the only piece that doesn't
apply if you only need stress-ng + profilers.

> **Authoritative state, May 2026.** Documents what is currently
> deployed on `intp-master` (Hetzner SB Xeon Gold 5412U) for the IADA/IntP
> SBAC-PAD campaign. Cross-references real configuration captured from
> the running host and chat-history decisions, so any drift between
> repo scripts and reality is called out explicitly.

---

## 1. Hardware target

| Item | Value | Source / verification |
|---|---|---|
| Server | Hetzner Server Auction (SB) | rented by user |
| CPU | Intel Xeon Gold 5412U, Sapphire Rapids, 24C/48T | `metadata.txt` from any campaign |
| Memory | 8 × 32 GiB DDR5-4800 ECC = 256 GiB nominal | dmidecode |
| Storage | 2 × 1.92 TB NVMe (datacenter) | Hetzner spec |
| Network | 2 × 1 GbE Intel X550-AT2; only `eno1` (195.201.193.143) carries traffic | `ip a` on host |
| RDT support | Full: CMT, MBM, CAT, MBA | `shared/intp-detect.sh` |

The hardware is the implicit assumption everywhere downstream. Different
CPU/memory generation invalidates the calibration values in §5.

### Design constraint: single socket, single node

This entire setup is **single-socket, single-node**. One CPU package
(the 5412U, 24C/48T, no NUMA across sockets), one physical machine, no
cluster. Every choice that follows in this document — Spark `local[*]`,
HDFS `file:///`, daemons off during measurement, loopback as the only
live network path, mem-bandwidth ground truth from one IMC — is a
direct adaptation to that constraint:

- **No multi-host distributed traffic** to measure → can't reproduce
  paper-style cluster numbers, but probing fidelity per-app is testable.
- **No cross-socket interference** → mbw / llcocc readings are
  per-socket only, no remote-socket false signals.
- **No cluster scheduling overhead** → CloudSim/IADA is the simulator
  that fills that role; the bench feeds it real per-app fingerprints.
- **HiBench in `local[*]` + `file:///`** so Spark and HDFS daemons don't
  add their own footprint on top of the workload signal.

When you read "loopback-only", "in-process Spark", or "no cluster", the
single-socket/single-node constraint is what's driving it.

---

## 2. OS install via Hetzner installimage

Two disks, two distros (only one bootable at a time via Hetzner Robot
boot-order toggle):

| Disk | Distro | Kernel | Used for |
|---|---|---|---|
| `nvme0n1` | Ubuntu 22.04 LTS (jammy) + HWE 6.5 | 6.5.x pinned | V0 (stap-2022) baseline (kernel must be ≤6.7) |
| `nvme1n1` | Ubuntu 24.04 LTS (noble) | 6.8.0-111-generic stock | stap-nollc, stap-nohelper, stap-modern, C-ABI, ebpf-ring, bpftrace |

The current campaign runs on **noble (nvme1n1)**. Templates:

- `bench/setup/installimage-jammy.conf` — stap-2022 baseline OS
- `bench/setup/installimage-noble.conf` — modern OS

Reproduction steps (Hetzner Rescue System):

```bash
# In Rescue System with the chosen disk targeted:
wget -O /tmp/installimage.conf https://<your-mirror>/installimage-noble.conf
installimage -a -c /tmp/installimage.conf -x default
reboot
```

Partitioning per template (single disk per install): 256 MiB EFI, 1 GiB
`/boot` ext4, 8 GiB swap, rest `/` ext4. **No RAID.**

---

## 3. Bootstrap — `bench/setup/setup-host.sh`

After the OS comes up over SSH, this is the **single automated step**
that brings the host from "fresh distro" to "ready for IntP runs":

```bash
sudo bash bench/setup/setup-host.sh
```

It auto-detects jammy vs noble and does, in order:

1. **Common packages**: build-essential, gcc, git, curl, wget, jq,
   stress-ng, iperf3, sysstat, numactl, bc, linux-tools-$(uname -r),
   ca-certificates.
2. **Matching kernel compiler** for stap module builds (auto-detected
   via `/proc/version`).
3. **resctrl mount** at `/sys/fs/resctrl` + `/etc/fstab` entry for
   persistence.
4. **`/etc/sysctl.d/99-intp.conf`** with:
   - `kernel.perf_event_paranoid = -1`
   - `kernel.kptr_restrict = 0`
5. **Profile-specific software**:
   - **jammy**: SystemTap 5.2 from source, intel-cmt-cat, kernel debuginfo via ddebs, `stap-prep`
   - **noble**: systemtap + systemtap-runtime (apt), bpftrace, clang/llvm/libbpf-dev/libelf-dev/pahole, kernel-headers, kernel debuginfo
6. **Builds C-ABI and ebpf-ring** (`make -C variants/v2-c-abi`, `make -C variants/v3-ebpf-ring`).
7. **Self-tests** for each profiler.

Idempotent — safe to re-run. Logs to stdout.

### What it does NOT do (manual gap)

- `/etc/default/grub` cmdline (mitigations, hugepages, isolcpus, nohz)
   — left at distro defaults
- CPU frequency governor, turbo boost, c-states — left at defaults
- Transparent hugepages, swap, vm.* sysctls — left at defaults
- LLC CAT / MBA schemata persistence — runtime profilers create
   `/sys/fs/resctrl/mon_groups/intp` dynamically, no systemd unit to
   restore on boot
- IADA env (R 4.3 + JRI flags) — separate, see §6

These are reproducibility gaps. The campaign tolerates defaults but if
you re-run on a different host, set `INTP_BENCH_SET_CPU_GOVERNOR=1` for
deterministic CPU freq.

---

## 4. Network namespace pair (currently active on `intp-master`)

### Why this exists

stress-ng `--sock` and `--udp` default to `127.0.0.1`. Loopback bypasses
`__dev_queue_xmit` against any real device, so the ebpf-ring/bpftrace tracepoints
filter `lo` ([intp.bpf.c:148-161](../../variants/v3-ebpf-ring/src/intp.bpf.c#L148-L161),
[netp.bt:28-38](../../variants/v3.1-bpftrace/scripts/netp.bt#L28-L38)) and C-ABI's
`/proc/softirqs` NET_RX/TX path is kernel-bypassed for `lo`. **All three
return zero for `netp`/`nets` on synthetic loopback workloads, by design.**
stap-modern stap probes higher in the TCP stack and remains sensitive.

### What's deployed on `intp-master` right now (verified May 2026)

```text
intp-veth-h@if6 (host root netns, 10.42.0.1/24)  <==veth==>  intp-veth-g (netns intp-net, 10.42.0.2/24)
                qdisc: netem rate 1gbit                       lo also UP inside netns
```

Setup script: [setup-netns-pair.sh](setup-netns-pair.sh). Verify with:

```bash
ip a show intp-veth-h          # host side, 10.42.0.1
ip netns list | grep intp-net  # guest netns present
ip netns exec intp-net ping -c1 10.42.0.1
tc -s qdisc show dev intp-veth-h    # netem rate set (default 1gbit)
```

### How to drive traffic across it

[run-net-pair-workload.sh](run-net-pair-workload.sh) wraps an iperf3
server (in netns) + client (on host) for any duration. Used as a
"control positive" workload that hits the NIC code path:

```bash
sudo bench/setup/run-net-pair-workload.sh -d 90 -P 16
```

This makes C-ABI/ebpf-ring/bpftrace emit nonzero `netp`/`nets` (since `intp-veth-h`
is not literal `lo` and `__dev_queue_xmit` fires). It is **not wired
into the bench WORKLOADS array** — must be invoked manually around a
profiler run, or extended into a new workload entry.

### Tear down

```bash
sudo bench/setup/teardown-netns-pair.sh
```

### Reproduction (if veth pair is missing on a fresh host)

```bash
sudo bash bench/setup/setup-netns-pair.sh                    # default 1gbit
sudo INTP_NETNS_RATE=100mbit bash bench/setup/setup-netns-pair.sh   # cap to 100mbit
```

### ⚠ The netns pair is NOT persistent

Network namespaces and veth pairs are **kernel runtime state, not config
on disk** — they vanish on:

- Reboot (always)
- Manual `teardown-netns-pair.sh`
- Any `ip netns delete intp-net`

Verify before any campaign run that depends on the veth path:

```bash
ip netns list | grep -qx intp-net && echo "OK" || echo "MISSING — re-run setup-netns-pair.sh"
ip a show intp-veth-h >/dev/null 2>&1 && echo "OK" || echo "MISSING"
```

To make it survive reboots, drop a systemd unit at
`/etc/systemd/system/intp-netns.service`:

```ini
[Unit]
Description=IntP netns + veth pair for bench network workloads
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/root/intp/bench/setup/setup-netns-pair.sh
ExecStop=/root/intp/bench/setup/teardown-netns-pair.sh

[Install]
WantedBy=multi-user.target
```

Then `systemctl enable --now intp-netns`.

---

## 5. Calibration values (host-specific)

Auto-detected by `shared/intp-detect.sh` and consumed by every variant
for metric normalization. Verified on `intp-master`:

| Var | Detected | Source |
|---|---|---|
| `INTP_MEM_BW_MBPS` | 281,600 (281.6 GB/s) | `dmidecode` × DDR5-4800 × 8 channels |
| `INTP_NIC_SPEED_MBPS` | 1,000 | `/sys/class/net/eno1/speed` |
| `INTP_LLC_SIZE_KB` | 46,080 (45 MiB) | `/sys/devices/system/cpu/cpu0/cache/index3/size` |

### `MEM_BW_MAX_BPS=24000000000` override (24 GB/s)

The campaign command passes this **manually**, overriding the detected
281.6 GB/s. Source not in transcripts; treat as a campaign parameter,
not a hardware fact. Document in your paper which value was used and
why if you replicate.

To verify the actual peak with a real measurement:

```bash
stress-ng --vm 8 --vm-bytes 100% --metrics --timeout 30s 2>&1 | tail -5
# OR more rigorously:
bench/setup/run-stream-bench.sh   # if/when available
```

---

## 6. IADA / CloudSim environment (separate, automated)

This is the only campaign component **not bootstrapped by `setup-host.sh`**.

```bash
sudo bash bench/iada/scripts/setup-iada.sh --auto-clone
```

Installs: R, r-base-dev, r-cran-rjava, libtirpc-dev, openjdk-17-jdk-headless,
plus R packages (caret, e1071, dplyr, ggplot2, ocp) into `~/R/library`.
Clones the [ggrv-intp/CloudSimInterference](https://github.com/ggrv-intp/CloudSimInterference)
fork next to this repo (override with `--clone-root` or `--cloudsim`),
applies `bench/iada/patches/mlclassifier-env-vars.patch` idempotently if the
fork doesn't already expose `INTP_R_FOLDER` (the ggrv-intp `master` already
does, so the patch is skipped silently), and writes `~/.iada-env` with
`CLOUDSIM_REPO`, `INTP_R_FOLDER`, `INTP_R_LIBPATHS`, `JAVA_HOME`,
`R_LIBS_USER`, `LD_LIBRARY_PATH`, `INTP_JAVA_OPTS`.

### Required JVM flags (now in `INTP_JAVA_OPTS`)

R 4.3 installs signal handlers that conflict with the JVM. Without these
flags, `library(caret)` segfaults during JRI initialization. The setup
script bakes them into `INTP_JAVA_OPTS` in `~/.iada-env`:

```bash
export INTP_JAVA_OPTS="-DR_SignalHandlers=0 -XX:+UseSerialGC -Xss8m"
```

Wrappers (`run-iada-experiment.sh`, `run-iada-from-bench.sh`) pick them up
automatically. Document any deviations in
[bench/iada/docs/iada-campaign.md](../iada/docs/iada-campaign.md).

### MLClassifier.java patch (idempotent, in repo)

The patch reads `INTP_R_FOLDER` and `INTP_R_LIBPATHS` env vars rather
than dispatching on hostname. It ships as
[bench/iada/patches/mlclassifier-env-vars.patch](../iada/patches/mlclassifier-env-vars.patch)
and is applied automatically by `setup-iada.sh`. The default fork
([ggrv-intp/CloudSimInterference](https://github.com/ggrv-intp/CloudSimInterference))
already carries the change, so on first-time setup the patch step is a
no-op log line ("MLClassifier.java already exposes INTP_R_FOLDER — patch
skipped"). If you point `--cloudsim` at an unmodified upstream Meyer
checkout, the patch is applied and the operator is reminded to rebuild
CloudSim.

---

## 7. Profiler stack — what's installed and how to re-verify

After `setup-host.sh`, validate each variant:

```bash
# V1.1 (SystemTap)
which stap && stap -V

# V2 (C hybrid)
variants/v2-c-abi/intp-hybrid --list-backends

# V3 (eBPF/libbpf)
variants/v3-ebpf-ring/intp-ebpf --list-capabilities
ls /sys/kernel/btf/vmlinux   # must exist

# V3.1 (bpftrace)
bpftrace -V
bash variants/v3.1-bpftrace/run-intp-bpftrace.sh --help

# resctrl
mount | grep resctrl
cat /sys/fs/resctrl/info/L3_MON/mon_features

# perf permissions
sysctl kernel.perf_event_paranoid kernel.kptr_restrict
```

All of these are exercised by the bench's own `detect` and `build`
stages on every campaign start.

---

## 8. HiBench / Hadoop / Spark — Hadoop-specific section

The only piece of host setup that's about Hadoop, isolated here so it can
be skipped if you don't run HiBench.

### What's deployed on `intp-master`

- **HiBench** at `/opt/HiBench` (checked out from upstream, `hadoop3` profile)
- **Hadoop 3.3.6** at `/opt/hadoop`
- **Python 2.7.18** via pyenv (HiBench `load-config.py` requires py2)
- **Spark** included via HiBench's setup script (`hadoop3` Spark binary)

**Daemons NOT running during campaign.** Verified May 2026:

```bash
jps
# 3404309 Jps    <-- only Jps itself, no NameNode/DataNode/SparkMaster
```

### Two-phase setup that needs to be reproduced in order

**Phase A — install/setup (daemons UP, one-time):** HiBench's
`setup-spark-hibench.sh` requires running HDFS to:
- format the NameNode
- start NameNode + DataNode
- run each workload's `prepare/prepare.sh` (TeraGen, RandomTextWriter,
   pagerank graph generation, kmeans data, bayes corpus, etc.) which
   writes datasets to HDFS
- start Spark Master + Worker so the prepare jobs run end-to-end

After prepare completes, the **datasets are persisted** in HDFS storage
on disk. They survive daemon shutdown.

**Phase B — campaign (daemons DOWN, every run):** the actual benchmark
runs read those persisted datasets via local-FS URIs:

- `hibench.hdfs.master = file:///` (no HDFS daemon)
- `hibench.spark.master = local[$ncores]` (Spark in-process, no
   standalone cluster)
- All Spark RPC stays in-JVM or via 127.0.0.1 → loopback

**Deliberate choice**: keep daemons OFF during measurement so namenode/
datanode/master overhead doesn't pollute the profiler signal, and so
runs are deterministic single-host. Datasets stay readable because Phase
A wrote them and `file:///` mode reads them from the same paths.

The tradeoff (consequence of this choice): C-ABI/ebpf-ring/bpftrace see zero `netp`/
`nets` for HiBench because Spark internal traffic is loopback. stap-modern
captures it because it probes higher in the stack.

### Reproduction

```bash
# After setup-host.sh, run:
sudo bash bench/hibench/setup-hadoop-localmode.sh
sudo HADOOP_PROFILE=3 HIBENCH_SCALE=large \
     bash bench/hibench/setup-spark-hibench.sh
```

`setup-spark-hibench.sh` overwrites scale.profile and workload.input/output
in `/opt/HiBench/conf/hibench.conf`. To bypass when re-running on an
already-configured host:

```bash
SKIP_SPARK_HIBENCH_SETUP=1 bash run-big-batch.sh
```

### Distributed-via-veth mode (NEW — wired up, validated May 2026)

For the netp/nets fidelity campaign there is a third HiBench mode driven
by [bench/setup/setup-distributed-mode.sh](setup-distributed-mode.sh):

- HDFS NameNode + DataNode bind to **10.42.0.1** (host side of veth)
- Spark Master + Worker bind to **10.42.0.1**
- HiBench Spark Driver runs **inside netns intp-app** (10.42.0.2) and
  reaches Master/NameNode by traversing `intp-veth-h ↔ intp-veth-g`
- All RPC packets cross a real device (not `lo`), so C-ABI/ebpf-ring/bpftrace detect
  netp/nets > 0 (C-ABI via softirq counts, ebpf-ring/bpftrace via tracepoints that
  filter only literal `lo`)

**Caveat about bind-only solutions**: just binding HDFS/Spark to
`<eth0_ip>:9000` does NOT route traffic through a NIC. The kernel's
local routing table sends local IPs through `lo` regardless of bind
(`ip route get $eth0_ip` returns `local … dev lo`). The veth + netns
pair is what actually forces packets through `__dev_queue_xmit`.

**Lifecycle**:

```bash
# One-time (writes parallel configs in /opt/hadoop/etc/hadoop-distributed/
# and /opt/spark/conf-distributed/, formats NameNode, drops /etc/netns/intp-net/hosts):
sudo bash bench/setup/setup-netns-pair.sh
sudo bash bench/setup/setup-distributed-mode.sh init

# Each session (daemons UP):
sudo bash bench/setup/setup-distributed-mode.sh start
sudo bash bench/setup/setup-distributed-mode.sh smoke    # validates Driver-in-netns can submit job

# One-time (populate HDFS with HiBench datasets — survives until /var/lib/hadoop wiped):
sudo bash bench/setup/setup-distributed-mode.sh prepare-hdfs

# Run the campaign with daemons UP and Driver-in-netns:
sudo INTP_DISTRIBUTED_MODE=1 \
     <other env vars...> \
     bash run-big-batch.sh

# Tear daemons down between campaigns:
sudo bash bench/setup/setup-distributed-mode.sh stop
```

**Smoke validated May 2026**: `Pi is roughly 3.1415863141586313` —
Spark Pi job submitted from inside netns intp-app, scheduled by Master
on the veth host side, traffic crossed `intp-veth-h`. All 4 IntP
variants observe nonzero netp/nets when running this stack.

### Veth-routed stress-ng workloads (NEW)

Companion to distributed mode: synthetic net workloads in
`bench/run-intp-bench.sh` `WORKLOADS=` and `PAIRWISE=` arrays now
include three veth-routed entries (additive — original loopback ones
preserved for back-compat / control comparison):

- `app11b_tcp_veth` — iperf3 TCP across the veth pair (replaces /
  complements `app11_sort_net` which uses loopback `--sock`)
- `app12b_udp_veth` — iperf3 UDP across the veth pair
- `tcp_v_tcp_veth` — pairwise victim+antagonist both via veth on
  different ports (replaces / complements `net_v_net`)

Args use `VETH:<proto>:<port>:<extra>` format. The launcher
([launch_veth_workload](../run-intp-bench.sh)) starts iperf3 server
inside netns intp-net (auto-exits via `-1`), runs iperf3 client on the
host bound to 10.42.0.1.

---

## 9. Reproduction checklist (clean host → ready for campaign)

```bash
# 1. OS install via Hetzner installimage (manual, ~10 min)
# Use bench/setup/installimage-noble.conf

# 2. Single-pass automated bootstrap (~15 min)
sudo bash bench/setup/setup-host.sh

# 3. Verify (~30 sec)
sudo bash shared/intp-detect.sh
sudo bash bench/run-intp-bench.sh --stage detect,build --variants v1.1,v2,v3,v3.1

# 4. HiBench (only if running HiBench segment)
sudo bash bench/hibench/setup-hadoop-localmode.sh
sudo HADOOP_PROFILE=3 HIBENCH_SCALE=large bash bench/hibench/setup-spark-hibench.sh

# 5. Veth pair for NIC-traversing network workloads (~10 sec, non-persistent)
sudo bash bench/setup/setup-netns-pair.sh

# 6. Distributed mode (HDFS pseudo + Spark Standalone via veth) — required
#    only for the netp/nets fidelity campaign; skip for localmode-only runs:
sudo bash bench/setup/setup-distributed-mode.sh init
sudo bash bench/setup/setup-distributed-mode.sh start
sudo bash bench/setup/setup-distributed-mode.sh smoke    # expect "Pi is roughly 3.14..."
sudo bash bench/setup/setup-distributed-mode.sh prepare-hdfs   # one-shot, ~10-30 min

# 7. IADA environment (only if running CloudSim afterward)
#    --auto-clone fetches ggrv-intp/CloudSimInterference next to this repo
#    and applies the MLClassifier.java patch idempotently (already a no-op
#    against the ggrv-intp fork's master).
sudo bash bench/iada/scripts/setup-iada.sh --auto-clone
source ~/.iada-env

# 8. Smoke test the bench end-to-end
sudo REPS=2 DURATION=30 RUN_HIBENCH=0 RUN_PLOTS=0 \
     BENCH_VARIANTS=v3.1 BENCH_WORKLOADS=app01_ml_llc \
     bash run-big-batch.sh

# 9. Smoke test the veth dispatch (no daemons needed):
sudo REPS=1 DURATION=20 RUN_HIBENCH=0 RUN_PLOTS=0 \
     BENCH_VARIANTS=v3.1 BENCH_WORKLOADS=app11b_tcp_veth \
     bash run-big-batch.sh
```

---

## 9b. One-shot per-OS campaign — `ub24run.sh` / `ub22run.sh`

For the SBAC-PAD artifact the steps in §9 are wrapped by two
one-command campaign scripts in the repo root. Each one runs, in a
**strict non-intercalated order**, the whole pipeline for one OS leg:

1. veth-routing setup (`bench/setup/setup-netns-pair.sh`)
2. ensures the Hadoop/Spark cluster is **down** (no daemons during stress-ng)
3. the full **stress-ng** benchmark — veth routed, cluster down
4. brings Hadoop + Spark + HiBench **up** (install, build Spark
   workloads, format HDFS, start daemons, populate datasets)
5. the full **HiBench** benchmark — veth routed, cluster up
6. tears the cluster back down
7. publishes data + plots + metrics into `sbac-results/`
   (`bench/publish-sbac-results.sh`)

| Script        | OS leg        | Variants        |
|---------------|---------------|-----------------|
| `ub24run.sh`  | Ubuntu 24.04  | `v1.1,v2,v3.2`  |
| `ub22run.sh`  | Ubuntu 22.04  | `v0.2`          |

```bash
# UB24 host (after setup-host.sh has bootstrapped it):
sudo bash ub24run.sh                 # full campaign, HiBench size=large
sudo bash ub24run.sh --dry-run       # print every step, run nothing

# UB22 / legacy host:
sudo bash ub22run.sh                 # adds HIBENCH_MVN_DIRECT_VERSIONS=1
```

Both delegate to the shared engine `bench/run-os-campaign.sh` (see
`--help` for every knob: `HIBENCH_SIZE`, `HIBENCH_PROFILE`, `REPS`,
`DURATION`, and `SKIP_KERNEL_CONFIG` / `SKIP_VETH` / `SKIP_STRESS` /
`SKIP_HIBENCH_SETUP` / `SKIP_HIBENCH` / `SKIP_PUBLISH` resume flags).
The two legs run on separate hosts and both publish into the same
`sbac-results/` tree; `publish-sbac-results.sh` merges them (disjoint
per-variant subtrees, dedup-merged `aggregate-means.tsv`).

These scripts do **not** install packages or pin kernels — run
`setup-host.sh` (§3) first. They **do**, in Stage 0, re-assert the live
runtime kernel knobs the profilers need — resctrl mount,
`perf_event_paranoid=-1`, `kptr_restrict=0` — so a host whose sysctls
drifted since boot (or never persisted them) still runs clean. Stage 0
is the runtime half of §3's "Kernel runtime config"; it does not write
`/etc/sysctl.d` or `/etc/fstab` (that persistence stays setup-host.sh's
job).

---

## 10. Reproducibility risks worth flagging in the paper

| Risk | Impact |
|---|---|
| Kernel mitigations status not captured | small perf shift if next host differs |
| CPU governor not pinned | up to 5% throughput variance run-to-run |
| `MEM_BW_MAX_BPS=24 GB/s` source unclear | calibration is reproducible only if value is documented |
| MLClassifier.java patch out-of-tree (historical) | resolved: patch is in `bench/iada/patches/` and applied by `setup-iada.sh`. The default fork (ggrv-intp) already carries the change, so the apply step is a no-op there. |
| resctrl schemata not persisted | reboot loses CAT/MBA state until first run re-creates |
| Veth pair not in `WORKLOADS` array | `netp`/`nets` gap on V2+ unless veth-driven workload is invoked manually |

These are the only places where naive "git clone + setup-host.sh + run"
won't quite reproduce. The fixes are tracked but were not gating for
the SBAC-PAD May 2026 campaign.

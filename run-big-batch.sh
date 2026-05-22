#!/usr/bin/env bash
# run-big-batch.sh — Full IntP benchmark campaign: full bench + HiBench + plots.
#
# Key environment variables (all optional — defaults shown below):
#
#   Timing / quality
#     DURATION=90          stress-ng run duration per rep (seconds; paper campaign)
#     REPS=12              repetitions per workload (paper campaign)
#     INTERVAL=1           profiler sampling interval (seconds)
#     WARMUP=15            pre-recording ramp time (seconds)
#     COOLDOWN=10          post-workload cooldown (seconds)
#     TIMESERIES_DURATION=600   timeseries stage window (seconds)
#     OVERHEAD_DURATION=90      overhead stage steady-state window (seconds; paper campaign)
#     OVERHEAD_WARMUP=10        head-start before sampling each overhead arm
#     OVERHEAD_VOLPERT=1        1 = enable perf-stat scheduler counters in overhead
#     RUN_SEED=                 deterministic seed for per-rep shuffle (default: wall clock)
#
#   Execution environments (run-intp-bench.sh full-bench only)
#     BENCH_ENVS=bare           comma-separated execution environments. Values:
#                                 bare              workload + profiler on host
#                                 container         workload in Docker, profiler on host (--pid=host)
#                                 container-guest   workload + profiler INSIDE container (own PID ns)
#                                 vm                workload in QEMU guest, profiler on host (qemu PID)
#                                 vm-guest          workload + profiler INSIDE guest, results scp'd back
#                               container-guest needs Docker; vm-guest needs cloud-localds + a qcow2
#                               with sshd + cloud-init, ideally with IntP build deps preinstalled.
#     BENCH_VARIANTS=v0.2,v1.1,v2,v3  comma-separated profiler variants for full
#                                   bench (the measured UB22 4-variant matrix).
#                                   Opt-in extras: v0 (classic stap baseline),
#                                   v1 (stap-native), v3.1 (bpftrace), v3.2
#                                   (in-kernel-aggregating) — e.g.
#                                   BENCH_VARIANTS=v0,v0.2,v1.1,v2,v3,v3.2.
#     HIBENCH_VARIANTS=<BENCH_VARIANTS minus v0>    override profiler variants
#                                         for HiBench. Defaults to BENCH_VARIANTS
#                                         with v0 stripped (sustained-load HiBench
#                                         on kernel 5.15 with stap has high
#                                         operational risk; V0 runs only on the
#                                         stress-ng layer). Exposed as a separate
#                                         knob so a specific campaign can drop a
#                                         variant that's flaky on the target
#                                         host without touching the stress-ng
#                                         list.
#     BENCH_WORKLOADS=             comma-separated stress-ng workload IDs to keep
#                                  (default: empty = all 15 apps from the catalog).
#                                  Useful to skip workloads that misbehaved in a
#                                  prior campaign — e.g. drop app15_query_inerge
#                                  if V1 stap captured <15% of expected samples.
#     CONTAINER_IMAGE=ubuntu:24.04  Docker image for container/container-guest envs
#     VM_IMAGE=                 path to .qcow2 for vm/vm-guest envs (required when set)
#     VM_MEM=                   memory for QEMU guest (default: inherits BENCH_MEM)
#     VM_CPUS=                  vCPUs for QEMU guest (default: inherits BENCH_CPUS)
#     BENCH_CPUS=               cross-env CPU parity knob; applied as cgroup
#                                cpu.max for bare, --cpus for container, -smp for VM.
#                                Default: floor(nproc * 2/3). See docs/CROSS-ENV-CAMPAIGN.md.
#     BENCH_MEM=                cross-env memory parity knob; applied as cgroup
#                                memory.max for bare, --memory for container, -m for VM.
#                                Default: floor(MemTotal * 2/3) in GB.
#     INTP_VMG_ALLOW_STAP=0     set to 1 if your qcow2 has linux-headers + stap (vm-guest stap support)
#
#   Segment toggles
#     RUN_STRESS_BENCH=1        run stress-ng full bench stages (detect/build/solo/pairwise/overhead/timeseries/report)
#     RUN_HIBENCH=1             run HiBench Spark subset
#     HIBENCH_SIZE=medium       HiBench dataset: small | medium | large
#       (maps to HiBench scale: tiny | small | large)
#     HIBENCH_PROFILE=both      standard | netp-extreme | both
#     HIBENCH_WORKLOADS=all     comma-separated HiBench workloads
#     HIBENCH_REPS=4            min Spark invocations per workload (default: REPS)
#     HIBENCH_INTERVAL=1        HiBench profiler sampling interval (seconds)
#     HIBENCH_WARMUP=15         HiBench pre-job warmup before Spark run (seconds)
#     HIBENCH_MAX_DURATION=600  HiBench profiler max duration per Spark invocation (seconds)
#     HIBENCH_ELAPSED_CV_WARN_PCT=20  Warn when duration CV across reps reaches threshold
#     HADOOP_PROFILE=3          Spark binary variant (hadoop2 or hadoop3)
#       (used by setup-spark-hibench.sh to select spark-X.Y.Z-bin-hadoop3.tgz)
#     RUN_PLOTS=1               generate plots at end
#
#   V1 SystemTap module-accumulation guard
#     INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5
#
#   Distributed mode (HDFS pseudo + Spark Standalone bound to veth pair)
#     INTP_DISTRIBUTED_MODE=0   set to 1 to run HiBench Spark Driver inside
#                                netns intp-app (10.42.0.2) so RPC to
#                                Master/NameNode at 10.42.0.1 traverses
#                                intp-veth-h and is observable by V2/V3/V3.1.
#                                Requires:
#                                  bench/setup/setup-netns-pair.sh (veth UP)
#                                  bench/setup/setup-distributed-mode.sh init+start
#                                Workloads must be re-prepared into HDFS pseudo
#                                (one-shot; survives until /var/lib/hadoop wiped).
#
# Usage examples:
#   sudo bash run-big-batch.sh
#   sudo BENCH_ENVS=bare,container bash run-big-batch.sh
#   sudo BENCH_ENVS=bare,vm VM_IMAGE=/var/lib/intp/ubuntu24.qcow2 VM_MEM=16G VM_CPUS=8 bash run-big-batch.sh
#   sudo RUN_HIBENCH=0 REPS=3 DURATION=60 bash run-big-batch.sh   # quick sizing run
#   # Cross-env campaign (Hetzner Sapphire Rapids, see docs/CROSS-ENV-CAMPAIGN.md):
#   sudo BENCH_ENVS=bare,container,vm-guest BENCH_VARIANTS=v1.1,v2,v3,v3.1 \
#        VM_IMAGE=/var/lib/intp/ubuntu24.qcow2 BENCH_CPUS=64 BENCH_MEM=192G \
#        REPS=10 DURATION=120 bash run-big-batch.sh

set -u -o pipefail

# Derived from script location so the campaign survives repo path changes
# (e.g. the historical intp → intp-comparison rename).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resume support: set RESUME_DIR to an existing big-batch output directory for
# idempotent re-execution. The stress-ng segment skips reps whose profiler.tsv
# already has samples; the HiBench segment reuses each profile's existing
# <profile>-<size>-<ts> run-dir and skips reps that completed cleanly (it is
# passed --resume below when RESUME_DIR is set), so a re-run fills only the gaps
# instead of minting a second run-dir per profile. If unset, a fresh timestamped
# directory is created.
if [ -n "${RESUME_DIR:-}" ]; then
    OUT="$RESUME_DIR"
    if [ ! -d "$OUT" ]; then
        echo "ERROR: RESUME_DIR=$OUT does not exist" >&2; exit 1
    fi
    echo ">>> Resuming into $OUT"
else
    TS="$(date +%Y%m%d_%H%M%S)"
    OUT="$ROOT/results/big-batch-$TS"
    mkdir -p "$OUT"
fi
ln -sfn "$OUT" "$ROOT/results/LATEST-BIG"

# ── Timing / quality ───────────────────────────────────────────────────────────
# Defaults below are the SBAC-PAD campaign parameters (paper §IV-C):
# 12 reps, 90 s steady-state, 15 s warmup, 10 s cooldown, 600 s timeseries,
# 90 s overhead window. Override via env vars for quicker sizing runs.
DURATION="${DURATION:-90}"
REPS="${REPS:-12}"
INTERVAL="${INTERVAL:-1}"
TIMESERIES_DURATION="${TIMESERIES_DURATION:-600}"
OVERHEAD_DURATION="${OVERHEAD_DURATION:-90}"
OVERHEAD_WARMUP="${OVERHEAD_WARMUP:-10}"
OVERHEAD_VOLPERT="${OVERHEAD_VOLPERT:-1}"
RUN_SEED="${RUN_SEED:-}"
WARMUP="${WARMUP:-15}"
COOLDOWN="${COOLDOWN:-10}"

# ── Execution environments (full bench only) ────────────────────────────────────
# bare    → stress-ng runs directly on the host
# container → stress-ng in Docker (--pid=host; profiler sees container PID)
# vm      → stress-ng in QEMU/KVM guest (profiler measures qemu PID on host);
#            requires /dev/kvm, cloud-localds, and VM_IMAGE pointing to a qcow2
BENCH_ENVS="${BENCH_ENVS:-bare}"
# Default measured matrix: the 4-variant UB22 campaign — v0.2 (the
# v0-faithful, recalibrated baseline), v1.1, v2, v3. The planned next
# campaign replaces v3 with v3.2 → BENCH_VARIANTS="v0.2,v1.1,v2,v3.2".
# Opt-in extras:
#   v0   classic stap baseline — only builds on very old kernels; add with
#        BENCH_VARIANTS="v0,v0.2,v1.1,v2,v3".
#   v1   stap-native (pre-helper) — BENCH_VARIANTS="...,v1".
#   v3.1 bpftrace alternative — BENCH_VARIANTS="...,v3.1".
#   v3.2 in-kernel-aggregating variant (addresses the V-D amplification);
#        see variants/v3.2-ebpf-agg/DESIGN.md — BENCH_VARIANTS="...,v3.2".
BENCH_VARIANTS="${BENCH_VARIANTS:-v0.2,v1.1,v2,v3}"
# HIBENCH_VARIANTS defaults to BENCH_VARIANTS, EXCEPT that the classic V0
# (exact token "v0", not v0.2) is excluded from HiBench by default.
# Sustained-load HiBench on kernel 5.15 with classic-V0 stap exposes the
# systemd-logind / stap_* module-accumulation cliff documented in
# bench/findings/v0-baseline-failure-diagnosis.md, and the recovery cost is
# reboot-level. v0.2 uses the helper-based template and does NOT hit that
# cliff, so it stays in HiBench. Classic V0 stays in the stress-ng segment
# only (shorter runs, deep cleanup every rep). To force classic V0 into
# HiBench explicitly:  HIBENCH_VARIANTS="v0,v0.2,v1.1,v2,v3" ./run-big-batch.sh
HIBENCH_VARIANTS_DEFAULT=$(echo "$BENCH_VARIANTS" | tr ',' '\n' | grep -vx 'v0' | paste -sd, -)
HIBENCH_VARIANTS="${HIBENCH_VARIANTS:-$HIBENCH_VARIANTS_DEFAULT}"
BENCH_WORKLOADS="${BENCH_WORKLOADS:-}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ubuntu:24.04}"
VM_IMAGE="${VM_IMAGE:-}"
# VM_MEM / VM_CPUS now default to empty so they inherit BENCH_MEM /
# BENCH_CPUS in run-intp-bench.sh; explicit settings still win.
VM_MEM="${VM_MEM:-}"
VM_CPUS="${VM_CPUS:-}"
# Cross-env parity knobs (see docs/CROSS-ENV-CAMPAIGN.md). Empty values
# let run-intp-bench.sh compute defaults as floor(nproc * 2/3) /
# floor(MemTotal_GB * 2/3).
BENCH_CPUS="${BENCH_CPUS:-}"
BENCH_MEM="${BENCH_MEM:-}"

# ── Segment toggles ────────────────────────────────────────────────────────────
RUN_STRESS_BENCH="${RUN_STRESS_BENCH:-1}"
RUN_HIBENCH="${RUN_HIBENCH:-1}"
HIBENCH_SIZE="${HIBENCH_SIZE:-medium}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-both}"
HIBENCH_WORKLOADS="${HIBENCH_WORKLOADS:-all}"
HIBENCH_REPS="${HIBENCH_REPS:-$REPS}"
HIBENCH_INTERVAL="${HIBENCH_INTERVAL:-$INTERVAL}"
HIBENCH_WARMUP="${HIBENCH_WARMUP:-$WARMUP}"
HIBENCH_MAX_DURATION="${HIBENCH_MAX_DURATION:-$TIMESERIES_DURATION}"
HIBENCH_ELAPSED_CV_WARN_PCT="${HIBENCH_ELAPSED_CV_WARN_PCT:-20}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
RUN_PLOTS="${RUN_PLOTS:-1}"

# ── Calibration knobs (host-specific ground-truth normalisation) ──────────────
# Pass through to run-hibench-subset.sh so utilization metrics aren't pinned
# to default detect.c estimates that may be off for this NIC/DRAM/LLC.
MEM_BW_MAX_BPS="${MEM_BW_MAX_BPS:-}"
NIC_SPEED_BPS="${NIC_SPEED_BPS:-}"
LLC_SIZE_BYTES="${LLC_SIZE_BYTES:-}"

# ── V1 guard ───────────────────────────────────────────────────────────────────
export INTP_BENCH_V3_DEEP_CLEANUP_EVERY="${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}"

# ── Distributed mode toggle (forwarded to bench/hibench/run-hibench-subset.sh) ──
export INTP_DISTRIBUTED_MODE="${INTP_DISTRIBUTED_MODE:-0}"
export INTP_NETNS_NAME="${INTP_NETNS_NAME:-intp-net}"
export INTP_NETNS_HOST_IP="${INTP_NETNS_HOST_IP:-10.42.0.1}"
export INTP_NETNS_GUEST_IP="${INTP_NETNS_GUEST_IP:-10.42.0.2}"

# ── Container / VM env vars forwarded to run-intp-bench.sh via env ─────────────
export INTP_BENCH_CONTAINER="$CONTAINER_IMAGE"
export INTP_BENCH_VM_IMAGE="$VM_IMAGE"
export INTP_BENCH_VM_MEM="$VM_MEM"
export INTP_BENCH_VM_CPUS="$VM_CPUS"
# Cross-env resource parity: BENCH_CPUS/BENCH_MEM apply to all three envs
# (bare cgroup, container --cpus/--memory, VM -smp/-m). When empty,
# run-intp-bench.sh derives 2/3 of host nproc / MemTotal.
export INTP_BENCH_CPUS="$BENCH_CPUS"
export INTP_BENCH_MEM="$BENCH_MEM"

exec > >(tee -a "$OUT/big-batch.log") 2>&1

ok=0
fail=0

run_step() {
  local name="$1"
  shift
  echo
  echo "===== STEP: $name ====="
  if "$@"; then
    echo "===== PASS: $name ====="
    ok=$((ok+1))
  else
    local rc=$?
    echo "===== FAIL: $name (rc=$rc) ====="
    fail=$((fail+1))
  fi
}

cd "$ROOT"

echo "Big batch config:"
echo "  out=$OUT"
echo "  duration=$DURATION  reps=$REPS  interval=$INTERVAL"
echo "  warmup=$WARMUP  cooldown=$COOLDOWN"
echo "  timeseries_duration=$TIMESERIES_DURATION  overhead_duration=$OVERHEAD_DURATION  overhead_warmup=$OVERHEAD_WARMUP  overhead_volpert=$OVERHEAD_VOLPERT  run_seed=${RUN_SEED:-<auto>}"
echo "  bench_envs=$BENCH_ENVS"
echo "  bench_variants=$BENCH_VARIANTS  hibench_variants=$HIBENCH_VARIANTS"
echo "  bench_workloads=${BENCH_WORKLOADS:-<all>}"
echo "    container_image=$CONTAINER_IMAGE"
echo "    vm_image=${VM_IMAGE:-<not set>}  vm_mem=${VM_MEM:-<inherit>}  vm_cpus=${VM_CPUS:-<inherit>}"
echo "    bench_cpus=${BENCH_CPUS:-<auto 2/3 nproc>}  bench_mem=${BENCH_MEM:-<auto 2/3 MemTotal>}"
echo "  run_stress_bench=$RUN_STRESS_BENCH"
echo "  run_hibench=$RUN_HIBENCH  hibench_size=$HIBENCH_SIZE  hibench_profile=$HIBENCH_PROFILE  hibench_workloads=$HIBENCH_WORKLOADS  hadoop_profile=$HADOOP_PROFILE"
echo "    hibench_reps=$HIBENCH_REPS  hibench_interval=$HIBENCH_INTERVAL  hibench_warmup=$HIBENCH_WARMUP  hibench_max_duration=$HIBENCH_MAX_DURATION  hibench_elapsed_cv_warn_pct=$HIBENCH_ELAPSED_CV_WARN_PCT"
echo "  run_plots=$RUN_PLOTS"
echo "  v1_deep_cleanup_every=$INTP_BENCH_V3_DEEP_CLEANUP_EVERY"
echo "  distributed_mode=$INTP_DISTRIBUTED_MODE  netns=$INTP_NETNS_NAME  host_ip=$INTP_NETNS_HOST_IP  guest_ip=$INTP_NETNS_GUEST_IP"
echo "  calibration: mem_bw_max_bps=${MEM_BW_MAX_BPS:-auto}  nic_speed_bps=${NIC_SPEED_BPS:-auto}  llc_size_bytes=${LLC_SIZE_BYTES:-auto}"

# ── Preflight ──────────────────────────────────────────────────────────────────
# Only build/check the variants this campaign actually runs. A per-OS campaign
# (e.g. UB22 → v0.2, UB24 → v1.1,v2,v3.2) must not FAIL on a build for a variant
# it never uses -- e.g. v3/v3.2 need clang+libbpf which the UB22 legacy leg
# lacks. _variant_requested tests membership in BENCH_VARIANTS ∪ HIBENCH_VARIANTS.
_variant_requested() {
  case ",$BENCH_VARIANTS,$HIBENCH_VARIANTS," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

run_step "preflight detect" bash shared/intp-detect.sh
if _variant_requested v1; then
  run_step "v1 deps check" bash -lc '
    command -v stap >/dev/null 2>&1 \
    && test -f variants/v1-stap-only/intp-resctrl.stp \
    && test -x shared/intp-resctrl-helper.sh
  '
fi
_variant_requested v0.2 && run_step "build v0.2" make -C variants/v0.2-legacy-bridge all
_variant_requested v1.1 && run_step "build v1.1" make -C variants/v1.1-stap-helper all
_variant_requested v2   && run_step "build v2"   make -C variants/v2-hybrid-c all
_variant_requested v3   && run_step "build v3"   make -C variants/v3-ebpf-ringbuf all
_variant_requested v3.2 && run_step "build v3.2" make -C variants/v3.2-ebpf-agg all
_variant_requested v3.1 && run_step "v3.1 deps check" make -C variants/v3.1-bpftrace deps
true   # keep exit status clean after the short-circuit && chains above
run_step "python benchmark deps" bash -c '
  pip3 install --quiet --break-system-packages numpy matplotlib pandas scipy 2>/dev/null \
  || pip3 install --quiet numpy matplotlib pandas scipy
'

# Distributed-mode preflight: fail fast if netns/daemons/HDFS aren't ready.
if [ "$INTP_DISTRIBUTED_MODE" = "1" ]; then
  run_step "distributed mode preflight (netns + daemons + HDFS)" bash -c '
    set -e
    ip netns list | grep -qE "^'"$INTP_NETNS_NAME"'( |$)" \
      || { echo "netns '"$INTP_NETNS_NAME"' missing — run bench/setup/setup-netns-pair.sh"; exit 1; }
    pgrep -f "NameNode" >/dev/null \
      || { echo "NameNode not running — run bench/setup/setup-distributed-mode.sh start"; exit 1; }
    pgrep -f "DataNode" >/dev/null \
      || { echo "DataNode not running — run bench/setup/setup-distributed-mode.sh start"; exit 1; }
    pgrep -f "org.apache.spark.deploy.master.Master" >/dev/null \
      || { echo "Spark Master not running — run bench/setup/setup-distributed-mode.sh start"; exit 1; }
    pgrep -f "org.apache.spark.deploy.worker.Worker" >/dev/null \
      || { echo "Spark Worker not running — run bench/setup/setup-distributed-mode.sh start"; exit 1; }
    HADOOP_CONF_DIR="${HADOOP_HOME:-/opt/hadoop}/etc/hadoop-distributed" \
      "${HADOOP_HOME:-/opt/hadoop}/bin/hdfs" dfs -ls /HiBench >/dev/null 2>&1 \
      || { echo "HDFS /HiBench missing or NameNode unreachable — run setup-distributed-mode.sh prepare-hdfs"; exit 1; }
    echo "distributed mode OK: netns up, daemons running, HDFS populated"
  '
fi

# Container preflight (only when container or container-guest in BENCH_ENVS)
case ",$BENCH_ENVS," in
  *,container,*|*,container-guest,*)
    run_step "container preflight (docker)" bash -c '
      command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }
      docker info >/dev/null 2>&1 || { echo "docker daemon not running"; exit 1; }
      docker pull --quiet '"$CONTAINER_IMAGE"' || { echo "pull failed"; exit 1; }
    '
    ;;
esac

# VM preflight (only when vm is in BENCH_ENVS)
case ",$BENCH_ENVS," in
  *,vm,*)
    run_step "vm preflight (qemu/kvm/cloud-init)" bash -c '
      test -e /dev/kvm              || { echo "/dev/kvm not present"; exit 1; }
      command -v qemu-system-x86_64 || { echo "qemu-system-x86_64 not found"; exit 1; }
      command -v cloud-localds      || { echo "cloud-localds not found (apt install cloud-image-utils)"; exit 1; }
      test -n "'"$VM_IMAGE"'" && test -f "'"$VM_IMAGE"'" \
        || { echo "VM_IMAGE not set or file missing: '"${VM_IMAGE:-<not set>}"'"; exit 1; }
    '
    ;;
esac

if [ "$RUN_HIBENCH" = "1" ]; then
  # Map our user-facing HIBENCH_SIZE → setup-spark-hibench's HIBENCH_SCALE.
  # Set SKIP_SPARK_HIBENCH_SETUP=1 to bypass entirely when running on a host
  # already configured (e.g. HDFS pseudo-distributed already up with prepared
  # datasets). The setup script overwrites scale.profile and workload.input/output
  # which clobbers a hand-tuned HDFS setup.
  case "$HIBENCH_SIZE" in
    small)  HIBENCH_SCALE_MAPPED=tiny ;;
    medium) HIBENCH_SCALE_MAPPED=small ;;
    large)  HIBENCH_SCALE_MAPPED=large ;;
    *)      HIBENCH_SCALE_MAPPED="$HIBENCH_SIZE" ;;
  esac
  # In distributed mode, setup-spark-hibench.sh would clobber hibench.conf /
  # spark.conf / hadoop.conf back to localmode (file:/// + local[*]). Auto-skip
  # unless the user explicitly opted in. Distributed mode assumes the operator
  # already ran setup-distributed-mode.sh init + start + prepare-hdfs.
  if [ "$INTP_DISTRIBUTED_MODE" = "1" ] && [ -z "${SKIP_SPARK_HIBENCH_SETUP+x}" ]; then
    echo "[distributed] auto-setting SKIP_SPARK_HIBENCH_SETUP=1 (preserves distributed HiBench config)"
    SKIP_SPARK_HIBENCH_SETUP=1
  fi
  if [ "${SKIP_SPARK_HIBENCH_SETUP:-0}" = "1" ]; then
    echo "Skipping spark+hibench setup (SKIP_SPARK_HIBENCH_SETUP=1)"
  else
    run_step "spark + hibench setup (scale=$HIBENCH_SCALE_MAPPED)" \
      env HADOOP_PROFILE="$HADOOP_PROFILE" HIBENCH_SCALE="$HIBENCH_SCALE_MAPPED" \
      bash bench/hibench/setup-spark-hibench.sh
    # Defense-in-depth: if user explicitly re-ran setup in distributed mode,
    # restore distributed HiBench config (so spark.master + hibench.hdfs.master
    # point at our daemons rather than local[*] / file:///).
    if [ "$INTP_DISTRIBUTED_MODE" = "1" ]; then
      echo "[distributed] restoring distributed HiBench config after setup-spark-hibench"
      run_step "switch HiBench to distributed (post-setup)" \
        bash bench/setup/setup-distributed-mode.sh switch-distributed
    fi
  fi

  # Distributed-mode path skips setup-spark-hibench.sh entirely, which is what
  # normally writes hibench.scale.profile. Patch it ourselves so HiBench reads
  # the right scale (must match whatever was prepared into HDFS via
  # setup-distributed-mode.sh prepare-hdfs).
  if [ "$INTP_DISTRIBUTED_MODE" = "1" ]; then
    HIBENCH_CONF_FILE="${HIBENCH_HOME:-/opt/HiBench}/conf/hibench.conf"
    if [ -f "$HIBENCH_CONF_FILE" ]; then
      if grep -qE '^hibench\.scale\.profile' "$HIBENCH_CONF_FILE"; then
        sed -i -E "s|^(hibench\.scale\.profile[[:space:]]+).*|\1$HIBENCH_SCALE_MAPPED|" "$HIBENCH_CONF_FILE"
      else
        printf '\nhibench.scale.profile          %s\n' "$HIBENCH_SCALE_MAPPED" >> "$HIBENCH_CONF_FILE"
      fi
      echo "[distributed] patched hibench.scale.profile=$HIBENCH_SCALE_MAPPED in $HIBENCH_CONF_FILE"
      echo "[distributed] (datasets in HDFS must match this scale — re-run prepare-hdfs if scale changed)"
    fi
  fi
fi

# ── Segment 1: Full bench — all stages, all variants, selected envs ────────────
# V1 cleanup guard is exported above; bench script inherits it automatically.
if [ "$RUN_STRESS_BENCH" = "1" ]; then
  BENCH_EXTRA_ARGS=()
  [ "$OVERHEAD_VOLPERT" = "1" ] && BENCH_EXTRA_ARGS+=(--overhead-volpert)
  [ -n "$RUN_SEED" ]            && BENCH_EXTRA_ARGS+=(--seed "$RUN_SEED")
  [ -n "$BENCH_WORKLOADS" ]     && BENCH_EXTRA_ARGS+=(--workloads "$BENCH_WORKLOADS")
  run_step "full bench all stages variants=$BENCH_VARIANTS (envs=$BENCH_ENVS)" \
    bash bench/run-intp-bench.sh \
      --stage detect,build,solo,pairwise,overhead,timeseries,report \
      --variants "$BENCH_VARIANTS" \
      --env "$BENCH_ENVS" \
      --interval "$INTERVAL" \
      --duration "$DURATION" \
      --reps "$REPS" \
      --warmup "$WARMUP" \
      --cooldown "$COOLDOWN" \
      --timeseries-duration "$TIMESERIES_DURATION" \
      --overhead-duration "$OVERHEAD_DURATION" \
      --overhead-warmup "$OVERHEAD_WARMUP" \
      "${BENCH_EXTRA_ARGS[@]}" \
      --output-dir "$OUT/bench-full"
else
  echo "Skipping full bench stress-ng segment (RUN_STRESS_BENCH=$RUN_STRESS_BENCH)"
fi

# ── Segment 2: HiBench Spark subset ──────────────────────────────────────────
if [ "$RUN_HIBENCH" = "1" ]; then
  HIBENCH_EXTRA_ARGS=()
  # Resume into the shared output dir: reuse each profile's existing run-dir and
  # skip reps that already completed cleanly, instead of minting a second
  # <profile>-<size>-<ts> dir (which doubled the rep count after publish merged
  # them). RESUME_DIR is set by run-os-campaign.sh on every leg, so the campaign
  # is idempotent; on a first run nothing exists to reuse/skip (no-op).
  [ -n "${RESUME_DIR:-}" ] && HIBENCH_EXTRA_ARGS+=(--resume)
  [ -n "$MEM_BW_MAX_BPS" ] && HIBENCH_EXTRA_ARGS+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
  [ -n "$NIC_SPEED_BPS"  ] && HIBENCH_EXTRA_ARGS+=(--nic-speed-bps  "$NIC_SPEED_BPS")
  [ -n "$LLC_SIZE_BYTES" ] && HIBENCH_EXTRA_ARGS+=(--llc-size-bytes "$LLC_SIZE_BYTES")
  run_step "hibench spark subset ($HIBENCH_PROFILE/$HIBENCH_SIZE) variants=$HIBENCH_VARIANTS" \
    bash bench/hibench/run-hibench-subset.sh \
      --variants "$HIBENCH_VARIANTS" \
      --workloads "$HIBENCH_WORKLOADS" \
      --size "$HIBENCH_SIZE" \
      --profile "$HIBENCH_PROFILE" \
      --reps "$HIBENCH_REPS" \
      --interval "$HIBENCH_INTERVAL" \
      --warmup "$HIBENCH_WARMUP" \
      --max-duration "$HIBENCH_MAX_DURATION" \
      --elapsed-cv-warn-pct "$HIBENCH_ELAPSED_CV_WARN_PCT" \
      "${HIBENCH_EXTRA_ARGS[@]}" \
      --out-root "$OUT/hibench"
else
  echo "Skipping HiBench subset (RUN_HIBENCH=$RUN_HIBENCH)"
fi

# ── Segment 3: plots ───────────────────────────────────────────────────────────
# Full figure set: the stress-ng bench figures + the fragility / PCA
# consumers that read the same bench-full/ tree, plus the HiBench figures.
# plot-intp-bench.py additionally auto-chains plot-cross-environment.py when
# the campaign has >=2 envs, so cross-env is covered without an extra call.
if [ "$RUN_PLOTS" = "1" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipping plots: python3 not found"
  else
    if [ -d "$OUT/bench-full" ]; then
      run_step "plot stress-ng bench figures" \
        python3 bench/plot/plot-intp-bench.py "$OUT/bench-full"
      run_step "extract stress-ng fragility table" \
        python3 bench/plot/extract-fragility.py "$OUT/bench-full"
      run_step "emit per-workload data-quality flags" \
        python3 bench/plot/quality-flags.py "$OUT/bench-full"
      if [ -f "$OUT/bench-full/aggregate-means.tsv" ]; then
        run_step "plot PCA correlation circle" \
          python3 bench/plot/plot-pca-correlation-circle.py \
            "$OUT/bench-full/aggregate-means.tsv"
      else
        echo "Skipping PCA circle: $OUT/bench-full/aggregate-means.tsv not found"
      fi
    else
      echo "Skipping stress-ng plots: bench-full not found at $OUT/bench-full"
    fi
    if [ "$RUN_HIBENCH" = "1" ]; then
      if [ -d "$OUT/hibench" ]; then
        run_step "plot HiBench figures" \
          python3 bench/plot/plot-hibench.py "$OUT/hibench"
      else
        echo "Skipping HiBench plots: $OUT/hibench not found"
      fi
    fi
  fi
else
  echo "Skipping plots (RUN_PLOTS=$RUN_PLOTS)"
fi

echo
echo "Big batch finished. PASS=$ok FAIL=$fail"
echo "Output: $OUT"
test "$fail" -eq 0

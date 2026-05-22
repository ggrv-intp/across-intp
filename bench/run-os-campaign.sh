#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-os-campaign.sh -- end-to-end per-OS SBAC-PAD campaign engine.
#
# This is the shared implementation behind ub24run.sh (UB24 -> v1.1,v2,v3.2)
# and ub22run.sh (UB22 -> v0.2). It runs the full pipeline in a strict,
# NON-INTERCALATED order:
#
#   1. veth-routing setup        bench/setup/setup-netns-pair.sh
#   2. ensure Hadoop/Spark DOWN  (no cluster daemons during the stress-ng leg)
#   3. STRESS-NG leg             all variants, veth-routed, NO Hadoop/Spark
#   4. Hadoop/Spark/HiBench up   install + build workloads + HDFS + daemons
#   5. HIBENCH leg               all variants, veth-routed, cluster up
#   6. tear the cluster down     (leave the host clean)
#   7. publish                   -> sbac-results/  (bench/publish-sbac-results.sh)
#
# The stress-ng leg and the HiBench leg are two separate run-big-batch.sh
# passes that share one output directory (RESUME_DIR), so stress-ng fully
# finishes -- with only the veth pair up and the Hadoop cluster down -- before
# any Spark/HDFS daemon is started.
#
# Usage:
#   sudo bash bench/run-os-campaign.sh --host-tag <tag> --variants <csv> [opts]
#
#   --host-tag <tag>     short leg label, e.g. ub24 | ub22 (publish namespace)
#   --variants <csv>     IntP variants to run, e.g. v1.1,v2,v3.2  or  v0.2
#   --legacy-mvn         pass HIBENCH_MVN_DIRECT_VERSIONS=1 to setup-spark-hibench
#                        (required on the UB22 / legacy leg)
#   --dry-run            print every external command instead of running it
#   -h, --help           show this help
#
# Environment overrides (all optional):
#   CAMPAIGN_OUT       reuse an existing results/<...>-campaign dir (resume).
#                      Resume is gap-filling: the stress-ng + HiBench legs skip
#                      reps that already completed cleanly and re-run only
#                      missing/failed ones -- no duplicate run-dirs, no 24-rep
#                      doubling. Combine with SKIP_* to resume from a stage.
#   HIBENCH_SIZE       HiBench dataset size      (default: large)
#   HIBENCH_PROFILE    HiBench co-runner profile (default: all-stress)
#   REPS               repetitions per workload  (default: 12)
#   DURATION           stress-ng seconds per rep (default: 90)
#   NETNS_NAME         veth guest netns name     (default: intp-net)
#   HADOOP_PROFILE     Hadoop major for HiBench  (default: 3)
#   Per-leg BUILD knobs (forwarded into setup-spark-hibench.sh when set; this is
#   how a leg pins the HiBench Maven/Scala build without changing versions):
#     SPARK_VERSION HIBENCH_REF HADOOP_VERSION SCALA_FULL_VERSION
#     KAFKA_VERSION KAFKA_BINARY_VERSION HIBENCH_MVN_EXTRA_ARGS
#   The launchers (ub22run.sh / ub24run.sh) set these in a per-leg env block;
#   unset knobs fall back to setup-spark-hibench.sh defaults.
#   SKIP_KERNEL_CONFIG / SKIP_VETH / SKIP_STRESS / SKIP_HIBENCH_SETUP /
#   SKIP_HIBENCH / SKIP_PUBLISH
#                      set any to 1 to skip that stage (resume support)
#   SKIP_DAEMON_STOP   set to 1 to NOT touch Hadoop/Spark daemon state
#
# Stage 0 asserts the RUNTIME kernel knobs the profilers need (resctrl mount,
# perf_event_paranoid=-1, kptr_restrict=0). This is NOT the full host
# bootstrap -- bench/setup/setup-host.sh still owns package installs, kernel
# pinning, and *persisting* these via /etc/sysctl.d + /etc/fstab. Stage 0 only
# guarantees the live values are correct for this campaign (no reboot).
# -----------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '[%s] [campaign] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

# ---- defaults / CLI ---------------------------------------------------------
HOST_TAG=""
VARIANTS=""
LEGACY_MVN=0
DRY_RUN=0

HIBENCH_SIZE="${HIBENCH_SIZE:-large}"
HIBENCH_PROFILE="${HIBENCH_PROFILE:-all-stress}"
REPS="${REPS:-12}"
DURATION="${DURATION:-90}"
NETNS_NAME="${NETNS_NAME:-intp-net}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"

SKIP_KERNEL_CONFIG="${SKIP_KERNEL_CONFIG:-0}"
SKIP_VETH="${SKIP_VETH:-0}"
SKIP_STRESS="${SKIP_STRESS:-0}"
SKIP_HIBENCH_SETUP="${SKIP_HIBENCH_SETUP:-0}"
SKIP_HIBENCH="${SKIP_HIBENCH:-0}"
SKIP_PUBLISH="${SKIP_PUBLISH:-0}"
SKIP_DAEMON_STOP="${SKIP_DAEMON_STOP:-0}"

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host-tag)  HOST_TAG="$2"; shift 2 ;;
        --variants)  VARIANTS="$2"; shift 2 ;;
        --legacy-mvn) LEGACY_MVN=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[ -n "$HOST_TAG" ] || die "--host-tag is required"
[ -n "$VARIANTS" ] || die "--variants is required"
case "$HOST_TAG" in *[!a-zA-Z0-9_-]*) die "invalid --host-tag: $HOST_TAG" ;; esac

# HiBench dataset size -> HiBench's internal scale profile (mirror run-big-batch).
case "$HIBENCH_SIZE" in
    small)  HIBENCH_SCALE=tiny ;;
    medium) HIBENCH_SCALE=small ;;
    large)  HIBENCH_SCALE=large ;;
    *)      HIBENCH_SCALE="$HIBENCH_SIZE" ;;
esac

NETNS_SETUP="$REPO_ROOT/bench/setup/setup-netns-pair.sh"
DIST_SETUP="$REPO_ROOT/bench/setup/setup-distributed-mode.sh"
HADOOP_SETUP="$REPO_ROOT/bench/hibench/setup-hadoop-localmode.sh"
SPARK_SETUP="$REPO_ROOT/bench/hibench/setup-spark-hibench.sh"
BIG_BATCH="$REPO_ROOT/run-big-batch.sh"
PUBLISH="$REPO_ROOT/bench/publish-sbac-results.sh"

for f in "$NETNS_SETUP" "$DIST_SETUP" "$HADOOP_SETUP" "$SPARK_SETUP" "$BIG_BATCH" "$PUBLISH"; do
    [ -f "$f" ] || die "required script missing: $f"
done

[ "$DRY_RUN" -eq 1 ] || [ "$(id -u)" = "0" ] || die "must run as root (profilers + setup need PMU/resctrl/HDFS)"

# ---- campaign output dir (shared by both run-big-batch passes) -------------
if [ -n "${CAMPAIGN_OUT:-}" ]; then
    OUT="$CAMPAIGN_OUT"
    [ -d "$OUT" ] || die "CAMPAIGN_OUT does not exist: $OUT"
    log "resuming into existing campaign dir: $OUT"
else
    OUT="$REPO_ROOT/results/${HOST_TAG}-campaign-$(date +%Y%m%d_%H%M%S)"
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$OUT"
fi

# ---- helpers ----------------------------------------------------------------
PASS=0; FAIL=0
run() {  # echo-and-run (honours --dry-run)
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY: $*"; return 0; fi
    "$@"
}
stage() {  # stage <name> <cmd...>  -- records pass/fail, never aborts
    local name="$1"; shift
    echo; echo "========== STAGE: $name =========="
    if run "$@"; then
        echo "========== OK: $name =========="; PASS=$((PASS + 1)); return 0
    fi
    local rc=$?
    echo "========== FAILED: $name (rc=$rc) =========="; FAIL=$((FAIL + 1)); return "$rc"
}

# Assert the runtime kernel knobs the IntP profilers need. Idempotent, no
# reboot. Mirrors bench/setup/setup-host.sh section 6 but applies LIVE values
# only -- persistence (/etc/sysctl.d, /etc/fstab) remains setup-host.sh's job.
# Without this: resctrl unmounted -> mbw/llcocc dead; kptr_restrict>0 ->
# SystemTap/eBPF kernel-symbol resolution fails.
ensure_runtime_kernel_config() {
    # resctrl mount -- backs the mbw + llcocc metrics.
    if grep -q resctrl /proc/filesystems 2>/dev/null; then
        if mountpoint -q /sys/fs/resctrl 2>/dev/null; then
            log "resctrl: already mounted at /sys/fs/resctrl"
        elif [ "$DRY_RUN" -eq 1 ]; then
            log "DRY: mount -t resctrl resctrl /sys/fs/resctrl"
        else
            mount -t resctrl resctrl /sys/fs/resctrl 2>/dev/null \
                && log "resctrl: mounted at /sys/fs/resctrl" \
                || warn "resctrl: mount failed -- mbw/llcocc will be unavailable"
        fi
    else
        warn "resctrl: not in /proc/filesystems (CONFIG_X86_CPU_RESCTRL?) -- mbw/llcocc unavailable"
    fi
    # perf_event_paranoid=-1 -- uncore IMC / perf_event_open counters.
    # kptr_restrict=0       -- kernel symbol resolution for SystemTap / eBPF.
    local knob val cur
    for knob in perf_event_paranoid:-1 kptr_restrict:0; do
        val="${knob##*:}"; knob="${knob%%:*}"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "DRY: echo $val > /proc/sys/kernel/$knob"; continue
        fi
        cur=$(cat "/proc/sys/kernel/$knob" 2>/dev/null || echo '?')
        if [ "$cur" = "$val" ]; then
            log "$knob: already $val"
        elif echo "$val" > "/proc/sys/kernel/$knob" 2>/dev/null; then
            log "$knob: $cur -> $val"
        else
            warn "$knob: could not set to $val (was $cur)"
        fi
    done
    return 0
}

hadoop_procs() { pgrep -af 'NameNode|DataNode|SecondaryNameNode|org\.apache\.spark\.deploy\.(master|worker)' 2>/dev/null; }

ensure_cluster_down() {
    [ "$SKIP_DAEMON_STOP" = "1" ] && { log "SKIP_DAEMON_STOP=1 -- not touching cluster state"; return 0; }
    log "bringing any running Hadoop/Spark daemons down before the stress-ng leg"
    run bash "$DIST_SETUP" stop || warn "setup-distributed-mode.sh stop returned non-zero (continuing)"
    [ "$DRY_RUN" -eq 1 ] && return 0
    sleep 2
    if hadoop_procs >/dev/null 2>&1; then
        warn "Hadoop/Spark daemons still alive after stop:"
        hadoop_procs >&2
        die "refusing to run the stress-ng leg with cluster daemons up (would contaminate measurements) -- stop them and retry"
    fi
    log "confirmed: no Hadoop/Spark daemons running"
}

# ---- banner -----------------------------------------------------------------
echo "==================================================================="
echo " IntP per-OS campaign"
echo "   host-tag      = $HOST_TAG"
echo "   variants      = $VARIANTS"
echo "   campaign out  = $OUT"
echo "   stress-ng     = reps=$REPS duration=${DURATION}s   (veth up, cluster DOWN)"
echo "   hibench       = size=$HIBENCH_SIZE (scale=$HIBENCH_SCALE) profile=$HIBENCH_PROFILE reps=$REPS"
echo "   netns         = $NETNS_NAME"
echo "   legacy mvn    = $LEGACY_MVN     dry-run = $DRY_RUN"
echo "==================================================================="

# ── Stage 0: runtime kernel config (resctrl mount, perf/kptr sysctls) ────────
if [ "$SKIP_KERNEL_CONFIG" = "1" ]; then
    log "SKIP_KERNEL_CONFIG=1 -- not asserting resctrl/sysctls (host assumed ready)"
else
    echo; echo "========== STAGE: runtime kernel config =========="
    if ensure_runtime_kernel_config; then
        echo "========== OK: runtime kernel config =========="; PASS=$((PASS + 1))
    else
        echo "========== FAILED: runtime kernel config =========="; FAIL=$((FAIL + 1))
    fi
fi

# ── Stage 1: veth-routing setup ──────────────────────────────────────────────
if [ "$SKIP_VETH" = "1" ]; then
    log "SKIP_VETH=1 -- skipping veth setup"
else
    stage "veth-routing setup (netns $NETNS_NAME)" \
        env INTP_NETNS_NAME="$NETNS_NAME" bash "$NETNS_SETUP" || warn "veth setup failed -- network workloads may read 0"
fi

# ── Stage 2: ensure the Hadoop/Spark cluster is DOWN ─────────────────────────
ensure_cluster_down

# ── Stage 3: STRESS-NG leg (veth routed, no cluster) ─────────────────────────
# run-big-batch pass A: stress-ng segment only, distributed mode OFF.
if [ "$SKIP_STRESS" = "1" ]; then
    log "SKIP_STRESS=1 -- skipping stress-ng leg"
else
    stage "stress-ng leg (variants=$VARIANTS)" \
        env RESUME_DIR="$OUT" \
            BENCH_VARIANTS="$VARIANTS" HIBENCH_VARIANTS="$VARIANTS" \
            RUN_STRESS_BENCH=1 RUN_HIBENCH=0 RUN_PLOTS=0 \
            INTP_DISTRIBUTED_MODE=0 INTP_NETNS_NAME="$NETNS_NAME" \
            REPS="$REPS" DURATION="$DURATION" \
            bash "$BIG_BATCH" \
        || warn "stress-ng leg reported failures -- see $OUT/big-batch.log"
fi

# ── Stage 4: bring up Hadoop + Spark + HiBench (ONLY now) ────────────────────
if [ "$SKIP_HIBENCH_SETUP" = "1" ]; then
    log "SKIP_HIBENCH_SETUP=1 -- assuming Hadoop/Spark/HiBench already provisioned"
else
    stage "install Hadoop CLI" \
        bash "$HADOOP_SETUP" || warn "hadoop-localmode setup failed"

    SPARK_ENV=(HADOOP_PROFILE="$HADOOP_PROFILE" HIBENCH_SCALE="$HIBENCH_SCALE")
    [ "$LEGACY_MVN" -eq 1 ] && SPARK_ENV+=(HIBENCH_MVN_DIRECT_VERSIONS=1)
    # Forward any per-leg build/Scala knobs the launcher (ub22run.sh / ub24run.sh)
    # exported. These pin the HiBench Maven/Scala build coordinates -- the
    # leg-specific surface that keeps the legacy (U22) HiBench compile clean
    # while both legs share the SAME Hadoop/Spark/HiBench VERSIONS. Each is
    # forwarded only when actually set, so setup-spark-hibench.sh's documented
    # defaults still apply when a launcher leaves it unset (U24 leg).
    for _k in SPARK_VERSION HIBENCH_REF HADOOP_VERSION SCALA_FULL_VERSION \
              KAFKA_VERSION KAFKA_BINARY_VERSION HIBENCH_MVN_EXTRA_ARGS; do
        [ -n "${!_k:-}" ] && SPARK_ENV+=("$_k=${!_k}")
    done
    stage "install + build Spark/HiBench (scale=$HIBENCH_SCALE)" \
        env "${SPARK_ENV[@]}" bash "$SPARK_SETUP" || warn "spark/hibench setup failed"

    # Distributed HDFS pseudo + Spark Standalone bound to the veth pair.
    stage "distributed-mode init"        bash "$DIST_SETUP" init        || warn "distributed init failed"
    stage "distributed-mode ssh-setup"   bash "$DIST_SETUP" ssh-setup   || warn "distributed ssh-setup failed"
    stage "distributed-mode start"       bash "$DIST_SETUP" start       || warn "distributed start failed"
    stage "distributed-mode smoke"       bash "$DIST_SETUP" smoke       || warn "distributed smoke test failed"
    stage "distributed-mode prepare-hdfs" bash "$DIST_SETUP" prepare-hdfs || warn "prepare-hdfs failed"
fi

# ── Stage 5: HIBENCH leg (veth routed, cluster up) ───────────────────────────
# run-big-batch pass B: HiBench segment only, distributed mode ON, same OUT.
# RUN_PLOTS=1 here renders figures for BOTH legs (bench-full/ + hibench/).
# Because RESUME_DIR="$OUT" is shared with pass A, run-big-batch passes --resume
# to the HiBench runner: a re-run reuses each profile's existing run-dir and
# fills only the missing/failed reps, instead of accumulating a SECOND run-dir
# per profile (which previously doubled reps to 24 after publish merged them).
if [ "$SKIP_HIBENCH" = "1" ]; then
    log "SKIP_HIBENCH=1 -- skipping HiBench leg"
else
    stage "hibench leg (variants=$VARIANTS, profile=$HIBENCH_PROFILE)" \
        env RESUME_DIR="$OUT" \
            BENCH_VARIANTS="$VARIANTS" HIBENCH_VARIANTS="$VARIANTS" \
            RUN_STRESS_BENCH=0 RUN_HIBENCH=1 RUN_PLOTS=1 \
            INTP_DISTRIBUTED_MODE=1 INTP_NETNS_NAME="$NETNS_NAME" \
            SKIP_SPARK_HIBENCH_SETUP=1 \
            HIBENCH_SIZE="$HIBENCH_SIZE" HIBENCH_PROFILE="$HIBENCH_PROFILE" \
            HIBENCH_REPS="$REPS" REPS="$REPS" \
            bash "$BIG_BATCH" \
        || warn "hibench leg reported failures -- see $OUT/big-batch.log"
fi

# ── Stage 6: tear the cluster back down ──────────────────────────────────────
if [ "$SKIP_DAEMON_STOP" != "1" ]; then
    stage "tear down Hadoop/Spark daemons" \
        bash "$DIST_SETUP" stop || warn "cluster teardown returned non-zero"
fi

# ── Stage 7: publish into sbac-results/ ──────────────────────────────────────
if [ "$SKIP_PUBLISH" = "1" ]; then
    log "SKIP_PUBLISH=1 -- skipping publish"
else
    stage "publish to sbac-results ($HOST_TAG)" \
        bash "$PUBLISH" "$OUT" "$HOST_TAG" || warn "publish step failed"
fi

echo
echo "==================================================================="
log "campaign finished -- stages PASS=$PASS FAIL=$FAIL"
log "campaign output : $OUT"
log "published under : $REPO_ROOT/sbac-results/ (leg: $HOST_TAG)"
echo "==================================================================="
[ "$FAIL" -eq 0 ]

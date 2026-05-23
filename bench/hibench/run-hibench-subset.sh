#!/usr/bin/env bash
# run-hibench-subset.sh — HiBench Spark subset with IntP profiler integration.
#
# For each workload (terasort, wordcount, pagerank, kmeans, bayes, dfsioe)
# the script launches each selected IntP variant as a background profiler,
# runs the Spark job, stops the profiler, and writes profiler.tsv in the same
# format as run-intp-bench.sh so the plotter can process HiBench results
# alongside stress-ng results.
#
# Usage:
#   sudo bash bench/hibench/run-hibench-subset.sh \
#     --variants v2,v3.1,v3 --size medium --profile both
#   sudo bash bench/hibench/run-hibench-subset.sh \
#     --variants v1,v2,v3.1,v3 --size medium --profile standard
#
# Output layout (mirrors run-intp-bench.sh: env/variant/stage/workload/rep):
#   out_root/<profile>-<size>-<ts>/
#     bare/<variant>/hibench/<workload>/
#       run.json            -- workload-level aggregate (per-rep series)
#       repN/
#         profiler.tsv      -- 7 IntP metrics + ts column for this rep
#         workload.log      -- Spark job stdout/stderr for this rep
#         run.json          -- per-rep timing, samples, status
#     aggregate-means.tsv   -- env, variant, stage, workload, rep, metrics
#                              (one row per profiler.tsv, schema-compatible
#                              with run-intp-bench.sh aggregate-means; stage
#                              column is 'hibench')
#     metadata.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/shared"

# Variant tool paths. Names match the variant IDs exactly (v1, v2, v3.1, …)
# to avoid the legacy V3/V4/V5/V6 numbering that no longer maps to anything.
V1_STP="$REPO_ROOT/variants/v1-stap-only/intp-resctrl.stp"
V1_HELPER="$SHARED_DIR/intp-resctrl-helper.sh"
V1_1_STP="$REPO_ROOT/variants/v1.1-stap-helper/intp-v1.1.stp"
V1_1_HELPER="$REPO_ROOT/variants/v1.1-stap-helper/intp-helper"
V0_2_TEMPLATE="$REPO_ROOT/variants/v0.2-legacy-bridge/intp.stp.template"
V0_2_GENERATOR="$REPO_ROOT/variants/v0.2-legacy-bridge/generate-stp.sh"
V0_2_RECAL_STP="$REPO_ROOT/variants/v0.2-legacy-bridge/intp.recal.stp"
V0_2_HELPER="$REPO_ROOT/variants/v0.2-legacy-bridge/intp-helper"
V2_BIN="$REPO_ROOT/variants/v2-hybrid-c/intp-hybrid"
V3_1_RUNNER="$REPO_ROOT/variants/v3.1-bpftrace/run-intp-bpftrace.sh"
V3_BIN="$REPO_ROOT/variants/v3-ebpf-ringbuf/intp-ebpf"
V3_2_BIN="$REPO_ROOT/variants/v3.2-ebpf-agg/intp-ebpf-agg"

# Defaults
SIZE="${SIZE:-medium}"
PROFILE="${PROFILE:-both}"
VARIANTS_CSV="${VARIANTS_CSV:-v2,v3.1,v3}"
WORKLOADS_CSV="${WORKLOADS_CSV:-all}"
OUT_ROOT="${OUT_ROOT:-/var/lib/hibench/runs}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
SPARK_HOME="${SPARK_HOME:-}"
# Deployment environment selector (mirrors run-intp-bench.sh --env values).
# Currently HiBench supports: bare, container-full, vm-full.
# host-observer modes (container, vm) and per-process in-guest (container-guest,
# vm-guest) are not meaningful for Spark jobs that drive HDFS+Spark themselves.
ENV_DEPLOY="${ENV_DEPLOY:-bare}"
INTP_FULL_IMAGE="${INTP_FULL_IMAGE:-intp-full:latest}"
INTP_FULL_VM_IMAGE="${INTP_FULL_VM_IMAGE:-}"
DRY_RUN=0
# Resume support (mirrors run-intp-bench.sh's per-rep skip contract). When set,
# run_subset_for_profile reuses an existing <profile>-<size>-<ts> run-dir under
# OUT_ROOT instead of minting a fresh timestamp, and reps whose profiler.tsv
# already has samples AND run.json status="ok" are skipped. Without this, a
# resumed campaign (run-os-campaign.sh always shares RESUME_DIR) accumulates a
# SECOND full run-dir per profile and doubles the rep count after publish merges
# them -- the "24 reps where 12 were intended" bug. Failed/empty reps are re-run.
RESUME="${RESUME:-0}"
INTERVAL=1
WARMUP=15                   # seconds to let Spark ramp before recording
MAX_WORKLOAD_DURATION=600   # max profiler window per Spark job (seconds)
# Memory-bandwidth ceiling (bytes/sec) used by v2/v3/v3.1/v3.2 to normalise
# mbw to a percentage. Empty here = derive it at startup via
# resolve_mem_bw_ceiling() (see below); an explicit env/CLI value wins.
#
# Why the script must resolve this rather than let the binary autodetect:
#   1. The binaries' built-in dmidecode autodetect (variants/*/detect/detect.c)
#      is unreliable on modern multi-channel DDR5 servers and silently falls
#      back to 51 GB/s (DDR4-3200 ×2ch).
#   2. The binaries do NOT convert units. --mem-bw-max-bps is bytes/sec, but
#      shared/intp-detect.sh reports INTP_MEM_BW_MBPS in MB/s. Passing the
#      MB/s number verbatim under-sizes the ceiling 1,000,000× — every mbw
#      sample then trips "exceeded ceiling" and the column is unusable.
# resolve_mem_bw_ceiling() reads intp-detect.sh and does the MB/s→B/s
# conversion (×1e6) in one place so neither trap can recur.
MEM_BW_MAX_BPS="${MEM_BW_MAX_BPS:-}"
LLC_SIZE_BYTES="${LLC_SIZE_BYTES:-}"
NIC_SPEED_BPS="${NIC_SPEED_BPS:-}"
# Spark executor/driver heap. Empty = auto-scale from --size via
# spark_memory_for_size(). The large/huge HiBench datasets -- kmeans in
# particular, which caches its samples RDD with MEMORY_ONLY -- OOM an 8g
# executor (the JVM exits with Spark's ExecutorExitCode.OOM=52 and the whole
# Spark job aborts). Env overrides win over the size-based default.
SPARK_EXECUTOR_MEMORY="${SPARK_EXECUTOR_MEMORY:-}"
SPARK_DRIVER_MEMORY="${SPARK_DRIVER_MEMORY:-}"
WORKLOAD_REPS=12            # Spark invocations per workload (paper campaign)
ELAPSED_CV_WARN_PCT=20      # warn when duration coefficient of variation reaches this percent
STAP_WAIT_MAX=30            # seconds to wait for stap intestbench to appear
# Process name that stap will filter for Spark JVM processes.
# Spark driver/executors all run as "java" on the host.
STAP_TARGET="${STAP_TARGET:-java}"

# stap module-accumulation guard (shared by v1/v1.1/v0.2)
STAP_RUN_COUNT=0
# INTP_BENCH_V3_DEEP_CLEANUP_EVERY kept as a deprecated alias for the old name.
STAP_DEEP_CLEANUP_EVERY="${INTP_BENCH_STAP_DEEP_CLEANUP_EVERY:-${INTP_BENCH_V3_DEEP_CLEANUP_EVERY:-5}}"
_ORIG_GOVERNORS=""
_ORIG_AUTOGROUP=""

# Per-run state (reset by start_profiler / stop_profiler)
PROFILER_PID=""
STAP_PID=""
STAP_COLLECTOR_PID=""
STRESSOR_PID=""
V1_1_HELPER_PID=""
ACTIVE_RESCTRL_HELPER=0

# Profile → stress-ng args. Empty = no co-runner.
# These run *concurrently* with Spark to inject controlled interference
# in a single-socket / local[*] setup where Spark itself can't generate
# enough pressure to exercise mbw / llcocc / etc. backends.
#
# Pressure mapping (HiBench-app ↔ stress-ng) — keep these names aligned with
# bench/run-intp-bench.sh app01..app15 so plots can pair real and synthetic:
#
#   axis      | hibench reference   | stress-ng profile     | metric
#   --------- | ------------------- | --------------------- | ------
#   cpu       | wordcount           | cpu-extreme           | cpu
#   mbw       | terasort            | mem-extreme           | mbw
#   llc       | kmeans              | cache-extreme         | llcocc/llcmr
#   disk      | bayes / dfsioe      | disk-extreme          | blk
#   netp      | dfsioe (HDFS RPC)   | netp-extreme          | netp
#   nets      | dfsioe (HDFS RPC)   | nets-extreme          | nets
#
PROFILE_STRESSNG_standard=""
PROFILE_STRESSNG_cpu_extreme="--cpu 8 --cpu-method matrixprod"
PROFILE_STRESSNG_mem_extreme="--vm 2 --vm-bytes 30% --vm-method all"
PROFILE_STRESSNG_cache_extreme="--cache 4 --cache-no-affinity"
PROFILE_STRESSNG_disk_extreme="--hdd 2 --hdd-bytes 4G --temp-path /var/tmp"
PROFILE_STRESSNG_netp_extreme="--netdev 4"
PROFILE_STRESSNG_nets_extreme="--sock 8 --sock-port 23440 --udp 4 --udp-port 23450"
VALID_PROFILES="standard cpu-extreme mem-extreme cache-extreme disk-extreme netp-extreme nets-extreme all-stress both"

VARIANTS=()
WORKLOADS=()

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

# Recursively SIGTERM/SIGKILL a PID and all its descendants. Needed because
# the profiler is launched as `{ printf; bin | awk; } > out &` — `$!` captures
# the wrapper subshell, and a plain `kill $!` leaves bin and awk as orphans
# that keep writing to `out` until --duration expires.
_kill_tree() {
    local sig="$1" root="$2"
    [ -n "$root" ] || return 0
    # BFS collect all descendants while still alive
    local frontier="$root"
    local all="$root"
    local depth=0
    while [ -n "$frontier" ] && [ $depth -lt 8 ]; do
        local next=""
        for p in $frontier; do
            local kids
            kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            [ -n "$kids" ] && { next="$next $kids"; all="$all $kids"; }
        done
        frontier="$next"
        depth=$((depth+1))
    done
    kill "-$sig" $all 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --variants CSV              IntP variants to run (default: v2,v3.1,v3)
                              Supported: v0.2,v1,v1.1,v2,v3.1,v3,v3.2
                              (v0/v0.1 are stress-ng-only and not run here)
                              Note: v0.2/v1.1 stap-side run in @system
                              (system-wide) mode for HiBench — see
                              _start_v1_1_profiler.
  --workloads CSV             Workloads to run (default: all)
                              'all' = the 6 paper workloads: terasort,wordcount,
                              pagerank,kmeans,bayes,dfsioe. sql_nweight is opt-in
                              (separate HiBench sql build) — name it explicitly.
  --size small|medium|large|huge|gigantic
                              HiBench dataset profile (default: medium).
                              Also scales the Spark executor/driver heap
                              (small/medium 8g, large 16g, huge 24g,
                              gigantic 32g) so big datasets don't OOM.
  --executor-memory SIZE      Override the size-scaled Spark executor heap
  --driver-memory SIZE        Override the size-scaled Spark driver heap
  --profile MODE              Co-runner mode (default: standard). One of:
                                standard       no co-runner (baseline)
                                cpu-extreme    stress-ng --cpu 8 (matrixprod)
                                mem-extreme    stress-ng --vm 2 --vm-bytes 30%
                                cache-extreme  stress-ng --cache 4
                                disk-extreme   stress-ng --hdd 2 --hdd-bytes 4G
                                netp-extreme   stress-ng --netdev 4
                                nets-extreme   stress-ng --sock 8 --udp 4 (loopback TCP/UDP)
                                both           standard + netp-extreme (legacy combo)
                                all-stress     full sweep: standard + cpu/mem/cache/disk/netp/nets
  --out-root DIR              Output root (default: $OUT_ROOT)
  --hibench-home DIR          HiBench installation (default: $HIBENCH_HOME)
  --spark-home DIR            Spark home override
  --interval N                Profiler sampling interval in seconds (default: $INTERVAL)
  --warmup N                  Seconds to let Spark ramp before recording (default: $WARMUP)
  --max-duration N            Max profiler window per job in seconds (default: $MAX_WORKLOAD_DURATION)
  --reps N                    Number of Spark invocations per workload (default: $WORKLOAD_REPS)
    --elapsed-cv-warn-pct N     Warn threshold for duration CV percent across reps (default: $ELAPSED_CV_WARN_PCT)
  --stap-target NAME          Process name for stap-variant filter
                              (v1/v1.1/v0.2; default: $STAP_TARGET)
  --mem-bw-max-bps N          Override detected memory-bandwidth ceiling (B/s)
  --llc-size-bytes N          Override detected LLC size (bytes)
  --nic-speed-bps N           Override detected NIC speed (B/s)
  --env MODE                  Deployment mode: bare | container-full | vm-full
                              (default: bare)
  --resume                    Reuse the existing <profile>-<size>-<ts> run-dir
                              under --out-root (instead of minting a new one)
                              and skip reps that already completed cleanly
                              (profiler.tsv has samples + run.json status=ok).
                              Failed/empty reps are re-run. Prevents the
                              double-run-dir / 24-rep accumulation on resume.
  --dry-run                   Print actions without executing
  -h, --help                  Show this help

Examples:
  sudo $0 --variants v2,v3.1,v3 --size medium --profile both
  sudo $0 --variants v1,v1.1,v2,v3.1,v3 --size medium --profile standard
  INTP_BENCH_STAP_DEEP_CLEANUP_EVERY=4 sudo $0 --variants v1 --size small
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --variants)      VARIANTS_CSV="$2"; shift 2 ;;
            --workloads)     WORKLOADS_CSV="$2"; shift 2 ;;
            --size)          SIZE="$2"; shift 2 ;;
            --profile)       PROFILE="$2"; shift 2 ;;
            --out-root)      OUT_ROOT="$2"; shift 2 ;;
            --hibench-home)  HIBENCH_HOME="$2"; shift 2 ;;
            --spark-home)    SPARK_HOME="$2"; shift 2 ;;
            --interval)      INTERVAL="$2"; shift 2 ;;
            --warmup)        WARMUP="$2"; shift 2 ;;
            --max-duration)  MAX_WORKLOAD_DURATION="$2"; shift 2 ;;
            --mem-bw-max-bps) MEM_BW_MAX_BPS="$2"; shift 2 ;;
            --llc-size-bytes) LLC_SIZE_BYTES="$2"; shift 2 ;;
            --nic-speed-bps)  NIC_SPEED_BPS="$2";  shift 2 ;;
            --reps)          WORKLOAD_REPS="$2"; shift 2 ;;
            --executor-memory) SPARK_EXECUTOR_MEMORY="$2"; shift 2 ;;
            --driver-memory)   SPARK_DRIVER_MEMORY="$2";   shift 2 ;;
            --elapsed-cv-warn-pct) ELAPSED_CV_WARN_PCT="$2"; shift 2 ;;
            --stap-target)   STAP_TARGET="$2"; shift 2 ;;
            --env)           ENV_DEPLOY="$2"; shift 2 ;;
            --resume)        RESUME=1; shift ;;
            --dry-run)       DRY_RUN=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$SIZE" in small|medium|large|huge|gigantic) ;; *) die "invalid --size: $SIZE" ;; esac
    case "$PROFILE" in
        standard|cpu-extreme|mem-extreme|cache-extreme|disk-extreme|netp-extreme|nets-extreme|both|all-stress) ;;
        *) die "invalid --profile: $PROFILE (valid: $VALID_PROFILES)" ;;
    esac
    case "$WORKLOAD_REPS" in ''|*[!0-9]*) die "invalid --reps: $WORKLOAD_REPS" ;; esac
    [ "$WORKLOAD_REPS" -ge 1 ] || die "--reps must be >= 1"
    case "$ELAPSED_CV_WARN_PCT" in ''|*[!0-9.]*|.*.*) die "invalid --elapsed-cv-warn-pct: $ELAPSED_CV_WARN_PCT" ;; esac

    local IFS=','
    read -r -a VARIANTS <<< "$VARIANTS_CSV"
    read -r -a WORKLOADS <<< "$WORKLOADS_CSV"
    unset IFS

    local w
    for w in "${WORKLOADS[@]}"; do
        case "$w" in
            all|terasort|wordcount|pagerank|kmeans|bayes|sql_nweight|dfsioe) ;;
            *) die "invalid --workloads entry: $w" ;;
        esac
    done

    if [ "${#WORKLOADS[@]}" -gt 1 ]; then
        for w in "${WORKLOADS[@]}"; do
            if [ "$w" = "all" ]; then
                die "--workloads cannot mix 'all' with specific workloads"
            fi
        done
    fi

    return 0
}

workload_selected() {
    local name="$1" w
    for w in "${WORKLOADS[@]}"; do
        # 'all' = the 6 canonical paper workloads. sql_nweight is NOT part of
        # 'all' (its HiBench sql module is a separate, optional build that the
        # campaign never ran); it must be requested explicitly by name.
        [ "$w" = "all" ] && [ "$name" != "sql_nweight" ] && return 0
        [ "$w" = "$name" ] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# V1 module-accumulation guard (same logic as run-intp-bench.sh)
# -----------------------------------------------------------------------------

stap_deep_cleanup() {
    local context="${1:-cleanup}"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY stap_deep_cleanup/$context"; return 0; }
    pkill -9 -f stapio  2>/dev/null || true
    pkill -9 -f staprun 2>/dev/null || true
    sleep 1
    local attempt mods
    for attempt in 1 2 3 4 5; do
        mods=$(lsmod | awk '/^stap_/ {print $1}')
        [ -z "$mods" ] && break
        for m in $mods; do rmmod "$m" 2>/dev/null || true; done
        sleep "$attempt"
    done
    local remaining
    remaining=$(lsmod | awk '/^stap_/ {print $1}' | wc -l)
    if [ "$remaining" -gt 0 ]; then
        warn "[stap_deep_cleanup/$context] $remaining stap_ module(s) still loaded"
    else
        log "[stap_deep_cleanup/$context] OK (0 stap_ modules)"
    fi
}

start_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=1; return 0; }
    [ -x "$V1_HELPER" ] && "$V1_HELPER" start >/dev/null 2>&1 || true
    ACTIVE_RESCTRL_HELPER=1
}

stop_resctrl_helper() {
    [ "$ACTIVE_RESCTRL_HELPER" -eq 0 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && { ACTIVE_RESCTRL_HELPER=0; return 0; }
    [ -x "$V1_HELPER" ] && "$V1_HELPER" stop >/dev/null 2>&1 || true
    ACTIVE_RESCTRL_HELPER=0
}

setup_cpu_env() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local gov_path gov count=0
    for gov_path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$gov_path" ] || continue
        gov=$(cat "$gov_path" 2>/dev/null || echo unknown)
        _ORIG_GOVERNORS="${_ORIG_GOVERNORS}${gov_path}=${gov}
"
        echo performance > "$gov_path" 2>/dev/null || true
        count=$((count+1))
    done
    if [ "$count" -gt 0 ]; then
        local first_gov
        first_gov=$(printf '%s\n' "$_ORIG_GOVERNORS" | head -1 | cut -d= -f2)
        log "[cpu_env] governor → performance (was: $first_gov on $count cpus)"
    else
        log "[cpu_env] no cpufreq sysfs — governor unchanged"
    fi
    _ORIG_AUTOGROUP=$(cat /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || echo 1)
    if [ "$_ORIG_AUTOGROUP" = "1" ]; then
        echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
        log "[cpu_env] sched_autogroup_enabled → 0"
    fi
}

restore_cpu_env() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    local entry gov_path gov
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        gov_path="${entry%%=*}"
        gov="${entry#*=}"
        [ -f "$gov_path" ] && echo "$gov" > "$gov_path" 2>/dev/null || true
    done <<< "$_ORIG_GOVERNORS"
    [ -n "$_ORIG_GOVERNORS" ] && log "[cpu_env] governor restored"
    [ -n "$_ORIG_AUTOGROUP" ] && echo "$_ORIG_AUTOGROUP" > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Profiler launchers
# start_profiler  variant outfile  → sets PROFILER_PID / STAP_PID / STAP_COLLECTOR_PID
#                                    returns 1 on startup failure (caller skips run)
# stop_profiler   variant outfile  → kills bg processes, V1 cleans modules
# -----------------------------------------------------------------------------

start_profiler() {
    local variant="$1" outfile="$2"
    PROFILER_PID="" STAP_PID="" STAP_COLLECTOR_PID="" V1_1_HELPER_PID="" V0_2_HELPER_PID=""

    case "$variant" in
        v0.2) _start_v0_2_profiler "$outfile" ;;
        v1)   _start_v1_profiler "$outfile" ;;
        v1.1) _start_v1_1_profiler "$outfile" ;;
        v2)   _start_binary_profiler v2 "$outfile" ;;
        v3.1) _start_v3_1_profiler "$outfile" ;;
        v3)   _start_binary_profiler v3 "$outfile" ;;
        v3.2) _start_binary_profiler v3.2 "$outfile" ;;
        *)    warn "unknown variant $variant"; return 1 ;;
    esac
}

stop_profiler() {
    local variant="$1" outfile="$2"

    # Run cleanup with errexit OFF: backgrounded jobs that die via SIGKILL
    # produce 137 exit codes that bash's job table reports asynchronously.
    # Under `set -e` + pipefail, those notifications can abort the script
    # unpredictably (we lost v3.1 and v3 because the script exited right
    # after v2's wrapper was killed). The cleanup phase is best-effort
    # already — there's nothing to abort on.
    set +e

    if [ -n "$PROFILER_PID" ]; then
        local pre_kids
        pre_kids=$(pgrep -P "$PROFILER_PID" 2>/dev/null | tr '\n' ' ')
        log "  [stop_profiler] PROFILER_PID=$PROFILER_PID children='${pre_kids}'"
        _kill_tree KILL "$PROFILER_PID"
        pkill -KILL -f 'intp-hybrid|intp-ebpf|intp-ebpf-agg|run-intp-bpftrace|orchestrator/aggregator\.py' 2>/dev/null
        pkill -KILL -f 'bpftrace -q' 2>/dev/null
        local k=0
        while [ $k -lt 8 ] && kill -0 "$PROFILER_PID" 2>/dev/null; do
            sleep 0.25; k=$((k + 1))
        done
        PROFILER_PID=""
        log "  [stop_profiler] cleaned (polled=${k}/8)"
    fi

    # Kill V1 collector loop tree
    if [ -n "$STAP_COLLECTOR_PID" ]; then
        _kill_tree TERM "$STAP_COLLECTOR_PID"
        sleep 0.5
        _kill_tree KILL "$STAP_COLLECTOR_PID"
        wait "$STAP_COLLECTOR_PID" 2>/dev/null || true
        STAP_COLLECTOR_PID=""
    fi

    # Kill V1 stap tree
    if [ -n "$STAP_PID" ]; then
        _kill_tree TERM "$STAP_PID"
        sleep 0.5
        _kill_tree KILL "$STAP_PID"
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
    fi

    # V1.1 helper cleanup (intp-helper userspace process feeding /tmp/intp-hw-data)
    if [ -n "$V1_1_HELPER_PID" ]; then
        kill -TERM "$V1_1_HELPER_PID" 2>/dev/null || true
        local k1=0
        while [ $k1 -lt 8 ] && kill -0 "$V1_1_HELPER_PID" 2>/dev/null; do
            sleep 0.25; k1=$((k1 + 1))
        done
        kill -KILL "$V1_1_HELPER_PID" 2>/dev/null || true
        wait "$V1_1_HELPER_PID" 2>/dev/null || true
        V1_1_HELPER_PID=""
    fi

    # V0.2 helper cleanup (same architecture as V1.1, separate /tmp data file)
    if [ -n "$V0_2_HELPER_PID" ]; then
        kill -TERM "$V0_2_HELPER_PID" 2>/dev/null || true
        local k2=0
        while [ $k2 -lt 8 ] && kill -0 "$V0_2_HELPER_PID" 2>/dev/null; do
            sleep 0.25; k2=$((k2 + 1))
        done
        kill -KILL "$V0_2_HELPER_PID" 2>/dev/null || true
        wait "$V0_2_HELPER_PID" 2>/dev/null || true
        V0_2_HELPER_PID=""
    fi

    if [ "$variant" = "v1" ] || [ "$variant" = "v1.1" ] || [ "$variant" = "v0.2" ]; then
        stap_deep_cleanup "post-hibench-${outfile##*/}"
    fi

    set -e
    return 0
}

_start_v1_profiler() {
    local outfile="$1"

    # Pre-run cleanup + periodic deep pause
    STAP_RUN_COUNT=$((STAP_RUN_COUNT + 1))
    stap_deep_cleanup "pre-hibench-run-${STAP_RUN_COUNT}"
    if [ "$STAP_RUN_COUNT" -gt 1 ] && [ $(( (STAP_RUN_COUNT - 1) % STAP_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
        log "[v1] periodic deep pause at hibench run ${STAP_RUN_COUNT} — sleeping 8s"
        [ "$DRY_RUN" -eq 0 ] && sleep 8
    fi
    start_resctrl_helper

    if [ "$DRY_RUN" -eq 1 ]; then
        {
            printf '# variant=v1 hibench target=%s\n' "$STAP_TARGET"
            printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        } > "$outfile"
        STAP_PID=""   # dry-run: no real process to track
        return 0
    fi

    local stap_log="${outfile%.tsv}.stap.log"
    stap --suppress-handler-errors -g \
        -B CONFIG_MODVERSIONS=y \
        -DMAXSKIPPED=1000000 \
        -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
        -DSTP_OVERLOAD_INTERVAL=1000000000LL \
        "$V1_STP" "$STAP_TARGET" > "$stap_log" 2>&1 &
    STAP_PID=$!

    # Wait for intestbench to appear (stap compile + module load)
    local intestbench=""
    for _ in $(seq 1 "$STAP_WAIT_MAX"); do
        intestbench=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1)
        [ -n "$intestbench" ] && break
        sleep 1
    done

    if [ -z "$intestbench" ]; then
        warn "[v1] intestbench did not appear after ${STAP_WAIT_MAX}s for HiBench"
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
        stap_deep_cleanup "startup-timeout"
        return 1
    fi

    {
        printf '# variant=v1 hibench target=%s\n' "$STAP_TARGET"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
    } > "$outfile"

    # Background collector: poll intestbench and append timestamped rows
    local ib="$intestbench" of="$outfile" iv="$INTERVAL"
    (
        while true; do
            local line ts
            ts=$(date +%s.%N)
            line=$(grep -E '^[0-9]' "$ib" 2>/dev/null | tail -1 || true)
            [ -n "$line" ] && printf '%s\t%s\n' "$ts" "$line" >> "$of"
            sleep "$iv"
        done
    ) &
    STAP_COLLECTOR_PID=$!
}

_start_v1_1_profiler() {
    # V1.1 = stap script + userspace helper. Helper owns the RCU-unsafe
    # operations (uncore IMC perf events, resctrl mon_group); the stap
    # script reads /tmp/intp-hw-data via a procfs read probe.
    #
    # HiBench-specific: the stap side runs in SYSTEM-WIDE mode (@1="@system"
    # sentinel). HiBench's Spark Driver is launched AFTER stap attach, often
    # inside netns intp-app, so per-process probes (process(@1).begin and
    # [pid()] in mpids gates) miss it. The system-wide branch in intp-v1.1.stp
    # drops all PID filtering and matches the semantics V2 / V3 / V3.1 already
    # use for HiBench. The helper still receives the comm pattern (e.g. "java")
    # because resctrl mon_group enrollment scans /proc/*/comm — that part
    # works fine across netns since PID namespace is shared with the host.
    local outfile="$1"

    STAP_RUN_COUNT=$((STAP_RUN_COUNT + 1))
    stap_deep_cleanup "pre-hibench-v1.1-run-${STAP_RUN_COUNT}"
    if [ "$STAP_RUN_COUNT" -gt 1 ] && [ $(( (STAP_RUN_COUNT - 1) % STAP_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
        log "[v1.1] periodic deep pause at hibench run ${STAP_RUN_COUNT} — sleeping 8s"
        [ "$DRY_RUN" -eq 0 ] && sleep 8
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        {
            printf '# variant=v1.1 hibench target=%s helper=%s mode=@system\n' "@system" "$STAP_TARGET"
            printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        } > "$outfile"
        STAP_PID=""   # dry-run: no real process to track
        return 0
    fi

    if [ ! -x "$V1_1_HELPER" ]; then
        warn "[v1.1] helper not built: $V1_1_HELPER"
        return 1
    fi

    # Launch helper first; it primes /tmp/intp-hw-data with the first
    # uncore-IMC + resctrl reading before stap attaches.
    local helper_log="${outfile%.tsv}.helper.log"
    rm -f /tmp/intp-hw-data
    "$V1_1_HELPER" "$STAP_TARGET" > "$helper_log" 2>&1 &
    V1_1_HELPER_PID=$!
    sleep 0.3

    # Calibrate v1.1's nic_bytes_per_sec from intp-detect.sh so the netphy
    # report normalises against the actual NIC line rate, not a hardcoded
    # 1 GbE constant. Passed via stap -G; if detect fails the script keeps
    # its 125000000 default.
    local v1_1_extra=()
    local detect_out
    detect_out="$("$REPO_ROOT/shared/intp-detect.sh" 2>/dev/null || true)"
    # shellcheck disable=SC2046
    eval "$(echo "$detect_out" | grep -E '^INTP_NIC_SPEED_MBPS=' || true)"
    if [ -n "${INTP_NIC_SPEED_MBPS:-}" ] && [ "$INTP_NIC_SPEED_MBPS" -gt 0 ] 2>/dev/null; then
        v1_1_extra+=(-G "nic_bytes_per_sec=$((INTP_NIC_SPEED_MBPS * 125000))")
    fi

    local stap_log="${outfile%.tsv}.stap.log"
    stap --suppress-handler-errors -g \
        -B CONFIG_MODVERSIONS=y \
        -DMAXSKIPPED=1000000 \
        -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
        -DSTP_OVERLOAD_INTERVAL=1000000000LL \
        "${v1_1_extra[@]}" \
        "$V1_1_STP" "@system" > "$stap_log" 2>&1 &
    STAP_PID=$!

    local intestbench=""
    for _ in $(seq 1 "$STAP_WAIT_MAX"); do
        intestbench=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1)
        [ -n "$intestbench" ] && break
        sleep 1
    done

    if [ -z "$intestbench" ]; then
        warn "[v1.1] intestbench did not appear after ${STAP_WAIT_MAX}s for HiBench"
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
        kill "$V1_1_HELPER_PID" 2>/dev/null || true
        wait "$V1_1_HELPER_PID" 2>/dev/null || true
        V1_1_HELPER_PID=""
        stap_deep_cleanup "v1.1-startup-timeout"
        return 1
    fi

    {
        printf '# variant=v1.1 hibench mode=@system helper=%s\n' "$STAP_TARGET"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
    } > "$outfile"

    local ib="$intestbench" of="$outfile" iv="$INTERVAL"
    (
        while true; do
            local line ts
            ts=$(date +%s.%N)
            line=$(grep -E '^[0-9]' "$ib" 2>/dev/null | tail -1 || true)
            [ -n "$line" ] && printf '%s\t%s\n' "$ts" "$line" >> "$of"
            sleep "$iv"
        done
    ) &
    STAP_COLLECTOR_PID=$!
}

_start_v0_2_profiler() {
    # V0.2 = V0-faithful stap + userspace helper, targeting kernel 5.15 GA.
    # Same architecture as V1.1, with two differences:
    #   1. The .stp script is regenerated per-run from intp.stp.template by
    #      generate-stp.sh, which substitutes calibration constants from
    #      intp-detect.sh output (DRAM bw, L3 size, IMC PMU type).
    #   2. Helper writes to /tmp/intp-v0.2-hw-data (V1.1 uses /tmp/intp-hw-data),
    #      so the two variants' helpers can coexist conceptually.
    # HiBench-specific: stap runs in SYSTEM-WIDE mode ("@system") — same
    # rationale as V1.1: HiBench's Spark Driver is launched after stap attach,
    # often inside netns intp-app, so per-process probes miss it.
    local outfile="$1"

    STAP_RUN_COUNT=$((STAP_RUN_COUNT + 1))
    stap_deep_cleanup "pre-hibench-v0.2-run-${STAP_RUN_COUNT}"
    if [ "$STAP_RUN_COUNT" -gt 1 ] && [ $(( (STAP_RUN_COUNT - 1) % STAP_DEEP_CLEANUP_EVERY )) -eq 0 ]; then
        log "[v0.2] periodic deep pause at hibench run ${STAP_RUN_COUNT} — sleeping 8s"
        [ "$DRY_RUN" -eq 0 ] && sleep 8
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        {
            printf '# variant=v0.2 hibench target=%s helper=%s mode=@system\n' "@system" "$STAP_TARGET"
            printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        } > "$outfile"
        STAP_PID=""   # dry-run: no real process to track
        return 0
    fi

    if [ ! -x "$V0_2_GENERATOR" ]; then
        warn "[v0.2] generator not executable: $V0_2_GENERATOR"
        return 1
    fi
    if [ ! -x "$V0_2_HELPER" ]; then
        warn "[v0.2] helper not built: $V0_2_HELPER"
        return 1
    fi

    # Regenerate the calibrated stp script from template + intp-detect.sh.
    local kv_log="${outfile%.tsv}.v0.2-calibration.kv"
    if ! "$V0_2_GENERATOR" > "$kv_log" 2>"${kv_log%.kv}.err"; then
        warn "[v0.2] generate-stp.sh failed (rc=$?); see ${kv_log%.kv}.err"
        return 1
    fi

    # Capture IMC PMU range / DRAM bw / L3 size for the helper. intp-detect.sh
    # filters out firmware-managed `uncore_imc_free_running_*` pseudos (whose
    # types — 81-84 on SPR Xeon Gold 5412U — are not openable via the same
    # perf_event_open path) and emits INTP_IMC_PMU_TYPE_{FIRST,LAST} as the
    # usable range. We forward both to the helper so it iterates every real
    # channel; without _FIRST/_LAST the helper falls back to single-type and
    # undercounts mbw by channel_count×. Explicit parent-env overrides
    # (INTP_HELPER_IMC_PMU_TYPE_{FIRST,LAST}) still win — see helper docs.
    local detect_out
    detect_out="$("$REPO_ROOT/shared/intp-detect.sh" 2>/dev/null || true)"
    # shellcheck disable=SC2046
    eval "$(echo "$detect_out" | grep -E '^INTP_[A-Z0-9_]+=' || true)"

    local helper_log="${outfile%.tsv}.helper.log"
    rm -f /tmp/intp-v0.2-hw-data
    INTP_HELPER_DRAM_BW_MBPS="${INTP_MEM_BW_MBPS:-}" \
    INTP_HELPER_L3_SIZE_KB="${INTP_LLC_SIZE_KB:-}" \
    INTP_HELPER_IMC_PMU_TYPE="${INTP_IMC_PMU_TYPE:-}" \
    INTP_HELPER_IMC_PMU_TYPE_FIRST="${INTP_HELPER_IMC_PMU_TYPE_FIRST:-${INTP_IMC_PMU_TYPE_FIRST:-}}" \
    INTP_HELPER_IMC_PMU_TYPE_LAST="${INTP_HELPER_IMC_PMU_TYPE_LAST:-${INTP_IMC_PMU_TYPE_LAST:-}}" \
    INTP_HELPER_DATA_FILE="/tmp/intp-v0.2-hw-data" \
        "$V0_2_HELPER" "$STAP_TARGET" > "$helper_log" 2>&1 &
    V0_2_HELPER_PID=$!
    sleep 0.3

    local stap_log="${outfile%.tsv}.stap.log"
    stap --suppress-handler-errors -g \
        -B CONFIG_MODVERSIONS=y \
        -DMAXSKIPPED=1000000 \
        -DSTP_OVERLOAD_THRESHOLD=2000000000LL \
        -DSTP_OVERLOAD_INTERVAL=1000000000LL \
        "$V0_2_RECAL_STP" "@system" > "$stap_log" 2>&1 &
    STAP_PID=$!

    local intestbench=""
    for _ in $(seq 1 "$STAP_WAIT_MAX"); do
        intestbench=$(find /proc/systemtap -name intestbench 2>/dev/null | head -1)
        [ -n "$intestbench" ] && break
        sleep 1
    done

    if [ -z "$intestbench" ]; then
        warn "[v0.2] intestbench did not appear after ${STAP_WAIT_MAX}s for HiBench"
        kill "$STAP_PID" 2>/dev/null || true
        wait "$STAP_PID" 2>/dev/null || true
        STAP_PID=""
        kill "$V0_2_HELPER_PID" 2>/dev/null || true
        wait "$V0_2_HELPER_PID" 2>/dev/null || true
        V0_2_HELPER_PID=""
        stap_deep_cleanup "v0.2-startup-timeout"
        return 1
    fi

    {
        printf '# variant=v0.2 hibench mode=@system helper=%s\n' "$STAP_TARGET"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
    } > "$outfile"

    local ib="$intestbench" of="$outfile" iv="$INTERVAL"
    (
        while true; do
            local line ts
            ts=$(date +%s.%N)
            line=$(grep -E '^[0-9]' "$ib" 2>/dev/null | tail -1 || true)
            [ -n "$line" ] && printf '%s\t%s\n' "$ts" "$line" >> "$of"
            sleep "$iv"
        done
    ) &
    STAP_COLLECTOR_PID=$!
}

_start_binary_profiler() {
    local variant="$1" outfile="$2"
    local bin log args=()

    case "$variant" in
        v2)   bin="$V2_BIN" ;;
        v3)   bin="$V3_BIN" ;;
        v3.2) bin="$V3_2_BIN" ;;
    esac
    log="${outfile%.tsv}.${variant}.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=%s hibench\n' "$variant" > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=""   # dry-run: no real process to track
        return 0
    }

    args=(--interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --output tsv)
    # V3.2 has a trailing mbw_raw_mbps column by default; suppress it
    # so the captured TSV keeps the canonical 7-column shape the rest
    # of the hibench pipeline expects.
    [ "$variant" = "v3.2" ] && args+=(--no-raw-mbw)
    [ -n "$MEM_BW_MAX_BPS" ] && args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    [ -n "$LLC_SIZE_BYTES" ] && args+=(--llc-size-bytes "$LLC_SIZE_BYTES")
    [ -n "$NIC_SPEED_BPS" ]  && args+=(--nic-speed-bps  "$NIC_SPEED_BPS")
    {
        printf '# variant=%s hibench\n' "$variant"
        "$bin" "${args[@]}" 2>"$log" \
            | awk '/^#/||/^netp/{print; fflush(); next} {print systime() "\t" $0; fflush()}'
    } > "$outfile" &
    PROFILER_PID=$!
}

_start_v3_1_profiler() {
    local outfile="$1"
    local log="${outfile%.tsv}.v3.1.log"

    [ "$DRY_RUN" -eq 1 ] && {
        printf '# variant=v3.1 hibench\n' > "$outfile"
        printf 'ts\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n' >> "$outfile"
        PROFILER_PID=""   # dry-run: no real process to track
        return 0
    }

    local v3_1_args=(--interval "$INTERVAL" --duration "$MAX_WORKLOAD_DURATION" --header)
    [ -n "$MEM_BW_MAX_BPS" ] && v3_1_args+=(--mem-bw-max-bps "$MEM_BW_MAX_BPS")
    [ -n "$LLC_SIZE_BYTES" ] && v3_1_args+=(--llc-size-bytes "$LLC_SIZE_BYTES")
    [ -n "$NIC_SPEED_BPS" ]  && v3_1_args+=(--nic-speed-bps  "$NIC_SPEED_BPS")
    {
        printf '# variant=v3.1 hibench\n'
        "$V3_1_RUNNER" "${v3_1_args[@]}" 2>"$log" \
            | awk '/^#/||/^netp/{print; fflush(); next} {print systime() "\t" $0; fflush()}'
    } > "$outfile" &
    PROFILER_PID=$!
}

# -----------------------------------------------------------------------------
# Spark runner
# -----------------------------------------------------------------------------

resolve_runner() {
    local first="$1"
    local cand
    for cand in "$@"; do
        [ -x "$HIBENCH_HOME/$cand" ] && { printf '%s\n' "$HIBENCH_HOME/$cand"; return 0; }
    done
    [ "$DRY_RUN" -eq 1 ] && { warn "dry-run: runner not found, using $HIBENCH_HOME/$first"; printf '%s\n' "$HIBENCH_HOME/$first"; return 0; }
    return 1
}

# Echo "<executor_heap> <driver_heap>" for the active --size. Bigger datasets
# need a bigger executor JVM heap or the workload OOMs (see kmeans note on
# SPARK_EXECUTOR_MEMORY above). Env overrides SPARK_EXECUTOR_MEMORY /
# SPARK_DRIVER_MEMORY (or --executor-memory / --driver-memory) win.
spark_memory_for_size() {
    local exec_mem drv_mem
    case "$SIZE" in
        small)    exec_mem=8g  ; drv_mem=8g  ;;
        medium)   exec_mem=8g  ; drv_mem=8g  ;;
        large)    exec_mem=16g ; drv_mem=16g ;;   # paper campaign default
        huge)     exec_mem=24g ; drv_mem=16g ;;
        gigantic) exec_mem=32g ; drv_mem=24g ;;
        *)        exec_mem=8g  ; drv_mem=8g  ;;
    esac
    [ -n "$SPARK_EXECUTOR_MEMORY" ] && exec_mem="$SPARK_EXECUTOR_MEMORY"
    [ -n "$SPARK_DRIVER_MEMORY" ]   && drv_mem="$SPARK_DRIVER_MEMORY"
    printf '%s %s\n' "$exec_mem" "$drv_mem"
}

spark_env_for_profile() {
    local mode="$1"
    local local_dir="/var/lib/hibench/spark-local/$mode"
    mkdir -p "$local_dir" 2>/dev/null || { local_dir="/tmp/hibench-spark-local/$mode"; mkdir -p "$local_dir"; }

    local exec_mem drv_mem
    read -r exec_mem drv_mem <<< "$(spark_memory_for_size)"

    # All profiles use the same Spark settings now: the *-extreme profiles
    # differentiate themselves via the stress-ng co-runner, not Spark config.
    # (The legacy netp-extreme partition bump had no effect in local[*] mode.)
    # Executor/driver heap scale with --size via spark_memory_for_size().
    printf 'export SPARK_LOCAL_DIRS=%s\nexport SPARK_SUBMIT_OPTS="%s"\n' \
        "$local_dir" \
        "-Dspark.sql.shuffle.partitions=400 -Dspark.default.parallelism=400 -Dspark.shuffle.spill=true -Dspark.executor.instances=4 -Dspark.executor.cores=4 -Dspark.executor.memory=$exec_mem -Dspark.driver.memory=$drv_mem"
}

# Resolve stress-ng args for a given profile name.
# Hyphen → underscore for variable lookup (bash assoc-array workaround).
stressor_args_for_profile() {
    local mode="$1"
    case "$mode" in
        standard)       echo "" ;;
        cpu-extreme)    echo "$PROFILE_STRESSNG_cpu_extreme" ;;
        mem-extreme)    echo "$PROFILE_STRESSNG_mem_extreme" ;;
        cache-extreme)  echo "$PROFILE_STRESSNG_cache_extreme" ;;
        disk-extreme)   echo "$PROFILE_STRESSNG_disk_extreme" ;;
        netp-extreme)   echo "$PROFILE_STRESSNG_netp_extreme" ;;
        nets-extreme)   echo "$PROFILE_STRESSNG_nets_extreme" ;;
        *)              echo "" ;;
    esac
}

# Start a stress-ng co-runner for the given profile. Sets STRESSOR_PID.
# Runs concurrently with Spark+profiler so the IntP variants can be
# evaluated on their ability to *detect* injected interference.
start_stressor() {
    local mode="$1" outdir="$2"
    STRESSOR_PID=""
    local args
    args="$(stressor_args_for_profile "$mode")"
    [ -z "$args" ] && return 0

    if ! command -v stress-ng >/dev/null 2>&1; then
        warn "[stressor/$mode] stress-ng not installed — running without co-runner"
        return 0
    fi

    [ "$DRY_RUN" -eq 1 ] && {
        log "  DRY: stress-ng $args"
        STRESSOR_PID=""   # dry-run: no real process to track
        return 0
    }

    local sl="$outdir/stressor.log"
    # shellcheck disable=SC2086
    stress-ng $args --metrics-brief > "$sl" 2>&1 &
    STRESSOR_PID=$!
    log "  [stressor/$mode] started PID=$STRESSOR_PID  args='$args'"
    sleep 2  # let stress-ng ramp before profiler starts
}

stop_stressor() {
    [ -n "$STRESSOR_PID" ] || return 0
    # Best-effort cleanup with errexit OFF (same reasoning as stop_profiler).
    set +e
    _kill_tree KILL "$STRESSOR_PID"
    pkill -KILL -f 'stress-ng' 2>/dev/null
    log "  [stressor] stopped"
    STRESSOR_PID=""
    set -e
}

set_hibench_size() {
    local conf="$HIBENCH_HOME/conf/hibench.conf"
    [ "$DRY_RUN" -eq 1 ] && [ ! -f "$conf" ] && { warn "dry-run: skipping size config"; return 0; }
    [ -f "$conf" ] || die "missing $conf"
    case "$SIZE" in
        small)    sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             tiny/'     "$conf" || true ;;
        medium)   sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             small/'    "$conf" || true ;;
        large)    sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             large/'    "$conf" || true ;;
        huge)     sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             huge/'     "$conf" || true ;;
        gigantic) sed -i 's/^hibench.scale.profile.*/hibench.scale.profile             gigantic/' "$conf" || true ;;
    esac
}

# Scale the Spark executor/driver heap in HiBench's spark.conf to match --size.
# This is the channel HiBench's load_config.py reads (it whitelists
# spark.executor.memory / spark.driver.memory into the generated
# --properties-file), so it applies in both local and distributed mode.
set_spark_memory() {
    local conf="$HIBENCH_HOME/conf/spark.conf"
    local exec_mem drv_mem
    read -r exec_mem drv_mem <<< "$(spark_memory_for_size)"
    if [ ! -f "$conf" ]; then
        [ "$DRY_RUN" -eq 1 ] || warn "missing $conf -- Spark heap not scaled (size=$SIZE)"
        return 0
    fi
    if grep -q '^spark.executor.memory' "$conf"; then
        sed -i "s/^spark.executor.memory.*/spark.executor.memory             $exec_mem/" "$conf" || true
    else
        printf 'spark.executor.memory             %s\n' "$exec_mem" >> "$conf"
    fi
    if grep -q '^spark.driver.memory' "$conf"; then
        sed -i "s/^spark.driver.memory.*/spark.driver.memory               $drv_mem/" "$conf" || true
    else
        printf 'spark.driver.memory               %s\n' "$drv_mem" >> "$conf"
    fi
    log "Spark heap: executor=$exec_mem driver=$drv_mem (size=$SIZE) -> $conf"
}

# -----------------------------------------------------------------------------
# Per-workload runner: one variant × one workload
# -----------------------------------------------------------------------------

# Dispatcher for full-deployment modes (container-full, vm-full).
# Runs HiBench Spark workload + profiler INSIDE one container/VM. Stressor
# runs alongside on the host (intentional — keeps the synthetic-stress
# antagonist as an external pressure source rather than coupling it to
# the deployment unit).
run_workload_full_deploy() {
    local mode="$1" variant="$2" workload_name="$3" outdir="$4" profile_mode="$5"
    local profiler_tsv="$outdir/profiler.tsv"
    local workload_log="$outdir/workload.log"
    mkdir -p "$outdir"
    local cname="intp-hibench-${mode}-${variant}-${workload_name}-${profile_mode}-$$"

    start_stressor "$profile_mode" "$outdir"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  DRY: [$mode] intp-entrypoint run-hibench $variant $workload_name -> $outdir"
        : > "$profiler_tsv"; echo 0 > "$profiler_tsv.samples"
        stop_stressor
        return 0
    fi

    case "$mode" in
        container-full)
            if ! docker image inspect "$INTP_FULL_IMAGE" >/dev/null 2>&1; then
                warn "  [$mode] image '$INTP_FULL_IMAGE' missing — build with bench/deploy/build-full-image.sh"
                stop_stressor; return 1
            fi
            local hibench_workload
            hibench_workload=$(printf '%s' "$workload_name" | sed 's|_|/|')
            docker run --rm --name "$cname" \
                --network host \
                --cap-add SYS_ADMIN --cap-add SYS_RESOURCE --cap-add SYS_NICE \
                --cap-add NET_ADMIN --cap-add CAP_PERFMON --cap-add CAP_BPF \
                -v "$REPO_ROOT:/opt/intp:ro" \
                -v "$outdir:/opt/results" \
                -v /sys/kernel/btf:/sys/kernel/btf:ro \
                -v /sys/fs/resctrl:/sys/fs/resctrl \
                -e "INTP_DURATION=$MAX_WORKLOAD_DURATION" \
                -e "INTP_INTERVAL=$INTERVAL" \
                "$INTP_FULL_IMAGE" \
                bash -lc "intp-entrypoint start-hdfs && \
                          /opt/HiBench/bin/workloads/${hibench_workload}/prepare/prepare.sh > /opt/results/prepare.log 2>&1 && \
                          intp-entrypoint run-hibench $variant $hibench_workload && \
                          intp-entrypoint stop-hdfs" \
                > "$workload_log" 2>&1 \
                || warn "  [$mode] container exited non-zero — see $workload_log"
            ;;
        vm-full)
            warn "  [vm-full] HiBench-in-VM is gated behind a baked qcow2 (build-full-vm.sh); falling back to skip"
            : > "$profiler_tsv"; echo 0 > "$profiler_tsv.samples"
            ;;
    esac
    stop_stressor
    awk '/^[0-9]/{n++}END{print n+0}' "$profiler_tsv" > "$profiler_tsv.samples" 2>/dev/null || true
    return 0
}

# rep_is_complete <rep_dir>  -- resume predicate. A rep counts as "done" only
# if it produced samples AND its Spark job exited cleanly. Reps with
# status="spark_failed"/"profiler_start_failed" (e.g. the disk-full casualties)
# or an empty/missing profiler.tsv return non-zero so they get re-run.
rep_is_complete() {
    local rep_dir="$1"
    local tsv="$rep_dir/profiler.tsv" rj="$rep_dir/run.json"
    [ -f "$tsv" ] && [ -f "$rj" ] || return 1
    grep -q '"status":"ok"' "$rj" 2>/dev/null || return 1
    local n
    n=$(awk '/^[0-9]/{n++}END{print n+0}' "$tsv" 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

run_workload_with_profiler() {
    # Args: variant, workload_name, spark_script, spark_env, workload_outdir, profile_mode
    # workload_outdir is the per-(variant, workload) directory; per-rep
    # subdirectories repN/ are created here. Each rep gets its own profiler
    # lifecycle (start → warmup → Spark → stop), which exercises stap deep
    # cleanup between reps for V1 and produces independent profiler.tsv files
    # consumable by convert-profiler-to-meyer.py + generate-iada-tree.py.
    local variant="$1" workload_name="$2" spark_script="$3" spark_env="$4" workload_outdir="$5" profile_mode="${6:-standard}"

    # Delegate to full-deployment handler when ENV_DEPLOY != bare. Single-rep
    # only (multi-rep across containers/VMs needs separate orchestration).
    case "$ENV_DEPLOY" in
        bare) ;;  # fall through
        container-full|vm-full)
            mkdir -p "$workload_outdir/rep1"
            run_workload_full_deploy "$ENV_DEPLOY" "$variant" "$workload_name" "$workload_outdir/rep1" "$profile_mode"
            return $?
            ;;
        *) die "ENV_DEPLOY='$ENV_DEPLOY' not supported (use bare, container-full, vm-full)" ;;
    esac

    mkdir -p "$workload_outdir"

    local rep_total="$WORKLOAD_REPS"
    [ "$rep_total" -ge 1 ] || rep_total=1

    # Resume fast-path: if every rep already completed cleanly, don't start the
    # stressor or re-run anything -- the existing per-rep data is kept and
    # build_aggregate_means() (profile level) picks it up unchanged.
    if [ "$RESUME" = "1" ]; then
        local _c=0 _need=0
        while [ "$_c" -lt "$rep_total" ]; do
            _c=$((_c + 1))
            rep_is_complete "$workload_outdir/rep${_c}" || { _need=1; break; }
        done
        if [ "$_need" -eq 0 ]; then
            log "  [$variant] $workload_name — resume: all ${rep_total} reps already complete; skipping"
            return 0
        fi
    fi

    # Stressor stays steady across all reps so interference signal is constant.
    start_stressor "$profile_mode" "$workload_outdir"

    local r=0
    local successful_reps=0
    local total_elapsed=0
    local total_samples=0
    local -a REP_ELAPSED=()
    local -a REP_SAMPLES=()
    local -a REP_STATUS=()

    while [ "$r" -lt "$rep_total" ]; do
        r=$((r + 1))
        local rep_outdir="$workload_outdir/rep${r}"
        local profiler_tsv="$rep_outdir/profiler.tsv"
        local workload_log="$rep_outdir/workload.log"

        # Resume: keep a rep that already completed cleanly; re-run failed/empty.
        if [ "$RESUME" = "1" ] && rep_is_complete "$rep_outdir"; then
            local _prev
            _prev=$(awk '/^[0-9]/{n++}END{print n+0}' "$profiler_tsv" 2>/dev/null)
            log "  [$variant] $workload_name rep=${r}/${rep_total} — skip (resume: already ok, ${_prev} samples)"
            REP_ELAPSED+=("0"); REP_SAMPLES+=("$_prev"); REP_STATUS+=("\"ok\"")
            total_samples=$((total_samples + _prev))
            successful_reps=$((successful_reps + 1))
            continue
        fi

        mkdir -p "$rep_outdir"
        : > "$workload_log"

        log "  [$variant] $workload_name rep=${r}/${rep_total} — starting profiler"
        if ! start_profiler "$variant" "$profiler_tsv"; then
            warn "  [$variant] $workload_name rep=${r} — profiler failed to start; skipping rep"
            REP_ELAPSED+=("0")
            REP_SAMPLES+=("0")
            REP_STATUS+=("\"profiler_start_failed\"")
            printf '{"variant":"%s","workload":"%s","rep":%d,"status":"profiler_start_failed"}\n' \
                "$variant" "$workload_name" "$r" > "$rep_outdir/run.json"
            continue
        fi

        # Warmup: let Spark JVM/dataset come back online before recording.
        # Each rep needs its own warmup because Spark setup may have torn down
        # JVMs between reps (especially for short workloads).
        [ "$DRY_RUN" -eq 0 ] && sleep "$WARMUP"

        log "  [$variant] $workload_name rep=${r}/${rep_total} — running Spark job"
        local t0 run_elapsed rep_rc=0
        t0=$(date +%s)
        if [ "$DRY_RUN" -eq 1 ]; then
            if [ "${INTP_DISTRIBUTED_MODE:-0}" = "1" ]; then
                log "  DRY: ip netns exec ${INTP_NETNS_NAME:-intp-net} bash $spark_script >> $workload_log 2>&1"
            else
                log "  DRY: (spark_env) && bash $spark_script >> $workload_log 2>&1"
            fi
            sleep 2
        elif [ "${INTP_DISTRIBUTED_MODE:-0}" = "1" ]; then
            # Distributed mode: run Spark Driver inside netns intp-app so that
            # Driver↔Master/Worker RPC traverses intp-veth-h. SPARK_CONF_DIR +
            # HADOOP_CONF_DIR point at the parallel distributed configs from
            # bench/setup/setup-distributed-mode.sh.
            local netns="${INTP_NETNS_NAME:-intp-net}"
            local spark_conf_dist="${SPARK_HOME:-/opt/spark}/conf-distributed"
            local hadoop_conf_dist="${HADOOP_HOME:-/opt/hadoop}/etc/hadoop-distributed"
            (
                printf '===== rep %s start %s (distributed: netns=%s) =====\n' "$r" "$(date -Iseconds)" "$netns"
                eval "$spark_env"
                [ -n "$SPARK_HOME" ] && export SPARK_HOME
                export HIBENCH_HOME
                export SPARK_CONF_DIR="$spark_conf_dist"
                export HADOOP_CONF_DIR="$hadoop_conf_dist"
                # HiBench's load_config.py only whitelists 4 spark keys
                # (executor.memory, driver.memory, parallelism, shuffle.partitions)
                # for translation into the generated --properties-file. So
                # spark.driver.bindAddress etc. cannot be propagated via
                # /opt/HiBench/conf/spark.conf. Inject them via SPARK_SUBMIT_OPTS
                # as JVM -D system properties — spark-submit reads them and
                # the Driver JVM (which runs in the spark-submit process for
                # deploy-mode=client) picks them up as Spark configs.
                local guest_ip="${INTP_NETNS_GUEST_IP:-10.42.0.2}"
                local spark_submit_opts="-Dspark.driver.bindAddress=$guest_ip"
                spark_submit_opts="$spark_submit_opts -Dspark.driver.host=$guest_ip"
                spark_submit_opts="$spark_submit_opts -Dspark.driver.port=30000"
                spark_submit_opts="$spark_submit_opts -Dspark.driver.blockManager.port=30001"
                spark_submit_opts="$spark_submit_opts -Dspark.ui.enabled=false"
                # Re-assert the size-scaled heap here too: this distributed
                # branch overwrites SPARK_SUBMIT_OPTS from spark_env, so the
                # executor/driver memory set there would otherwise be lost.
                local exec_mem drv_mem
                read -r exec_mem drv_mem <<< "$(spark_memory_for_size)"
                spark_submit_opts="$spark_submit_opts -Dspark.executor.memory=$exec_mem"
                spark_submit_opts="$spark_submit_opts -Dspark.driver.memory=$drv_mem"
                ip netns exec "$netns" env \
                    SPARK_HOME="$SPARK_HOME" \
                    HIBENCH_HOME="$HIBENCH_HOME" \
                    SPARK_CONF_DIR="$spark_conf_dist" \
                    HADOOP_CONF_DIR="$hadoop_conf_dist" \
                    SPARK_LOCAL_IP="$guest_ip" \
                    SPARK_SUBMIT_OPTS="$spark_submit_opts" \
                    JAVA_HOME="${JAVA_HOME:-}" \
                    PATH="$PATH" \
                    bash "$spark_script"
                rc=$?
                printf '===== rep %s end rc=%s %s =====\n' "$r" "$rc" "$(date -Iseconds)"
                exit "$rc"
            ) >> "$workload_log" 2>&1 || rep_rc=$?
        else
            (
                printf '===== rep %s start %s =====\n' "$r" "$(date -Iseconds)"
                eval "$spark_env"
                [ -n "$SPARK_HOME" ] && export SPARK_HOME
                export HIBENCH_HOME
                bash "$spark_script"
                rc=$?
                printf '===== rep %s end rc=%s %s =====\n' "$r" "$rc" "$(date -Iseconds)"
                exit "$rc"
            ) >> "$workload_log" 2>&1 || rep_rc=$?
        fi
        run_elapsed=$(( $(date +%s) - t0 ))

        log "  [$variant] $workload_name rep=${r}/${rep_total} — stopping profiler (elapsed=${run_elapsed}s)"
        stop_profiler "$variant" "$profiler_tsv"

        local rep_samples=0
        [ -f "$profiler_tsv" ] && rep_samples=$(awk '/^[0-9]/{n++}END{print n+0}' "$profiler_tsv" 2>/dev/null)

        # Propagate the Spark exit code. A non-zero rc (e.g. an executor
        # OutOfMemoryError, which surfaces as exit 52) means the workload did
        # NOT complete -- its profiler.tsv captured a crashing job, so it must
        # not be counted as a successful rep or reported as status "ok".
        local rep_status="ok"
        if [ "$rep_rc" -ne 0 ]; then
            rep_status="spark_failed"
            warn "  [$variant] $workload_name rep=${r} — Spark job failed rc=${rep_rc} (see $workload_log)"
        fi

        REP_ELAPSED+=("$run_elapsed")
        REP_SAMPLES+=("$rep_samples")
        REP_STATUS+=("\"$rep_status\"")
        total_elapsed=$((total_elapsed + run_elapsed))
        total_samples=$((total_samples + rep_samples))
        [ "$rep_rc" -eq 0 ] && successful_reps=$((successful_reps + 1))

        cat > "$rep_outdir/run.json" <<EOF
{"variant":"$variant","workload":"$workload_name","rep":$r,"elapsed_s":$run_elapsed,"samples":$rep_samples,"status":"$rep_status"}
EOF
    done

    stop_stressor

    local rep_elapsed_csv
    rep_elapsed_csv=$(IFS=,; echo "${REP_ELAPSED[*]}")
    local elapsed_mean_s elapsed_stddev_s elapsed_cv_pct elapsed_min_s elapsed_max_s
    read -r elapsed_mean_s elapsed_stddev_s elapsed_cv_pct elapsed_min_s elapsed_max_s <<EOF
$(awk -F',' '
    {
        n=NF
        min=$1+0; max=$1+0; sum=0
        for(i=1;i<=NF;i++) {
            x=$i+0
            sum+=x
            if(x<min) min=x
            if(x>max) max=x
            a[i]=x
        }
        mean=(n>0)?sum/n:0
        var=0
        for(i=1;i<=n;i++) {
            d=a[i]-mean
            var+=d*d
        }
        std=(n>1)?sqrt(var/(n-1)):0
        cv=(mean>0)?(100*std/mean):0
        printf "%.3f %.3f %.3f %.3f %.3f\n", mean, std, cv, min, max
    }
' <<< "$rep_elapsed_csv")
EOF

    local high_variation
    high_variation=$(awk -v cv="$elapsed_cv_pct" -v th="$ELAPSED_CV_WARN_PCT" 'BEGIN{print (cv>=th)?"true":"false"}')
    local elapsed_series_json="[$rep_elapsed_csv]"
    local samples_series_json
    samples_series_json="[$(IFS=,; echo "${REP_SAMPLES[*]}")]"
    local status_series_json
    status_series_json="[$(IFS=,; echo "${REP_STATUS[*]}")]"

    local agg_status="ok"
    if [ "$successful_reps" -eq 0 ]; then
        agg_status="all_reps_failed"
    elif [ "$successful_reps" -lt "$r" ]; then
        agg_status="partial_failure"
    fi

    cat > "$workload_outdir/run.json" <<EOF
{"variant":"$variant","workload":"$workload_name","elapsed_s":$total_elapsed,"repetitions":$r,"successful_repetitions":$successful_reps,"elapsed_series_s":$elapsed_series_json,"samples_series":$samples_series_json,"status_series":$status_series_json,"elapsed_mean_s":$elapsed_mean_s,"elapsed_stddev_s":$elapsed_stddev_s,"elapsed_cv_pct":$elapsed_cv_pct,"elapsed_min_s":$elapsed_min_s,"elapsed_max_s":$elapsed_max_s,"high_variation":$high_variation,"samples":$total_samples,"status":"$agg_status"}
EOF
    log "  [$variant] $workload_name — done (reps=${r} ok=${successful_reps} elapsed=${total_elapsed}s mean=${elapsed_mean_s}s std=${elapsed_stddev_s}s cv=${elapsed_cv_pct}% samples=${total_samples})"
    if [ "$high_variation" = "true" ]; then
        warn "  [$variant] $workload_name — high duration variation across reps (cv=${elapsed_cv_pct}% >= ${ELAPSED_CV_WARN_PCT}%)"
    fi
    if [ "$successful_reps" -eq 0 ]; then
        warn "  [$variant] $workload_name — all ${r} reps failed (see per-rep run.json)"
    elif [ "$successful_reps" -lt "$r" ]; then
        warn "  [$variant] $workload_name — only ${successful_reps}/${r} reps succeeded"
    fi
}

# -----------------------------------------------------------------------------
# Spark Standalone Worker scratch reap (between workloads only)
# -----------------------------------------------------------------------------

reap_spark_worker_scratch_between_workloads() {
    # Delete finished app-* dirs under $SPARK_HOME/work/. Called only at the
    # workload boundary inside the main loop — every variant has finished and
    # no profiler is running, so the rm cannot perturb measurements.
    #
    # Without this, each Spark application (one per rep) leaves ~1.3 GB of
    # executor logs + shuffle index files in work/ and the Standalone Worker
    # defaults (spark.worker.cleanup.enabled=false) never reap them. A single
    # all-stress/large HiBench pass otherwise grows work/ by ~95 GB.
    #
    # Safety: only fires when INTP_DISTRIBUTED_MODE=1 (otherwise no Worker
    # exists) and only matches app-* dirs older than ~1 minute (find -mmin
    # +0), so a concurrent unrelated Spark application's in-flight scratch
    # is left alone. Operators on dedicated benchmark hosts get the full reap.
    local workload_name="${1:-}"
    [ "${DRY_RUN:-0}" -eq 1 ] && return 0
    [ "${INTP_DISTRIBUTED_MODE:-0}" = "1" ] || return 0
    [ -n "${SPARK_HOME:-}" ] && [ -d "$SPARK_HOME/work" ] || return 0

    local before_kb after_kb freed_kb reaped
    before_kb=$(du -sk "$SPARK_HOME/work" 2>/dev/null | awk '{print $1+0}')
    reaped=$(find "$SPARK_HOME/work" -mindepth 1 -maxdepth 1 -type d \
                   -name 'app-*' -mmin +0 -print 2>/dev/null | wc -l)
    find "$SPARK_HOME/work" -mindepth 1 -maxdepth 1 -type d \
         -name 'app-*' -mmin +0 -exec rm -rf {} + 2>/dev/null || true
    after_kb=$(du -sk "$SPARK_HOME/work" 2>/dev/null | awk '{print $1+0}')
    freed_kb=$((before_kb - after_kb))
    [ "$freed_kb" -lt 0 ] && freed_kb=0
    log "  [reap] $workload_name done — removed $reaped Spark app dir(s), freed $((freed_kb/1024)) MB from $SPARK_HOME/work"
}

# -----------------------------------------------------------------------------
# Aggregate means (same format as run-intp-bench.sh aggregate-means.tsv)
# -----------------------------------------------------------------------------

build_aggregate_means() {
    # Per-rep aggregate matching the schema produced by run-intp-bench.sh
    # (env, variant, stage, workload, rep, 7 metrics). HiBench rows carry
    # stage='hibench-<profile>' (e.g. hibench-cpu-extreme) -- the co-runner
    # profile is encoded into the stage column so the 7-profile axis SURVIVES
    # the publish merge, which dedups by env+variant+stage+workload+rep. A bare
    # 'hibench' stage made all 7 profiles share one key, collapsing the merged
    # aggregate-means.tsv to a single profile (last-write-wins). Downstream
    # consumers that want every HiBench row match stage with the 'hibench-'
    # prefix; those wanting stress-ng still match 'solo'/'pairwise' exactly.
    local outdir="$1"
    local agg="$outdir/aggregate-means.tsv"
    # Profile parsed from the run-dir name <profile>-<size>-<ts>.
    local profile; profile="${outdir##*/}"; profile="${profile%-"$SIZE"-*}"
    {
        printf 'env\tvariant\tstage\tworkload\trep\tnetp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n'
        find "$outdir" -name profiler.tsv | while read -r f; do
            # Path layout: .../<env>/<variant>/<stage>/<workload>/repN/profiler.tsv
            local env variant stage workload rep
            env=$(echo "$f" | awk -F/ '{print $(NF-5)}')
            variant=$(echo "$f" | awk -F/ '{print $(NF-4)}')
            stage=$(echo "$f" | awk -F/ '{print $(NF-3)}')
            workload=$(echo "$f" | awk -F/ '{print $(NF-2)}')
            rep=$(echo "$f" | awk -F/ '{print $(NF-1)}' | sed 's/rep//')
            # The path stage component is the literal 'hibench' dir; tag the
            # co-runner profile so merged rows stay distinct across profiles.
            [ "$stage" = "hibench" ] && stage="hibench-$profile"
            awk -v E="$env" -v V="$variant" -v S="$stage" -v W="$workload" -v R="$rep" '
                /^#/||/^ts/||/^netp/||NF==0 { next }
                /^[0-9]/ {
                    # 7 metrics live in the last 7 columns regardless of how
                    # many prefix columns the variant emits:
                    #   V0/V0.1 (stap):    7 cols (no time_ms, no host ts)  → off=0
                    #   V2/V3/V3.1:        8 cols (host ts + 7 metrics)     → off=1
                    #   V1/V1.1 (stap):    9 cols (host ts + stap time_ms + 7 metrics) → off=2
                    # Compute off=NF-7 so any prefix arrangement maps correctly.
                    n=NF; off=n-7
                    if (off < 0) next
                    for(i=1;i<=7;i++){ if($(i+off)!="--"){s[i]+=$(i+off);c[i]++} }
                }
                END {
                    printf "%s\t%s\t%s\t%s\t%s",E,V,S,W,R
                    for(i=1;i<=7;i++){ if(c[i]>0) printf "\t%.3f",s[i]/c[i]; else printf "\t--" }
                    printf "\n"
                }
            ' "$f"
        done
    } > "$agg"
    log "aggregate-means: $agg"
}

# -----------------------------------------------------------------------------
# Profile runner (outer loop: workloads × variants)
# -----------------------------------------------------------------------------

run_subset_for_profile() {
    local mode="$1"
    local outdir=""
    # Resume: reuse the newest existing run-dir for this profile instead of
    # minting a fresh timestamp. Minting a new one on every invocation is what
    # produced two <profile>-<size>-<ts> dirs per profile (=> 24 reps) when the
    # campaign was re-run with a shared RESUME_DIR.
    if [ "$RESUME" = "1" ]; then
        # `ls` exits 2 when the glob matches nothing -- the first profile in a
        # fresh campaign dir. The `2>/dev/null` hides the message but NOT that
        # exit code, and under `set -euo pipefail` pipefail propagates the 2 and
        # set -e kills the script before any profile runs (silent rc=2). The
        # trailing `|| true` makes a no-match benign so the line below mints a
        # fresh run-dir instead of resuming a non-existent one.
        outdir="$(ls -1d "$OUT_ROOT/$mode-$SIZE-"*/ 2>/dev/null | sed 's:/*$::' | sort | tail -n1)" || true
        if [ -n "$outdir" ] && [ -d "$outdir" ]; then
            log "resume: reusing existing run-dir for profile=$mode -> $outdir"
        else
            outdir=""
        fi
    fi
    [ -n "$outdir" ] || outdir="$OUT_ROOT/$mode-$SIZE-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$outdir" 2>/dev/null || {
        # Fall back to $HOME, not /tmp: /tmp is wiped on reboot and silently
        # strands a whole run's profiler.tsv data. $HOME is visible and
        # survives a repo rename/move.
        outdir="$HOME/hibench-runs/$mode-$SIZE-$(date +%Y%m%d_%H%M%S)"
        log "WARN: could not create output dir under OUT_ROOT='$OUT_ROOT' -- falling back to $outdir"
        mkdir -p "$outdir"
    }

    log "HiBench subset profile=$mode size=$SIZE variants=$VARIANTS_CSV workloads=$WORKLOADS_CSV reps=$WORKLOAD_REPS elapsed_cv_warn_pct=${ELAPSED_CV_WARN_PCT}"
    log "output: $outdir"

    set_hibench_size
    set_spark_memory

    local spark_env
    spark_env="$(spark_env_for_profile "$mode")"

    # Resolve workload runners from HIBENCH_HOME
    local -a RUNNERS=()
    local runner

    if workload_selected terasort; then
        runner=$(resolve_runner \
            "bin/workloads/micro/terasort/spark/run.sh" \
            "bin/workloads/micro/sort/spark/run.sh") || die "terasort/sort runner not found"
        RUNNERS+=("terasort:$runner")
    fi

    if workload_selected wordcount; then
        runner=$(resolve_runner "bin/workloads/micro/wordcount/spark/run.sh") || die "wordcount runner not found"
        RUNNERS+=("wordcount:$runner")
    fi

    if workload_selected pagerank; then
        runner=$(resolve_runner "bin/workloads/websearch/pagerank/spark/run.sh") || die "pagerank runner not found"
        RUNNERS+=("pagerank:$runner")
    fi

    if workload_selected kmeans; then
        runner=$(resolve_runner "bin/workloads/ml/kmeans/spark/run.sh") || die "kmeans runner not found"
        RUNNERS+=("kmeans:$runner")
    fi

    if workload_selected bayes; then
        runner=$(resolve_runner "bin/workloads/ml/bayes/spark/run.sh") || die "bayes runner not found"
        RUNNERS+=("bayes:$runner")
    fi

    if workload_selected sql_nweight; then
        if runner=$(resolve_runner "bin/workloads/sql/nweight/spark/run.sh"); then
            RUNNERS+=("sql_nweight:$runner")
        else
            warn "sql_nweight runner not found — continuing without sql_nweight"
        fi
    fi

    if workload_selected dfsioe; then
        if runner=$(resolve_runner \
            "bin/workloads/micro/dfsioe/hadoop/run.sh" \
            "bin/workloads/micro/dfsioe/spark/run.sh"); then
            RUNNERS+=("dfsioe:$runner")
        else
            warn "dfsioe runner not found — continuing without dfsioe (HDFS required)"
        fi
    fi

    [ "${#RUNNERS[@]}" -gt 0 ] || die "no runnable workloads selected"

    {
        printf 'date=%s\nprofile=%s\nsize=%s\nvariants=%s\nworkloads=%s\nreps=%s\nhibench_home=%s\nspark_home=%s\n' \
            "$(date -Iseconds)" "$mode" "$SIZE" "$VARIANTS_CSV" "$WORKLOADS_CSV" "$WORKLOAD_REPS" "$HIBENCH_HOME" "${SPARK_HOME:-auto}"
        printf 'elapsed_cv_warn_pct=%s\n' "$ELAPSED_CV_WARN_PCT"
    } > "$outdir/metadata.env"

    # Main loop: for each workload, run all variants back-to-back so measurements
    # are taken under the same system state (same Spark dataset just run). Each
    # call writes per-rep dirs (rep1/, rep2/, ..., repN/) under the workload dir.
    # Path layout matches run-intp-bench.sh: <env>/<variant>/<stage>/<workload>/<rep>
    # so convert-profiler-to-meyer.py and generate-iada-tree.py treat HiBench
    # rows the same way as stress-ng solo rows.
    local item workload_name script variant
    for item in "${RUNNERS[@]}"; do
        workload_name="${item%%:*}"
        script="${item#*:}"
        log "workload=$workload_name reps=$WORKLOAD_REPS"
        for variant in "${VARIANTS[@]}"; do
            run_workload_with_profiler \
                "$variant" "$workload_name" "$script" "$spark_env" \
                "$outdir/bare/$variant/hibench/$workload_name" "$mode"
        done
        # Reap finished Spark Standalone Worker app-* scratch between
        # workloads. All variants for this workload are done and no profiler
        # is running, so the rm is invisible to measurements. Skipped in
        # localmode (no Worker) and in dry-run.
        reap_spark_worker_scratch_between_workloads "$workload_name"
    done

    build_aggregate_means "$outdir"
    log "completed profile=$mode → $outdir"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

cleanup_stale_orphans() {
    # Defensive: nuke anything left over from a previous crashed run.
    # Without this, leaked stress-ng workers from a failed cycle keep
    # eating RAM and signals get throttled, causing the next run to hang.
    [ "$DRY_RUN" -eq 1 ] && return 0
    local victims
    victims=$(pgrep -f 'intp-hybrid|intp-ebpf|run-intp-bpftrace|orchestrator/aggregator\.py|bench/hibench/run-hibench-subset|stress-ng' 2>/dev/null \
              | grep -v "^$$\$" || true)
    if [ -n "$victims" ]; then
        warn "[preflight] killing stale processes: $(echo $victims | tr '\n' ' ')"
        # shellcheck disable=SC2086
        kill -KILL $victims 2>/dev/null || true
        sleep 1
    fi
    pkill -KILL -f 'bpftrace -q' 2>/dev/null || true
    # Stale resctrl mon groups from any prior aborted run (intp-v1.1, intp-v2,
    # intp-v3, intp-v3.1, plus PID-suffixed mon_groups from intp-helper).
    for g in /sys/fs/resctrl/mon_groups/intp-v* /sys/fs/resctrl/mon_groups/intp-[0-9]*; do
        [ -d "$g" ] && rmdir "$g" 2>/dev/null || true
    done
}

preflight() {
    [ "$(id -u)" = "0" ] || [ "$DRY_RUN" -eq 1 ] || die "must run as root (profilers need PMU/resctrl)"

    cleanup_stale_orphans

    local v
    for v in "${VARIANTS[@]}"; do
        case "$v" in
            v1)
                [ "$DRY_RUN" -eq 1 ] && continue
                command -v stap >/dev/null 2>&1 || die "stap not found (required for v1)"
                [ -f "$V1_STP" ] || die "V1 script not found: $V1_STP"
                [ -x "$V1_HELPER" ] || die "resctrl helper not found: $V1_HELPER"
                ;;
            v1.1)
                [ "$DRY_RUN" -eq 1 ] && continue
                command -v stap >/dev/null 2>&1 || die "stap not found (required for v1.1)"
                [ -f "$V1_1_STP" ] || die "V1.1 script not found: $V1_1_STP"
                [ -x "$V1_1_HELPER" ] || die "V1.1 helper not built: $V1_1_HELPER (run 'make -C $REPO_ROOT/variants/v1.1-stap-helper')"
                ;;
            v0.2)
                [ "$DRY_RUN" -eq 1 ] && continue
                command -v stap >/dev/null 2>&1 || die "stap not found (required for v0.2)"
                [ -f "$V0_2_TEMPLATE" ] || die "V0.2 template not found: $V0_2_TEMPLATE"
                [ -x "$V0_2_GENERATOR" ] || die "V0.2 generator not executable: $V0_2_GENERATOR"
                [ -x "$V0_2_HELPER" ] || die "V0.2 helper not built: $V0_2_HELPER (run 'make -C $REPO_ROOT/variants/v0.2-legacy-bridge')"
                ;;
            v2) [ -x "$V2_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v2 binary not found: $V2_BIN" ;;
            v3.1) [ -x "$V3_1_RUNNER" ] || [ "$DRY_RUN" -eq 1 ] || die "v3.1 runner not found: $V3_1_RUNNER" ;;
            v3) [ -x "$V3_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v3 binary not found: $V3_BIN" ;;
            v3.2) [ -x "$V3_2_BIN" ] || [ "$DRY_RUN" -eq 1 ] || die "v3.2 binary not found: $V3_2_BIN (run 'make -C $REPO_ROOT/variants/v3.2-ebpf-agg')" ;;
            *)  die "unknown variant: $v" ;;
        esac
    done

    if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$HIBENCH_HOME" ]; then
        die "HIBENCH_HOME not found: $HIBENCH_HOME (run bench/hibench/setup-spark-hibench.sh first)"
    fi
    setup_cpu_env
}

# -----------------------------------------------------------------------------
# Cleanup trap
# -----------------------------------------------------------------------------

_on_exit() {
    # Profiler tree FIRST — it's the data integrity boundary. If this hangs,
    # next run inherits orphan binaries that contaminate fresh tsv files.
    if [ -n "$PROFILER_PID" ]; then
        _kill_tree KILL "$PROFILER_PID" 2>/dev/null || true
    fi
    if [ -n "$STAP_COLLECTOR_PID" ]; then
        _kill_tree KILL "$STAP_COLLECTOR_PID" 2>/dev/null || true
    fi
    if [ -n "$STAP_PID" ]; then
        _kill_tree KILL "$STAP_PID" 2>/dev/null || true
    fi
    # Belt-and-suspenders for any profiler binary that escaped tracking
    pkill -KILL -f 'intp-hybrid|intp-ebpf|run-intp-bpftrace|orchestrator/aggregator\.py' 2>/dev/null || true
    pkill -KILL -f 'bpftrace -q' 2>/dev/null || true
    # Stressor last (lower data-integrity priority; clean up RAM)
    stop_stressor
    restore_cpu_env
    stop_resctrl_helper
    # Deep stap-module cleanup if ANY stap-based variant ran (v1/v1.1/v0.2);
    # all three load kernel modules that accumulate without this.
    local v
    for v in "${VARIANTS[@]}"; do
        case "$v" in
            v1|v1.1|v0.2)
                stap_deep_cleanup "exit-trap"
                break
                ;;
        esac
    done

    return 0
}
trap '_on_exit' EXIT INT TERM

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Populate MEM_BW_MAX_BPS (bytes/sec) from shared/intp-detect.sh when the
# operator did not pass an explicit value. intp-detect.sh reports
# INTP_MEM_BW_MBPS in MB/s; the v2/v3/v3.1/v3.2 binaries expect --mem-bw-max-bps
# in bytes/sec and do NOT convert -- so the ×1e6 conversion happens here.
resolve_mem_bw_ceiling() {
    if [ -n "$MEM_BW_MAX_BPS" ]; then
        log "mbw ceiling: ${MEM_BW_MAX_BPS} B/s (explicit override)"
        return 0
    fi
    local detect="$REPO_ROOT/shared/intp-detect.sh" mbps=""
    # `|| true` and the END-print awk (no early `exit`) keep this safe under
    # `set -o pipefail` -- an early awk exit would SIGPIPE intp-detect.sh.
    [ -x "$detect" ] && mbps=$("$detect" 2>/dev/null \
        | awk -F= '/^INTP_MEM_BW_MBPS=/{v=$2} END{print v}' || true)
    case "$mbps" in
        ''|*[!0-9]*)
            warn "mbw ceiling: could not derive from intp-detect.sh -- v2/v3/v3.2 will fall back to their unreliable built-in autodetect" ;;
        *)
            MEM_BW_MAX_BPS=$(( mbps * 1000000 ))
            log "mbw ceiling: ${MEM_BW_MAX_BPS} B/s (derived: ${mbps} MB/s × 1e6 from intp-detect.sh)" ;;
    esac
}

main() {
    parse_args "$@"
    preflight
    resolve_mem_bw_ceiling

    case "$PROFILE" in
        both)
            run_subset_for_profile standard
            run_subset_for_profile netp-extreme
            ;;
        all-stress)
            for p in standard cpu-extreme mem-extreme cache-extreme disk-extreme netp-extreme nets-extreme; do
                run_subset_for_profile "$p"
            done
            ;;
        *)
            run_subset_for_profile "$PROFILE"
            ;;
    esac

    log "all requested profiles finished"
}

main "$@"

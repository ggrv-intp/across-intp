#!/usr/bin/env bash
# full-container-entrypoint.sh — orchestrates HDFS + workload + profiler
# inside the all-in-one image (see Dockerfile.full).
#
# Subcommands:
#   start-hdfs              format (idempotent), boot NN+DN+SNN
#   stop-hdfs               stop the daemons cleanly
#   prepare WORKLOAD        run HiBench prepare for a workload
#   run-stressng VARIANT ARGS DURATION   run stress-ng + profiler in parallel
#   run-hibench  VARIANT WORKLOAD        run HiBench Spark workload + profiler
#   shell                   drop to interactive bash
#
# Output convention: profiler writes to /opt/results/profiler.tsv (bind-mounted
# to host outdir by the launcher).
#
# Env knobs:
#   INTP_PROFILER_VARIANT  v2 | v3 | v3.1 | v1.1
#   INTP_INTERVAL          profiler sampling interval in s (default 1)
#   INTP_DURATION          profiler/workload duration in s (default 60)

set -u -o pipefail

INTP_ROOT="${INTP_ROOT:-/opt/intp}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"
RESULTS_DIR="${RESULTS_DIR:-/opt/results}"
INTERVAL="${INTP_INTERVAL:-1}"

log() { printf '[%s entrypoint] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

mkdir -p "$RESULTS_DIR"

# ─── HDFS lifecycle ─────────────────────────────────────────────────────────
hdfs_format_if_needed() {
    if [ ! -d /var/lib/hadoop/hdfs/name/current ]; then
        log "formatting NameNode (first boot)"
        "$HADOOP_HOME/bin/hdfs" namenode -format -force -nonInteractive >/dev/null 2>&1 \
            || die "namenode -format failed"
    fi
}

ssh_localhost_warmup() {
    # Hadoop's start-dfs.sh sshes to localhost. Warm the known-hosts entry.
    service ssh start >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null || true
    for i in 1 2 3 4 5; do
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes localhost true 2>/dev/null && return 0
        sleep 1
    done
    log "WARN: ssh to localhost not warming up"
}

cmd_start_hdfs() {
    ssh_localhost_warmup
    hdfs_format_if_needed
    "$HADOOP_HOME/sbin/start-dfs.sh" >/dev/null 2>&1
    sleep 3
    if ! "$HADOOP_HOME/bin/hdfs" dfsadmin -report >/dev/null 2>&1; then
        die "HDFS did not come up — check $HADOOP_HOME/logs/"
    fi
    "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /HiBench /user/root 2>/dev/null || true
    log "HDFS up"
}

cmd_stop_hdfs() {
    "$HADOOP_HOME/sbin/stop-dfs.sh" >/dev/null 2>&1 || true
    log "HDFS stopped"
}

# ─── Profiler launcher (mirrors the host-side _inguest_profiler_cmd) ────────
profiler_cmd() {
    # profiler_cmd <variant> <pid> <duration>
    local variant="$1" pid="$2" duration="$3"
    case "$variant" in
        v2)   echo "$INTP_ROOT/variants/v2-c-abi/intp-hybrid --pid $pid --interval $INTERVAL --duration $duration --no-prom" ;;
        v3)   echo "$INTP_ROOT/variants/v3-ebpf-ring/intp-ebpf --pid $pid --interval $INTERVAL --duration $duration" ;;
        v3.1) echo "bash $INTP_ROOT/variants/v3.1-bpftrace/run-intp-bpftrace.sh --pid $pid --interval $INTERVAL --duration $duration" ;;
        v1.1) echo "stap -DMAXACTION=8192 -DSTP_NO_OVERLOAD --suppress-handler-errors $INTP_ROOT/variants/v1.1-stap-modern/intp-v1.1.stp -x $pid --target-pid=$pid -F" ;;
        *) echo ""; return 1 ;;
    esac
}

# ─── stress-ng workload ──────────────────────────────────────────────────────
cmd_run_stressng() {
    local variant="$1"; shift
    local duration="${INTP_DURATION:-60}"
    local args="$*"
    [ -z "$args" ] && die "no stress-ng args provided"

    log "stress-ng: $args (timeout ${duration}s)"
    stress-ng $args --timeout "${duration}s" --metrics-brief \
        > "$RESULTS_DIR/workload.log" 2>&1 &
    local wl_pid=$!
    sleep 1

    local cmd
    cmd=$(profiler_cmd "$variant" "$wl_pid" "$duration") \
        || die "no profiler command for variant=$variant"
    log "profiler: $cmd"
    bash -lc "$cmd" > "$RESULTS_DIR/profiler.tsv" 2>&1 &
    local prof_pid=$!

    wait "$wl_pid" 2>/dev/null || true
    wait "$prof_pid" 2>/dev/null || true
    awk '/^[0-9]/{n++}END{print n+0}' "$RESULTS_DIR/profiler.tsv" \
        > "$RESULTS_DIR/profiler.tsv.samples"
    log "done. samples=$(cat $RESULTS_DIR/profiler.tsv.samples)"
}

# ─── HiBench Spark workload ──────────────────────────────────────────────────
cmd_run_hibench() {
    local variant="$1" workload="$2"
    local prep="$HIBENCH_HOME/bin/workloads/$workload/prepare/prepare.sh"
    local run="$HIBENCH_HOME/bin/workloads/$workload/spark/run.sh"
    [ -f "$prep" ] || die "prepare.sh not found for $workload"
    [ -f "$run" ]  || die "run.sh not found for $workload"

    log "HiBench prepare $workload"
    bash "$prep" > "$RESULTS_DIR/prepare.log" 2>&1 || die "prepare failed"

    log "HiBench run $workload (Spark + profiler $variant)"
    bash "$run" > "$RESULTS_DIR/workload.log" 2>&1 &
    local spark_wrapper=$!
    # Find the Spark driver JVM PID (created by spark-submit)
    local driver_pid="" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        driver_pid=$(pgrep -f 'org.apache.spark.deploy.SparkSubmit' | head -1)
        [ -n "$driver_pid" ] && break
        sleep 1
    done
    [ -z "$driver_pid" ] && die "Spark driver did not launch"

    local duration="${INTP_DURATION:-90}"
    local cmd
    cmd=$(profiler_cmd "$variant" "$driver_pid" "$duration") || \
        die "no profiler command for variant=$variant"
    log "profiler: $cmd  (driver_pid=$driver_pid)"
    bash -lc "$cmd" > "$RESULTS_DIR/profiler.tsv" 2>&1 &
    local prof_pid=$!

    wait "$prof_pid" 2>/dev/null || true
    # Wait for Spark to finish too
    wait "$spark_wrapper" 2>/dev/null || true
    awk '/^[0-9]/{n++}END{print n+0}' "$RESULTS_DIR/profiler.tsv" \
        > "$RESULTS_DIR/profiler.tsv.samples"
    log "done. samples=$(cat $RESULTS_DIR/profiler.tsv.samples)"
}

cmd_shell() { exec /bin/bash; }

case "${1:-help}" in
    start-hdfs) cmd_start_hdfs ;;
    stop-hdfs)  cmd_stop_hdfs ;;
    run-stressng) shift; cmd_run_stressng "$@" ;;
    run-hibench)  shift; cmd_run_hibench  "$@" ;;
    shell)      cmd_shell ;;
    help|*)
        cat <<EOF
Usage: docker run ... <image> COMMAND [ARGS...]

Commands:
  start-hdfs              boot HDFS NN+DN+SNN (idempotent format)
  stop-hdfs               graceful shutdown
  run-stressng VARIANT ARGS...
  run-hibench  VARIANT WORKLOAD
  shell                   interactive bash

Env vars:
  INTP_PROFILER_VARIANT, INTP_INTERVAL, INTP_DURATION

Mounts:
  /opt/intp     IntP repo (read-only) — bind from host
  /opt/results  output dir for profiler.tsv — bind to host outdir
EOF
        ;;
esac

#!/usr/bin/env bash
# intp-aux-rerun.sh -- Auxiliary reruns #4 and #5 for the SBAC-PAD paper.
#
#   #4: noise-floor characterization (V3 system-wide, HiBench stack UP and IDLE)
#   #5: pidstat + perf -p breakdown for the V3 composite-mechanism hypothesis
#
# Run via tmux so you can detach (Ctrl-b d) and reattach (tmux a -t intp-aux):
#
#     tmux new-session -d -s intp-aux \
#         'bash -lc "bash $REPO_ROOT/shared/intp-ebpf-checkout.sh; exec bash"'
#     tmux attach -t intp-aux
#
# Wall clock: ~40 min total (#4 ~18 min, #5 ~20 min).
#
# Paths: REPO_ROOT is derived from this script's location (shared/ is one level
# below the repo root). Override via env if invoking from outside the repo.

set -euo pipefail

# ============================================================================
# Configuration -- derived from script location; override via env if needed
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Variant under test for this noise-floor / composite-mechanism rerun.
#   v3   → variants/v3-ebpf-ring/intp-ebpf-ring         (per-event ring buffer)
#   v3.2 → variants/v3.2-ebpf-core/intp-ebpf-core (in-kernel aggregation)
# Both are ring-buffer eBPF variants, so the same noise-floor / pidstat
# experiment applies. For any other binary, set INTP_EBPF_BIN explicitly.
INTP_AUX_VARIANT="${INTP_AUX_VARIANT:-v3}"
case "$INTP_AUX_VARIANT" in
    v3)   _aux_default_bin="$REPO_ROOT/variants/v3-ebpf-ring/intp-ebpf-ring" ;;
    v3.2) _aux_default_bin="$REPO_ROOT/variants/v3.2-ebpf-core/intp-ebpf-core" ;;
    *)    _aux_default_bin="$REPO_ROOT/variants/v3-ebpf-ring/intp-ebpf-ring" ;;
esac
INTP_EBPF_BIN="${INTP_EBPF_BIN:-$_aux_default_bin}"
unset _aux_default_bin
# Upper-case label for log / plot headers (V3, V3.2, …).
VLABEL="$(echo "$INTP_AUX_VARIANT" | tr 'a-z' 'A-Z')"
# Output dir: prefer the repo's results/ so reruns stay centralised with the
# rest of the campaign data. Fall back to $HOME (visible, and survives the
# repo being renamed or moved) — never /tmp, which is wiped on reboot.
if [ -z "${OUT_DIR:-}" ]; then
    _aux_stamp="intp-aux-rerun-$INTP_AUX_VARIANT-$(date +%Y%m%d-%H%M%S)"
    if mkdir -p "$REPO_ROOT/results" 2>/dev/null && [ -w "$REPO_ROOT/results" ]; then
        OUT_DIR="$REPO_ROOT/results/$_aux_stamp"
    else
        OUT_DIR="$HOME/$_aux_stamp"
    fi
    unset _aux_stamp
fi
export OUT_DIR

# Timing / rep counts — env-overridable so a smoke run can shrink them
# (e.g. SMOKE_NOISE_FLOOR in run-smoke-all.sh sets DURATION=15 REPS_NF=2).
DURATION="${DURATION:-90}"   # seconds per rep, matches the existing overhead stage
WARMUP="${WARMUP:-5}"
COOLDOWN="${COOLDOWN:-2}"
REPS_NF="${REPS_NF:-12}"     # noise-floor reps (matches the bench's overhead stage default)
REPS_OVH="${REPS_OVH:-3}"    # pidstat reps (statistical sanity vs wall-clock budget)

# Reference loads -- adjust if your existing overhead stage used different flags
declare -A REF_LOADS=(
  [ref_cpu]="--cpu 0 --cpu-method all"
  [ref_disk]="--hdd 4 --hdd-bytes 1G"
  [ref_stream]="--stream 0"
)

# ============================================================================
# Pre-flight
# ============================================================================
mkdir -p "$OUT_DIR"/{noise_floor,ringbuf_pidstat/ref_cpu,ringbuf_pidstat/ref_disk,ringbuf_pidstat/ref_stream}
# Variant marker — consumed by bench/plot/plot-aux-rerun.py for figure labels.
echo "$INTP_AUX_VARIANT" > "$OUT_DIR/variant.txt"
exec > >(tee -a "$OUT_DIR/run.log") 2>&1

echo "=== IntP auxiliary rerun ==="
echo "Started:   $(date -Iseconds)"
echo "Script:    $SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
echo "Repo:      $REPO_ROOT"
echo "Variant:   $INTP_AUX_VARIANT ($VLABEL)"
echo "Binary:    $INTP_EBPF_BIN"
echo "Output:    $OUT_DIR"
echo

[ -x "$INTP_EBPF_BIN" ] || { echo "FATAL: intp-ebpf-ring not found at $INTP_EBPF_BIN"; exit 1; }
command -v pidstat   >/dev/null || { echo "FATAL: pidstat not found (apt install sysstat)"; exit 1; }
command -v perf      >/dev/null || { echo "FATAL: perf not found (apt install linux-tools-common)"; exit 1; }
command -v stress-ng >/dev/null || { echo "FATAL: stress-ng not found"; exit 1; }

# Capture env snapshot for the appendix
{
  echo "=== uname ==="; uname -a
  echo "=== /proc/cmdline ==="; cat /proc/cmdline
  echo "=== kernel.perf_event_paranoid ==="; sysctl kernel.perf_event_paranoid
  echo "=== resctrl info ==="; ls /sys/fs/resctrl/info/ 2>/dev/null || true
  echo "=== HiBench stack (jps) ==="
  if command -v jps >/dev/null; then
    jps
  else
    pgrep -af 'NameNode|DataNode|deploy.master.Master|deploy.worker.Worker' | sed 's/^/  /' || echo "  (jps unavailable; using pgrep)"
  fi
  echo "=== listeners on HDFS/Spark ports ==="
  ss -tlnp 2>/dev/null | grep -E ':(9000|9866|7077|7078|8080|8081)' || echo "  (none -- stack may not be up)"
} > "$OUT_DIR/env.txt"

# ============================================================================
# Experiment #4 -- noise floor
# Pre-condition: HiBench stack UP and IDLE (NameNode + DataNode + Master + Worker;
#                no Spark Driver running, no antagonist running).
# Method: 12 V3 system-wide windows of 90s each.
# Output: noise_floor/summary.tsv (per-metric mean/std across all samples).
# ============================================================================
echo
echo "==================================================================="
echo "Experiment #4: noise floor ($VLABEL system-wide, stack-up-but-idle)"
echo "==================================================================="
echo "Pre-check (stack should be UP and idle):"
grep -A5 'HiBench stack' "$OUT_DIR/env.txt"
echo

for r in $(seq 1 $REPS_NF); do
  rep_dir="$OUT_DIR/noise_floor/rep$(printf %02d $r)"
  mkdir -p "$rep_dir"
  echo "  [#4 rep $r/$REPS_NF] $(date +%H:%M:%S)"
  sudo timeout $((DURATION + 10)) "$INTP_EBPF_BIN" \
    --interval 1.0 --duration $DURATION --output tsv \
    > "$rep_dir/profiler.tsv" 2> "$rep_dir/intp.err" || true
  sleep 2
done

python3 - <<'PY'
import csv, glob, statistics as st, os
# Metrics emitted by intp-ebpf-ring --output tsv. All values are integer percentages (0-100),
# despite the comment-header in the TSV listing the underlying eBPF source (e.g. cpu:sched_switch).
metrics = ['netp','nets','blk','mbw','llcmr','llcocc','cpu']
out_dir = os.environ["OUT_DIR"]
rows = []
for rep in sorted(glob.glob(f"{out_dir}/noise_floor/rep*/profiler.tsv")):
    try:
        with open(rep) as f:
            # intp-ebpf-ring prefixes the TSV with "# ..." metadata lines; DictReader would otherwise treat them as the header.
            data_lines = [ln for ln in f if not ln.startswith('#') and ln.strip()]
        for row in csv.DictReader(data_lines, delimiter='\t'):
            try:
                rows.append({m: float(row.get(m, 0) or 0) for m in metrics})
            except (ValueError, TypeError):
                pass
    except FileNotFoundError:
        pass

if not rows:
    print("WARNING: no samples collected for #4")
else:
    out = f"{out_dir}/noise_floor/summary.tsv"
    print(f"\n  Noise floor (system-wide V3, stack-up-but-idle, n={len(rows)} samples):")
    print(f"  {'metric':<8} {'mean':>10} {'std':>10} {'p50':>10} {'p95':>10}")
    with open(out, 'w') as f:
        f.write("metric\tmean\tstd\tp50\tp95\tn\n")
        for m in metrics:
            vs = sorted(r[m] for r in rows)
            p50 = vs[len(vs)//2]
            p95 = vs[int(len(vs)*0.95)] if vs else 0
            print(f"  {m:<8} {st.mean(vs):>10.3f} {st.pstdev(vs):>10.3f} {p50:>10.3f} {p95:>10.3f}")
            f.write(f"{m}\t{st.mean(vs):.6f}\t{st.pstdev(vs):.6f}\t{p50:.6f}\t{p95:.6f}\t{len(vs)}\n")
    print(f"  Summary -> {out}")
PY

# ============================================================================
# Experiment #5 -- pidstat + perf -p breakdown for V3 composite hypothesis
# For each ref_* load, 3 reps with V3 attached. Captures:
#   - pidstat 1Hz CPU% of intp-ebpf-ring consumer  (the "CPU stealing" axis)
#   - perf stat -p intp-ebpf-ring context-switches (the consumer's own ctx-switches)
#   - perf stat -a sched:sched_switch          (system-wide, for delta vs baseline)
# Also 3 baseline reps per ref_load (no profiler) for the sched_switch delta.
# ============================================================================
echo
echo "==================================================================="
echo "Experiment #5: pidstat + perf -p breakdown ($VLABEL composite mechanism)"
echo "==================================================================="

for ref in ref_cpu ref_disk ref_stream; do
  flags="${REF_LOADS[$ref]}"
  echo
  echo "--- $ref  ($flags) ---"
  ref_dir="$OUT_DIR/ringbuf_pidstat/$ref"

  for arm in baseline with_profiler; do
    mkdir -p "$ref_dir/$arm"
    for r in $(seq 1 $REPS_OVH); do
      run_dir="$ref_dir/$arm/rep$(printf %02d $r)"
      mkdir -p "$run_dir"
      echo "  [#5 $ref/$arm rep $r] $(date +%H:%M:%S)"

      # Start the stress-ng workload (warmup + measurement + cooldown)
      total=$((WARMUP + DURATION + COOLDOWN))
      sudo stress-ng $flags --timeout ${total}s --metrics-brief \
        > "$run_dir/stress.log" 2>&1 &
      STRESS_PID=$!

      sleep $WARMUP   # let stress-ng reach steady state

      # Ground-truth context-switches and run-queue stats via vmstat (1Hz, independent
      # of perf+BPF interaction). Captured in BOTH arms for an apples-to-apples delta.
      vmstat 1 $DURATION > "$run_dir/vmstat.txt" 2>&1 &
      VMSTAT_PID=$!

      EBPF_PID=""
      if [ "$arm" = "with_profiler" ]; then
        sudo "$INTP_EBPF_BIN" --interval 1.0 --duration $DURATION --output tsv \
          > "$run_dir/intp.tsv" 2> "$run_dir/intp.err" &
        INTP_LAUNCHER_PID=$!
        # Poll up to 5s for the real intp-ebpf-ring process to appear. -nx matches the exact
        # comm name (basename), so it skips the "sudo" wrapper which also has "intp-ebpf-ring"
        # in its full command line. The previous -nf was catching the sudo PID, making
        # pidstat/perf-stat unable to find threads ("Problems finding threads of monitor").
        EBPF_BASENAME="$(basename "$INTP_EBPF_BIN")"
        for _ in $(seq 1 10); do
          EBPF_PID=$(pgrep -nx "$EBPF_BASENAME" 2>/dev/null || true)
          [ -n "$EBPF_PID" ] && break
          sleep 0.5
        done
        if [ -n "$EBPF_PID" ]; then
          echo "    intp-ebpf-ring consumer PID=$EBPF_PID"
          pidstat -p "$EBPF_PID" -u 1 $DURATION > "$run_dir/pidstat.txt" 2>&1 &
          PIDSTAT_PID=$!
          sudo perf stat -p "$EBPF_PID" -e context-switches,task-clock,cpu-migrations \
            -- sleep $DURATION 2> "$run_dir/perf_consumer.txt" &
          PERF_C_PID=$!
        else
          echo "  WARN: intp-ebpf-ring PID not found after 5s; consumer-side measurements skipped"
        fi
      fi

      # System-wide sched_switch for the same 90s window (kernel perf counter — may be
      # suppressed when BPF programs attach to sched:sched_switch; vmstat above is the
      # independent ground-truth).
      sudo perf stat -a -e sched:sched_switch \
        -- sleep $DURATION 2> "$run_dir/perf_system.txt" &
      PERF_S_PID=$!

      wait $PERF_S_PID 2>/dev/null || true
      wait $VMSTAT_PID 2>/dev/null || true
      if [ "$arm" = "with_profiler" ]; then
        wait ${PIDSTAT_PID:-} 2>/dev/null || true
        wait ${PERF_C_PID:-}  2>/dev/null || true
        wait $INTP_LAUNCHER_PID 2>/dev/null || true
      fi
      wait $STRESS_PID 2>/dev/null || true
      sleep $COOLDOWN
    done
  done
done

# Post-process #5
python3 - <<'PY'
import re, glob, statistics as st, os
from pathlib import Path

def parse_perf_one(path, event):
    try: text = Path(path).read_text(errors='ignore')
    except (FileNotFoundError, OSError): return None
    for line in text.splitlines():
        m = re.search(r'([\d,]+)\s+' + re.escape(event), line)
        if m:
            try: return int(m.group(1).replace(',', ''))
            except ValueError: return None
    return None

def parse_pidstat_cpu(path):
    try: text = Path(path).read_text(errors='ignore')
    except (FileNotFoundError, OSError): return []
    vs = []
    for line in text.splitlines():
        # pidstat default format columns: time UID PID %usr %system %guest %wait %CPU CPU Command
        parts = line.split()
        if len(parts) >= 9 and parts[0].count(':') == 2 and parts[2].isdigit():
            try: vs.append(float(parts[7]))
            except (ValueError, IndexError): pass
    return vs

def parse_vmstat_cs(path):
    # vmstat default 'cs' column is the 12th field on data rows.
    # Layout (vmstat 1 N): two header lines then N+1 data rows; first data row is
    # boot-time averages (discard), rows 2..N+1 are 1-second samples.
    try: text = Path(path).read_text(errors='ignore')
    except (FileNotFoundError, OSError): return []
    data = []
    for line in text.splitlines():
        parts = line.split()
        # Data rows start with integer 'r' (runnable proc count); skip headers + 'procs' line.
        if len(parts) >= 17 and parts[0].isdigit():
            try: data.append(int(parts[11]))   # cs = column index 11 (0-based)
            except (ValueError, IndexError): pass
    return data[1:] if len(data) > 1 else []   # discard first row (boot-time average)

root = Path(os.environ["OUT_DIR"]) / "ringbuf_pidstat"
print()
print("Experiment #5 -- composite mechanism summary:")
print(f"  {'ref':<11} {'perf sched_sw base':>20} {'perf sched_sw v3':>20} {'delta':>10}  "
      f"{'vmstat cs base':>16} {'vmstat cs v3':>14} {'cs delta':>10}  "
      f"{'consumer ctx-sw':>16} {'consumer CPU%':>14}")
for ref in ['ref_cpu','ref_disk','ref_stream']:
    pbase  = [v for v in (parse_perf_one(p, 'sched:sched_switch') for p in sorted(glob.glob(str(root/ref/'baseline'/'rep*'/'perf_system.txt')))) if v]
    pwithp = [v for v in (parse_perf_one(p, 'sched:sched_switch') for p in sorted(glob.glob(str(root/ref/'with_profiler'/'rep*'/'perf_system.txt')))) if v]
    cons   = [v for v in (parse_perf_one(p, 'context-switches')   for p in sorted(glob.glob(str(root/ref/'with_profiler'/'rep*'/'perf_consumer.txt')))) if v]
    # vmstat 'cs' values are per-second; sum over the 90s window to compare against perf counter.
    vbase  = [sum(parse_vmstat_cs(p)) for p in sorted(glob.glob(str(root/ref/'baseline'/'rep*'/'vmstat.txt')))]
    vwithp = [sum(parse_vmstat_cs(p)) for p in sorted(glob.glob(str(root/ref/'with_profiler'/'rep*'/'vmstat.txt')))]
    vbase  = [v for v in vbase  if v]
    vwithp = [v for v in vwithp if v]
    cpus = []
    for p in sorted(glob.glob(str(root/ref/'with_profiler'/'rep*'/'pidstat.txt'))):
        vs = parse_pidstat_cpu(p)
        if vs: cpus.append(st.mean(vs))

    mpb  = st.mean(pbase)  if pbase  else 0
    mpw  = st.mean(pwithp) if pwithp else 0
    mvb  = st.mean(vbase)  if vbase  else 0
    mvw  = st.mean(vwithp) if vwithp else 0
    mc   = st.mean(cons)   if cons   else 0
    mcpu = st.mean(cpus)   if cpus   else 0
    print(f"  {ref:<11} {mpb:>20,.0f} {mpw:>20,.0f} {mpw-mpb:>+10,.0f}  "
          f"{mvb:>16,.0f} {mvw:>14,.0f} {mvw-mvb:>+10,.0f}  "
          f"{mc:>16,.0f} {mcpu:>13.2f}%")
print()
print("Reading:")
print("  - Compare 'perf sched_sw delta' (kernel counter on sched:sched_switch tracepoint) vs")
print("    'vmstat cs delta' (independent /proc/stat-derived context-switch counter).")
print("  - If perf-delta is large but vmstat-delta is small => perf counter is suppressed by")
print("    the V3 BPF program attached to the same tracepoint (measurement artefact, NOT")
print("    composite mechanism).")
print("  - If BOTH deltas are large and negative => V3 genuinely reduces ctx-sw in the system.")
print("  - 'consumer ctx-sw' ~ |vmstat cs delta| on ref_cpu/ref_stream => mechanism #1 (adaptive wakeup) dominates.")
print("  - On ref_disk, |vmstat cs delta| >> consumer ctx-sw          => mechanism #2 (CPU stealing) dominates.")
print("  - consumer CPU% * 90s * (CLK_TCK=100) ~= jiffies axis from existing fig:overhead-jiffies.")
PY

echo
echo "=== Auxiliary rerun done: $(date -Iseconds) ==="
echo "Output dir: $OUT_DIR"
echo
echo "Next step: scp -r pantanal01:$OUT_DIR ./   and feed summary.tsv into the paper's"
echo "noise-floor table (§IV) and the composite-mechanism prose (§V-B)."

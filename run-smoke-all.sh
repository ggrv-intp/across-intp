#!/usr/bin/env bash
# run-smoke-all.sh — fast end-to-end smoke of the IntP campaign pipeline.
#
# Mirrors run-big-batch.sh in miniature: the same variants, the same
# segments (builds, stress-ng bench, HiBench, noise-floor aux rerun, plots),
# at smoke scale — short durations, 1 rep, 1 workload — so a broken stage
# surfaces in minutes instead of hours. Anything run-big-batch.sh can do has
# a smoke here; the heavier segments are opt-in so the base smoke stays fast.
#
# Segment toggles (defaults keep the base smoke fast):
#   SMOKE_STRESS=1         stress-ng bench-quick (detect,build,solo,report)
#   SMOKE_HIBENCH=0        HiBench quick smoke   (needs Spark+HiBench installed)
#   SMOKE_NOISE_FLOOR=0    noise-floor aux rerun (needs eBPF + perf/pidstat, root)
#   SMOKE_PLOTS=1          render the full plot set from whatever segments ran
#   SMOKE_CONTAINER_GUEST=0  exercise the container-guest path (needs docker)
#   SMOKE_VM_GUEST=0         exercise the vm-guest path (needs cloud-localds + qcow2)
#   SMOKE_CROSS_ENV=0        exercise bare/container/vm-guest + the cross-env plot
#   SMOKE_IADA=0             exercise the IADA M1 closed loop
#
# Variant / scale knobs:
#   SMOKE_BENCH_VARIANTS=v0.2,v1.1,v2,v3.1,v3,v3.2   stress-ng bench-quick variants
#   SMOKE_HIBENCH_VARIANTS=v0.2,v1.1,v2,v3           HiBench smoke variants
#   SMOKE_NF_VARIANT=v3                              noise-floor variant (v3|v3.2)
#   SMOKE_BENCH_WORKLOADS=app01_ml_llc               stress-ng workloads (1 = quick)
#   SMOKE_DURATION=20                                per-rep stress-ng duration (s)
#
# Usage:
#   sudo bash run-smoke-all.sh
#   sudo SMOKE_HIBENCH=1 SMOKE_NOISE_FLOOR=1 bash run-smoke-all.sh
#   sudo SMOKE_NF_VARIANT=v3.2 SMOKE_NOISE_FLOOR=1 bash run-smoke-all.sh

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$ROOT/results/smoke-$TS"
mkdir -p "$OUT"
ln -sfn "$OUT" "$ROOT/results/LATEST-SMOKE"

exec > >(tee -a "$OUT/smoke.log") 2>&1

# ── Segment toggles ──────────────────────────────────────────────────────────
SMOKE_STRESS="${SMOKE_STRESS:-1}"
SMOKE_HIBENCH="${SMOKE_HIBENCH:-0}"
SMOKE_NOISE_FLOOR="${SMOKE_NOISE_FLOOR:-0}"
SMOKE_PLOTS="${SMOKE_PLOTS:-1}"

# ── Variant / scale knobs ────────────────────────────────────────────────────
SMOKE_BENCH_VARIANTS="${SMOKE_BENCH_VARIANTS:-v0.2,v1.1,v2,v3.1,v3,v3.2}"
SMOKE_HIBENCH_VARIANTS="${SMOKE_HIBENCH_VARIANTS:-v0.2,v1.1,v2,v3}"
SMOKE_NF_VARIANT="${SMOKE_NF_VARIANT:-v3}"
SMOKE_BENCH_WORKLOADS="${SMOKE_BENCH_WORKLOADS:-app01_ml_llc}"
SMOKE_DURATION="${SMOKE_DURATION:-20}"

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
    rc=$?
    echo "===== FAIL: $name (rc=$rc) ====="
    fail=$((fail+1))
  fi
}

cd "$ROOT"

echo "Smoke config:"
echo "  out=$OUT"
echo "  segments: stress=$SMOKE_STRESS hibench=$SMOKE_HIBENCH noise_floor=$SMOKE_NOISE_FLOOR plots=$SMOKE_PLOTS"
echo "  bench_variants=$SMOKE_BENCH_VARIANTS  workloads=$SMOKE_BENCH_WORKLOADS  duration=${SMOKE_DURATION}s"
echo "  hibench_variants=$SMOKE_HIBENCH_VARIANTS  noise_floor_variant=$SMOKE_NF_VARIANT"

# ── Preflight ────────────────────────────────────────────────────────────────
run_step "detect host capabilities" bash shared/intp-detect.sh

# ── Builds — every variant run-big-batch.sh can measure ──────────────────────
run_step "v0.2 build" make -C variants/v0.2-stap-legacy clean all
run_step "v1.1 build" make -C variants/v1.1-stap-modern clean all
run_step "v2 build" make -C variants/v2-hybrid-c clean all
run_step "v2 unit tests" make -C variants/v2-hybrid-c run-tests
run_step "v3.1 deps" make -C variants/v3.1-bpftrace deps
run_step "v3.1 tests" make -C variants/v3.1-bpftrace test
run_step "v3 build" make -C variants/v3-ebpf-ring clean all
run_step "v3 load/attach test" make -C variants/v3-ebpf-ring test
run_step "v3.2 build" make -C variants/v3.2-ebpf-agg clean all

run_step "cross-variant modern quick" \
  bash shared/validate-cross-variant.sh \
    --start-workload \
    --interval 1 \
    --duration 15 \
    --tolerance 20 \
    --output-dir "$OUT/cross-variant"

# ── Segment: stress-ng bench-quick ───────────────────────────────────────────
if [ "$SMOKE_STRESS" = "1" ]; then
  run_step "bench quick detect+build+solo+report ($SMOKE_BENCH_VARIANTS)" \
    bash bench/run-intp-bench.sh \
      --stage detect,build,solo,report \
      --variants "$SMOKE_BENCH_VARIANTS" \
      --env bare \
      --workloads "$SMOKE_BENCH_WORKLOADS" \
      --duration "$SMOKE_DURATION" \
      --reps 1 \
      --output-dir "$OUT/bench-quick"
else
  echo "Skipping stress-ng bench-quick (SMOKE_STRESS=$SMOKE_STRESS)"
fi

# ── Segment: HiBench quick smoke ─────────────────────────────────────────────
# Opt-in: needs Spark + HiBench already installed (setup-spark-hibench.sh).
# One workload, tiny scale, 1 rep — just enough to exercise the HiBench
# profiler path and produce an aggregate-means.tsv for the plot consumer.
if [ "$SMOKE_HIBENCH" = "1" ]; then
  run_step "hibench quick smoke ($SMOKE_HIBENCH_VARIANTS, terasort)" \
    bash bench/hibench/run-hibench-subset.sh \
      --variants "$SMOKE_HIBENCH_VARIANTS" \
      --workloads terasort \
      --size small \
      --profile standard \
      --reps 1 \
      --interval 1 \
      --warmup 5 \
      --max-duration 120 \
      --out-root "$OUT/hibench-quick"
else
  echo "Skipping HiBench smoke (SMOKE_HIBENCH=$SMOKE_HIBENCH)"
fi

# ── Segment: noise-floor aux rerun ───────────────────────────────────────────
# Opt-in: the same experiment run-big-batch's campaign pairs with v3/v3.2
# (shared/intp-ebpf-checkout.sh — noise floor + pidstat breakdown). Shrunk to
# smoke scale via the env knobs that script now honours.
if [ "$SMOKE_NOISE_FLOOR" = "1" ]; then
  run_step "noise-floor aux rerun ($SMOKE_NF_VARIANT)" \
    env INTP_AUX_VARIANT="$SMOKE_NF_VARIANT" \
        OUT_DIR="$OUT/noise-floor-smoke" \
        DURATION=15 WARMUP=2 COOLDOWN=1 REPS_NF=2 REPS_OVH=1 \
      bash shared/intp-ebpf-checkout.sh
else
  echo "Skipping noise-floor aux rerun (SMOKE_NOISE_FLOOR=$SMOKE_NOISE_FLOOR)"
fi

# ── Segment: plots ───────────────────────────────────────────────────────────
# Exercises every plot consumer run-big-batch.sh drives, on whatever the
# segments above produced.
if [ "$SMOKE_PLOTS" = "1" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipping plots: python3 not found"
  else
    if [ "$SMOKE_STRESS" = "1" ] && [ -d "$OUT/bench-quick" ]; then
      run_step "plot stress-ng bench figures" \
        python3 bench/plot/plot-intp-bench.py "$OUT/bench-quick" \
          --variants "$SMOKE_BENCH_VARIANTS"
      run_step "extract stress-ng fragility table" \
        python3 bench/plot/extract-fragility.py "$OUT/bench-quick"
      if [ -f "$OUT/bench-quick/aggregate-means.tsv" ]; then
        run_step "plot PCA correlation circle" \
          python3 bench/plot/plot-pca-correlation-circle.py \
            "$OUT/bench-quick/aggregate-means.tsv"
      else
        echo "Skipping PCA circle: $OUT/bench-quick/aggregate-means.tsv not found"
      fi
    fi
    if [ "$SMOKE_HIBENCH" = "1" ] && [ -d "$OUT/hibench-quick" ]; then
      run_step "plot HiBench figures" \
        python3 bench/plot/plot-hibench.py "$OUT/hibench-quick"
    fi
    if [ "$SMOKE_NOISE_FLOOR" = "1" ] && [ -d "$OUT/noise-floor-smoke" ]; then
      run_step "plot noise-floor aux figures" \
        python3 bench/plot/plot-aux-rerun.py "$OUT/noise-floor-smoke"
    fi
  fi
else
  echo "Skipping plots (SMOKE_PLOTS=$SMOKE_PLOTS)"
fi

# Optional in-guest smokes — opt-in via env vars to keep the default smoke fast.
# SMOKE_CONTAINER_GUEST=1   exercises the container-guest path (needs docker).
# SMOKE_VM_GUEST=1          exercises the vm-guest path (needs cloud-localds + qcow2).
if [ "${SMOKE_CONTAINER_GUEST:-0}" = "1" ]; then
  run_step "bench in-guest container smoke (v3.1, app01)" \
    bash bench/run-intp-bench.sh \
      --stage detect,solo,report \
      --variants v3.1 \
      --env container-guest \
      --workloads app01_ml_llc \
      --duration 15 --reps 1 \
      --output-dir "$OUT/bench-quick-cg"
fi
if [ "${SMOKE_VM_GUEST:-0}" = "1" ]; then
  : "${VM_IMAGE:?SMOKE_VM_GUEST=1 requires VM_IMAGE pointing to a qcow2}"
  run_step "bench in-guest vm smoke (v3.1, app01)" \
    bash bench/run-intp-bench.sh \
      --stage detect,solo,report \
      --variants v3.1 \
      --env vm-guest \
      --workloads app01_ml_llc \
      --duration 15 --reps 1 \
      --output-dir "$OUT/bench-quick-vg"
fi
# SMOKE_CROSS_ENV=1   exercises the bare/container/vm-guest cross-env path
#                     and the plot-cross-environment.py consumer in one shot.
#                     Picks vm-guest (not plain vm) because cross-env analysis
#                     is most useful when all three envs report per-process
#                     metrics; the host-observer vm mode would zero out
#                     several columns for vm and degrade the comparison.
if [ "${SMOKE_CROSS_ENV:-0}" = "1" ]; then
  : "${VM_IMAGE:?SMOKE_CROSS_ENV=1 requires VM_IMAGE pointing to a qcow2}"
  run_step "cross-env smoke (v2,v3.1 in bare,container,vm-guest)" \
    bash bench/run-intp-bench.sh \
      --stage detect,solo,report \
      --variants v2,v3.1 \
      --env bare,container,vm-guest \
      --workloads app01_ml_llc \
      --duration 20 --reps 2 \
      --bench-cpus 4 --bench-mem 8G \
      --output-dir "$OUT/bench-cross-env-smoke"
  run_step "cross-env comparison plot" \
    python3 bench/plot/plot-cross-environment.py \
      "$OUT/bench-cross-env-smoke"
fi

# SMOKE_IADA=1   exercises the IADA M1 closed loop (Section V) end-to-end
#                against an existing cross-env-campaign output. Requires
#                an already-provisioned host (setup-iada.sh --auto-clone),
#                a sourced ~/.iada-env, and IADA_BENCH_CAMPAIGN_DIR pointing
#                at a real bench-full/ output directory. Picks v2 only and
#                env=container (M1 default) to keep wallclock bounded
#                (~CloudSim 25-30 min on a 16-core laptop).
if [ "${SMOKE_IADA:-0}" = "1" ]; then
  : "${IADA_BENCH_CAMPAIGN_DIR:?SMOKE_IADA=1 requires IADA_BENCH_CAMPAIGN_DIR (a cross-env-campaign output dir containing bench-full/aggregate-means.tsv)}"
  : "${CLOUDSIM_REPO:?SMOKE_IADA=1 requires CLOUDSIM_REPO from ~/.iada-env (source it after setup-iada.sh)}"

  run_step "iada M1 smoke (v2, container, sanity-checked)" \
    env MODALITY=M1 VARIANTS=v2 WORKLOAD_MIXES=all \
        OUT_ROOT="$OUT/iada-smoke" RUN_PLOT=1 \
        SANITY_SAMPLES=5 SANITY_FAIL_THRESHOLD_PCT=50 \
      bash bench/iada/scripts/run-iada-from-bench.sh \
        "$IADA_BENCH_CAMPAIGN_DIR"
fi

echo
echo "Smoke finished. PASS=$ok FAIL=$fail"
echo "Output: $OUT"
test "$fail" -eq 0

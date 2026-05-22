#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ub24run.sh -- one-shot SBAC-PAD campaign for the Ubuntu 24.04 leg.
#
# Runs, in strict order, on an already-bootstrapped UB24 host:
#
#   1. veth-routing setup (netns pair) for NIC-traversing workloads
#   2. ensures the Hadoop/Spark cluster is DOWN
#   3. the full stress-ng benchmark for v1.1, v2, v3.2 -- veth routed,
#      with NO Hadoop/Spark daemons running
#   4. brings Hadoop + Spark + HiBench up (installs, builds the Spark
#      workloads, formats HDFS, starts the daemons, populates datasets)
#   5. the full HiBench Spark benchmark for v1.1, v2, v3.2 -- veth routed,
#      cluster up
#   6. tears the cluster back down
#   7. publishes data + plots + metrics into sbac-results/ (leg "ub24")
#
# All of the above is the shared engine bench/run-os-campaign.sh; this file
# just pins the UB24 variant set. The UB22 / v0.2 counterpart is ub22run.sh.
#
# Prerequisite: the host is already bootstrapped (bench/setup/setup-host.sh
# has been run and any kernel pin/reboot completed). This script does NOT
# install packages or pin kernels -- but its Stage 0 DOES assert the live
# runtime kernel knobs the profilers need (resctrl mount, perf_event_paranoid
# = -1, kptr_restrict = 0), so a host whose sysctls drifted since boot still
# runs clean. Skip that stage with SKIP_KERNEL_CONFIG=1.
#
# Usage:
#   sudo bash ub24run.sh                 # full campaign (HiBench size=large)
#   sudo bash ub24run.sh --dry-run       # print every step, run nothing
#   sudo HIBENCH_SIZE=small bash ub24run.sh
#   sudo SKIP_STRESS=1 CAMPAIGN_OUT=results/ub24-campaign-... bash ub24run.sh
#
# Resume is idempotent gap-filling: pointing CAMPAIGN_OUT at an existing
# campaign dir re-runs only the reps that did not complete cleanly (both the
# stress-ng and HiBench legs), so re-running never doubles HiBench reps to 24.
#
# See bench/run-os-campaign.sh --help for every environment knob
# (HIBENCH_SIZE, HIBENCH_PROFILE, REPS, DURATION, SKIP_* resume flags, ...).
# -----------------------------------------------------------------------------

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- per-leg BUILD configuration (UB24 / modern v1.1,v2,v3.2) ---------------
# Same Hadoop/Spark/HiBench VERSIONS as the UB22 leg. The modern leg builds via
# HiBench's spark<X.Y> profile shortcut (no --legacy-mvn), so the Scala/Kafka
# coordinates come from that profile and need no explicit pins -- the legacy
# SCALA_FULL_VERSION/KAFKA_* knobs are intentionally left unset here (they are
# only consulted in direct-versions mode). Override only if a future
# HiBench/Spark bump needs it; run-os-campaign.sh forwards whatever is set.
export SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
export HIBENCH_MVN_EXTRA_ARGS="${HIBENCH_MVN_EXTRA_ARGS:-}"

exec bash "$SCRIPT_DIR/bench/run-os-campaign.sh" \
    --host-tag ub24 \
    --variants v1.1,v2,v3.2 \
    "$@"

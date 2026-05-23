#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ub22run.sh -- one-shot SBAC-PAD campaign for the Ubuntu 22.04 (legacy) leg.
#
# Identical pipeline to ub24run.sh, but for the single legacy variant v0.2:
#
#   1. veth-routing setup (netns pair) for NIC-traversing workloads
#   2. ensures the Hadoop/Spark cluster is DOWN
#   3. the full stress-ng benchmark for v0.2 -- veth routed, NO Hadoop/Spark
#   4. brings Hadoop + Spark + HiBench up (installs, builds the Spark
#      workloads, formats HDFS, starts the daemons, populates datasets)
#   5. the full HiBench Spark benchmark for v0.2 -- veth routed, cluster up
#   6. tears the cluster back down
#   7. publishes data + plots + metrics into sbac-results/ (leg "ub22")
#
# --legacy-mvn is passed to the engine: it forwards HIBENCH_MVN_DIRECT_VERSIONS=1
# to setup-spark-hibench.sh, which the UB22 / 5.x legacy leg needs because the
# cloned HiBench master lacks a Maven profile matching the requested Spark
# major.minor (see bench/hibench/setup-spark-hibench.sh header).
#
# Prerequisite: the host is already bootstrapped (bench/setup/setup-host.sh
# --profile legacy has been run and the HWE kernel pin/reboot completed).
# This script does NOT install packages or pin kernels -- but its Stage 0
# DOES assert the live runtime kernel knobs the profilers need (resctrl mount,
# perf_event_paranoid = -1, kptr_restrict = 0). Skip with SKIP_KERNEL_CONFIG=1.
#
# Usage:
#   sudo bash ub22run.sh                 # full campaign (HiBench size=large, profile=all-stress)
#   sudo bash ub22run.sh --dry-run       # print every step, run nothing
#   sudo HIBENCH_SIZE=small HIBENCH_PROFILE=standard bash ub22run.sh
#   sudo CAMPAIGN_OUT=results/ub22-campaign-... bash ub22run.sh   # resume
#
# Resume is idempotent gap-filling: pointing CAMPAIGN_OUT at an existing
# campaign dir re-runs only the reps that did not complete cleanly (both the
# stress-ng and HiBench legs), so re-running never doubles HiBench reps to 24.
#
# See bench/run-os-campaign.sh --help for every environment knob.
# -----------------------------------------------------------------------------

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- per-leg BUILD configuration (UB22 / legacy v0.2) -----------------------
# Same Hadoop/Spark/HiBench VERSIONS as the UB24 leg -- only the Maven/Scala
# BUILD path differs. --legacy-mvn already turns on HIBENCH_MVN_DIRECT_VERSIONS
# (bypass HiBench's spark<X.Y> profile and pin dep coords directly). These
# knobs, forwarded by run-os-campaign.sh into setup-spark-hibench.sh, pin the
# exact Scala/Kafka coordinates the legacy build needs so HiBench compiles
# cleanly on U22/5.15 (the legacy leg has no matching spark profile, so the
# missing version properties surface as Scala compile errors otherwise).
# Each is overridable from the call site:  SCALA_FULL_VERSION=… sudo bash ub22run.sh
export SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
export SCALA_FULL_VERSION="${SCALA_FULL_VERSION:-2.12.18}"
export KAFKA_VERSION="${KAFKA_VERSION:-1.1.1}"
export KAFKA_BINARY_VERSION="${KAFKA_BINARY_VERSION:-2.12}"
# Extra -D args for any further deps the missing legacy Spark profile would have
# pinned. Populate from the actual Maven Scala-compile errors, e.g.:
#   export HIBENCH_MVN_EXTRA_ARGS="-Dhadoop.version=3.3.6 -Dflume.version=1.9.0"
export HIBENCH_MVN_EXTRA_ARGS="${HIBENCH_MVN_EXTRA_ARGS:-}"

# ---- per-leg HiBench RUN configuration (UB22 / legacy v0.2) -----------------
# The measurement defaults for this leg: the full large-scale dataset under the
# complete co-runner sweep. run-os-campaign.sh applies the SAME fallback, but
# pinning it here makes the leg's intent explicit at the launcher and survives
# any future change to the engine defaults. Override per run from the call site:
#   sudo HIBENCH_SIZE=small HIBENCH_PROFILE=standard bash ub22run.sh
# (HIBENCH_SIZE large|medium|small -> HiBench scale large|small|tiny; valid
#  profiles incl. standard, <res>-extreme, all-stress -- see run-hibench-subset.sh.)
export HIBENCH_SIZE="${HIBENCH_SIZE:-large}"
export HIBENCH_PROFILE="${HIBENCH_PROFILE:-all-stress}"

exec bash "$SCRIPT_DIR/bench/run-os-campaign.sh" \
    --host-tag ub22 \
    --variants v0.2 \
    --legacy-mvn \
    "$@"

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
#   sudo bash ub22run.sh                 # full campaign (HiBench size=large)
#   sudo bash ub22run.sh --dry-run       # print every step, run nothing
#   sudo HIBENCH_SIZE=small bash ub22run.sh
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

exec bash "$SCRIPT_DIR/bench/run-os-campaign.sh" \
    --host-tag ub22 \
    --variants v0.2 \
    --legacy-mvn \
    "$@"

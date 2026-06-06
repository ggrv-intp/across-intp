#!/usr/bin/env bash
# test-environments.sh -- run an IntP V2 capture under bare-metal, container,
# and (optionally) VM, comparing the metrics each environment can supply.
#
# Usage: ./test-environments.sh [--dry-run] <workload-command> [duration-seconds]
#
# Outputs:   results-YYYYMMDD-HHMMSS/{baremetal,container,vm}.tsv
#            results-YYYYMMDD-HHMMSS/comparison.md (if compare script succeeds)
#
# VM mode is enabled by setting INTP_VM_IMAGE to a QCOW2 image that already
# contains an intp-hybrid binary at /usr/local/bin/intp-hybrid and whatever
# tooling the workload needs. The image is expected to listen on SSH port
# 2222 on localhost and accept the key pointed to by INTP_VM_SSH_KEY with
# user INTP_VM_SSH_USER (default "root").
#
# Example image-prep hints (commented; the script does not build an image):
#   virt-customize -a base.qcow2 \
#       --copy-in intp-hybrid:/usr/local/bin/ \
#       --run-command 'systemctl enable ssh'
#   virt-customize -a base.qcow2 \
#       --ssh-inject root:file:path/to/pub

set -euo pipefail

# ---- argument parsing --------------------------------------------------------
DRY_RUN=0
if [[ $# -ge 1 && "$1" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--dry-run] <workload-command> [duration-seconds]" >&2
    exit 1
fi

WORKLOAD=$1
DURATION=${2:-60}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
INTP=${INTP:-$ROOT_DIR/intp-hybrid}
OUTDIR=$ROOT_DIR/results-$(date +%Y%m%d-%H%M%S)

# In dry-run mode, run will just echo the command and not execute it.
run() {
    if (( DRY_RUN )); then
        printf 'DRY: '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# run_shell runs a shell pipeline (one string, with quoting preserved) in the
# same mode as `run` so complex background-and-wait pipelines still echo sanely.
run_shell() {
    if (( DRY_RUN )); then
        printf 'DRY: bash -c %q\n' "$1"
    else
        bash -c "$1"
    fi
}

run "mkdir" -p "$OUTDIR"
echo "==> output dir: $OUTDIR"

if [[ ! -x "$INTP" ]]; then
    if (( DRY_RUN )); then
        echo "DRY: (would verify $INTP is executable)"
    else
        echo "intp-hybrid binary not found at $INTP -- run 'make' first" >&2
        exit 1
    fi
fi

# ---- 1. bare-metal -----------------------------------------------------------
echo "==> bare-metal capture ($DURATION s)"
run_shell "\"$INTP\" --interval 1 --duration $DURATION --output tsv > \"$OUTDIR/baremetal.tsv\" & INTP_PID=\$!; ( $WORKLOAD ) & WORK_PID=\$!; wait \$INTP_PID 2>/dev/null || true; kill \$WORK_PID 2>/dev/null || true; wait \$WORK_PID 2>/dev/null || true"

# ---- 2. container (Docker) ---------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    echo "==> container capture ($DURATION s)"
    run docker run --rm --privileged \
        --pid=host \
        -v /sys/fs/resctrl:/sys/fs/resctrl \
        -v "$ROOT_DIR":/intp \
        -v "$OUTDIR":/out \
        ubuntu:24.04 bash -lc "
            apt-get update >/dev/null 2>&1 || true
            /intp/intp-hybrid --interval 1 --duration $DURATION --output tsv \
                > /out/container.tsv &
            INTP_PID=\$!
            ( $WORKLOAD ) &
            WORK_PID=\$!
            wait \$INTP_PID
            kill \$WORK_PID 2>/dev/null || true
        "
else
    echo "==> docker not present; skipping container capture"
fi

# ---- 3. VM (optional, via INTP_VM_IMAGE) ------------------------------------
run_vm_capture() {
    local image=$1
    local ssh_key=$2
    local ssh_user=$3
    local ssh_port=2222

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo "==> qemu-system-x86_64 not installed; skipping VM capture"
        echo "    install qemu-system-x86 (Debian/Ubuntu) or qemu-kvm to enable"
        return 0
    fi
    if [[ ! -r "$image" ]]; then
        echo "==> VM image not readable: $image -- skipping" >&2
        return 0
    fi
    if [[ ! -r "$ssh_key" ]]; then
        echo "==> SSH key not readable: $ssh_key -- skipping" >&2
        return 0
    fi

    echo "==> VM capture ($DURATION s) via $image"
    local qemu_pid=""
    # -cpu host,+pmu is what actually exposes the host PMU counters to the
    # guest. Without +pmu the PMU counters stay frozen at zero and the llcmr
    # backend's active probe will detect it.
    run_shell "qemu-system-x86_64 \
        -enable-kvm -cpu host,+pmu -smp 4 -m 4G \
        -drive file=\"$image\",if=virtio,format=qcow2 \
        -net user,hostfwd=tcp::$ssh_port-:22 -net nic \
        -virtfs local,path=\"$OUTDIR\",mount_tag=intp_out,security_model=mapped,id=intp_out \
        -display none -serial null -daemonize -pidfile \"$OUTDIR/qemu.pid\""
    if (( DRY_RUN )); then
        echo "DRY: (would wait up to 60s for ssh to come up on port $ssh_port)"
        echo "DRY: (would ssh and run the workload + intp capture)"
        echo "DRY: (would scp vm.tsv back and shut down the VM)"
        return 0
    fi
    qemu_pid=$(cat "$OUTDIR/qemu.pid" 2>/dev/null || true)

    # Wait for SSH to become reachable, up to 60 seconds.
    local waited=0
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -i $ssh_key -p $ssh_port"
    # shellcheck disable=SC2086
    until ssh $ssh_opts "$ssh_user@127.0.0.1" true 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if (( waited >= 60 )); then
            echo "==> VM did not boot within 60s, killing qemu (pid=$qemu_pid)" >&2
            [[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null || true
            return 1
        fi
    done

    # Run the workload and the capture in parallel inside the VM.
    local remote
    remote="set -e
        mkdir -p /mnt/intp_out
        mountpoint -q /mnt/intp_out || mount -t 9p -o trans=virtio intp_out /mnt/intp_out
        /usr/local/bin/intp-hybrid --interval 1 --duration $DURATION --output tsv \
            > /mnt/intp_out/vm.tsv &
        INTP_PID=\$!
        ( $WORKLOAD ) &
        WORK_PID=\$!
        wait \$INTP_PID
        kill \$WORK_PID 2>/dev/null || true
        sync"
    # shellcheck disable=SC2086
    ssh $ssh_opts "$ssh_user@127.0.0.1" "$remote" || \
        echo "==> remote capture failed; continuing with shutdown" >&2

    # Graceful shutdown; fall back to kill if it doesn't respond.
    # shellcheck disable=SC2086
    ssh $ssh_opts "$ssh_user@127.0.0.1" "shutdown -h now" 2>/dev/null || true
    if [[ -n "$qemu_pid" ]]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$qemu_pid" 2>/dev/null || break
            sleep 1
        done
        kill "$qemu_pid" 2>/dev/null || true
    fi
    rm -f "$OUTDIR/qemu.pid"
}

if [[ -n "${INTP_VM_IMAGE:-}" ]]; then
    run_vm_capture \
        "$INTP_VM_IMAGE" \
        "${INTP_VM_SSH_KEY:-$HOME/.ssh/id_rsa}" \
        "${INTP_VM_SSH_USER:-root}" || true
else
    echo "==> INTP_VM_IMAGE not set; skipping VM capture"
    echo "    set INTP_VM_IMAGE=/path/to/image.qcow2 and INTP_VM_SSH_KEY to enable"
fi

# ---- 4. optional comparison report ------------------------------------------
if (( DRY_RUN )); then
    echo "DRY: (would run compare-environments.py over $OUTDIR)"
elif [[ -x "$SCRIPT_DIR/compare-environments.py" ]]; then
    "$SCRIPT_DIR/compare-environments.py" "$OUTDIR" \
        > "$OUTDIR/comparison.md" || true
fi

echo "==> done. Results: $OUTDIR"

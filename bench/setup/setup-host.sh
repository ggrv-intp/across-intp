#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-host.sh -- Bootstrap an IntP testbed host.
#
# Auto-detects Ubuntu version and installs everything the bench script needs:
#
#   Ubuntu 22.04 (legacy / V0 baseline):
#       * pins HWE 6.5 kernel (latest pre-6.8, still has cqm_rmid for V0,
#         has full Sapphire Rapids uncore IMC support unlike kernel 5.10)
#       * SystemTap 5.2 + matching debuginfo via the ddebs archive
#       * intel-cmt-cat (RDT user-space)
#       * stress-ng / iperf3 / sysstat / perf / numactl / jq for the bench
#         script and its ground-truth side-channels
#       * docker + qemu + cloud-utils for the optional container/VM envs
#
#   Ubuntu 24.04 (modern / V0.1..V3):
#       * SystemTap + ddebs (V0.1 / V1 still need it)
#       * bpftrace (V3.1)
#       * clang / llvm / libbpf-dev / libelf-dev / pahole (V3)
#       * BTF availability check
#       * everything from the common set above
#
# In both profiles:
#       * mounts resctrl and persists it in /etc/fstab
#       * sets perf_event_paranoid=-1 and kptr_restrict=0 via sysctl.d
#       * builds v2 and (on 24.04) v3
#       * runs a smoke test for each installed profiler
#
# This script is idempotent. The first pass on a fresh 22.04 install will
# pin HWE 6.5 and request a reboot; running it again after the reboot
# completes the build and self-tests.
#
# Usage:
#   sudo ./setup-host.sh                   # auto-detect profile
#   sudo ./setup-host.sh --profile legacy  # force 22.04 / V0 path
#   sudo ./setup-host.sh --profile modern  # force 24.04 / V0.1..V3 path
#   sudo ./setup-host.sh --no-optional     # skip docker / qemu
#   sudo ./setup-host.sh --no-build        # skip make of v2/v3
#   sudo ./setup-host.sh --no-debuginfo    # skip ddebs (faster, no SystemTap full-signal)
# -----------------------------------------------------------------------------

set -euo pipefail

PROFILE_OVERRIDE=""
INSTALL_OPTIONAL=1
DO_BUILD=1
DO_DEBUGINFO=1
NEEDS_REBOOT=0

# -----------------------------------------------------------------------------
# 1. CLI / preflight
# -----------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)        PROFILE_OVERRIDE="$2"; shift 2 ;;
        --no-optional)    INSTALL_OPTIONAL=0; shift ;;
        --no-build)       DO_BUILD=0; shift ;;
        --no-debuginfo)   DO_DEBUGINFO=0; shift ;;
        -h|--help)
            sed -n '2,/^# ---/p' "$0" | sed 's/^# \?//; /^---$/q'
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "must run as root"

. /etc/os-release
case "${ID:-}" in
    ubuntu) ;;
    debian) warn "running on Debian -- this script is tuned for Ubuntu, but will try" ;;
    *) die "unsupported distro: ${ID:-unknown}" ;;
esac

CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
case "${VERSION_ID:-}" in
    22.04) DETECTED_PROFILE="legacy" ;;
    24.04) DETECTED_PROFILE="modern" ;;
    *)     DETECTED_PROFILE="" ;;
esac

PROFILE="${PROFILE_OVERRIDE:-$DETECTED_PROFILE}"
[ -n "$PROFILE" ] || die "could not infer profile from VERSION_ID=$VERSION_ID; use --profile"

case "$PROFILE" in
    legacy|modern) ;;
    *) die "invalid --profile: $PROFILE (legacy | modern)" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

log "host=$(hostname) os=$PRETTY_NAME kernel=$(uname -r) profile=$PROFILE"
log "repo=$REPO_ROOT"

# -----------------------------------------------------------------------------
# 2. Apt setup -- ddebs (matched debuginfo, SystemTap requires it)
# -----------------------------------------------------------------------------

setup_ddebs() {
    [ "$DO_DEBUGINFO" -eq 1 ] || { log "skipping debuginfo per --no-debuginfo"; return 0; }
    [ -n "$CODENAME" ] || { warn "no codename; skipping ddebs"; return 0; }

    local list=/etc/apt/sources.list.d/ddebs.list
    if [ ! -f "$list" ]; then
        log "configuring ddebs.ubuntu.com for $CODENAME"
        cat > "$list" <<EOF
deb http://ddebs.ubuntu.com/ ${CODENAME} main restricted universe multiverse
deb http://ddebs.ubuntu.com/ ${CODENAME}-updates main restricted universe multiverse
deb http://ddebs.ubuntu.com/ ${CODENAME}-proposed main restricted universe multiverse
EOF
    fi
    apt-get install -y ubuntu-dbgsym-keyring >/dev/null 2>&1 || \
        apt-key adv --keyserver keyserver.ubuntu.com --recv-keys C8CAB6595FDFF622 >/dev/null 2>&1 || \
        warn "could not install ddebs key -- ddeb installs will fail signature checks"
}

# -----------------------------------------------------------------------------
# 3. Kernel pinning -- only on 22.04, install latest 6.5 and hold
# -----------------------------------------------------------------------------

pin_hwe_65() {
    local cur kver_major kver_minor
    cur=$(uname -r)
    kver_major=$(echo "$cur" | cut -d. -f1)
    kver_minor=$(echo "$cur" | cut -d. -f2)

    if [ "$kver_major" -eq 6 ] && [ "$kver_minor" -eq 5 ]; then
        log "already running on a 6.5 kernel ($cur), no pin needed"
        return 0
    fi

    log "looking for the newest linux-image-6.5.* in apt"
    apt-get update -qq

    # Latest 6.5.x-NN-generic available in this archive snapshot.
    local latest
    latest=$(apt-cache search '^linux-image-6\.5\.[0-9]+-[0-9]+-generic$' \
                | awk '{print $1}' | sort -V | tail -1)
    if [ -z "$latest" ]; then
        warn "no 6.5 kernel in apt -- jammy archive may have moved past 6.5"
        warn "Check manually: 'apt list --all-versions linux-image-6.5*'"
        warn "If empty, fall back to manually downloading 6.5 .debs from"
        warn "https://launchpad.net/ubuntu/+source/linux-hwe-6.5/+publishinghistory"
        die "cannot proceed without 6.5 kernel for V0 baseline"
    fi
    local headers="linux-headers-${latest#linux-image-}"
    log "installing $latest + $headers"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$latest" "$headers"

    # Hold to prevent jammy-updates from rolling forward to 6.8+ (which would
    # break V0).
    apt-mark hold "$latest" "$headers" >/dev/null
    apt-mark hold linux-image-generic-hwe-22.04 linux-headers-generic-hwe-22.04 >/dev/null 2>&1 || true

    # Force GRUB to default to the 6.5 entry on next boot.
    local menuentry
    menuentry=$(grep -oP "menuentry '[^']*${latest#linux-image-}[^']*'" /boot/grub/grub.cfg \
                | head -1 | sed "s/menuentry '\(.*\)'/\1/")
    if [ -n "$menuentry" ]; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"Advanced options for Ubuntu>${menuentry}\"|" /etc/default/grub
        update-grub
    else
        warn "could not locate GRUB menuentry for $latest -- you may need to pick it manually on first boot"
    fi
    NEEDS_REBOOT=1
}

# -----------------------------------------------------------------------------
# 4. Common packages (both profiles)
# -----------------------------------------------------------------------------

install_common() {
    log "installing common packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential make gcc git curl wget jq pkg-config \
        stress-ng iperf3 sysstat numactl bc \
        linux-tools-common "linux-tools-$(uname -r)" \
        ca-certificates lsb-release
}

install_matching_kernel_compiler() {
    local compiler_pkg
    compiler_pkg=$(grep -oE 'gcc-[0-9]+' /proc/version | head -1 || true)

    if [ -z "$compiler_pkg" ]; then
        log "could not infer kernel compiler from /proc/version; relying on default gcc"
        return 0
    fi

    if command -v "$compiler_pkg" >/dev/null 2>&1; then
        log "kernel-matching compiler already present ($compiler_pkg)"
        return 0
    fi

    log "installing kernel-matching compiler ($compiler_pkg) for SystemTap module builds"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$compiler_pkg" \
        || warn "failed to install $compiler_pkg -- SystemTap builds may fail"
}

install_optional() {
    [ "$INSTALL_OPTIONAL" -eq 1 ] || { log "skipping optional packages per --no-optional"; return 0; }
    log "installing optional packages (docker / qemu / cloud-utils)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker.io qemu-system-x86 qemu-utils cloud-image-utils \
        || warn "optional packages partially failed (env=container/vm may not work)"
}

# -----------------------------------------------------------------------------
# 5. Profile-specific package sets
# -----------------------------------------------------------------------------

install_legacy_stack() {
    log "installing V0 stack (SystemTap 5.2 on 22.04 + HWE 6.5)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        intel-cmt-cat python3 python3-pip

    install_systemtap_52

    if [ "$DO_DEBUGINFO" -eq 1 ]; then
        # Matching debuginfo for the kernel that's actually running. After
        # pin_hwe_65 + reboot, this picks up 6.5.
        local krel=$(uname -r)
        local pkg="linux-image-${krel}-dbgsym"
        log "trying to install $pkg"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" \
            || warn "$pkg not yet available -- re-run setup after the kernel pin reboot"
        # SystemTap ships a helper that resolves and pulls everything else.
        stap-prep || warn "stap-prep returned non-zero (often benign)"
    fi
}

install_systemtap_52() {
    local stap_version srcdir

    if command -v stap >/dev/null 2>&1; then
        stap_version=$(stap --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\)\/.*/\1/p' | head -1)
        if [ -n "$stap_version" ] && dpkg --compare-versions "$stap_version" ge 5.2; then
            log "SystemTap $stap_version already installed"
            return 0
        fi
    fi

    log "building SystemTap 5.2 from source for kernel compatibility"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        autoconf automake bison flex gettext pkg-config \
        libavahi-client-dev libdw-dev libelf-dev libnspr4-dev libnss3-dev \
        libreadline-dev libsqlite3-dev libssl-dev libxml2-dev \
        python3-dev python3-setuptools zlib1g-dev

    srcdir=/usr/local/src/systemtap
    if [ -d "$srcdir/.git" ]; then
        git -C "$srcdir" fetch --tags origin
    else
        rm -rf "$srcdir"
        git clone https://sourceware.org/git/systemtap.git "$srcdir"
    fi

    git -C "$srcdir" checkout release-5.2
    (
        cd "$srcdir"
        ./configure --prefix=/usr/local --disable-docs --disable-publican --enable-sqlite --enable-virt >/dev/null
        make -j"$(nproc)"
        make install
    )
    hash -r

    if ! command -v stap >/dev/null 2>&1; then
        die "SystemTap 5.2 install completed but stap is not on PATH"
    fi
    log "using $(command -v stap) ($(stap --version 2>&1 | head -1))"
}

install_modern_stack() {
    log "installing V0.1..V3 stack (SystemTap + bpftrace + libbpf/CO-RE)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        systemtap systemtap-runtime libdw-dev gettext intel-cmt-cat \
        bpftrace python3 python3-pip python3-venv \
        clang llvm libbpf-dev libelf-dev pahole \
        "linux-headers-$(uname -r)"

    if [ "$DO_DEBUGINFO" -eq 1 ]; then
        local krel=$(uname -r)
        DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-image-${krel}-dbgsym" \
            || warn "kernel debuginfo unavailable -- V1 (SystemTap+resctrl) will fail probe compilation"
        stap-prep || warn "stap-prep returned non-zero"
    fi

    if [ ! -f /sys/kernel/btf/vmlinux ]; then
        warn "/sys/kernel/btf/vmlinux missing -- V3.1 and V3 will not load BPF programs"
    else
        log "BTF present at /sys/kernel/btf/vmlinux"
    fi
}

# -----------------------------------------------------------------------------
# 6. Kernel runtime config -- resctrl mount + sysctls
# -----------------------------------------------------------------------------

configure_kernel_runtime() {
    log "configuring kernel runtime (resctrl, sysctls)"

    if grep -q resctrl /proc/filesystems 2>/dev/null; then
        if ! mountpoint -q /sys/fs/resctrl; then
            mount -t resctrl resctrl /sys/fs/resctrl \
                && log "mounted resctrl at /sys/fs/resctrl" \
                || warn "failed to mount resctrl -- mbw / llcocc will be unavailable"
        fi
    else
        warn "resctrl filesystem not in /proc/filesystems -- check CONFIG_X86_CPU_RESCTRL"
    fi

    if ! grep -q '/sys/fs/resctrl' /etc/fstab; then
        echo 'resctrl /sys/fs/resctrl resctrl defaults 0 0' >> /etc/fstab
        log "persisted resctrl mount in /etc/fstab"
    fi

    cat > /etc/sysctl.d/99-intp-bench.conf <<'EOF'
# IntP bench: allow uncore IMC counters and kernel pointer reads needed by
# SystemTap and eBPF profilers. Only activates after `sysctl --system`.
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0
EOF
    sysctl --system >/dev/null
    log "applied perf_event_paranoid=-1 and kptr_restrict=0"
}

# -----------------------------------------------------------------------------
# 7. Build variants
# -----------------------------------------------------------------------------

build_variants() {
    [ "$DO_BUILD" -eq 1 ] || { log "skipping build per --no-build"; return 0; }

    if [ -d "$REPO_ROOT/variants/v2-c-abi" ]; then
        log "building v2 (hybrid procfs)"
        make -C "$REPO_ROOT/variants/v2-c-abi" || warn "v2 build failed"
    fi

    if [ "$PROFILE" = "modern" ] && [ -d "$REPO_ROOT/variants/v3-ebpf-ring" ]; then
        log "building v3 (eBPF/CO-RE)"
        make -C "$REPO_ROOT/variants/v3-ebpf-ring" || warn "v3 build failed"
    fi
}

# -----------------------------------------------------------------------------
# 8. Self-tests -- one per profiler we expect to work in this profile
# -----------------------------------------------------------------------------

selftest() {
    log "self-tests"

    if command -v stap >/dev/null 2>&1; then
        if timeout 30 stap -e 'probe begin { log("stap_ok"); exit() }' 2>/dev/null \
                | grep -q stap_ok; then
            log "  stap        OK"
        else
            warn "  stap        FAIL (missing gcc-X, headers, or module build mismatch?)"
        fi
    fi

    if [ -x "$REPO_ROOT/variants/v2-c-abi/intp-c-abi" ]; then
        if "$REPO_ROOT/variants/v2-c-abi/intp-c-abi" --list-backends >/dev/null 2>&1; then
            log "  v2          OK ($(${REPO_ROOT}/variants/v2-c-abi/intp-c-abi --list-backends 2>&1 | head -1))"
        else
            warn "  v2          FAIL (--list-backends returned non-zero)"
        fi
    fi

    if [ "$PROFILE" = "modern" ]; then
        if command -v bpftrace >/dev/null 2>&1; then
            log "  bpftrace    OK ($(bpftrace --version 2>&1 | head -1))"
        else
            warn "  bpftrace    missing"
        fi
        if [ -x "$REPO_ROOT/variants/v3-ebpf-ring/intp-ebpf-ring" ]; then
            if "$REPO_ROOT/variants/v3-ebpf-ring/intp-ebpf-ring" --list-capabilities >/dev/null 2>&1; then
                log "  v3          OK"
            else
                warn "  v3          FAIL"
            fi
        fi
    fi

    log "  resctrl     $([ -d /sys/fs/resctrl/info/L3_MON ] && echo OK || echo missing)"
    log "  BTF         $([ -f /sys/kernel/btf/vmlinux ] && echo OK || echo missing)"
    log "  paranoid    $(cat /proc/sys/kernel/perf_event_paranoid)"
}

# -----------------------------------------------------------------------------
# 9. Driver
# -----------------------------------------------------------------------------

main() {
    apt-get update -qq

    setup_ddebs

    if [ "$PROFILE" = "legacy" ]; then
        pin_hwe_65
        if [ "$NEEDS_REBOOT" -eq 1 ]; then
            log ""
            log "==============================================================="
            log "HWE 6.5 kernel installed and held. Reboot, then re-run this"
            log "script to install SystemTap, build the variants, and self-test."
            log ""
            log "    reboot"
            log "    sudo $0 --profile legacy"
            log "==============================================================="
            exit 0
        fi
    fi

    install_common
    install_matching_kernel_compiler
    install_optional

    if [ "$PROFILE" = "legacy" ]; then
        install_legacy_stack
    else
        install_modern_stack
    fi

    configure_kernel_runtime
    build_variants
    selftest

    log ""
    log "Setup complete. Next:"
    log "    sudo $REPO_ROOT/bench/run-intp-bench.sh --variants $([ "$PROFILE" = "legacy" ] && echo "v0" || echo "v0.1,v1,v2,v3.1,v3")"
}

main

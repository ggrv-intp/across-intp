#!/usr/bin/env bash
# export-vm-contents.sh — extract the IntP experimental stack from a qcow2
# OR from a bare-metal host's running filesystem into a portable tarball.
#
# Designed for two real-world flows:
#  1. Reformat-and-restore: snapshot the configured Hetzner Ubuntu 24 host
#     so a freshly rented / freshly imaged machine can recover the same
#     state without re-running setup-spark-hibench, HDFS provisioning, etc.
#  2. Cross-boot transfer: extract from a qcow2 or from the Ubuntu 24
#     installation, then restore on the same physical machine after it
#     boots into Ubuntu 22 + older kernel (kept on a different partition).
#
# Modes:
#   --from-qcow2 PATH    libguestfs virt-tar-out from a qcow2 image
#   --from-host          tar from the running host's filesystem
#
# Default INCLUDE_PATHS (override via env INCLUDE_PATHS=...):
#   /opt/hadoop                 full Hadoop dist + pseudo-distributed config
#   /opt/spark                  full Spark dist
#   /opt/HiBench                HiBench checkout + customised conf
#   /opt/intp                   IntP repo (skipped if /root/intp present)
#   /root/intp                  IntP repo (host bare-metal location)
#   /root/.ssh                  ssh keys (sshd-localhost auth for HDFS)
#   /var/lib/hadoop             HDFS storage dirs + tmp (CAREFUL: large)
#   /var/lib/hibench            HiBench reports + datasets metadata
#   /usr/local/bin/intp-entrypoint
#   /etc/profile.d/intp.sh
#
# Optional bundles (opt-in to keep tarball lean):
#   --no-hdfs-data        skip /var/lib/hadoop/hdfs/data (the multi-GB blocks)
#   --include-apt-list    snapshot dpkg --get-selections into ./apt-packages.list
#                         (consumed by import-vm-contents.sh)
#   --include-services    snapshot /etc/systemd/system/intp-*.service if any
#
# Usage:
#   bash export-vm-contents.sh --from-host --include-apt-list /tmp/intp-bundle.tar.zst
#   bash export-vm-contents.sh --from-qcow2 /var/lib/intp/ubuntu24.qcow2 /tmp/vm-bundle.tar.zst
#
# Output: zstd-compressed tarball (~few GB without HDFS data, 10+ GB with).

set -u -o pipefail

log()  { printf '[export-vm-contents] %s\n' "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

INCLUDE_PATHS=(
    /opt/hadoop
    /opt/spark
    /opt/HiBench
    /opt/intp
    /root/across-intp
    /root/.ssh
    /var/lib/hadoop
    /var/lib/hibench
    /usr/local/bin/intp-entrypoint
    /etc/profile.d/intp.sh
)

MODE=""
SOURCE=""
OUT=""
INCLUDE_APT_LIST=0
INCLUDE_SERVICES=0
NO_HDFS_DATA=0
EXCLUDE_PATHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --from-qcow2)        MODE=qcow2; SOURCE="$2"; shift 2 ;;
        --from-host)         MODE=host; shift ;;
        --include-apt-list)  INCLUDE_APT_LIST=1; shift ;;
        --include-services)  INCLUDE_SERVICES=1; shift ;;
        --no-hdfs-data)      NO_HDFS_DATA=1; shift ;;
        --exclude)           EXCLUDE_PATHS+=("$2"); shift 2 ;;
        -h|--help)           sed -n '1,/^$/p' "$0"; exit 0 ;;
        *) [ -z "$OUT" ] && OUT="$1" || die "unexpected arg: $1"; shift ;;
    esac
done

if [ "$NO_HDFS_DATA" = "1" ]; then
    EXCLUDE_PATHS+=(/var/lib/hadoop/hdfs/data /var/lib/hadoop/tmp)
fi
[ -z "$MODE" ] && die "specify --from-host or --from-qcow2 PATH"
[ -z "$OUT"  ] && die "missing output tarball path"

# Pick a compressor: zstd is fastest for big files, fall back to gzip.
if command -v zstd >/dev/null 2>&1; then
    COMPRESS="zstd -3 -T0"
    EXT=".zst"
else
    COMPRESS="gzip -3"
    EXT=".gz"
    log "WARN: zstd not in PATH; using gzip (slower)"
fi
case "$OUT" in
    *.zst|*.gz) ;;
    *) OUT="${OUT}${EXT}" ;;
esac

mkdir -p "$(dirname "$OUT")"
TMP_TAR="$(mktemp)"

_apt_list_path() { echo "$WORK_DIR/intp-export-meta/apt-packages.list"; }
_services_dir()  { echo "$WORK_DIR/intp-export-meta/systemd"; }

WORK_DIR=$(mktemp -d -t intp-export-XXXXXX)
trap 'rm -rf "$WORK_DIR" "$TMP_TAR"' EXIT

# Build sidecar metadata (apt list, services) if requested.
mkdir -p "$WORK_DIR/intp-export-meta"
echo "$(date -Iseconds) host=$(hostname) kernel=$(uname -r) os=$(. /etc/os-release; echo $PRETTY_NAME)" \
    > "$WORK_DIR/intp-export-meta/manifest.txt"
if [ "$INCLUDE_APT_LIST" = "1" ]; then
    log "snapshotting dpkg --get-selections"
    dpkg --get-selections > "$(_apt_list_path)" 2>/dev/null || \
        warn "dpkg failed (likely not on Debian/Ubuntu host)"
fi
if [ "$INCLUDE_SERVICES" = "1" ]; then
    mkdir -p "$(_services_dir)"
    cp -a /etc/systemd/system/intp-*.service "$(_services_dir)/" 2>/dev/null || true
fi

# Build tar exclusion args once
TAR_EXCLUDE_ARGS=()
for ex in "${EXCLUDE_PATHS[@]}"; do
    TAR_EXCLUDE_ARGS+=(--exclude="$ex")
done

case "$MODE" in
    host)
        log "exporting from running host"
        local_paths=()
        for p in "${INCLUDE_PATHS[@]}"; do
            if [ -e "$p" ]; then
                local_paths+=("$p")
            else
                log "  skip (not present): $p"
            fi
        done
        [ ${#local_paths[@]} -eq 0 ] && die "no INCLUDE_PATHS exist on host"
        log "  paths: ${local_paths[*]}"
        [ ${#TAR_EXCLUDE_ARGS[@]} -gt 0 ] && log "  excluding: ${EXCLUDE_PATHS[*]}"
        # --numeric-owner so we don't depend on UIDs matching across hosts;
        # preserve permissions; explicit excludes for opt-out paths.
        tar --numeric-owner --preserve-permissions \
            "${TAR_EXCLUDE_ARGS[@]}" \
            -C "$WORK_DIR" -cf "$TMP_TAR" intp-export-meta
        tar --numeric-owner --preserve-permissions \
            "${TAR_EXCLUDE_ARGS[@]}" \
            --append -f "$TMP_TAR" "${local_paths[@]}"
        ;;
    qcow2)
        [ -f "$SOURCE" ] || die "qcow2 not found: $SOURCE"
        command -v virt-tar-out >/dev/null 2>&1 || \
            die "missing: virt-tar-out (apt: libguestfs-tools)"
        log "exporting from qcow2: $SOURCE"
        # virt-tar-out extracts a directory tree from a guest filesystem to a
        # local tarball. We invoke it once per top-level path because the
        # tool takes a single -d and a single output path; we concatenate.
        : > "$TMP_TAR"
        for p in "${INCLUDE_PATHS[@]}"; do
            log "  extracting $p"
            local_tar="$(mktemp)"
            if virt-tar-out -a "$SOURCE" "$p" "$local_tar" 2>/dev/null; then
                # Append into the cumulative tar (skip the leading "./" prefix).
                tar --concatenate --file="$TMP_TAR" "$local_tar" 2>/dev/null \
                    || cat "$local_tar" >> "$TMP_TAR"
                rm -f "$local_tar"
            else
                log "    skip (not in image): $p"
                rm -f "$local_tar"
            fi
        done
        ;;
esac

log "compressing → $OUT"
$COMPRESS < "$TMP_TAR" > "$OUT"
log "done. size: $(du -h "$OUT" | cut -f1)"
log ""
log "Restore on another host with:"
log "  bash bench/deploy/import-vm-contents.sh $OUT"

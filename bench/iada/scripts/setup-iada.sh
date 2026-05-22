#!/usr/bin/env bash
# setup-iada.sh — Provisioning script for the IADA/CloudSim simulation host.
#
# Installs R + rJava + native deps, prepares env vars, clones (or refreshes)
# the CloudSimInterference fork, applies the MLClassifier.java env-var patch
# if needed, and writes ~/.iada-env for downstream campaigns.
#
# Idempotent: re-runs are safe.
#
# Usage:
#   sudo bash bench/iada/scripts/setup-iada.sh --auto-clone
#   sudo bash bench/iada/scripts/setup-iada.sh \
#       --cloudsim /existing/CloudSimInterference \
#       --intp-r-folder /existing/CloudSimInterference/R
#
# After this finishes, source the env file before running campaigns:
#   source ~/.iada-env

set -euo pipefail

CLOUDSIM_REPO=""
INTP_R_FOLDER=""
JAVA_HOME_OVERRIDE=""
AUTO_CLONE=0
NO_UPDATE=0
CLONE_ROOT=""
CLOUDSIM_REF="master"
CLOUDSIM_URL="https://github.com/ggrv-intp/CloudSimInterference.git"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# bench/iada/scripts → repo root is three levels up
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  --auto-clone               Clone CloudSimInterference if missing
                             (default: refuse and instruct)
  --no-update                If repo present, do not fetch/pull
  --clone-root DIR           Parent dir where CloudSimInterference is/will be
                             (default: parent of this repo: $(dirname "$REPO_ROOT"))
  --cloudsim-ref REF         Branch/tag/SHA to checkout (default: master)
  --cloudsim DIR             Explicit path to existing CloudSimInterference
                             (overrides --clone-root)
  --intp-r-folder DIR        Path to CloudSim's R/ subdir (auto-derived if absent)
  --java-home DIR            Override JAVA_HOME (default: auto-detect Java 17)
  -h, --help                 Show this help

What this does:
  1. Installs apt packages: r-base, r-base-dev, r-cran-rjava, libtirpc-dev,
     openjdk-17-jdk-headless, build-essential, git
  2. Installs R packages into ~/R/library: ocp, e1071, caret, dplyr, ggplot2
  3. Clones/refreshes CloudSimInterference under <clone-root>
  4. Applies mlclassifier-env-vars.patch idempotently (skipped silently if
     the fork already carries the env-var loader for INTP_R_FOLDER)
  5. Writes ~/.iada-env (CLOUDSIM_REPO, INTP_R_FOLDER, INTP_R_LIBPATHS,
     JAVA_HOME, LD_LIBRARY_PATH, INTP_JAVA_OPTS)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --auto-clone)     AUTO_CLONE=1; shift ;;
        --no-update)      NO_UPDATE=1; shift ;;
        --clone-root)     CLONE_ROOT="$2"; shift 2 ;;
        --cloudsim-ref)   CLOUDSIM_REF="$2"; shift 2 ;;
        --cloudsim)       CLOUDSIM_REPO="$2"; shift 2 ;;
        --intp-r-folder)  INTP_R_FOLDER="$2"; shift 2 ;;
        --java-home)      JAVA_HOME_OVERRIDE="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (apt install needs it)"

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# Default --clone-root to the parent dir of this repo, so that
# across-intp and CloudSimInterference end up as siblings.
if [ -z "$CLONE_ROOT" ]; then
    CLONE_ROOT="$(dirname "$REPO_ROOT")"
fi

# ─── 1. apt deps ─────────────────────────────────────────────────────────────
log "installing apt dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    r-base r-base-dev r-cran-rjava \
    libtirpc-dev libcurl4-openssl-dev libssl-dev libxml2-dev \
    openjdk-17-jdk-headless \
    build-essential pkg-config git \
    >/dev/null

# ─── 2. JAVA_HOME ────────────────────────────────────────────────────────────
if [ -n "$JAVA_HOME_OVERRIDE" ]; then
    JAVA_HOME="$JAVA_HOME_OVERRIDE"
elif [ -d /usr/lib/jvm/java-17-openjdk-amd64 ]; then
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
else
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
fi
[ -d "$JAVA_HOME" ] || die "JAVA_HOME=$JAVA_HOME does not exist"
log "JAVA_HOME = $JAVA_HOME"

# ─── 3. rJava reconfig ───────────────────────────────────────────────────────
log "rJava JAVA reconfigure"
JAVA_HOME="$JAVA_HOME" R CMD javareconf >/dev/null 2>&1 || \
    warn "R CMD javareconf returned non-zero — check openjdk-17-jdk-headless"

# ─── 4. R packages into user library ─────────────────────────────────────────
R_LIBS_USER="$TARGET_HOME/R/library"
mkdir -p "$R_LIBS_USER"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/R" 2>/dev/null || true

log "installing R packages into $R_LIBS_USER"
sudo -u "$TARGET_USER" \
    R_LIBS_USER="$R_LIBS_USER" \
    JAVA_HOME="$JAVA_HOME" \
    R --no-save --quiet <<'RSCRIPT' || warn "some R packages failed to install — review output"
options(repos = c(CRAN = "https://cloud.r-project.org"))
required <- c("ocp", "e1071", "caret", "dplyr", "ggplot2", "rJava")
to_install <- setdiff(required, rownames(installed.packages(lib.loc = Sys.getenv("R_LIBS_USER"))))
if (length(to_install) > 0) {
    install.packages(to_install, lib = Sys.getenv("R_LIBS_USER"), Ncpus = 4)
}
cat("R libraries installed:\n")
for (p in required) {
    found <- p %in% rownames(installed.packages(lib.loc = Sys.getenv("R_LIBS_USER")))
    cat(sprintf("  %-12s %s\n", p, ifelse(found, "OK", "MISSING")))
}
RSCRIPT

# ─── 5. CloudSimInterference clone-or-update ─────────────────────────────────
_clone_or_update() {
    # Resolve target dir.
    if [ -z "$CLOUDSIM_REPO" ]; then
        CLOUDSIM_REPO="$CLONE_ROOT/CloudSimInterference"
    fi
    log "CloudSim target: $CLOUDSIM_REPO"

    if [ ! -e "$CLOUDSIM_REPO" ]; then
        if [ "$AUTO_CLONE" != "1" ]; then
            die "$CLOUDSIM_REPO missing. Pass --auto-clone to fetch it, or use --cloudsim <existing-path>."
        fi
        mkdir -p "$CLONE_ROOT"
        sudo -u "$TARGET_USER" git clone "$CLOUDSIM_URL" "$CLOUDSIM_REPO" \
            || die "git clone failed"
        log "cloned $CLOUDSIM_URL → $CLOUDSIM_REPO"
    else
        if [ ! -d "$CLOUDSIM_REPO/.git" ]; then
            die "$CLOUDSIM_REPO exists but is not a git repo — refusing to touch"
        fi
        local origin
        origin=$(sudo -u "$TARGET_USER" git -C "$CLOUDSIM_REPO" remote get-url origin 2>/dev/null || true)
        if [ -z "$origin" ]; then
            warn "$CLOUDSIM_REPO has no 'origin' remote — leaving as-is"
        elif [ "$origin" != "$CLOUDSIM_URL" ]; then
            warn "$CLOUDSIM_REPO origin=$origin (expected $CLOUDSIM_URL) — leaving as-is, please verify"
        fi
        if [ "$NO_UPDATE" != "1" ]; then
            sudo -u "$TARGET_USER" git -C "$CLOUDSIM_REPO" fetch --tags origin \
                || warn "git fetch failed (offline?) — continuing with local state"
        fi
    fi

    sudo -u "$TARGET_USER" git -C "$CLOUDSIM_REPO" checkout "$CLOUDSIM_REF" \
        || die "git checkout $CLOUDSIM_REF failed"
    if [ "$NO_UPDATE" != "1" ]; then
        sudo -u "$TARGET_USER" git -C "$CLOUDSIM_REPO" pull --ff-only \
            || warn "git pull --ff-only failed (detached or behind?) — continuing"
    fi
    local head_sha
    head_sha=$(sudo -u "$TARGET_USER" git -C "$CLOUDSIM_REPO" rev-parse HEAD)
    log "CloudSim HEAD = $head_sha"
}
_clone_or_update

# Auto-derive INTP_R_FOLDER from CLOUDSIM_REPO if not given.
if [ -z "$INTP_R_FOLDER" ]; then
    INTP_R_FOLDER="$CLOUDSIM_REPO/R"
fi
[ -d "$INTP_R_FOLDER" ] || warn "$INTP_R_FOLDER does not exist"

# ─── 6. MLClassifier.java patch (idempotent, silent skip if already in) ──────
ML_CLASSIFIER=$(find "$CLOUDSIM_REPO" -name 'MLClassifier.java' 2>/dev/null | head -1)
PATCH_FILE="$REPO_ROOT/bench/iada/patches/mlclassifier-env-vars.patch"

if [ -z "$ML_CLASSIFIER" ]; then
    warn "MLClassifier.java not found in $CLOUDSIM_REPO"
elif grep -q 'INTP_R_FOLDER' "$ML_CLASSIFIER"; then
    log "MLClassifier.java already exposes INTP_R_FOLDER — patch skipped"
elif [ ! -f "$PATCH_FILE" ]; then
    warn "$PATCH_FILE missing — cannot patch automatically; apply manually"
else
    log "applying $PATCH_FILE to $CLOUDSIM_REPO"
    if (cd "$CLOUDSIM_REPO" && sudo -u "$TARGET_USER" git apply --check "$PATCH_FILE" 2>/dev/null); then
        (cd "$CLOUDSIM_REPO" && sudo -u "$TARGET_USER" git apply "$PATCH_FILE") \
            || die "git apply failed mid-way"
        log "patch applied — OPERATOR: rebuild CloudSim (mvn package / gradle build / your toolchain) before running campaigns"
    else
        warn "patch does not apply cleanly; inspect manually"
    fi
fi

# ─── 7. JRI library path detection ────────────────────────────────────────────
JRI_LIB=""
for cand in \
    "$R_LIBS_USER/rJava/jri" \
    /usr/lib/R/site-library/rJava/jri \
    /usr/local/lib/R/site-library/rJava/jri; do
    if [ -d "$cand" ] && [ -f "$cand/libjri.so" ]; then
        JRI_LIB="$cand"; break
    fi
done
[ -z "$JRI_LIB" ] && warn "libjri.so not found — rJava install may have failed"
R_LIB_DIR=$(R RHOME 2>/dev/null)/lib
log "JRI lib = $JRI_LIB"
log "R lib   = $R_LIB_DIR"

# ─── 8. Write env file ────────────────────────────────────────────────────────
ENV_FILE="$TARGET_HOME/.iada-env"
log "writing $ENV_FILE"
cat > "$ENV_FILE" <<EOF
# Generated by setup-iada.sh on $(date -Iseconds). Source before running IADA.
# Required to keep R 4.x + Java 17 cooperating without segfault under JRI.
export JAVA_HOME="$JAVA_HOME"
export PATH="\$JAVA_HOME/bin:\$PATH"
export R_LIBS_USER="$R_LIBS_USER"
export LD_LIBRARY_PATH="$JRI_LIB:$R_LIB_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"

# CloudSimInterference checkout (cloned/refreshed by setup-iada.sh).
export CLOUDSIM_REPO="$CLOUDSIM_REPO"

# IntP R folder read by the patched MLClassifier.java.
export INTP_R_FOLDER="$INTP_R_FOLDER"
export INTP_R_LIBPATHS="$R_LIBS_USER"

# JVM flags that prevent JRI ↔ R signal-handler clashes.
# - R_SignalHandlers=0 disables R's own SIGINT/SIGSEGV handlers in JRI mode
# - SerialGC + Xss8m reduce contention with native R threads
export INTP_JAVA_OPTS="-DR_SignalHandlers=0 -XX:+UseSerialGC -Xss8m"
EOF
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"

# ─── 9. Next steps ───────────────────────────────────────────────────────────
cat <<NEXT

================================================================================
SETUP COMPLETE
================================================================================

CloudSim:           $CLOUDSIM_REPO
INTP_R_FOLDER:      $INTP_R_FOLDER
env file:           $ENV_FILE

1. Source the env file in every shell that runs IADA campaigns:

       source ~/.iada-env

2. (If the patch step warned about a missing build) rebuild CloudSim:

       cd "\$CLOUDSIM_REPO" && <your build command, e.g. mvn package>

3. Smoke test the wrapper end-to-end:

       bash bench/iada/scripts/run-iada-from-bench.sh \\
           results/<some-cross-env-campaign-dir>

================================================================================
NEXT

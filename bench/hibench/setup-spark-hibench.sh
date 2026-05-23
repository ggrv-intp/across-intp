#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-spark-hibench.sh
#
# Provision a single-node Spark + HiBench stack on Ubuntu for IntP experiments.
#
# Goals:
# - keep execution local (no external cluster required)
# - support the representative subset used for IntP metric coverage
# - install Python benchmark dependencies (numpy, matplotlib, pandas, scipy)
#
# Environment overrides:
#   SPARK_VERSION             (default: 3.5.3)
#   HADOOP_PROFILE            (default: 3)
#   HIBENCH_REF               (default: master)
#   INSTALL_ROOT              (default: /opt)
#   JOBS_DIR                  (default: /var/lib/hibench)
#   HIBENCH_SCALE             (default: small)
#   SKIP_DATA_PREP            (default: 0)   set to 1 to skip dataset generation
#   SCALA_FULL_VERSION        (default: 2.12.18) only consulted when direct-version mode is on
#   HIBENCH_MVN_DIRECT_VERSIONS (default: 0) when 1, pass -Dspark.version / -Dscala.version
#                             literally instead of relying on HiBench's -Dspark=<X.Y>
#                             profile shortcut. Required on the U22/5.15 legacy leg
#                             where the cloned HiBench master lacks a profile that
#                             matches the requested Spark major.minor and the build
#                             fails with literal '${spark.version}' in dep coordinates.
#   KAFKA_VERSION             (default: 1.1.1) only consulted in direct-version mode
#                             (legacy/U22 leg). HiBench's common/pom.xml hardcodes
#                             0.8.2.1 which doesn't exist for scala_2.12; the
#                             auto-patcher rewrites that literal to ${kafka.version}
#                             so this override takes effect. 1.1.1 is the last Kafka
#                             with the legacy AdminUtils / ZKStringSerializer API
#                             that hibench-common's MetricsUtil.scala references —
#                             Kafka 2.x+ drops those classes and fails compile with
#                             32 errors. Streaming workloads can't run against Spark
#                             3.5 anyway; this just keeps the unused code compilable.
#                             Not needed on the U24/6.8 leg (profile-shortcut mode
#                             gets kafka.version from HiBench's spark<X.Y> profile).
#   KAFKA_BINARY_VERSION      (default: same as SCALA_VERSION, i.e. 2.12)
#   HIBENCH_MVN_EXTRA_ARGS    (default: empty) extra -D args appended to every mvn
#                             invocation, word-split. Use this to chase further
#                             pinned deps that the missing profile would have set,
#                             e.g. HIBENCH_MVN_EXTRA_ARGS="-Dhadoop.version=3.3.6
#                             -Dflume.version=1.9.0".
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SPARK_VERSION="${SPARK_VERSION:-3.5.3}"
HADOOP_PROFILE="${HADOOP_PROFILE:-3}"
HIBENCH_REF="${HIBENCH_REF:-master}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
JOBS_DIR="${JOBS_DIR:-/var/lib/hibench}"
HIBENCH_SCALE="${HIBENCH_SCALE:-small}"
SKIP_DATA_PREP="${SKIP_DATA_PREP:-0}"
SCALA_FULL_VERSION="${SCALA_FULL_VERSION:-2.12.18}"
HIBENCH_MVN_DIRECT_VERSIONS="${HIBENCH_MVN_DIRECT_VERSIONS:-0}"
# KAFKA_VERSION default is for the legacy/U22 leg (HIBENCH_MVN_DIRECT_VERSIONS=1).
# 1.1.1 is the last Kafka release with the AdminUtils API that hibench-common
# references; raising this breaks the build with 32 Scala compile errors. The
# U24 leg ignores this var (its spark<X.Y> profile sets kafka.version itself).
KAFKA_VERSION="${KAFKA_VERSION:-1.1.1}"
KAFKA_BINARY_VERSION="${KAFKA_BINARY_VERSION:-2.12}"
HIBENCH_MVN_EXTRA_ARGS="${HIBENCH_MVN_EXTRA_ARGS:-}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"

SPARK_DIR="spark-$SPARK_VERSION-bin-hadoop$HADOOP_PROFILE"
SPARK_HOME_VERSIONED="$INSTALL_ROOT/$SPARK_DIR"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"   # canonical symlink used by all scripts
HIBENCH_HOME="${HIBENCH_HOME:-$INSTALL_ROOT/HiBench}"
HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
SCALA_VERSION="2.12"

# Build the Maven version arguments once. Two shapes:
#   profile shortcut (default):   -Dspark=<major.minor> -Dscala=<binary>
#       Relies on HiBench's parent pom defining a profile activated by the
#       'spark' property. Works when the cloned HiBench supports the
#       requested Spark major.minor.
#   direct versions (toggle on):  -Dspark.version=<full> -Dscala.binary.version=<binary>
#                                 -Dscala.version=<full>
#       Bypasses the profile mechanism and pins the dep coords directly.
#       Use on the U22/5.15 legacy leg (HIBENCH_MVN_DIRECT_VERSIONS=1).
if [ "$HIBENCH_MVN_DIRECT_VERSIONS" = "1" ]; then
    MVN_VERSION_ARGS=(
        "-Dspark.version=$SPARK_VERSION"
        "-Dscala.binary.version=$SCALA_VERSION"
        "-Dscala.version=$SCALA_FULL_VERSION"
        "-Dkafka.version=$KAFKA_VERSION"
        "-Dkafka.binary.version=$KAFKA_BINARY_VERSION"
    )
    log_mvn_mode() { log "Maven version mode: direct (spark.version=$SPARK_VERSION scala.version=$SCALA_FULL_VERSION kafka.version=$KAFKA_VERSION)"; }
else
    MVN_VERSION_ARGS=(
        "-Dspark=$(echo "$SPARK_VERSION" | cut -d. -f1-2)"
        "-Dscala=$SCALA_VERSION"
    )
    log_mvn_mode() { log "Maven version mode: profile shortcut (-Dspark=$(echo "$SPARK_VERSION" | cut -d. -f1-2) -Dscala=$SCALA_VERSION)"; }
fi

# Optional extra -D args, word-split. Intentional split to allow multiple -Dk=v
# entries from a single env var.
# shellcheck disable=SC2206
MVN_EXTRA_ARGS=($HIBENCH_MVN_EXTRA_ARGS)

ensure_hadoop_localmode_runtime() {
    local helper="$SCRIPT_DIR/setup-hadoop-localmode.sh"
    [ -x "$helper" ] || die "missing helper script: $helper"

    # HiBench depends on python2 loader + Hadoop CLI even in file:/// local mode.
    # Delegate provisioning to the dedicated helper to keep this script simple.
    # SKIP_HIBENCH_PATCH=1: this script's configure_hibench owns HiBench conf;
    # the helper's patch step would duplicate writes AND fail when hadoop.conf
    # hasn't been seeded from its template yet (helper runs before configure).
    log "ensuring Hadoop local-mode runtime (python2 + hadoop cli)"
    SKIP_DATA_PREP=1 SKIP_SMOKE=1 SKIP_HIBENCH_PATCH=1 \
    HIBENCH_HOME="$HIBENCH_HOME" \
    INSTALL_ROOT="$INSTALL_ROOT" \
    JOBS_DIR="$JOBS_DIR" \
    HADOOP_HOME="$HADOOP_HOME" \
    bash "$helper"

    HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-$HADOOP_HOME/etc/hadoop}"
    [ -x "$HADOOP_HOME/bin/hadoop" ] || die "hadoop executable not found at $HADOOP_HOME/bin/hadoop"
}

ensure_localhost_ssh_noninteractive() {
    # HiBench prepare scripts can invoke ssh to the host's own hostname,
    # FQDN, or IPv4/IPv6 addresses (Hadoop start-dfs.sh, MR daemon launches,
    # HiBench bayes/pagerank prepare via spark-submit --master local).
    # Whitelisting only 'localhost' leaves prompts on every other identity
    # the kernel resolves the host to. Collect them all idempotently.
    local ssh_dir="/root/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [ ! -f "$ssh_dir/id_rsa" ]; then
        ssh-keygen -q -N "" -t rsa -f "$ssh_dir/id_rsa"
    fi

    touch "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    local pubkey
    pubkey=$(cat "$ssh_dir/id_rsa.pub")
    grep -qxF "$pubkey" "$ssh_dir/authorized_keys" || echo "$pubkey" >> "$ssh_dir/authorized_keys"

    # Build the full identity list. Some hostname flags may be empty
    # (no FQDN, no global IPv6); set -u-safe via the [ -n ] guard.
    local -a host_names=( localhost localhost.localdomain 127.0.0.1 ::1 )
    local n
    for n in $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) $(hostname -I 2>/dev/null); do
        [ -n "$n" ] && host_names+=( "$n" )
    done
    # Dedup preserving order (requires bash 4+; Ubuntu ships 5).
    local -A seen=()
    local -a uniq=()
    for n in "${host_names[@]}"; do
        [ -n "${seen[$n]:-}" ] && continue
        seen[$n]=1
        uniq+=( "$n" )
    done

    touch "$ssh_dir/known_hosts"
    chmod 600 "$ssh_dir/known_hosts"
    for n in "${uniq[@]}"; do
        # -T 5: cap probe at 5s so a missing IPv6 listener doesn't stall.
        ssh-keyscan -H -T 5 "$n" 2>/dev/null >> "$ssh_dir/known_hosts" || true
    done
    sort -u "$ssh_dir/known_hosts" -o "$ssh_dir/known_hosts"

    mkdir -p /etc/ssh/ssh_config.d
    {
        printf 'Host %s\n' "${uniq[*]}"
        printf '    StrictHostKeyChecking accept-new\n'
        printf '    UserKnownHostsFile /root/.ssh/known_hosts\n'
        printf '    LogLevel ERROR\n'
        printf '    BatchMode yes\n'
    } > /etc/ssh/ssh_config.d/99-hibench-localhost.conf

    # If sshd exists, refresh to ensure auth path is ready.
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^ssh\.service'; then
        systemctl restart ssh >/dev/null 2>&1 || true
    fi

    log "non-interactive SSH configured for: ${uniq[*]}"
}

install_os_deps() {
    log "installing OS dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        maven \
        git \
        wget \
        curl \
        tar \
        rsync \
        python3 \
        python3-pip \
        >/dev/null
    # scala system package is unreliable on Ubuntu 24.04 — Maven bundles its own
    JAVA_HOME_DETECTED="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
    export JAVA_HOME="${JAVA_HOME:-$JAVA_HOME_DETECTED}"
    log "JAVA_HOME=$JAVA_HOME  ($(java -version 2>&1 | head -1))"
}

install_python_deps() {
    log "installing Python benchmark dependencies (numpy, matplotlib, pandas, scipy)"
    pip3 install --quiet --break-system-packages \
        numpy matplotlib pandas scipy 2>/dev/null || \
    pip3 install --quiet \
        numpy matplotlib pandas scipy
}

download_spark() {
    if [ -d "$SPARK_HOME_VERSIONED" ] && [ -f "$SPARK_HOME_VERSIONED/bin/spark-submit" ]; then
        log "Spark $SPARK_VERSION already present at $SPARK_HOME_VERSIONED"
    else
        local tgz="$SPARK_DIR.tgz"
        local primary="https://downloads.apache.org/spark/spark-$SPARK_VERSION/$tgz"
        local fallback="https://archive.apache.org/dist/spark/spark-$SPARK_VERSION/$tgz"
        local tmp="/tmp/$tgz"

        if [ ! -f "$tmp" ]; then
            log "downloading Spark $SPARK_VERSION…"
            wget -q --show-progress -O "$tmp" "$primary" 2>&1 || \
            wget -q --show-progress -O "$tmp" "$fallback" 2>&1 || \
            die "Spark download failed from both mirrors — check connectivity"
        fi
        log "extracting Spark…"
        mkdir -p "$INSTALL_ROOT"
        tar -xf "$tmp" -C "$INSTALL_ROOT"
    fi

    # Canonical symlink so all scripts use SPARK_HOME=/opt/spark regardless of version
    if [ "$SPARK_HOME" != "$SPARK_HOME_VERSIONED" ]; then
        ln -sfn "$SPARK_HOME_VERSIONED" "$SPARK_HOME"
        log "symlink $SPARK_HOME → $SPARK_HOME_VERSIONED"
    fi
    export PATH="$SPARK_HOME/bin:$PATH"
}

clone_hibench() {
    if [ -d "$HIBENCH_HOME/.git" ]; then
        log "HiBench already cloned at $HIBENCH_HOME — skipping"
        return 0
    fi
    log "cloning HiBench (ref=$HIBENCH_REF)…"
    mkdir -p "$(dirname "$HIBENCH_HOME")"
    git clone --depth 1 --branch "$HIBENCH_REF" \
        https://github.com/Intel-bigdata/HiBench.git "$HIBENCH_HOME" 2>&1 | tail -5
}

_find_java8_home() {
    # HiBench uses Scala 2.10/2.11 which is incompatible with Java 9+.
    # Return the first Java 8 JAVA_HOME found, or empty string if none.
    local candidates=(
        /usr/lib/jvm/java-8-openjdk-amd64
        /usr/lib/jvm/java-8-openjdk
        /usr/lib/jvm/java-8-openjdk-arm64
        /usr/local/jdk1.8.0
    )
    for d in "${candidates[@]}"; do
        if [ -x "$d/bin/javac" ]; then
            echo "$d"
            return 0
        fi
    done
    # fallback: scan /usr/lib/jvm
    find /usr/lib/jvm -maxdepth 2 -name javac 2>/dev/null | while read -r p; do
        local home="${p%/bin/javac}"
        local ver
        ver=$("$home/bin/java" -version 2>&1 | awk -F'"' '/version/{print $2}' | head -1)
        case "$ver" in 1.8.*|8.*) echo "$home"; return 0 ;; esac
    done
}

# In direct-version mode we bypass HiBench's spark<X.Y> profile, but HiBench's
# poms hardcode several versions the profile would have overridden, AND its
# common/streaming code uses Kafka 0.8.x API (ZkClient/AdminUtils with old
# signatures) that no longer compiles against any Kafka with a scala_2.12 build
# (Kafka 1.0+). Streaming workloads can't run against Spark 3.5 either, so this
# function disables them entirely so the rest of HiBench (micro, ml, sql, graph,
# websearch) builds clean. Idempotent.
_patch_hibench_poms_for_direct_versions() {
    [ "$HIBENCH_MVN_DIRECT_VERSIONS" = "1" ] || return 0

    # 1. Rewrite kafka version literal to a property so -Dkafka.version takes effect.
    local common_pom="$HIBENCH_HOME/common/pom.xml"
    if [ -f "$common_pom" ] && grep -q '<artifactId>kafka_\${scala.binary.version}</artifactId>' "$common_pom"; then
        if grep -A1 '<artifactId>kafka_\${scala.binary.version}</artifactId>' "$common_pom" | grep -q '<version>0.8.2.1</version>'; then
            log "patching kafka version literal in $common_pom → \${kafka.version}"
            sed -i.bak '/<artifactId>kafka_\${scala.binary.version}</,/<\/dependency>/ { s|<version>0\.8\.2\.1</version>|<version>${kafka.version}</version>| }' "$common_pom"
        fi
    fi

    # 2. Disable streaming subpackage in hibench-common (Kafka 0.8 vs 1.x API).
    #    Must move OUT of src/main/scala/ — scala-maven-plugin recursively globs
    #    **/*.scala there, so renaming the parent dir to .disabled is not enough
    #    (the compiler still descends into it). Park sources under common/ but
    #    outside the compile root so they're preserved for future reference.
    local common_scala_root="$HIBENCH_HOME/common/src/main/scala/com/intel/hibench/common"
    local common_streaming="$common_scala_root/streaming"
    local common_streaming_legacy_disabled="$common_scala_root/streaming.disabled"
    local stash_dir="$HIBENCH_HOME/common/.streaming-src-disabled"
    if [ -d "$common_streaming" ]; then
        log "disabling $common_streaming → $stash_dir (Kafka API drift, dead code with Spark 3.5)"
        mkdir -p "$stash_dir"
        rm -rf "$stash_dir/streaming"
        mv "$common_streaming" "$stash_dir/streaming"
    fi
    # Recover from the previous broken layout: directory renamed to
    # streaming.disabled but still inside src/main/scala (got compiled anyway).
    if [ -d "$common_streaming_legacy_disabled" ]; then
        log "relocating stale $common_streaming_legacy_disabled → $stash_dir"
        mkdir -p "$stash_dir"
        rm -rf "$stash_dir/streaming"
        mv "$common_streaming_legacy_disabled" "$stash_dir/streaming"
    fi

    # 3. Comment out streaming + structuredStreaming modules in sparkbench parent pom.
    local sparkbench_pom="$HIBENCH_HOME/sparkbench/pom.xml"
    if [ -f "$sparkbench_pom" ]; then
        for mod in streaming structuredStreaming; do
            if grep -q "^[[:space:]]*<module>$mod</module>" "$sparkbench_pom"; then
                log "commenting <module>$mod</module> in $sparkbench_pom"
                sed -i.bak "s|<module>$mod</module>|<!-- <module>$mod</module> disabled (direct-versions mode) -->|" "$sparkbench_pom"
            fi
        done
    fi

    # 4. Remove sparkbench-streaming + sparkbench-structuredStreaming deps from
    # the assembly pom so it doesn't try to pull artifacts that are no longer built.
    local assembly_pom="$HIBENCH_HOME/sparkbench/assembly/pom.xml"
    if [ -f "$assembly_pom" ]; then
        for mod in sparkbench-streaming sparkbench-structuredStreaming; do
            if grep -q "<artifactId>$mod</artifactId>" "$assembly_pom"; then
                log "removing <dependency> on $mod from $assembly_pom"
                # Multi-line sed: when we see <dependency>, accumulate until
                # </dependency>, then drop the whole block if it mentions $mod.
                sed -i.bak "/<dependency>/{:a;N;/<\\/dependency>/!ba; /$mod/d}" "$assembly_pom"
            fi
        done
    fi

    # 5. sparkbench-ml uses com.github.fommil.netlib.BLAS in its data generators
    #    (SVMDataGenerator, LinearRegressionDataGenerator). Spark 2.x bundled
    #    that package transitively via spark-mllib; Spark 3.0+ moved to
    #    dev.ludovic.netlib and stopped re-exporting it. The standalone
    #    com.github.fommil.netlib:core:1.1.2 artifact is still on Maven Central
    #    and works as a drop-in (pure-Java F2J impl, BLAS.getInstance() falls
    #    back to it when no native binding is present). Inject it as an
    #    explicit dependency in sparkbench/ml/pom.xml.
    local ml_pom="$HIBENCH_HOME/sparkbench/ml/pom.xml"
    if [ -f "$ml_pom" ] && ! grep -q 'com\.github\.fommil\.netlib' "$ml_pom"; then
        log "injecting com.github.fommil.netlib:core dependency into $ml_pom"
        awk '
            BEGIN { inserted = 0 }
            /<\/dependencies>/ && !inserted {
                print "    <dependency>"
                print "      <groupId>com.github.fommil.netlib</groupId>"
                print "      <artifactId>core</artifactId>"
                print "      <version>1.1.2</version>"
                print "    </dependency>"
                inserted = 1
            }
            { print }
        ' "$ml_pom" > "$ml_pom.tmp" && mv "$ml_pom.tmp" "$ml_pom"
    fi
}

build_hibench() {
    local autogen_jar="$HIBENCH_HOME/autogen/target/autogen-8.0-SNAPSHOT-jar-with-dependencies.jar"
    local sparkbench_jar="$HIBENCH_HOME/sparkbench/assembly/target/sparkbench-assembly-8.0-SNAPSHOT-dist.jar"
    if [ -f "$autogen_jar" ] && [ -f "$sparkbench_jar" ]; then
        log "HiBench already built at $HIBENCH_HOME — skipping build"
        return 0
    fi

    _patch_hibench_poms_for_direct_versions

    # Scala 2.10 (used by hibench-common) requires Java 8 to compile.
    local build_java_home
    build_java_home="$(_find_java8_home)"
    if [ -z "$build_java_home" ]; then
        log "Java 8 not found — installing openjdk-8-jdk for HiBench build…"
        apt-get install -y -qq openjdk-8-jdk 2>&1 | tail -3
        build_java_home="$(_find_java8_home)"
        [ -n "$build_java_home" ] || die "Java 8 install failed; cannot build HiBench"
    fi
    log "using Java 8 at $build_java_home for HiBench build (Scala 2.10 compat)"

    log_mvn_mode

    if [ -f "$autogen_jar" ] && [ ! -f "$sparkbench_jar" ]; then
        log "autogen present but sparkbench JAR missing — building sparkbench module…"
        (
            cd "$HIBENCH_HOME"
            JAVA_HOME="$build_java_home" \
            MAVEN_OPTS="-Xmx2g" mvn -q \
                -pl sparkbench/assembly -am \
                -Psparkbench -U \
                "${MVN_VERSION_ARGS[@]}" \
                "${MVN_EXTRA_ARGS[@]}" \
                -DskipTests clean package 2>&1 | tail -20
        ) || { warn "sparkbench build failed — check Maven output above"; return 1; }
        log "sparkbench build complete"
        return 0
    fi

    if [ ! -f "$autogen_jar" ] || [ ! -f "$sparkbench_jar" ]; then
        log "one or more JARs missing — building autogen + sparkbench modules…"
        (
            cd "$HIBENCH_HOME"
            JAVA_HOME="$build_java_home" \
            MAVEN_OPTS="-Xmx2g" mvn -q \
                -pl autogen,sparkbench/assembly -am \
                -Psparkbench -U \
                "${MVN_VERSION_ARGS[@]}" \
                "${MVN_EXTRA_ARGS[@]}" \
                -DskipTests clean package 2>&1 | tail -20
        ) || { warn "HiBench partial build failed"; return 1; }
        log "HiBench partial build complete"
        return 0
    fi

    log "building HiBench for Spark $SPARK_VERSION — takes 5–15 min…"
    (
        cd "$HIBENCH_HOME"
        JAVA_HOME="$build_java_home" \
        MAVEN_OPTS="-Xmx2g" mvn -q \
            -Psparkbench -U \
            "${MVN_VERSION_ARGS[@]}" \
            "${MVN_EXTRA_ARGS[@]}" \
            -DskipTests \
            -T "$(nproc)" \
            clean package 2>&1 | tail -20
    ) || { warn "HiBench build failed — check Maven output above"; return 1; }
    log "HiBench build complete"
}

_ensure_conf_file() {
    # Ensure $1 exists. Prefer copying from $1.template if present; otherwise
    # create empty. Idempotent. HiBench's conf layout has drifted across
    # releases — some files ship as templates, some as direct files, and on
    # newer master there is no hadoop.conf.template at all.
    local target="$1"
    [ -f "$target" ] && return 0
    if [ -f "${target}.template" ]; then
        cp -f "${target}.template" "$target"
        log "created $target from template"
    else
        : > "$target"
        log "no template found for $(basename "$target"); created empty file"
    fi
}

_set_prop() {
    # Set HiBench-style "key   value" property: replace line if key exists,
    # otherwise append. Safe under set -e. Uses '|' delimiter for sed so
    # paths with '/' don't need escaping.
    local file="$1" key="$2" value="$3"
    local key_re
    key_re="$(printf '%s' "$key" | sed 's|[.[\*^$]|\\&|g')"
    if grep -qE "^${key_re}([[:space:]]|$)" "$file"; then
        sed -i "s|^${key_re}[[:space:]].*|${key}             ${value}|" "$file"
    else
        printf '%-34s %s\n' "$key" "$value" >> "$file"
    fi
}

configure_hibench() {
    log "configuring HiBench for local Spark"
    mkdir -p "$JOBS_DIR" "$JOBS_DIR/spark-local" "$JOBS_DIR/report"

    local confdir="$HIBENCH_HOME/conf"
    local ncores
    ncores=$(nproc)
    local exec_instances=$(( ncores / 4 > 1 ? ncores / 4 : 1 ))
    local shuffle_par=$(( ncores * 4 ))

    _ensure_conf_file "$confdir/hadoop.conf"
    _ensure_conf_file "$confdir/spark.conf"
    _ensure_conf_file "$confdir/hibench.conf"

    _set_prop "$confdir/hadoop.conf" "hibench.hadoop.home"          "$HADOOP_HOME"
    _set_prop "$confdir/hadoop.conf" "hibench.hdfs.master"          "file:///"
    _set_prop "$confdir/hadoop.conf" "hibench.hadoop.configure.dir" "$HADOOP_CONF_DIR"
    _set_prop "$confdir/hadoop.conf" "hibench.hadoop.executable"    "$HADOOP_HOME/bin/hadoop"
    _set_prop "$confdir/hadoop.conf" "hibench.hadoop.release"       "apache"

    _set_prop "$confdir/spark.conf" "hibench.spark.home"          "$SPARK_HOME"
    _set_prop "$confdir/spark.conf" "hibench.spark.master"        "local[$ncores]"
    _set_prop "$confdir/spark.conf" "hibench.spark.deploymode"    "client"
    _set_prop "$confdir/spark.conf" "spark.executor.instances"    "$exec_instances"
    _set_prop "$confdir/spark.conf" "spark.executor.cores"        "4"
    _set_prop "$confdir/spark.conf" "spark.executor.memory"       "8g"
    _set_prop "$confdir/spark.conf" "spark.driver.memory"         "8g"
    _set_prop "$confdir/spark.conf" "spark.sql.shuffle.partitions" "$shuffle_par"

    _set_prop "$confdir/hibench.conf" "hibench.scale.profile"   "$HIBENCH_SCALE"
    _set_prop "$confdir/hibench.conf" "hibench.report.dir"      "$JOBS_DIR/report"
    # Local-mode: use explicit file:// paths so prepare/run scripts don't expect HDFS.
    _set_prop "$confdir/hibench.conf" "hibench.workload.input"  "file://$JOBS_DIR/input"
    _set_prop "$confdir/hibench.conf" "hibench.workload.output" "file://$JOBS_DIR/output"
    _set_prop "$confdir/hibench.conf" "hibench.workload.scratch" "file://$JOBS_DIR/scratch"

    # HiBench parses every conf/*.conf, including a leftover
    # hibench.distributed.conf overlay from a prior distributed-mode campaign,
    # ON TOP of the localmode values just written above — which would silently
    # aim these prepare jobs at a spark:// / hdfs:// cluster that isn't up yet.
    # Drop it so local[*] + file:/// win. The campaign's distributed-mode init
    # re-creates the overlay later, when it actually needs it.
    rm -f "$confdir/hibench.distributed.conf"
}

prepare_datasets() {
    if [ "$SKIP_DATA_PREP" = "1" ]; then
        log "SKIP_DATA_PREP=1 — skipping dataset generation"
        return 0
    fi
    log "preparing datasets (scale=$HIBENCH_SCALE) — may take several minutes…"
    local workloads=(
        "micro/wordcount"
        "micro/terasort"
        "websearch/pagerank"
        "ml/kmeans"
        "ml/bayes"
        "sql/nweight"
    )
    mkdir -p "$JOBS_DIR/input" "$JOBS_DIR/output" "$JOBS_DIR/report"

    local prep_log_dir="$JOBS_DIR/report/_setup-prepare"
    mkdir -p "$prep_log_dir"
    local prep_timeout="${PREPARE_TIMEOUT:-1800}"  # seconds — kill before HiBench's 20-min YARN-retry storm

    for wl in "${workloads[@]}"; do
        local prep="$HIBENCH_HOME/bin/workloads/$wl/prepare/prepare.sh"
        if [ -x "$prep" ]; then
            log "  prepare: $wl"
            export JAVA_HOME SPARK_HOME HIBENCH_HOME
            export HADOOP_HOME
            export HADOOP_CONF_DIR
            export YARN_CONF_DIR="$HADOOP_CONF_DIR"
            export PATH="$HADOOP_HOME/bin:$PATH"
            export HADOOP_EXECUTABLE="${HADOOP_EXECUTABLE:-$HADOOP_HOME/bin/hadoop}"
            # Some HiBench prepare scripts require these variables when running
            # in local mode and can fail with INPUT_HDFS unbound otherwise.
            export INPUT_HDFS="file://$JOBS_DIR/input"
            export OUTPUT_HDFS="file://$JOBS_DIR/output"
            export REPORT_DIR="$JOBS_DIR/report"
            local safe_name; safe_name="$(echo "$wl" | tr '/' '_')"
            local plog="$prep_log_dir/$safe_name.log"
            if timeout "$prep_timeout" bash "$prep" >"$plog" 2>&1; then
                log "    OK ($(wc -l <"$plog") lines, log: $plog)"
            else
                local rc=$?
                warn "  $wl prepare failed (rc=$rc, log: $plog)"
                tail -20 "$plog" | sed 's/^/      /'
            fi
        else
            log "  SKIP $wl (prepare script not found)"
        fi
    done
    log "dataset preparation complete"
}

print_summary() {
    cat <<EOF

=== setup-spark-hibench complete ===
  SPARK_HOME   = $SPARK_HOME  (→ $SPARK_HOME_VERSIONED)
  HIBENCH_HOME = $HIBENCH_HOME
  Scale        = $HIBENCH_SCALE
  Data dir     = $JOBS_DIR

Run IntP HiBench benchmarks with:
  sudo bash bench/hibench/run-hibench-subset.sh \\
    --variants v1,v2,v3.1,v3 --size medium --profile both
EOF
}

install_os_deps
install_python_deps
download_spark
clone_hibench
build_hibench
ensure_hadoop_localmode_runtime
ensure_localhost_ssh_noninteractive
configure_hibench
prepare_datasets
print_summary

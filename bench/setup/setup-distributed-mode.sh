#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-distributed-mode.sh -- HDFS pseudo-distributed + Spark Standalone
# bound to the veth pair set up by setup-netns-pair.sh.
#
# Why this exists:
#   By default the IntP campaign runs HiBench in `local[*]` (in-process Spark)
#   + `file:///` (no HDFS daemons). That gives ZERO network traffic, so V2/V3/
#   V3.1 net probes (which look at NIC code paths) report netp/nets = 0.
#
#   This script provisions a side-by-side "distributed" config that:
#     - HDFS NameNode + DataNode bind to 10.42.0.1 (host side of veth)
#     - Spark Master + Worker bind to 10.42.0.1 (host side of veth)
#     - HiBench Driver runs INSIDE netns intp-app (10.42.0.2), connects to
#       Master/NameNode at 10.42.0.1 via veth pair → real TCP RPC traffic
#       crosses intp-veth-h, all 4 IntP variants observe netp/nets > 0.
#
#   Localmode configs are NOT overwritten. We use parallel config dirs
#   (etc/hadoop-distributed/, conf-distributed/) and switch via env vars.
#
# Topology (depends on bench/setup/setup-netns-pair.sh having been run):
#
#     +========= HOST root netns ==========+    +===== NETNS intp-app ======+
#     |                                     |    |                            |
#     | NameNode  bind 10.42.0.1:9000       |◄──►| Spark Driver  10.42.0.2   |
#     | DataNode  bind 10.42.0.1:9866       |    |   (HiBench job)            |
#     | SparkMaster  bind 10.42.0.1:7077    |    |                            |
#     | SparkWorker  conects to Master      |    |                            |
#     |                                     |    |                            |
#     | intp-veth-h  10.42.0.1/24           |    | intp-veth-g  10.42.0.2/24 |
#     +=====================================+    +============================+
#
# Usage:
#   sudo ./setup-distributed-mode.sh init                # one-time: write configs + format NameNode
#   sudo ./setup-distributed-mode.sh start               # bring daemons up
#   sudo ./setup-distributed-mode.sh stop                # bring daemons down
#   sudo ./setup-distributed-mode.sh status              # show what's running
#   sudo ./setup-distributed-mode.sh smoke               # verify Driver-in-netns can reach Master
#   sudo ./setup-distributed-mode.sh switch-distributed  # patch HiBench conf for hdfs:// + spark://
#   sudo ./setup-distributed-mode.sh switch-localmode    # restore HiBench conf to file:/// + local[*]
#   sudo ./setup-distributed-mode.sh ssh-setup           # idempotent: known_hosts + authorized_keys for intp-host/intp-app
#   sudo ./setup-distributed-mode.sh prepare-hdfs        # one-shot: populate HDFS pseudo with HiBench datasets
#   sudo ./setup-distributed-mode.sh teardown            # remove distributed configs (keep dataset)
# -----------------------------------------------------------------------------

set -euo pipefail

HADOOP_HOME="${HADOOP_HOME:-/opt/hadoop}"
SPARK_HOME="${SPARK_HOME:-/opt/spark}"
HIBENCH_HOME="${HIBENCH_HOME:-/opt/HiBench}"

HOST_IP="${INTP_NETNS_HOST_IP:-10.42.0.1}"
GUEST_IP="${INTP_NETNS_GUEST_IP:-10.42.0.2}"
NETNS="${INTP_NETNS_NAME:-intp-net}"

NN_PORT=9000
DN_PORT=9866
DN_IPC_PORT=9867
DN_HTTP_PORT=9864
NN_HTTP_PORT=9870
SPARK_MASTER_PORT=7077
SPARK_MASTER_WEBUI=8080
SPARK_WORKER_PORT=7078
SPARK_WORKER_WEBUI=8081
DRIVER_PORT=30000
DRIVER_BLOCKMGR_PORT=30001

HADOOP_DATA_DIR="${HADOOP_DATA_DIR:-/var/lib/hadoop}"
HADOOP_DIST_CONF="$HADOOP_HOME/etc/hadoop-distributed"
SPARK_DIST_CONF="$SPARK_HOME/conf-distributed"

LOG_DIR="${INTP_DIST_LOG_DIR:-/var/log/intp-distributed}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root"
}

require_veth() {
    if ! ip netns list | awk '{print $1}' | grep -qx "$NETNS"; then
        die "netns '$NETNS' missing — run bench/setup/setup-netns-pair.sh first"
    fi
    if ! ip a show intp-veth-h >/dev/null 2>&1; then
        die "intp-veth-h missing — run bench/setup/setup-netns-pair.sh first"
    fi
}

require_paths() {
    [ -x "$HADOOP_HOME/bin/hadoop" ] || die "Hadoop not found at $HADOOP_HOME (run bench/hibench/setup-hadoop-localmode.sh first)"
    [ -x "$SPARK_HOME/bin/spark-submit" ] || die "Spark not found at $SPARK_HOME (run bench/hibench/setup-spark-hibench.sh first)"
}

# ---------------------------------------------------------------------------
# init: write parallel configs and format the NameNode (one-time)
# ---------------------------------------------------------------------------

write_hadoop_configs() {
    mkdir -p "$HADOOP_DIST_CONF"
    # Inherit base hadoop-env.sh, mapred-site.xml, etc. from etc/hadoop/
    # We only override files that need distributed-mode bind values.
    if [ -d "$HADOOP_HOME/etc/hadoop" ]; then
        find "$HADOOP_HOME/etc/hadoop" -maxdepth 1 -type f \
            ! -name 'core-site.xml' ! -name 'hdfs-site.xml' \
            -exec cp --no-clobber {} "$HADOOP_DIST_CONF/" \;
    fi

    cat > "$HADOOP_DIST_CONF/core-site.xml" <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://$HOST_IP:$NN_PORT</value>
  </property>
  <property>
    <name>hadoop.tmp.dir</name>
    <value>$HADOOP_DATA_DIR/tmp</value>
  </property>
  <property>
    <!-- Allow connections from anywhere within 10.42.0.0/24 (netns). -->
    <name>hadoop.proxyuser.root.hosts</name>
    <value>*</value>
  </property>
  <property>
    <name>hadoop.proxyuser.root.groups</name>
    <value>*</value>
  </property>
</configuration>
EOF

    cat > "$HADOOP_DIST_CONF/hdfs-site.xml" <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file://$HADOOP_DATA_DIR/dfs/name</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file://$HADOOP_DATA_DIR/dfs/data</value>
  </property>

  <!-- Bind every NameNode endpoint to the veth host IP so traffic from the
       netns side traverses intp-veth-h and is observable by V2/V3/V3.1. -->
  <property>
    <name>dfs.namenode.rpc-bind-host</name>
    <value>$HOST_IP</value>
  </property>
  <property>
    <name>dfs.namenode.servicerpc-bind-host</name>
    <value>$HOST_IP</value>
  </property>
  <property>
    <name>dfs.namenode.http-bind-host</name>
    <value>$HOST_IP</value>
  </property>
  <property>
    <name>dfs.namenode.https-bind-host</name>
    <value>$HOST_IP</value>
  </property>

  <!-- DataNode endpoints likewise. -->
  <property>
    <name>dfs.datanode.address</name>
    <value>$HOST_IP:$DN_PORT</value>
  </property>
  <property>
    <name>dfs.datanode.ipc.address</name>
    <value>$HOST_IP:$DN_IPC_PORT</value>
  </property>
  <property>
    <name>dfs.datanode.http.address</name>
    <value>$HOST_IP:$DN_HTTP_PORT</value>
  </property>

  <!-- Force DataNode to advertise the veth IP, not the default hostname,
       so HDFS clients in the netns connect via 10.42.0.1 and not via the
       resolvable hostname (which would route through eno1 / loopback). -->
  <property>
    <name>dfs.datanode.hostname</name>
    <value>$HOST_IP</value>
  </property>
  <property>
    <name>dfs.client.use.datanode.hostname</name>
    <value>false</value>
  </property>
</configuration>
EOF

    log "wrote Hadoop distributed configs to $HADOOP_DIST_CONF"
}

write_spark_configs() {
    mkdir -p "$SPARK_DIST_CONF"
    # Inherit log4j, metrics from base conf/ if present.
    if [ -d "$SPARK_HOME/conf" ]; then
        find "$SPARK_HOME/conf" -maxdepth 1 -type f \
            ! -name 'spark-defaults.conf' ! -name 'spark-env.sh' \
            -exec cp --no-clobber {} "$SPARK_DIST_CONF/" \;
    fi

    cat > "$SPARK_DIST_CONF/spark-env.sh" <<EOF
#!/usr/bin/env bash
# Distributed-mode env: Master/Worker bind to host veth IP.
SPARK_MASTER_HOST=$HOST_IP
SPARK_MASTER_PORT=$SPARK_MASTER_PORT
SPARK_MASTER_WEBUI_PORT=$SPARK_MASTER_WEBUI
SPARK_WORKER_PORT=$SPARK_WORKER_PORT
SPARK_WORKER_WEBUI_PORT=$SPARK_WORKER_WEBUI
SPARK_LOCAL_IP=$HOST_IP
HADOOP_CONF_DIR=$HADOOP_DIST_CONF
EOF
    chmod +x "$SPARK_DIST_CONF/spark-env.sh"

    cat > "$SPARK_DIST_CONF/spark-defaults.conf" <<EOF
# IntP distributed-mode Spark defaults.
# Driver runs in netns "$NETNS" with IP $GUEST_IP.
# Master/Worker run in host root netns with IP $HOST_IP.
# All RPC crosses intp-veth-h <-> intp-veth-g, observed by V2/V3/V3.1.

spark.master                       spark://$HOST_IP:$SPARK_MASTER_PORT
spark.driver.bindAddress           $GUEST_IP
spark.driver.host                  $GUEST_IP
spark.driver.port                  $DRIVER_PORT
spark.driver.blockManager.port     $DRIVER_BLOCKMGR_PORT
spark.network.timeout              300s
spark.executor.heartbeatInterval   30s

# Disable SparkUI/Jetty in the Driver. Two reasons:
#   1. The Driver runs inside netns "$NETNS" which has minimal /etc/hosts;
#      Jetty's hostname resolution chain fails there.
#   2. The UI itself emits heartbeat/refresh traffic that would pollute the
#      netp/nets signal we are trying to measure precisely.
spark.ui.enabled                   false

# Standalone Worker scratch cleanup. The primary reap is deterministic and
# happens between workloads inside bench/hibench/run-hibench-subset.sh
# (reap_spark_worker_scratch_between_workloads), where no profiler is
# running. These keys are a safety net for non-HiBench Spark traffic and
# for any app-* dirs that slip past the workload-boundary reap (e.g. the
# very last workload before publish). interval=1800s + appDataTtl=600s
# ensures any tick falls in a multi-minute gap between reps, NOT during a
# profiled rep: terasort/kmeans reps run ~20-30 min so cleanup activity
# stays outside the measurement window.
spark.worker.cleanup.enabled       true
spark.worker.cleanup.interval      1800
spark.worker.cleanup.appDataTtl    600
EOF

    log "wrote Spark distributed configs to $SPARK_DIST_CONF"
}

write_hibench_overlay() {
    # HiBench reads conf/hibench.conf and conf/{hadoop,spark}.conf. We don't
    # overwrite those (localmode-friendly) — instead we provide a wrapper
    # config file the orchestrator sources before invoking workloads.
    local overlay="$HIBENCH_HOME/conf/hibench.distributed.conf"
    cat > "$overlay" <<EOF
# IntP distributed-mode overlay for HiBench (parsed AFTER hadoop.conf/spark.conf).
hibench.hdfs.master              hdfs://$HOST_IP:$NN_PORT
hibench.spark.master             spark://$HOST_IP:$SPARK_MASTER_PORT
hibench.hadoop.configure.dir     $HADOOP_DIST_CONF
hibench.spark.confdir            $SPARK_DIST_CONF
# Disable HiBench's built-in monitor (start_monitor.sh) — it SSHes to master/
# slaves to start dstat/etc, which prompts for known_hosts confirmation inside
# our netns and hangs the run. We use IntP profilers instead.
hibench.monitor.enable           false
EOF
    log "wrote HiBench overlay $overlay"
}

format_namenode() {
    local nn_dir="$HADOOP_DATA_DIR/dfs/name"
    if [ -d "$nn_dir" ] && [ -n "$(ls -A "$nn_dir" 2>/dev/null)" ]; then
        log "NameNode already formatted at $nn_dir — skip"
        return 0
    fi
    mkdir -p "$HADOOP_DATA_DIR/dfs/name" "$HADOOP_DATA_DIR/dfs/data" \
             "$HADOOP_DATA_DIR/tmp" "$LOG_DIR"
    HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
    HADOOP_LOG_DIR="$LOG_DIR" \
        "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive -clusterId intp-pseudo
    log "NameNode formatted (clusterId intp-pseudo)"
}

write_netns_hosts() {
    # Some Java/Spark/MapReduce code paths resolve hostnames via JNI/
    # getaddrinfo and blow up inside a minimal netns. Provide a /etc/hosts
    # override visible only inside the netns (via bind mount) so localhost,
    # the veth aliases, and the host's own hostname all resolve.
    #
    # The host hostname matters because Hadoop's LocalJobRunner (used by
    # dfsioe / TestDFSIOEnh) calls InetAddress.getLocalHost() which returns
    # the kernel hostname; that lookup must succeed inside the netns or
    # JobClient.submitJob fails with UnknownHostException.
    local netns_hosts="/etc/netns/$NETNS/hosts"
    mkdir -p "$(dirname "$netns_hosts")"
    local kernel_hostname kernel_short
    kernel_hostname="$(hostname -f 2>/dev/null || hostname)"
    kernel_short="$(hostname -s 2>/dev/null || hostname)"
    {
        printf '127.0.0.1   localhost %s %s\n' "$kernel_short" "$kernel_hostname"
        printf '::1         localhost ip6-localhost ip6-loopback\n'
        printf '%s    intp-host %s %s\n' "$HOST_IP" "$kernel_short" "$kernel_hostname"
        printf '%s    intp-app\n' "$GUEST_IP"
    } > "$netns_hosts"
    log "wrote $netns_hosts (visible only inside netns $NETNS)"
}

write_ssh_setup() {
    # HiBench's start_monitor.sh + Spark Standalone's start-all.sh do SSH calls
    # to "master/slave" hostnames. Inside the netns, intp-host (10.42.0.1)
    # resolves but isn't in known_hosts → prompts interactively → hangs. Pre-
    # populate known_hosts under all 4 aliases (intp-host, intp-app, host IP,
    # guest IP) using the local sshd's host key. Also set up passwordless root
    # SSH so any wrapper that spawns "ssh root@..." just works.
    local ssh_dir=/root/.ssh
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # 1) Generate root key if missing (used for self-SSH inside the netns).
    if [ ! -f "$ssh_dir/id_ed25519" ]; then
        ssh-keygen -q -t ed25519 -N "" -f "$ssh_dir/id_ed25519" -C "intp-distributed-self"
    fi
    # 2) Trust the root key for self-SSH.
    if [ -f "$ssh_dir/id_ed25519.pub" ]; then
        local pub
        pub="$(cat "$ssh_dir/id_ed25519.pub")"
        touch "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
        if ! grep -qF "$pub" "$ssh_dir/authorized_keys"; then
            echo "$pub" >> "$ssh_dir/authorized_keys"
        fi
    fi
    # 3) Pre-populate known_hosts with the host's sshd key under each alias.
    #    Cover not just the netns aliases but also the kernel hostname /
    #    FQDN / actual NIC IPs — Hadoop and HiBench prepare scripts ssh to
    #    the host's identity (not just localhost) and prompt interactively
    #    if those names aren't in known_hosts. Collect them dynamically.
    local -a aliases=( intp-host intp-app "$HOST_IP" "$GUEST_IP" localhost localhost.localdomain 127.0.0.1 ::1 )
    local n
    for n in $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) $(hostname -I 2>/dev/null); do
        [ -n "$n" ] && aliases+=( "$n" )
    done
    # Dedup preserving order.
    local -A seen=()
    local -a uniq=()
    for n in "${aliases[@]}"; do
        [ -n "${seen[$n]:-}" ] && continue
        seen[$n]=1
        uniq+=( "$n" )
    done

    local host_key_pub=/etc/ssh/ssh_host_ed25519_key.pub
    if [ -r "$host_key_pub" ]; then
        local host_key
        host_key="$(awk '{print $1, $2}' "$host_key_pub")"
        local kh="$ssh_dir/known_hosts"
        touch "$kh"
        chmod 600 "$kh"
        local alias
        for alias in "${uniq[@]}"; do
            # ssh-keygen -F returns 0 if the alias already has a key entry; only
            # append when missing to avoid duplicates.
            if ! ssh-keygen -F "$alias" -f "$kh" >/dev/null 2>&1; then
                echo "$alias $host_key" >> "$kh"
            fi
        done
        log "populated $kh for: ${uniq[*]}"
    else
        warn "$host_key_pub not readable — skipping known_hosts pre-population"
    fi
    # 4) Belt-and-suspenders: SSH config disables strict checking for these
    #    aliases (only — does not affect other hosts).
    local sshcfg="$ssh_dir/config"
    touch "$sshcfg"
    chmod 600 "$sshcfg"
    if grep -q '^# IntP distributed-mode block' "$sshcfg" 2>/dev/null; then
        # Refresh the block in place so re-running the script picks up any
        # new hostname/IP without leaving stale aliases.
        local tmp
        tmp="$(mktemp)"
        awk '
            /^# IntP distributed-mode block/ { skip=1 }
            skip && /^$/ { skip=0; next }
            !skip { print }
        ' "$sshcfg" > "$tmp"
        mv "$tmp" "$sshcfg"
        chmod 600 "$sshcfg"
    fi
    cat >> "$sshcfg" <<EOF

# IntP distributed-mode block (added by setup-distributed-mode.sh)
Host ${uniq[*]}
    StrictHostKeyChecking accept-new
    LogLevel ERROR
    BatchMode yes
EOF
    log "wrote SSH client block to $sshcfg for: ${uniq[*]}"
}

cmd_init() {
    require_root
    require_veth
    require_paths
    write_hadoop_configs
    write_spark_configs
    write_hibench_overlay
    write_netns_hosts
    write_ssh_setup
    format_namenode
    log "init complete. Next: '$0 start'"
}

cmd_ssh_setup() {
    require_root
    write_ssh_setup
}

# ---------------------------------------------------------------------------
# start / stop daemons
# ---------------------------------------------------------------------------

is_running() {
    local pattern="$1"
    pgrep -f "$pattern" >/dev/null 2>&1
}

cmd_start() {
    require_root
    require_veth
    require_paths
    [ -d "$HADOOP_DIST_CONF" ] || die "distributed configs missing — run '$0 init' first"

    mkdir -p "$LOG_DIR"

    if is_running 'NameNode'; then
        log "NameNode already running"
    else
        log "starting NameNode (bind $HOST_IP:$NN_PORT)..."
        HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
        HADOOP_LOG_DIR="$LOG_DIR" \
            "$HADOOP_HOME/bin/hdfs" --daemon start namenode
    fi

    if is_running 'DataNode'; then
        log "DataNode already running"
    else
        log "starting DataNode (bind $HOST_IP:$DN_PORT)..."
        HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
        HADOOP_LOG_DIR="$LOG_DIR" \
            "$HADOOP_HOME/bin/hdfs" --daemon start datanode
    fi

    # Give HDFS time to leave safemode.
    sleep 3
    HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
        "$HADOOP_HOME/bin/hdfs" dfsadmin -safemode wait >/dev/null || true

    if is_running 'org.apache.spark.deploy.master.Master'; then
        log "Spark Master already running"
    else
        log "starting Spark Master (bind $HOST_IP:$SPARK_MASTER_PORT)..."
        SPARK_CONF_DIR="$SPARK_DIST_CONF" \
        SPARK_LOG_DIR="$LOG_DIR" \
            "$SPARK_HOME/sbin/start-master.sh" --host "$HOST_IP" --port "$SPARK_MASTER_PORT"
    fi
    sleep 2

    if is_running 'org.apache.spark.deploy.worker.Worker'; then
        log "Spark Worker already running"
    else
        log "starting Spark Worker (connects to spark://$HOST_IP:$SPARK_MASTER_PORT)..."
        SPARK_CONF_DIR="$SPARK_DIST_CONF" \
        SPARK_LOG_DIR="$LOG_DIR" \
            "$SPARK_HOME/sbin/start-worker.sh" "spark://$HOST_IP:$SPARK_MASTER_PORT" \
                --host "$HOST_IP"
    fi

    sleep 2
    cmd_status
    log "start complete."
}

cmd_stop() {
    require_root
    require_paths

    if is_running 'org.apache.spark.deploy.worker.Worker'; then
        log "stopping Spark Worker..."
        SPARK_CONF_DIR="$SPARK_DIST_CONF" \
        SPARK_LOG_DIR="$LOG_DIR" \
            "$SPARK_HOME/sbin/stop-worker.sh" 2>/dev/null || true
    fi
    if is_running 'org.apache.spark.deploy.master.Master'; then
        log "stopping Spark Master..."
        SPARK_CONF_DIR="$SPARK_DIST_CONF" \
        SPARK_LOG_DIR="$LOG_DIR" \
            "$SPARK_HOME/sbin/stop-master.sh" 2>/dev/null || true
    fi
    if is_running 'DataNode'; then
        log "stopping DataNode..."
        HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
        HADOOP_LOG_DIR="$LOG_DIR" \
            "$HADOOP_HOME/bin/hdfs" --daemon stop datanode 2>/dev/null || true
    fi
    if is_running 'NameNode'; then
        log "stopping NameNode..."
        HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
        HADOOP_LOG_DIR="$LOG_DIR" \
            "$HADOOP_HOME/bin/hdfs" --daemon stop namenode 2>/dev/null || true
    fi

    # Belt-and-suspenders: pkill anything left over.
    sleep 1
    pkill -f 'NameNode|DataNode|deploy.master.Master|deploy.worker.Worker' 2>/dev/null || true
    log "stop complete."
}

cmd_status() {
    log "daemons:"
    if command -v jps >/dev/null 2>&1; then
        jps | grep -E 'NameNode|DataNode|Master|Worker' || echo "  (none)"
    else
        pgrep -af 'NameNode|DataNode|deploy.master.Master|deploy.worker.Worker' || echo "  (none)"
    fi
    echo
    log "listening on veth IP $HOST_IP:"
    ss -tlnp 2>/dev/null \
        | grep -E ":(${NN_PORT}|${DN_PORT}|${SPARK_MASTER_PORT}|${SPARK_WORKER_PORT})\b" \
        | sed 's/^/  /' \
        || echo "  (none)"
}

# ---------------------------------------------------------------------------
# smoke: verify Driver-in-netns can reach Master + NameNode
# ---------------------------------------------------------------------------

cmd_smoke() {
    require_root
    require_veth

    log "ping host from netns..."
    ip netns exec "$NETNS" ping -c2 -W2 "$HOST_IP" >/dev/null \
        || die "netns cannot reach $HOST_IP (veth pair broken?)"

    log "TCP reach NameNode :$NN_PORT from netns..."
    ip netns exec "$NETNS" timeout 3 bash -c "</dev/tcp/$HOST_IP/$NN_PORT" \
        || die "netns cannot connect to NameNode at $HOST_IP:$NN_PORT"

    log "TCP reach Spark Master :$SPARK_MASTER_PORT from netns..."
    ip netns exec "$NETNS" timeout 3 bash -c "</dev/tcp/$HOST_IP/$SPARK_MASTER_PORT" \
        || die "netns cannot connect to Spark Master at $HOST_IP:$SPARK_MASTER_PORT"

    log "submitting Spark Pi job from netns Driver..."

    # Resolve the examples jar defensively: glob may match nothing, multiple
    # files, or be in a non-default path on some Spark builds.
    local examples_jar
    examples_jar=$(ls "$SPARK_HOME/examples/jars/"spark-examples_*.jar 2>/dev/null | head -1)
    if [ -z "$examples_jar" ]; then
        log "WARN: spark-examples_*.jar not found under $SPARK_HOME/examples/jars/"
        log "      TCP reach to Master :$SPARK_MASTER_PORT and NN :$NN_PORT was already confirmed above."
        log "      Skipping Pi job submission. Network plumbing is OK; HiBench can run."
        return 0
    fi
    log "  using jar: $examples_jar"

    local pi_log
    pi_log=$(mktemp)
    if SPARK_CONF_DIR="$SPARK_DIST_CONF" \
       HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
       ip netns exec "$NETNS" \
           "$SPARK_HOME/bin/spark-submit" \
           --master "spark://$HOST_IP:$SPARK_MASTER_PORT" \
           --conf "spark.driver.bindAddress=$GUEST_IP" \
           --conf "spark.driver.host=$GUEST_IP" \
           --conf "spark.driver.port=$DRIVER_PORT" \
           --conf "spark.driver.blockManager.port=$DRIVER_BLOCKMGR_PORT" \
           --conf "spark.ui.enabled=false" \
           --class org.apache.spark.examples.SparkPi \
           "$examples_jar" 100 \
           >"$pi_log" 2>&1
    then
        # Pi line looks like: "Pi is roughly 3.14159..."
        local pi_line
        pi_line=$(grep -i 'Pi is roughly' "$pi_log" | tail -1)
        if [ -n "$pi_line" ]; then
            log "smoke OK: $pi_line"
            log "Traffic crossed veth, all 4 IntP variants will observe it."
        else
            log "WARN: spark-submit returned 0 but no Pi line found. Last 20 lines:"
            tail -20 "$pi_log" | sed 's/^/  /'
        fi
    else
        log "FAIL: spark-submit exited non-zero. Full log at $pi_log"
        log "Last 30 lines:"
        tail -30 "$pi_log" | sed 's/^/  /'
        rm -f "$pi_log"
        return 3
    fi
    rm -f "$pi_log"
}

# ---------------------------------------------------------------------------
# switch-mode: flip HiBench's hibench.conf + spark.conf between localmode
#              (file:/// + local[*]) and distributed (hdfs:// + spark://).
#              Required because HiBench reads conf/hibench.conf directly,
#              not the .distributed.conf overlay.
# ---------------------------------------------------------------------------

cmd_switch_distributed() {
    require_root
    require_paths
    [ -d "$HADOOP_DIST_CONF" ] || die "distributed configs missing — run '$0 init' first"
    local hbench="$HIBENCH_HOME/conf/hibench.conf"
    local sconf="$HIBENCH_HOME/conf/spark.conf"
    [ -f "$hbench" ] || die "$hbench not found"

    # Refresh netns /etc/hosts so the host hostname is resolvable inside the
    # netns (dfsioe / Hadoop LocalJobRunner needs InetAddress.getLocalHost()
    # to succeed). Idempotent.
    write_netns_hosts

    # One-time backup of localmode versions.
    [ -f "${hbench}.localmode" ] || cp "$hbench" "${hbench}.localmode"
    [ -f "${sconf}.localmode" ]  || cp "$sconf"  "${sconf}.localmode"

    sed -i -E "s|^(hibench\.hdfs\.master[[:space:]]+).*|\1hdfs://$HOST_IP:$NN_PORT|" "$hbench"
    sed -i -E "s|^(hibench\.spark\.master[[:space:]]+).*|\1spark://$HOST_IP:$SPARK_MASTER_PORT|" "$sconf"
    # Disable HiBench's start_monitor.sh (it SSHes to master/slaves and hangs
    # in our minimal netns). Patch hibench.conf so the setting persists even
    # if the overlay isn't read.
    if grep -qE '^hibench\.monitor\.enable' "$hbench"; then
        sed -i -E "s|^(hibench\.monitor\.enable[[:space:]]+).*|\1false|" "$hbench"
    else
        printf '\n# IntP distributed-mode override (added by setup-distributed-mode.sh).\nhibench.monitor.enable           false\n' >> "$hbench"
    fi
    # HiBench derives `hadoop --config <DIR>` from hibench.hadoop.configure.dir
    # (if absent, falls back to ${hibench.hadoop.home}/etc/hadoop = localmode).
    # Patch hadoop.conf so prepare.sh and TestDFSIOEnh see the distributed dir.
    local hadoopconf="$HIBENCH_HOME/conf/hadoop.conf"
    if [ -f "$hadoopconf" ]; then
        [ -f "${hadoopconf}.localmode" ] || cp "$hadoopconf" "${hadoopconf}.localmode"
        if grep -qE '^hibench\.hadoop\.configure\.dir' "$hadoopconf"; then
            sed -i -E "s|^(hibench\.hadoop\.configure\.dir[[:space:]]+).*|\1$HADOOP_DIST_CONF|" "$hadoopconf"
        else
            printf '\n# IntP distributed-mode override (added by setup-distributed-mode.sh).\nhibench.hadoop.configure.dir   %s\n' "$HADOOP_DIST_CONF" >> "$hadoopconf"
        fi
    fi
    # HiBench builds spark-submit with --properties-file from spark.conf (which
    # MAKES Spark IGNORE $SPARK_CONF_DIR/spark-defaults.conf). So the
    # spark.driver.bindAddress / .host / .port settings we wrote to
    # conf-distributed/spark-defaults.conf get bypassed → driver tries to bind
    # on the host's hostname IP, fails inside the netns. Fix: write the bind
    # config into HiBench's spark.conf (hibench.spark.X.Y → spark.X.Y).
    _patch_or_append_kv() {
        local key="$1" val="$2" file="$3"
        if grep -qE "^${key}[[:space:]]" "$file"; then
            sed -i -E "s|^(${key}[[:space:]]+).*|\1${val}|" "$file"
        else
            printf '%s    %s\n' "$key" "$val" >> "$file"
        fi
    }
    _patch_or_append_kv 'hibench.spark.driver.bindAddress'      "$GUEST_IP"  "$sconf"
    _patch_or_append_kv 'hibench.spark.driver.host'             "$GUEST_IP"  "$sconf"
    _patch_or_append_kv 'hibench.spark.driver.port'             "$DRIVER_PORT" "$sconf"
    _patch_or_append_kv 'hibench.spark.driver.blockManager.port' "$DRIVER_BLOCKMGR_PORT" "$sconf"
    _patch_or_append_kv 'hibench.spark.ui.enabled'              "false"      "$sconf"
    log "HiBench switched to distributed (hdfs://$HOST_IP:$NN_PORT, spark://$HOST_IP:$SPARK_MASTER_PORT, driver.bind=$GUEST_IP:$DRIVER_PORT, hadoop.conf=$HADOOP_DIST_CONF)"
}

cmd_switch_localmode() {
    require_root
    require_paths
    local hbench="$HIBENCH_HOME/conf/hibench.conf"
    local sconf="$HIBENCH_HOME/conf/spark.conf"
    local hadoopconf="$HIBENCH_HOME/conf/hadoop.conf"
    if [ -f "${hbench}.localmode" ]; then
        cp "${hbench}.localmode" "$hbench"
    fi
    if [ -f "${sconf}.localmode" ]; then
        cp "${sconf}.localmode" "$sconf"
    fi
    if [ -f "${hadoopconf}.localmode" ]; then
        cp "${hadoopconf}.localmode" "$hadoopconf"
    fi
    log "HiBench switched to localmode (file:/// + local[*])"
}

# ---------------------------------------------------------------------------
# prepare-hdfs: run HiBench prepare/prepare.sh for each workload so the
#               HDFS pseudo gets populated with terasort/wordcount/...
#               datasets. Run once after 'init + start'; data persists
#               until /var/lib/hadoop is wiped.
# ---------------------------------------------------------------------------

cmd_prepare_hdfs() {
    require_root
    require_paths
    [ -d "$HADOOP_DIST_CONF" ] || die "distributed configs missing — run '$0 init' first"
    if ! is_running 'NameNode' || ! is_running 'DataNode'; then
        die "HDFS daemons not running — run '$0 start' first"
    fi

    cmd_switch_distributed

    # Honor HIBENCH_SCALE env so the operator can prepare different scales
    # without manually editing hibench.conf each time. Valid: tiny|small|large|huge|gigantic.
    if [ -n "${HIBENCH_SCALE:-}" ]; then
        local hbench="$HIBENCH_HOME/conf/hibench.conf"
        if [ -f "$hbench" ]; then
            if grep -qE '^hibench\.scale\.profile' "$hbench"; then
                sed -i -E "s|^(hibench\.scale\.profile[[:space:]]+).*|\1$HIBENCH_SCALE|" "$hbench"
            else
                printf '\nhibench.scale.profile          %s\n' "$HIBENCH_SCALE" >> "$hbench"
            fi
            log "patched hibench.scale.profile=$HIBENCH_SCALE"
        fi
    fi
    local current_scale
    current_scale=$(grep -E '^hibench\.scale\.profile' "$HIBENCH_HOME/conf/hibench.conf" 2>/dev/null \
                    | awk '{print $2}' || echo unknown)
    log "preparing at hibench.scale.profile=$current_scale"

    local default_workloads="micro/terasort micro/wordcount websearch/pagerank ml/kmeans ml/bayes micro/dfsioe"
    local workloads="${INTP_DIST_WORKLOADS:-$default_workloads}"

    log "preparing HDFS datasets for: $workloads"
    log "(prepare runs from host root netns; NameNode at $HOST_IP:$NN_PORT is reachable directly)"

    local failed=0
    for wkl in $workloads; do
        local prep="$HIBENCH_HOME/bin/workloads/$wkl/prepare/prepare.sh"
        if [ ! -x "$prep" ]; then
            warn "  $wkl prepare script missing or not executable: $prep"
            failed=$((failed + 1))
            continue
        fi
        log "  $wkl prepare..."
        if env HIBENCH_HOME="$HIBENCH_HOME" \
               SPARK_HOME="$SPARK_HOME" \
               HADOOP_HOME="$HADOOP_HOME" \
               HADOOP_CONF_DIR="$HADOOP_DIST_CONF" \
               SPARK_CONF_DIR="$SPARK_DIST_CONF" \
               JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}" \
               PATH="$HADOOP_HOME/bin:$SPARK_HOME/bin:$PATH" \
               bash "$prep" >/tmp/prep-"${wkl##*/}".log 2>&1
        then
            log "    OK ($(grep -cE 'INFO|copyFromLocal' /tmp/prep-"${wkl##*/}".log 2>/dev/null) ops)"
        else
            warn "    FAIL — see /tmp/prep-${wkl##*/}.log"
            failed=$((failed + 1))
        fi
    done

    log "prepare-hdfs done. failures=$failed"
    log "Check HDFS contents:"
    log "  HADOOP_CONF_DIR=$HADOOP_DIST_CONF $HADOOP_HOME/bin/hdfs dfs -ls /HiBench"
}

# ---------------------------------------------------------------------------
# teardown: remove distributed configs (does not delete HDFS data dir)
# ---------------------------------------------------------------------------

cmd_teardown() {
    require_root
    cmd_stop
    log "removing parallel config dirs (HDFS data dir at $HADOOP_DATA_DIR is preserved)..."
    rm -rf "$HADOOP_DIST_CONF" "$SPARK_DIST_CONF"
    rm -f "$HIBENCH_HOME/conf/hibench.distributed.conf"
    log "teardown complete. To wipe HDFS data: rm -rf $HADOOP_DATA_DIR"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    sed -n '3,42p' "$0"
}

case "${1:-help}" in
    init)              cmd_init ;;
    start)             cmd_start ;;
    stop)              cmd_stop ;;
    restart)           cmd_stop; cmd_start ;;
    status)            cmd_status ;;
    smoke)             cmd_smoke ;;
    ssh-setup)         cmd_ssh_setup ;;
    switch-distributed) cmd_switch_distributed ;;
    switch-localmode)  cmd_switch_localmode ;;
    prepare-hdfs)      cmd_prepare_hdfs ;;
    teardown)          cmd_teardown ;;
    help|-h|--help)    usage ;;
    *) usage; exit 2 ;;
esac

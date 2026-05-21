#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# diagnose-netp-veth-coverage.sh -- pin the cause of V3.2 netp=0 on TCP-over-veth.
#
# CONTEXT (UB24 campaign, bench/findings/ub24-campaign-metric-validity.md §4):
#   V3.2 reports netp=0 for the veth-routed TCP workloads (tcp_v_tcp_veth,
#   app11b_tcp_veth) but netp~99 for app12b_udp_veth, while V2 reads ~97 for the
#   same TCP case. Two hypotheses were ALREADY ruled out from the code:
#     - loopback skip:  veth (intp-veth-h) is NOT 'lo'; V2 and V3 both skip only
#                       'lo', and UDP-over-veth is counted -- so the veth iface
#                       is not being filtered.
#     - PID attribution: the bench runs V2/V3 SYSTEM-WIDE (V_USE_PID_FILTER=0),
#                       so should_monitor_current() is always true.
#   What remains: does the veth TCP path (GSO super-frames, GRO on the peer)
#   actually FIRE the two tracepoints V3.2's netp hooks --
#   net:net_dev_xmit and net:netif_receive_skb -- with the right byte counts?
#
# WHAT THIS DOES:
#   For a window, it measures the SAME bytes two ways on a chosen iface:
#     (A) tracepoint bytes  = net:net_dev_xmit + net:netif_receive_skb  (V3.2 source)
#     (B) sysfs bytes       = /sys/class/net/<iface>/statistics tx+rx delta (V2 source)
#   Run it once with TCP traffic and once with UDP. The expected signatures:
#     - TCP: (A) << (B)   -> the tracepoints undercount veth TCP  => V3.2 BPF gap
#                            (and, since real NICs use TSO/GSO, a likely PRODUCTION
#                             undercount too -- not merely a bench artifact)
#     - UDP: (A) ~= (B)   -> control; confirms the probe path is otherwise sound
#
# This is a DIAGNOSTIC ONLY (read-only tracepoints + sysfs); it changes nothing.
# It must run on the measurement host (needs tracefs/BTF + bpftrace + the veth
# pair from bench/setup/setup-netns-pair.sh). Run as root.
#
# Usage:
#   sudo bash diagnose-netp-veth-coverage.sh --proto tcp   # then: --proto udp
#   sudo bash diagnose-netp-veth-coverage.sh --proto tcp --no-self-drive  # drive traffic yourself
#
# Options:
#   --proto tcp|udp     traffic to drive when --self-drive (default tcp)
#   --iface NAME        host-side veth to inspect (default: intp-veth-h)
#   --netns NAME        guest netns for the iperf3 server (default: intp-net)
#   --guest-ip IP       iperf3 server bind/target (default: 10.42.0.2)
#   --port N            iperf3 port (default: 23460)
#   --duration N        measurement window seconds (default: 15)
#   --parallel N        iperf3 parallel streams (default: 16)
#   --no-self-drive     do NOT launch iperf3; just measure (you drive the load)
#   -h, --help
# -----------------------------------------------------------------------------
set -uo pipefail

PROTO=tcp
IFACE=intp-veth-h
NETNS=intp-net
GUEST_IP=10.42.0.2
PORT=23460
DURATION=15
PARALLEL=16
SELF_DRIVE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --proto)        PROTO="$2"; shift 2 ;;
        --iface)        IFACE="$2"; shift 2 ;;
        --netns)        NETNS="$2"; shift 2 ;;
        --guest-ip)     GUEST_IP="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --duration)     DURATION="$2"; shift 2 ;;
        --parallel)     PARALLEL="$2"; shift 2 ;;
        --no-self-drive) SELF_DRIVE=0; shift ;;
        -h|--help)      sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "FATAL: must run as root (tracepoints + netns)"; exit 1; }
command -v bpftrace >/dev/null 2>&1 || { echo "FATAL: bpftrace not in PATH (apt install bpftrace)"; exit 1; }
case "$PROTO" in tcp|udp) ;; *) echo "FATAL: --proto must be tcp|udp"; exit 2 ;; esac

STAT="/sys/class/net/$IFACE/statistics"
[ -d "$STAT" ] || { echo "FATAL: iface '$IFACE' not found ($STAT). Run bench/setup/setup-netns-pair.sh first."; exit 1; }

read_sysfs() { echo "$(( $(cat "$STAT/tx_bytes") + $(cat "$STAT/rx_bytes") ))"; }

echo "=== netp veth coverage diagnostic: proto=$PROTO iface=$IFACE window=${DURATION}s ==="

# (A) tracepoint bytes -- exactly the two tracepoints V3.2's netp hooks, lo excluded.
BT_OUT="$(mktemp)"
bpftrace -e '
tracepoint:net:net_dev_xmit      /str(args->name) != "lo"/ { @tx[str(args->name)] += (uint64)args->len; }
tracepoint:net:netif_receive_skb /str(args->name) != "lo"/ { @rx[str(args->name)] += (uint64)args->len; }
interval:s:'"$DURATION"' { exit(); }
' > "$BT_OUT" 2>/dev/null &
BT_PID=$!
sleep 1   # let bpftrace attach before traffic starts

SYS_BEFORE="$(read_sysfs)"

# Optionally drive iperf3 across the veth (mirrors bench/setup/run-net-pair-workload.sh).
SRV_PID=""
if [ "$SELF_DRIVE" = 1 ]; then
    command -v iperf3 >/dev/null 2>&1 || { echo "FATAL: iperf3 not in PATH"; kill "$BT_PID" 2>/dev/null; exit 1; }
    ip netns exec "$NETNS" iperf3 -s -B "$GUEST_IP" -p "$PORT" -1 >/tmp/diag-iperf-srv.log 2>&1 &
    SRV_PID=$!
    sleep 1
    UDP_FLAG=""; [ "$PROTO" = udp ] && UDP_FLAG="-u -b 0"
    # shellcheck disable=SC2086
    iperf3 -c "$GUEST_IP" -p "$PORT" -t "$DURATION" -P "$PARALLEL" $UDP_FLAG >/tmp/diag-iperf-cli.log 2>&1 || true
else
    echo "  --no-self-drive: drive your $PROTO-over-veth load now (${DURATION}s window running)..."
fi

wait "$BT_PID" 2>/dev/null
[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
SYS_AFTER="$(read_sysfs)"

# Parse bpftrace per-iface sums for the target iface.
tp_bytes_for() {  # $1 = map name (@tx/@rx)
    awk -v map="$1" -v ifc="$IFACE" '
        $0 ~ "^"map"\\[" {
            # line form:  @tx[intp-veth-h]: 12345
            gsub(/.*\[/,""); split($0, a, "]:"); name=a[1]; val=a[2]+0
            if (name==ifc) print val
        }' "$BT_OUT"
}
TP_TX="$(tp_bytes_for @tx)"; TP_TX="${TP_TX:-0}"
TP_RX="$(tp_bytes_for @rx)"; TP_RX="${TP_RX:-0}"
TP_TOTAL=$(( TP_TX + TP_RX ))
SYS_DELTA=$(( SYS_AFTER - SYS_BEFORE ))

echo
echo "  (A) tracepoint bytes (V3.2 source): net_dev_xmit=$TP_TX  netif_receive_skb=$TP_RX  total=$TP_TOTAL"
echo "  (B) sysfs bytes      (V2 source)  : tx+rx delta on $IFACE = $SYS_DELTA"
if [ "$SYS_DELTA" -gt 0 ]; then
    PCT=$(awk -v a="$TP_TOTAL" -v b="$SYS_DELTA" 'BEGIN{printf "%.1f", (b>0)?100*a/b:0}')
    echo "  coverage (A/B) = ${PCT}%"
    echo
    if awk -v a="$TP_TOTAL" -v b="$SYS_DELTA" 'BEGIN{exit !(a < 0.5*b)}'; then
        echo "  VERDICT: tracepoints capture << sysfs  => V3.2 netp UNDERCOUNTS $PROTO-over-veth."
        [ "$PROTO" = tcp ] && echo "           Consistent with GSO/TSO: the veth TCP path bypasses per-frame"
        [ "$PROTO" = tcp ] && echo "           net_dev_xmit/netif_receive_skb accounting. Likely a PRODUCTION gap too."
    else
        echo "  VERDICT: tracepoints ~= sysfs => netp is captured for $PROTO-over-veth (control)."
    fi
else
    echo "  WARN: no sysfs byte delta -- did traffic actually flow on $IFACE? Check netns/iperf3 logs."
fi
rm -f "$BT_OUT"

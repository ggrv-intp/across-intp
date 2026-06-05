# Synthetic `netp` traffic via veth + netns

## The problem

`netp` (network physical-layer utilization) is computed across all four
IntP variants as **bytes observed at `dev_queue_xmit` (or
`netfilter.ip.local_out`) divided by the calibrated NIC line speed**.
On a single-host bare-metal setup the bench's stress-ng `--sock` and
`--udp` workloads (`app11_sort_net`, `app12_sort_net`) talk to
`127.0.0.1`, and:

- The `lo` device deliberately bypasses driver-level transmit
  accounting in some kernels.
- Even when `lo` does fire `__dev_queue_xmit`, ebpf-ring's BPF probe filters
  loopback explicitly (`tp_dev_is_lo()` in `intp.bpf.c`) because
  including loopback double-counts (sender xmit + receiver xmit on the
  same packet) and breaks correlation with the per-NIC sysfs
  ground-truth which excludes lo.

Result: `netp` reads zero on every variant for stress-ng synthetic net
workloads, even though `nets` (kernel net stack latency) is hot on
those same workloads.

## The fix

Route the workload through a **veth pair into a network namespace**.
Traffic crossing veth hits real `dev_queue_xmit` accounting and is
**not** loopback, so it survives ebpf-ring's lo filter and registers on
`netp` for every variant.

```
        host root netns                  guest netns "intp-net"
      +------------------+              +---------------------+
      |  intp-veth-h     |==============|  intp-veth-g        |
      |  10.42.0.1/24    |  veth pair   |  10.42.0.2/24       |
      |  (iperf3 client) |              |  (iperf3 server)    |
      +------------------+              +---------------------+
              |
              +-- tc qdisc netem rate $RATE  (calibrated cap)
```

Traffic across the veth pair traverses real network device queue logic.
Because the two endpoints live in different netns, the kernel cannot
short-circuit through `lo` — it has to push frames out one veth and
receive them on the other. `tc-netem rate` on the host side gives the
`netp` divisor a calibrated ceiling so the metric maps cleanly to a
0–100% range regardless of the underlying veth speed.

## How to use it

### 1. Bring up the pair

```bash
sudo bench/setup/setup-netns-pair.sh
```

Defaults: netns `intp-net`, host veth `intp-veth-h` at 10.42.0.1/24,
guest veth `intp-veth-g` at 10.42.0.2/24, tc-netem cap 1 gbit. Override
with the `INTP_NETNS_*` env vars documented at the top of the script.

### 2. Drive traffic + run the profiler

For one-shot validation that `netp` actually fires, use the helper:

```bash
# Foreground iperf3 across the veth pair. Returns its own PID via $!.
sudo bench/setup/run-net-pair-workload.sh -d 90 -P 16 &
WL_PID=$!

# Attach any IntP variant to that PID and read the netp column.
sudo variants/v1.1-stap-modern/intp-helper "$WL_PID" &
sudo stap -g variants/v1.1-stap-modern/intp-v1.1.stp "$WL_PID"
```

Or, with the in-bench profilers (after enabling `V46_USE_PID_FILTER=1`
so they accept `--pids`):

```bash
sudo INTP_BENCH_V46_PID_FILTER=1 \
    variants/v3-ebpf-ring/intp-ebpf --pids "$WL_PID" --duration 90 --output tsv
```

### 3. Tear down

```bash
sudo bench/setup/teardown-netns-pair.sh
```

## Integrating with `run-intp-bench.sh`

The bench's `WORKLOADS` array hard-codes `stress-ng <args>` as the
launcher. Splitting iperf3 across two netns doesn't fit that pattern,
so integration is **deliberately not automatic** — three options:

1. **One-off netp validation runs** — bring up the pair, kick off
   `run-net-pair-workload.sh` in the background, run the profiler with
   `--pids` against its PID, tear down. No bench changes needed.

2. **Add a dispatch hook for non-stress-ng workloads** — modify
   `launch_workload_bare()` to recognise an entry whose `args` field
   begins with a `cmd:` sentinel and exec that path instead of
   stress-ng. Then add e.g.
   `app16_real_net|network|cmd:bench/setup/run-net-pair-workload.sh -d $DURATION -P 16`
   to `WORKLOADS`. This is an isolated change but every consumer of
   `args` (including container/VM launchers) needs the same special
   case.

3. **Use stress-ng `--rawudp`** with `--rawudp-if intp-veth-h` — fits
   the existing dispatch and registers on `netp` for stap-2022/stap-nohelper/stap-modern because
   raw UDP packets traverse the IP layer (and thus
   `netfilter.ip.local_out`). Caveats: ebpf-ring's loopback filter excludes
   `lo` only by interface *name*, so `intp-veth-h` is fine; but
   `--rawudp` sends to a self-bound socket, so packets don't actually
   leave the host even with `--rawudp-if`. Less semantically clean than
   the iperf3 approach but works without changing dispatch.

## Does this affect HiBench?

**No, with one nuance.**

HiBench (Spark + HDFS) and the netns pair are independent surfaces:

- The veth interfaces are passive; nothing routes through them unless a
  process explicitly binds to `10.42.0.1` or `10.42.0.2`. HDFS by
  default binds to `0.0.0.0` which the kernel resolves to the
  configured RPC address (typically `localhost` or the primary
  external IP), neither of which matches the netns range.

- HiBench's `hadoop_profile=3` localmode setup (see
  `bench/hibench/setup-hadoop-localmode.sh`) talks to NameNode/DataNode
  via `127.0.0.1`. Spark `local[*]` mode keeps driver and executors in
  the same JVM, so there is no inter-process network traffic at all.
  Adding a veth pair doesn't change any of this — HDFS RPC continues
  through `lo`.

- `tc qdisc netem` on `intp-veth-h` is an interface-scoped qdisc.
  It does **not** rate-limit `lo`, `eno1`, or any other interface, so
  HiBench bandwidth on those paths is unchanged.

The one nuance: if you ever run a multi-node HiBench (which the
current `bench_envs=bare` localmode setup does not), and you give a
DataNode the `10.42.0.0/24` address by mistake, then yes — HDFS
replication traffic will go through the rate-capped veth and HiBench
will look slower than it is. To prevent this, the setup script picks
`10.42.0.0/24` (RFC1918 carrier-grade NAT space) which doesn't
collide with any default Hadoop config. If you choose to override the
range via `INTP_NETNS_HOST_IP` / `INTP_NETNS_GUEST_IP`, audit
`core-site.xml` / `hdfs-site.xml` for any address that might land on
the new subnet.

In short: leave the netns pair up across the entire bench run if you
want; HiBench won't notice. Tear it down only if you need to free
those names/IPs for some other purpose.

## Why `netp` will still register zero on stress-ng under HiBench's HDFS

In single-node localmode HiBench, every Spark/HDFS RPC is on `lo`. The
HiBench workloads will stress `nets`, `blk`, `cpu`, `mbw`, `llcocc`,
and `llcmr` heavily, but `netp` will be near-zero for the same reason
the stress-ng workloads were. To get `netp` signal from HiBench, run
it in a multi-node configuration where Spark executors talk over
`eno1`. That's outside the scope of the current bare bench profile.

## See also

- `bench/setup/setup-netns-pair.sh` — bring-up
- `bench/setup/teardown-netns-pair.sh` — tear-down
- `bench/setup/run-net-pair-workload.sh` — iperf3 driver
- `docs/METRICS-DEEP-DIVE.md` § netp — variant-by-variant probe encoding
- `bench/run-intp-bench.sh:177-203` — the `WORKLOADS` array

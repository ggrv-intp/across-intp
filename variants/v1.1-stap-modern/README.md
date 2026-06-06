# v1.1 (stap-modern) -- SystemTap with userspace helper for hardware metrics

Status: complete. Helper, matching `.stp` script, and bench integration
all done; nets switched to softirq tapset for kernel-6.8/veth fidelity
(see `METRICS-ALIGNMENT.md`).

This variant pairs a stap script (software metrics: net, block, cpu,
LLC miss ratio) with a userspace daemon that owns the RCU-unsafe
operations (uncore IMC perf events; resctrl mon_group). The daemon
writes the latest hardware values to `/tmp/intp-hw-data` once per
second; the stap script reads that file from a procfs read probe
(process context, RCU-safe).

See `DESIGN.md` for the full architecture and the rationale.

## Build

    make

Produces `./intp-helper`. No external dependencies beyond glibc.

## Run

    sudo ./intp-helper <comm-pattern>

The pattern is matched as a substring against `/proc/<pid>/comm`. For
example:

    sudo ./intp-helper stress-ng

The helper:

1. opens uncore IMC perf events via `perf_event_open(2)`
2. creates `/sys/fs/resctrl/mon_groups/intp-<pid>/` (PID-suffixed so
   parallel campaigns do not collide)
3. polls `/proc` once per second; each new matching PID is added to the
   mon_group's `tasks` file
4. reads counters and writes a single line atomically to
   `/tmp/intp-hw-data`:

       <timestamp_ns>\t<mbw_pct>\t<llcocc_pct>\n

5. on `SIGTERM` / `SIGINT`: closes events, removes the mon_group,
   deletes the data file.

## Override defaults via env

| Variable | Default | Meaning |
|----------|---------|---------|
| `INTP_HELPER_DRAM_BW_MBPS` | 281600 | Nominal DRAM bandwidth in MB/s; used to normalize mbw to a percentage |
| `INTP_HELPER_L3_SIZE_KB` | 46080 | L3 cache size in KB; used to normalize llcocc to a percentage |
| `INTP_HELPER_INTERVAL_S` | 1 | Polling / output interval |
| `INTP_HELPER_DATA_FILE` | `/tmp/intp-hw-data` | Output path |

The defaults assume Xeon Gold 5412U (Sapphire Rapids, 8x DDR5-4800,
45 MiB L3). Override on other platforms.

## Graceful degradation

- If uncore IMC events fail to open (different platform, permissions,
  not exposed): the helper logs a warning and reports `mbw=0`.
- If resctrl is not available (`/sys/fs/resctrl/info/L3_MON` missing):
  the helper logs a warning and reports `llcocc=0`.
- Either failure is independent; the helper still runs and writes
  whatever it can.

The stap side never blocks on this file; if `/tmp/intp-hw-data` is
missing or stale, both metrics report 0.

## Lifecycle in the bench script

    sudo ./intp-helper "$WORKLOAD" &
    HELPER_PID=$!

    sudo stap -g intp-v1.1.stp "$WORKLOAD"  # blocks during the run

    kill -TERM "$HELPER_PID"
    wait "$HELPER_PID"

The bench harness (`bench/run-intp-bench.sh`) launches the helper for
stap-modern only and tears it down after the run completes.

## Limitations / known issues

- **Hardcoded uncore IMC types (78..89)** for Sapphire Rapids. Other
  platforms expose different PMU type numbers; see
  `/sys/bus/event_source/devices/uncore_imc_*/type`. Autodetection is
  TODO.
- **Single-socket assumption**: events are opened on CPU 0. For
  multi-socket hosts the helper would need to enumerate
  `cpumask` per IMC PMU.
- **No CPU pinning**: the polling thread inherits the parent's
  affinity. For low-overhead profiling, pin to a non-target CPU
  (`taskset -c 0 ./intp-helper ...`).
- **`comm` substring match**: limited to 15 characters per
  `/proc/<pid>/comm`. For workloads that mask `comm`, switch to
  `/proc/<pid>/cmdline` matching (TODO).

## Standalone use (packaging)

This folder is self-contained: copy it into your own project and use it on its own —
no other folder from this repository is required. Follow the build/run steps above.

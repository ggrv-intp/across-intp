# V2 (hybrid-c) -- Hybrid procfs / perf_event / resctrl Implementation

IntP rebuilt using only stable Linux kernel interfaces. No SystemTap, no
eBPF, no kernel modules, no debuginfo. The dissertation's claim that all
seven IntP interference dimensions can be collected with stable ABIs is
proven empirically by this binary.

## Architecture in one sentence

V2 (hybrid-c) is a runtime-adaptive hierarchy of backends -- each metric carries an
ordered list of (probe, init, read, cleanup) backends, the runtime picks
the first backend that probes successfully on the current host, and the
output declares which backend supplied each value so consumers can tell
"real reading" from "approximation" from "proxy".

See `DESIGN.md` for the full backend hierarchy, decision tree, tradeoffs,
RMID budget management, and cross-environment behaviour.

## Quick start

Build (no external dependencies beyond glibc + libpthread):

    make

Detect what backends will be used on this host (no monitoring, just a
capability dump):

    ./intp-hybrid --list-backends

Run system-wide, IntP-compatible 7-column TSV at 1-second resolution:

    sudo ./intp-hybrid --interval 1

Per-PID monitoring, JSON line-delimited output:

    sudo ./intp-hybrid --pids 1234,5678 --output json

Prometheus exposition (intended for `textfile_collector`):

    sudo ./intp-hybrid --output prometheus --duration 1

## Output format

The default `tsv` output is byte-compatible with the original `intestbench`
7-column TSV (`netp nets blk mbw llcmr llcocc cpu`), so the existing IADA
pipeline and downstream consumers work unchanged. A leading `# v2 backends:`
banner declares which backend each column came from.

`--output json` is line-delimited; each record carries `value`, `status`
(ok/degraded/proxy/unavailable), `backend`, and an optional `note`.

`--output prometheus` writes the standard text exposition format with
labels `metric`, `backend`, `status`.

## Privileges

| capability                               | what it unlocks                       |
|------------------------------------------|---------------------------------------|
| no privileges                            | netp, nets, blk, cpu (system-wide)    |
| `CAP_PERFMON` (kernel 5.8+) or root      | llcmr per-PID via PERF_TYPE_HW_CACHE  |
| root + `perf_event_paranoid <= -1`       | mbw via uncore IMC / AMD DF / ARM CMN |
| root (or CAP_SYS_ADMIN)                  | resctrl mon_groups (mbw + llcocc)     |

The binary degrades gracefully: every metric whose backend cannot be
selected reports `--` in TSV and `null` in JSON, with the `# v2 backends:`
banner naming `none` for that column.

## Supported platforms

| Platform                    | netp | nets | blk  | mbw         | llcmr  | llcocc   | cpu  |
|-----------------------------|------|------|------|-------------|--------|----------|------|
| Intel Xeon (RDT)            | full | dgrd | full | resctrl     | full   | resctrl  | full |
| Intel Consumer (no RDT)     | full | dgrd | full | imc \*      | full   | proxy    | full |
| AMD EPYC Rome+ (resctrl)    | full | dgrd | full | resctrl     | full   | resctrl  | full |
| AMD EPYC pre-Rome           | full | dgrd | full | amd_df \*   | full   | proxy    | full |
| ARM Neoverse + MPAM (6.19+) | full | dgrd | full | resctrl     | full   | resctrl  | full |
| ARM Neoverse (no MPAM)      | full | dgrd | full | arm_cmn \*  | full   | proxy    | full |
| VM with PMU passthrough     | full | dgrd | full | varies      | full   | varies   | full |
| VM without PMU passthrough  | full | dgrd | full | none        | none   | none     | full |
| Container, host resctrl mnt | full | dgrd | full | resctrl     | varies | resctrl  | full |
| Container, no resctrl mnt   | full | dgrd | full | none        | varies | proxy    | full |

`full` = primary backend; `dgrd` = degraded (always for nets, see
DESIGN.md); `proxy` = llcocc derived from llcmr (directional only);
`*` = needs CAP_SYS_ADMIN or `perf_event_paranoid <= -1`.

## Forcing or disabling a backend (for experiments)

For evaluation runs that need a specific backend (e.g. comparing resctrl
MBM against uncore IMC on the same Intel host):

    ./intp-hybrid --force-backend mbw:perf_uncore_imc
    ./intp-hybrid --disable-metric nets

## Layout

    include/        intp.h, backend.h, detect.h, resctrl.h, perfev.h, procutil.h
    src/            one .c per concern; metrics expose metric_<name>()
    tests/          test-detect.c, test-procutil.c (run via `make run-tests`)
    scripts/        test-environments.sh, build-deb.sh, compare-environments.py
    intp-hybrid.c   CLI, polling loop, output formatters

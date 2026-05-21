# Bench Findings

This directory is the canonical location for empirical findings from the IntP
benchmark campaign.

## Index

- [V0 Baseline -- Compilation failure diagnosis](v0-baseline-failure-diagnosis.md)
  - Documents why the original V0 probe fails deterministically on modern
    kernel/header combinations.
- [V1 Modernization -- Reliability findings](v1-modernization-reliability-findings.md)
  - Documents what was improved in V1 (the restored stap-native build) and
    which operational limitations remain under modern kernels and hardware.
    The userspace-helper recovery path is implemented in V1.1.
- [UB24 campaign -- Metric validity notes](ub24-campaign-metric-validity.md)
  - Why per-variant metric magnitudes differ (v1.1 reads `llcocc=0` on 100% of
    HiBench reps — multi-process blindness, not noise); the `mbw` ceiling fix
    and current validity; and why `aggregate-means.tsv` carries only one HiBench
    profile (stage-key collapse on merge).

## Legacy-V0 campaign reports (Ubuntu 22.04 + kernel 5.15)

Reports from the legacy-V0 campaign land here once the operator
completes them on the U22 host. Expected filenames:

- `u22-preflight-<host>-<YYYYMMDD>.md` — output of
  `shared/intp-preflight.sh` after the U22 reboot, plus
  `shared/intp-detect.sh` output and the human verification notes
  (kernel version, debuginfo+headers package state, RDT flags,
  `/sys/devices/uncore_imc*` enumeration, `/sys/devices/intel_cqm/`
  presence). Documents the host's actual recalibration inputs.
- `u22-v0-smoke-<host>-<YYYYMMDD>.md` — first V0 rep on the U22 host:
  `v0-calibration.kv` values, generator log, `stap -p4` outcome, the
  profiler TSV first/last rows, any `stall-monitor/stall-dump-*`
  bundles produced during the smoke test, and an outcome verdict
  (`pass` / `fail-with-evidence`).

These stubs are placeholders for the operator's human-authored reports;
do not auto-generate them.

## V0 stall captures

V0 on Ubuntu 22.04 + kernel 5.15 GA hits stalls that are not symbolic
crashes — the host stops accepting new SSH sessions while existing
processes drift into D-state. The `bench/v0-stall-monitor.sh` watchdog
runs in parallel with every V0 rep and writes forensic snapshots into
`<rep-dir>/stall-monitor/`:

- `heartbeat-<epoch>.txt` — one-page status sample every `POLL_INTERVAL`
  seconds: loadavg, D-state count, `stap_*` module count, target PID
  state, journal tail, new dmesg lines.
- `stall-dump-<epoch>/` — full evidence bundle when any detector fires:
  - `why.txt` — which detector tripped and the reading that caused it.
  - `dmesg.txt`, `dmesg-post-sysrq-t.txt`, `dmesg-post-sysrq-l.txt` —
    kernel log before and after SysRq task / lock dumps.
  - `proc.txt` — `/proc/loadavg`, `/proc/stat`, `/proc/meminfo`,
    `/proc/interrupts`.
  - `ps.txt`, `sched-debug.txt`, `lsmod.txt`,
    `stap-modules-refcnt.txt` — process / scheduler / module state.
  - `journal.txt` — last 60s of journald.
  - `target-stack.txt`, `wchan.txt` — kernel stack and wait-channel for
    the target PID when readable.

Detectors are intentionally conservative (loadavg 1m > 50; D-state > 8;
RCU stall / soft lockup / hung_task / `BUG:` in fresh dmesg; target PID
in D-state >30s; `Failed to create session` in journal). A dump is
citable evidence of the reliability cliff — pair it with the rep's
profiler TSV and `v0-calibration.kv` to reconstruct what V0 was doing
just before the host went silent.

`MONITOR_AGGRESSIVE=1` opt-in escalates to a `sysrq-c` panic at
loadavg>200 (kdump bait); off by default because a panic without kdump
configured discards the evidence we just collected.

## Scope

Each finding should include:

1. Context and environment.
2. Reproducible evidence (commands/logs).
3. Root-cause analysis.
4. Impact on benchmark validity.
5. Mitigation status and implications for variant comparison.

## Why this matters

The dissertation compares historical portability (V0 / V0.1 / V0.2)
versus modern reliability (V1 / V1.1 stap+helper, V2 procfs,
V3.1 bpftrace, V3 eBPF/CO-RE / **V3.2 eBPF in-kernel aggregation**).
The four measured-result variants for the SBAC-PAD 2026 paper are
**V0.2, V1.1, V2, V3.2**; V3 is retained as the predecessor of V3.2
and the empirical motivation for the in-kernel-aggregation design
(see `docs/V3-OVERHEAD-FINDINGS.md`). V3.1 stays runnable but is
held out of the default matrix. Keeping findings centralized and
versioned in this directory makes that argument auditable and
reproducible.

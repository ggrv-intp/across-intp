# v0 (stap-2022) -- Original IntP (SystemTap, requires `intel_cqm` driver)

Reference baseline used for portability and metric-fidelity comparison.
This directory holds the canonical stap-2022 script (`intp.stp`, 660 lines)
preserved unchanged from the 2022 IntP paper, plus the template and
generator that recalibrate it for any host other than the original
PUCRS dev machine.

The canonical script also remains useful for:

- the Makefile to parse-check it (`make validate-v0`),
- `docs/METRICS-DEEP-DIVE.md` and `docs/VARIANT-COMPARISON.md` to cite
  exact line numbers, and
- `bench/findings/v0-baseline-failure-diagnosis.md` to document why
  this script no longer compiles on current mainline kernels (the
  underlying `cqm_rmid` field and `intel_cqm` perf PMU driver were
  removed in kernel 4.14, Nov 2017; mainstream distros stopped
  shipping the vendor backport around 2019-2020).

## Workflow

stap-2022 is measured on Ubuntu 22.04 + kernel 5.15 in the legacy-V0 campaign:

```
shared/intp-detect.sh                  hardware values from sysfs
        │
        ▼
variants/v0-stap-2022/intp.stp.template      placeholder script (read-only)
        │
        ▼  generate-stp.sh substitutes placeholders + logs KEY=VALUE
        │
        ▼
variants/v0-stap-2022/intp.recal.stp         what stap actually loads
                                       (gitignored, regenerated per run)
```

`intp.stp` itself is **never modified** — it is the byte-faithful copy
of the 2022 paper script. All host adaptation flows through the
template and the generator. `bench/run-intp-bench.sh`
(`run_profiler_systemtap_v0`) calls the generator before every stap
invocation and saves the KV log next to the rep TSV as
`v0-calibration.kv`. `bench/v0-stall-monitor.sh` runs alongside the
profiler and captures forensic snapshots on stall indicators.

## Files

- `intp.stp` -- the canonical stap-2022 SystemTap script. **Read-only**; do not
  modify. Contract with the 2022 paper baseline.
- `intp.stp.template` -- byte-for-byte copy of `intp.stp` with hardware
  constants replaced by `@@PLACEHOLDER@@` tokens. Edited only when the
  recalibration set itself changes.
- `generate-stp.sh` -- sources `shared/intp-detect.sh`, substitutes
  placeholders, writes `intp.recal.stp`. Prints a `KEY=VALUE` calibration log
  on stdout (captured per-rep as `<rep>/...v0-calibration.kv`).
- `intp.recal.stp` -- the recalibrated script actually loaded by `stap`.
  Gitignored; regenerated on every stap-2022 run.

## Recalibration constants

The original `intp.stp` embeds calibrated constants from the 2022 PUCRS dev
machine. Five of them must be recomputed per-host or normalisation produces
the wrong percentage. `intp.stp.template` carries the placeholders below;
`generate-stp.sh` fills them from `shared/intp-detect.sh`.

| Placeholder                  | Source variable             | Unit (template)   | Original value     | Source                                                          |
|------------------------------|-----------------------------|-------------------|--------------------|-----------------------------------------------------------------|
| `@@NIC_BYTES_PER_SEC@@`      | `INTP_NIC_SPEED_MBPS`       | bytes/sec (×125k) | `125000000` (1GbE) | `/sys/class/net/<iface>/speed`                                  |
| `@@LLC_BYTES@@`              | `INTP_LLC_SIZE_KB`          | bytes (×1024)     | `34000000` (~34MB) | `/sys/devices/system/cpu/cpu0/cache/index*/size`                |
| `@@MEM_BW_BYTES_PER_SEC@@`   | `INTP_MEM_BW_MBPS`          | bytes/sec (×125k) | `34000000000`      | dmidecode (root) or DDR4-2666 dual-channel default              |
| `@@IMC_PMU_TYPE@@`           | `INTP_IMC_PMU_TYPE`         | integer           | `14`               | `/sys/devices/uncore_imc/type` or `/sys/devices/uncore_imc_0/type` |
| `@@CMT_SCALE_FACTOR@@`       | `INTP_CMT_SCALE_FACTOR`     | bytes/RMID-tick   | `49152`            | `/sys/devices/intel_cqm/format/event` (fallback: 49152)         |

Constants **not** placed via the template:

- **IMC channel count.** `intp.stp` registers events on CPUs 0 and 1
  (two channels). Sapphire Rapids exposes up to 8 channels per socket
  (`uncore_imc_0..7`). The generator warns when
  `INTP_IMC_CHANNEL_COUNT > 2`; measured `mbw` is a lower bound until
  the script is extended.
- **CMT IPI cpumask.** The embedded C block IPIs CPUs 0 and 1 to read
  `MSR_IA32_QM_CTR`. On dual-socket hosts the second CPU should live on
  socket 1. Single-socket Sapphire Rapids is unaffected.
- **NIC iface / block dev.** Not hardcoded in `intp.stp` -- the netfilter
  and `kernel.trace("block_rq_complete")` probes are system-wide.
  `INTP_DEFAULT_NIC_IFACE` / `INTP_DEFAULT_BLOCK_DEV` are exported for
  launcher-side filtering, not for substitution.

## Status

- Compiles only on kernels that still carry the `intel_cqm` perf PMU
  driver -- mainline removed it in **kernel 4.14** (Nov 2017, commit
  `c39a0e2c8850`), and enterprise LTS vendor backports kept it
  available until roughly 2019-2020. The `MSR_IA32_QM_CTR` /
  `QM_EVTSEL` redefinitions in the embedded C blocks additionally
  conflict with `<asm/msr-index.h>` on any kernel that already
  defines them, which compounds the failure mode on modern headers.
  For modern kernels use stap-nollc (`variants/v0.1-stap-nollc/`), stap-nohelper
  (`variants/v1-stap-nohelper/`), or stap-modern (`variants/v1.1-stap-modern/`).
- Hardware constants (1 GbE NIC, 34 GB/s memory bandwidth, 34 MB LLC,
  IMC PMU type 14, CMT scale factor 49152) reflect the 2022 PUCRS dev
  machine. Variants C-ABI/ebpf-ring/bpftrace autodetect these via
  `shared/intp-detect.sh`.

## See also

- Upstream archival repo: <https://github.com/projectintp/intp> -- the
  original layout (additional `.STP` build variants, screenshots, and
  Debian/RedHat install guides) is preserved there.
- Top-level [README.md](../README.md) -- variant matrix and quick start.
- [VERSIONS.md](../VERSIONS.md) -- legacy ↔ current naming map.
- [METRICS-ALIGNMENT.md](../METRICS-ALIGNMENT.md) -- per-metric formulas
  across all variants, with stap-2022 as reference.

## Standalone use (packaging)

This folder builds and runs on its own (see the steps above) with **one** repo-level
dependency: `shared/intp-detect.sh` (hardware autodetection, sourced by
`generate-stp.sh`). To use this folder outside the repository, copy
`shared/intp-detect.sh` next to it (or keep a repo checkout on hand).

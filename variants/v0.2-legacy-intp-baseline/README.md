# v0.2 — V0 semantics with userspace helper (target: kernel 5.15 GA)

`v0.2` is a new variant that keeps the paper-faithful V0 SystemTap script
for `netp`, `nets`, `blk`, `llcmr`, and `cpu` (all RCU-safe) while moving
the two RCU-unsafe operations -- uncore IMC perf events and `cqm_rmid`
LLC occupancy -- into a userspace helper. The target kernel is **5.15 GA
(Ubuntu 22.04)**; on that kernel V0 is technically still runnable (cqm_rmid
has not yet been removed) but the Canonical RCU-checking backports
destabilise V0's embedded `perf_event_create_kernel_counter()` path inside
stap probe context, surfacing as stapio orphans, `stap_*` module
accumulation, and eventually systemd-logind deadlock.

`v0.2` runs paper-faithfully on kernel 5.15 *without* triggering that
fragility cascade. It coexists with:

- `variants/v0-stap-2022/` — the read-only paper-original (preserved by contract);
- `variants/v0.1-stap-nollc/` — the minimal kernel-6.8 patch (LLC occupancy disabled);
- `variants/v1.1-stap-modern/` — the same helper pattern but on kernel ≥ 6.8.

See `DESIGN.md` for the architecture and the rationale.

## Build

    make

Produces `./intp-helper`. No external dependencies beyond glibc.

## Run

The host launcher (`bench/run-intp-bench.sh`) does this automatically when
the operator selects `--variants v0.2`; for ad-hoc use:

    sudo INTP_HELPER_IMC_PMU_TYPE=14 \
         INTP_HELPER_DRAM_BW_MBPS=34000 \
         INTP_HELPER_L3_SIZE_KB=35840 \
         ./intp-helper stress-ng &
    # in another terminal: generate the recalibrated .stp and load it
    sudo bash variants/v0.2-legacy-intp-baseline/generate-stp.sh
    sudo stap -g variants/v0.2-legacy-intp-baseline/intp.recal.stp stress-ng

The pattern is matched as a substring against `/proc/<pid>/comm`.

The helper:

1. opens uncore IMC perf events via `perf_event_open(2)` for the PMU
   type range you pass via env;
2. creates `/sys/fs/resctrl/mon_groups/intp-v02-<pid>/` (PID-suffixed
   so parallel campaigns and the stap-modern helper don't collide);
3. polls `/proc` once per second; each new matching PID joins the
   mon_group's `tasks` file;
4. reads counters and writes a single line atomically to
   `/tmp/intp-v0.2-hw-data`:

       <timestamp_ns>\t<mbw_pct>\t<llcocc_pct>\n

5. on `SIGTERM` / `SIGINT`: closes events, removes the mon_group,
   deletes the data file.

## Override defaults via env

| Variable                          | Default            | Meaning                                                                 |
|-----------------------------------|--------------------|-------------------------------------------------------------------------|
| `INTP_HELPER_DRAM_BW_MBPS`        | 34000              | Nominal DRAM bandwidth in MB/s; used to normalize mbw to a percentage   |
| `INTP_HELPER_L3_SIZE_KB`          | 35840              | L3 cache size in KB; used to normalize llcocc to a percentage           |
| `INTP_HELPER_IMC_PMU_TYPE`        | 14                 | Single uncore_imc PMU type (the 2022 paper kernel's value)              |
| `INTP_HELPER_IMC_PMU_TYPE_FIRST`  | = IMC_PMU_TYPE     | First PMU type in a range (used on hosts that expose multiple uncore_imc_N) |
| `INTP_HELPER_IMC_PMU_TYPE_LAST`   | = FIRST            | Last PMU type in the range (single-type by default)                     |
| `INTP_HELPER_INTERVAL_S`          | 1                  | Polling interval in seconds                                             |
| `INTP_HELPER_DATA_FILE`           | /tmp/intp-v0.2-hw-data | Output path (separate from stap-modern to avoid collision)          |

`bench/run-intp-bench.sh` derives all of these from `shared/intp-detect.sh`
at run time and passes them through; the defaults above are the 2022 paper
dev box values and are intended as a safe fallback for hosts where
detection fails.

## intp.stp.template

`intp.stp.template` is the legacy-intp-baseline stap script with a placeholder for the
host NIC bandwidth (`@@NIC_BYTES_PER_SEC@@`). `generate-stp.sh` sources
`shared/intp-detect.sh`, substitutes the placeholder, writes
`intp.recal.stp`, and that is what `stap` loads. The template itself is
checked in; `intp.recal.stp` is generated per-host and is in
`.gitignore`. The paper-original `variants/v0-stap-2022/intp.stp` is untouched.

## Failure modes (designed-in graceful degradation)

| Condition                                          | Effect on data                |
|----------------------------------------------------|-------------------------------|
| Helper not running when stap reads the data file   | mbw=0 and llcocc=0; warning   |
| Helper's resctrl mon_group cannot be created       | llcocc=0; helper warn at start|
| Helper's IMC PMU types open zero perf events       | mbw=0; helper warn at start   |
| Per-host knobs unset, defaults used                | values are normalized against the 2022 paper dev box -- expect under/overshoot until you pass real values |

## Validation step

```bash
# 1. Helper starts and writes the data file:
sudo INTP_HELPER_IMC_PMU_TYPE=14 ./intp-helper stress-ng &
sleep 2
cat /tmp/intp-v0.2-hw-data
# expect: <ns>\t<0..99>\t<0..99>\n

# 2. Stap script reads it from the procfs read probe (manual):
sudo bash generate-stp.sh
sudo stap -g intp.recal.stp stress-ng
# In another shell, while stress-ng runs:
cat /proc/intestbench
# expect all 7 columns populated, mbw and llcocc non-zero
```

## Status

Scaffolded 2026-05-11. Not yet validated on a U22 / kernel 5.15 host —
the operator runs the smoke test as part of the legacy-V0 campaign
preflight (`bench/setup/setup-host-legacy.sh` + the V0.2 smoke step
once added to `run-smoke-all.sh`).

## Standalone use (packaging)

This folder builds and runs on its own (see the steps above) with **one** repo-level
dependency: `shared/intp-detect.sh` (hardware autodetection, sourced by
`generate-stp.sh`). To use this folder outside the repository, copy
`shared/intp-detect.sh` next to it (or keep a repo checkout on hand).

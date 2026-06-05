# Hardware Compatibility

Intel RDT, AMD PQoS, and ARM MPAM feature tables across processor
generations, with per-metric status and execution guides for each
platform.

## 1. Feature Requirements by Metric

| Metric | Feature Required | Intel | AMD | ARM | Fallback |
|--------|-----------------|-------|-----|-----|----------|
| netp | NIC + sysfs speed | OK | OK | OK | procfs `/proc/net/dev` (DEGRADED if speed unknown) |
| nets | Kernel tracepoints | OK | OK | OK | — |
| blk | Kernel tracepoints | OK | OK | OK | — |
| mbw | resctrl MBM or perf uncore | RDT MBM | PQoS MBM | MPAM | perf_uncore_imc / perf_amd_df / perf_arm_cmn |
| llcmr | perf HW cache counters | OK | OK | Partial | perf_raw with vendor-specific event codes |
| llcocc | resctrl CMT | RDT CMT | PQoS L3 | MPAM | proxy from llcmr (PROXY, directional only) |
| cpu | Kernel tracepoints | OK | OK | OK | — |

**Legend:** OK = full support. DEGRADED = reduced accuracy. PROXY =
directional estimate only. UNAVAILABLE = metric emits `--` / NaN.

---

## 2. Intel Xeon — RDT Full Support

### 2.1 Processor Generation Table

| Generation | Microarch | RDT CMT | RDT MBM | CAT L3 | MBA | resctrl kernel |
|------------|-----------|:-------:|:-------:|:------:|:---:|:--------------:|
| Haswell-EP (v1) | Haswell | ✓ | — | — | — | 4.10+ |
| Broadwell-EP (v2) | Broadwell | ✓ | ✓ | ✓ | — | 4.10+ |
| Skylake-SP | Skylake | ✓ | ✓ | ✓ | ✓ | 4.12+ |
| Cascade Lake-SP | Skylake | ✓ | ✓ | ✓ | ✓ | 4.12+ |
| Ice Lake-SP | Sunny Cove | ✓ | ✓ | ✓ | ✓ | 5.0+ |
| **Sapphire Rapids** | Golden Cove | ✓ | ✓ | ✓ | ✓ | 5.18+ |
| Emerald Rapids | Golden Cove | ✓ | ✓ | ✓ | ✓ | 6.2+ |
| Granite Rapids | Redwood Cove | ✓ | ✓ | ✓ | ✓ | 6.6+ |

### 2.2 Runtime Detection

```bash
# CPU flags (all should appear on Broadwell-EP+)
grep -oP 'cqm|cqm_occup_llc|cqm_mbm_total|cqm_mbm_local|cat_l3|mba' /proc/cpuinfo | sort -u

# resctrl monitoring features (kernel must be 4.10+)
cat /sys/fs/resctrl/info/L3_MON/mon_features
# Expected: llc_occupancy  mbm_total_bytes  mbm_local_bytes

# Number of available RMIDs (typically 32-256)
cat /sys/fs/resctrl/info/L3_MON/num_rmids

# Uncore IMC (memory controller perf events)
ls /sys/devices/uncore_imc_*/
```

### 2.3 IntP Backend Priority (hybrid-c)

```
mbw:   resctrl_mbm > perf_uncore_imc
llcocc: resctrl > proxy_from_miss_ratio
llcmr:  perf_hwcache > perf_raw (0x4F2E / 0x412E)
```

### 2.4 Known Errata

- **Haswell-EP:** CMT only (no MBM). `mbw` falls to `perf_uncore_imc`.
- **`cqm_rmid` removal:** the field was deleted from
  `struct hw_perf_event` in **kernel 4.14** (November 2017, commit
  `c39a0e2c8850`) together with the `intel_cqm` perf PMU driver.
  Vendor backports kept it usable on some enterprise LTS kernels
  until roughly 2019-2020; today no mainstream distro ships the
  backport, so stap-2022 will fail to compile on any current kernel
  (Ubuntu 22.04's stock 5.15 already lacks the field; 6.8 is
  simply when the failure becomes inescapable). stap-nollc+ handle this.
  SystemTap's `perf_rmid_read()` is no longer available.
- **RMID budget:** Each resctrl `mon_group` consumes 1 RMID.
  Haswell has 32, Broadwell+ has 128-256. IntP uses 1 group per run.
  Keep total mon_groups below 75% of `num_rmids`.

### 2.5 Dell PowerEdge R740 / R750 Specifics

The R740 ships with Skylake-SP / Cascade Lake-SP (2× Xeon Gold/Platinum).
The R750 ships with Ice Lake-SP (2× Xeon Gold/Platinum 3rd Gen).
Both have **full RDT** (CMT + MBM + CAT + MBA).

```bash
# Typical R740 (Cascade Lake, 2× Xeon Gold 6230)
#   LLC: 27.5 MB per socket → llc_size_bytes = 28835840 × 2
#   NIC: Broadcom 25GbE or Intel X710 10GbE
#   Memory: DDR4-2933 6-channel → ~140 GB/s

# Typical R750 (Ice Lake, 2× Xeon Gold 6338)
#   LLC: 48 MB per socket → llc_size_bytes = 50331648 × 2
#   NIC: Broadcom 25GbE
#   Memory: DDR4-3200 8-channel → ~204 GB/s
```

CLI overrides (if autodetect doesn't match):

```bash
# V2
sudo ./intp-hybrid --nic-speed-bps 3125000000 --llc-size-bytes 57671680 --mem-bw-max-bps 140000000000

# V3.1
sudo ./run-intp-bpftrace.sh --nic-speed-bps 3125000000 --llc-size-bytes 57671680 --mem-bw-max-bps 140000000000

# V3
sudo ./intp-ebpf --nic-speed-bps 3125000000 --llc-size-bytes 57671680 --mem-bw-max-bps 140000000000
```

---

## 3. AMD EPYC — PQoS Support

### 3.1 Processor Generation Table

| Generation | Microarch | L3 QoS Mon | MBM | CAT L3 | MBA | resctrl kernel |
|------------|-----------|:----------:|:---:|:------:|:---:|:--------------:|
| Naples (7001) | Zen 1 | — | — | — | — | — |
| **Rome (7002)** | Zen 2 | ✓ | ✓ | ✓ | — | 5.1+ |
| Milan (7003) | Zen 3 | ✓ | ✓ | ✓ | ✓ | 5.14+ |
| Genoa (9004) | Zen 4 | ✓ | ✓ | ✓ | ✓ | 6.1+ |
| Turin (9005) | Zen 5 | ✓ | ✓ | ✓ | ✓ | 6.8+ |

### 3.2 Runtime Detection

```bash
# AMD does NOT expose cqm_* flags; detection goes through resctrl
cat /sys/fs/resctrl/info/L3_MON/mon_features
# Expected on Rome+: llc_occupancy  mbm_total_bytes  mbm_local_bytes

# AMD Data Fabric perf events (for mbw fallback)
ls /sys/devices/amd_df*/

# Verify vendor
grep AuthenticAMD /proc/cpuinfo
```

### 3.3 IntP Backend Priority (hybrid-c)

```texts
mbw:    resctrl_mbm > perf_amd_df (DRAM beats, 64B granularity)
llcocc: resctrl > proxy_from_miss_ratio
llcmr:  perf_hwcache > perf_raw (L3_LOOKUP=0x04 / L3_MISS=0x06)
```

### 3.4 Known Differences vs Intel

- **Naples (Zen 1):** No QoS monitoring at all. `mbw` = UNAVAILABLE,
  `llcocc` = PROXY. Only 5/7 metrics at full quality.
- **CCD topology:** AMD L3 is per-CCD (Core Complex Die), not per-socket.
  `resctrl` sums across `mon_L3_*` domains — IntP handles this correctly.
- **No `cqm_*` cpuinfo flags:** IntP's detect falls back to reading
  `/sys/fs/resctrl/info/L3_MON/mon_features` directly.
- **`perf_amd_df`** requires `perf_event_paranoid ≤ -1` or `CAP_PERFMON`.

### 3.5 Execution Guide — AMD EPYC

```bash
# 1. Mount resctrl (Rome+)
sudo mount -t resctrl resctrl /sys/fs/resctrl

# 2. Verify features
cat /sys/fs/resctrl/info/L3_MON/mon_features
#    llc_occupancy  mbm_total_bytes  mbm_local_bytes

# 3. Run (same commands as Intel)
sudo ./intp-hybrid --pid $(pgrep -f my_workload)                # V2
sudo ./run-intp-bpftrace.sh --pid $(pgrep -f my_workload)      # V3.1
sudo ./intp-ebpf --pids $(pgrep -f my_workload)                # V3

# 4. If on Naples (Zen 1) — no resctrl, mbw/llcocc unavailable
sudo ./intp-hybrid --pid $(pgrep -f my_workload)
# Output: mbw=-- llcocc=-- (or proxy)
```

---

## 4. ARM — MPAM Support

### 4.1 Processor Table

| Platform | Arch | MPAM | resctrl kernel |
|----------|------|:----:|:--------------:|
| Cortex-A55/A76/A78 | ARMv8.2 | — | — |
| Neoverse N1 | ARMv8.2 | Partial | — |
| **Neoverse N2** | ARMv9 | ✓ | 6.19+ |
| Neoverse V0.1 (Grace) | ARMv9 | ✓ | 6.19+ |
| Neoverse V1 | ARMv9 | ✓ | 6.19+ |
| Graviton 3 (AWS) | Neoverse V0 | — | — |
| **Graviton 4 (AWS)** | Neoverse V0.1 | ✓ | 6.19+ |
| Ampere Altra | ARMv8.2+ | — | — |

### 4.2 Runtime Detection

```bash
# Verify ARM
grep 'CPU implementer' /proc/cpuinfo

# MPAM via resctrl (requires kernel 6.19+)
cat /sys/fs/resctrl/info/L3_MON/mon_features 2>/dev/null
cat /sys/fs/resctrl/info/MB_MON/mon_features 2>/dev/null

# ARM CMN (Coherent Mesh Network) perf events
ls /sys/devices/arm_cmn*/
```

### 4.3 IntP Backend Priority (hybrid-c)

```text
mbw:    resctrl_mbm > perf_arm_cmn (HN-F memory traffic, 64B)
llcocc: resctrl > proxy_from_miss_ratio
llcmr:  perf_hwcache > perf_raw (LL_CACHE=0x32 / LL_CACHE_MISS_RD=0x37)
```

### 4.4 Known Limitations

- **MPAM kernel support is very new** (6.19+, mainlined late 2025).
  Most ARM servers in production today run kernels without MPAM resctrl.
  On these, `mbw` = UNAVAILABLE and `llcocc` = PROXY.
- **`perf_hwcache` for llcmr:** ARM's L2/L3 cache event naming varies
  by microarchitecture. `PERF_COUNT_HW_CACHE_LL` works on Neoverse
  but may report 0 on older Cortex designs.
- **`perf_arm_cmn`** requires `CAP_PERFMON` or `perf_event_paranoid ≤ -1`.
- **No `cpuinfo flags` field on ARM.** Detection uses `"CPU implementer"`
  and `"Features"` lines instead.

### 4.5 Execution Guide — ARM

```bash
# 1. Check kernel version (need 6.19+ for MPAM resctrl)
uname -r

# 2. Mount resctrl (Neoverse N2/V0.1+ with kernel 6.19+)
sudo mount -t resctrl resctrl /sys/fs/resctrl

# 3. If no MPAM: mbw and llcocc will be proxy/unavailable
#    Other 5 metrics work normally

# V2 (works on any ARM64 with /proc and /sys)
sudo ./intp-hybrid --pid $(pgrep -f my_workload)

# V3.1 (needs bpftrace + BTF; aarch64 bpftrace available in Ubuntu 24.04)
sudo ./run-intp-bpftrace.sh --pid $(pgrep -f my_workload)

# V3 (needs clang + libbpf; cross-compile or native build on ARM64)
sudo ./intp-ebpf --pids $(pgrep -f my_workload)
```

---

## 5. Platform Comparison Summary

| Aspect | Intel Xeon (Broadwell+) | AMD EPYC (Rome+) | ARM Neoverse (N2+) |
|--------|:-----------------------:|:-----------------:|:------------------:|
| Metrics at full quality | 7/7 | 7/7 | 5-7/7 (MPAM needed) |
| Min kernel for 7/7 | 4.10 | 5.1 | 6.19 |
| resctrl auto-mount | No | No | No |
| detect auto-discovery | cpuinfo flags | resctrl files | resctrl files |
| Uncore perf fallback | `uncore_imc` | `amd_df` | `arm_cmn` |
| LLC topology | Per-socket | Per-CCD | Per-cluster |
| RMID count | 32-256 | 128-256 | TBD (MPAM) |
| Container support | `--privileged` + resctrl | Same | Same |
| VM PMU passthrough | libvirt `<pmu>` | Same | Same |

---

## 6. Quick-Start per Platform

### 6.1 Intel Xeon (Dell R740/R750 or similar)

```bash
# Dependencies
sudo apt install build-essential clang libbpf-dev linux-tools-generic bpftrace python3

# resctrl
sudo mount -t resctrl resctrl /sys/fs/resctrl

# Build all
cd variants/v2-hybrid-c && make && cd ..
cd variants/v3-ebpf-ring && make && cd ..

# Validate 7/7
./shared/intp-detect.sh | grep INTP_
sudo ./variants/v2-hybrid-c/intp-hybrid --list-backends
sudo ./variants/v3-ebpf-ring/intp-ebpf --list-capabilities

# Run
sudo ./variants/v2-hybrid-c/intp-hybrid --interval 1 --duration 60
sudo ./variants/v3.1-bpftrace/run-intp-bpftrace.sh --interval 1 --duration 60
sudo ./variants/v3-ebpf-ring/intp-ebpf --interval 1 --duration 60

# Cross-variant comparison
sudo ./shared/validate-cross-variant.sh --start-workload --duration 30
```

### 6.2 AMD EPYC (Rome / Milan / Genoa)

```bash
# Dependencies (same as Intel)
sudo apt install build-essential clang libbpf-dev linux-tools-generic bpftrace python3

# resctrl (Rome+)
sudo mount -t resctrl resctrl /sys/fs/resctrl

# Build
cd variants/v2-hybrid-c && make && cd ..
cd variants/v3-ebpf-ring && make && cd ..

# Verify — look for amd_df and resctrl features
ls /sys/devices/amd_df*/ 2>/dev/null && echo "AMD DF: available"
cat /sys/fs/resctrl/info/L3_MON/mon_features

# Run (identical commands)
sudo ./variants/v2-hybrid-c/intp-hybrid --interval 1 --duration 60
sudo ./variants/v3.1-bpftrace/run-intp-bpftrace.sh --interval 1 --duration 60
sudo ./variants/v3-ebpf-ring/intp-ebpf --interval 1 --duration 60
```

### 6.3 ARM64 (Neoverse N2/V0.1, Graviton 4)

```bash
# Dependencies (aarch64 packages)
sudo apt install build-essential clang libbpf-dev linux-tools-generic bpftrace python3

# resctrl — ONLY on kernel 6.19+ with MPAM
uname -r   # must be >= 6.19
sudo mount -t resctrl resctrl /sys/fs/resctrl 2>/dev/null

# Build (native on ARM64)
cd variants/v2-hybrid-c && make && cd ..
cd variants/v3-ebpf-ring && make && cd ..

# Verify
cat /sys/fs/resctrl/info/L3_MON/mon_features 2>/dev/null || echo "No MPAM — mbw/llcocc will be proxy/unavailable"
ls /sys/devices/arm_cmn*/ 2>/dev/null && echo "ARM CMN: available"

# Run
sudo ./variants/v2-hybrid-c/intp-hybrid --interval 1 --duration 60
sudo ./variants/v3.1-bpftrace/run-intp-bpftrace.sh --interval 1 --duration 60
sudo ./variants/v3-ebpf-ring/intp-ebpf --interval 1 --duration 60
```

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `mbw=--` and `llcocc=--` | resctrl not mounted | `sudo mount -t resctrl resctrl /sys/fs/resctrl` |
| `llcmr=--` | perf_event_paranoid too high | `sudo sysctl -w kernel.perf_event_paranoid=-1` |
| `netp` value seems wrong | NIC speed misdetected | Use `--nic-speed-bps` override |
| `mbw` always 0 | mem_bw_max autodetect failed | Use `--mem-bw-max-bps` override (check dmidecode) |
| ebpf-ring build fails: "vmlinux.h not found" | BTF absent | `apt install linux-image-$(uname -r)-dbg` or check `CONFIG_DEBUG_INFO_BTF` |
| bpftrace: "bpftrace: failed to load BTF" | Kernel lacks BTF | Need kernel 5.8+ with `CONFIG_DEBUG_INFO_BTF=y` |
| ebpf-ring: "failed to attach" in container | Missing capabilities | `docker run --privileged` or add `CAP_BPF,CAP_PERFMON,CAP_SYS_RESOURCE` |
| resctrl mount fails | Kernel lacks RDT/PQoS/MPAM | Hardware doesn't support it; mbw/llcocc degrade |

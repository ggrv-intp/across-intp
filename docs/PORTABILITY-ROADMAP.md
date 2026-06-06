# Portability Roadmap

Per-variant portability analysis across kernel versions, distributions,
architectures, and deployment environments.

## 1. Variant Summary

| Aspect | V2 hybrid-procfs | V3.1 bpftrace | V3 eBPF/CO-RE | V3.2 eBPF in-kernel agg |
|--------|:-----------------:|:-----------:|:-------------:|:----------------:|
| Language | C11 | bpftrace DSL + Python 3 | C11 + eBPF C | C11 + eBPF C |
| Framework | None (procfs/sysfs/perf_event) | bpftrace runtime | libbpf + CO-RE | libbpf + CO-RE |
| Build tool | gcc + make | None (interpreted) | clang + gcc + bpftool + make | clang + gcc + bpftool + make |
| Binary portability | Recompile per target | Runs anywhere with bpftrace | CO-RE: compile once, run on 5.8+ | CO-RE: compile once, run on 5.8+ |
| Startup time | < 100 ms | 1-3 s | ~ 500 ms | ~ 500 ms |
| Root required | Partial (perf + resctrl) | Yes (BPF + tracing) | Yes (BPF + tracing) | Yes (BPF + tracing) |

---

## 2. Kernel Version Support

### 2.1 V2 — hybrid procfs

| Kernel | netp | nets | blk | cpu | llcmr | mbw | llcocc | Notes |
|--------|:----:|:----:|:---:|:---:|:-----:|:---:|:------:|-------|
| 3.x | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | No resctrl |
| 4.10+ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Intel RDT resctrl |
| 5.1+ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | + AMD Rome PQoS |
| 6.8+ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | mainstream distros no longer ship the `intel_cqm` backport; V2 unaffected (resctrl-based). `cqm_rmid` itself was removed in 4.14 (Nov 2017, commit `c39a0e2c8850`). |
| 6.19+ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | + ARM MPAM |

**Minimum:** Any kernel with `/proc` and `/sys`. All 5 software metrics
work everywhere. Hardware metrics (mbw, llcocc) need resctrl.

### 2.2 V3.1 — bpftrace

| Kernel | Status | Notes |
|--------|--------|-------|
| < 5.2 | ✗ | bpftrace needs BPF ring buffer + BTF |
| 5.8+ | ✓ | Full support (BTF, CAP_BPF, BPF_MAP_TYPE_RINGBUF) |
| 6.x+ | ✓ | Tested on 6.1, 6.5, 6.8, 6.11 |

**Minimum:** 5.8 with `CONFIG_DEBUG_INFO_BTF=y`.

### 2.3 V3 — eBPF/CO-RE

| Kernel | Status | Notes |
|--------|--------|-------|
| < 5.2 | ✗ | No CO-RE support |
| 5.2–5.7 | Partial | CO-RE available but no CAP_BPF / ring buffer |
| 5.8+ | ✓ | Full support |
| 6.x+ | ✓ | Tested; CO-RE relocations handle struct changes |

**Minimum:** 5.8 with `CONFIG_DEBUG_INFO_BTF=y`.

**CO-RE portability note:** The compiled `intp.bpf.o` is portable across
kernels ≥ 5.8 without recompilation. The libbpf loader reads the target
kernel's BTF at load time and relocates struct field accesses. However,
`vmlinux.h` generation (`bpftool btf dump`) should ideally be done on
the build machine's kernel; CO-RE handles the delta.

### 2.4 V3.2 — eBPF in-kernel aggregation

Same kernel constraints as V3 (BTF + CO-RE + CAP_BPF) — V3.2 uses the
same `intp.bpf.o`-style compiled bytecode and the same libbpf
relocation path. The map types V3.2 relies on
(`BPF_MAP_TYPE_PERCPU_ARRAY`, `BPF_MAP_TYPE_HASH`,
`BPF_PROG_TYPE_PERF_EVENT`) have been available since the 4.x series,
so the kernel floor is set by the BTF requirement, not the maps.

| Kernel | Status | Notes |
|--------|--------|-------|
| < 5.2 | ✗ | No CO-RE support |
| 5.2–5.7 | Partial | CO-RE available but no CAP_BPF |
| 5.8+ | ✓ | Full support |
| 6.x+ | ✓ | Tested; CO-RE relocations handle struct changes |

**Minimum:** 5.8 with `CONFIG_DEBUG_INFO_BTF=y`, same as V3.

---

## 3. Distribution Support

### 3.1 Ubuntu

| Ubuntu | Kernel | V2 | V3.1 | V3 | Notes |
|--------|--------|:---:|:---:|:---:|-------|
| 20.04 LTS | 5.4 | ✓ | ✗ | ✗ | Kernel too old for BTF by default |
| 22.04 LTS | 5.15 | ✓ | ✓ | ✓ | BTF enabled; bpftrace 0.14+ in repo |
| 24.04 LTS | 6.8 | ✓ | ✓ | ✓ | Recommended; all packages in main repo |

**Package names (Ubuntu 24.04):**

```bash
# V2 only
sudo apt install build-essential

# V3.1
sudo apt install bpftrace python3

# V3
sudo apt install build-essential clang libbpf-dev libelf-dev \
                 zlib1g-dev linux-tools-common linux-tools-generic

# All variants
sudo apt install build-essential clang libbpf-dev libelf-dev \
                 zlib1g-dev linux-tools-common linux-tools-generic \
                 bpftrace python3
```

### 3.2 RHEL / Rocky / Alma

| Version | Kernel | V2 | V3.1 | V3 | Notes |
|---------|--------|:---:|:---:|:---:|-------|
| RHEL 8 | 4.18 | ✓ | ✗ | ✗ | Kernel too old; no BTF |
| RHEL 9 | 5.14 | ✓ | ✓ | ✓ | BTF enabled; bpftrace in EPEL |

**Package names (RHEL 9):**

```bash
# V2
sudo dnf install gcc make

# V3.1
sudo dnf install bpftrace python3

# V3
sudo dnf install clang libbpf-devel elfutils-libelf-devel \
                 zlib-devel bpftool kernel-devel
```

### 3.3 Debian

| Version | Kernel | V2 | V3.1 | V3 |
|---------|--------|:---:|:---:|:---:|
| 11 Bullseye | 5.10 | ✓ | ✗ | ✗ |
| 12 Bookworm | 6.1 | ✓ | ✓ | ✓ |
| 13 Trixie | 6.x | ✓ | ✓ | ✓ |

---

## 4. Architecture Support

### 4.1 x86_64 (Intel / AMD)

Primary development and test target. All variants fully supported.

### 4.2 aarch64 (ARM64)

| Component | Status | Notes |
|-----------|--------|-------|
| V2 build | ✓ | Standard C11; no x86 dependencies |
| V2 perf_raw events | ✓ | ARM-specific codes (0x32, 0x37) in llcmr.c |
| V2 detect | ✓ | Parses `CPU implementer` / `Features` |
| V3.1 bpftrace | ✓ | aarch64 bpftrace in Ubuntu 24.04 |
| V3 clang -target bpf | ✓ | BPF bytecode is arch-independent |
| V3 userspace | ✓ | Standard C11; cross-compile or native |
| resctrl (MPAM) | ✓ | Kernel 6.19+ on Neoverse N2/V0.1+ |

### 4.3 RISC-V

Not currently tested. V2 should work (procfs/sysfs are
architecture-independent). V3.1/V3 require bpftrace/libbpf support for
RISC-V, which is emerging but not yet stable.

---

## 5. Deployment Environments

### 5.1 Bare-Metal

Full functionality. All metrics available subject to hardware features.
Recommended for Phase 3 comparative evaluation.

### 5.2 Docker / Podman

| Requirement | Flag |
|------------|------|
| Privileged mode | `--privileged` (or fine-grained caps below) |
| BPF capability | `--cap-add CAP_BPF --cap-add CAP_PERFMON` |
| resctrl bind-mount | `-v /sys/fs/resctrl:/sys/fs/resctrl` |
| BTF access | `-v /sys/kernel/btf:/sys/kernel/btf:ro` |
| procfs host view | `--pid=host` (for system-wide monitoring) |

Example:

```bash
docker run --rm -it --privileged --pid=host \
  -v /sys/fs/resctrl:/sys/fs/resctrl \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  intp:latest \
  /app/intp-c-abi --interval 1 --duration 30
```

### 5.3 KVM / QEMU Virtual Machines

| Requirement | Configuration |
|-------------|--------------|
| PMU passthrough | libvirt: `<cpu><feature policy='require' name='pmu'/></cpu>` |
| | QEMU: `-cpu host,pmu=on` |
| Nested perf | Host: `perf_event_paranoid ≤ -1` |
| resctrl | Not available inside guest (host-only filesystem) |

**Limitation:** `mbw` and `llcocc` are UNAVAILABLE inside VMs
(resctrl is not virtualizable). `llcmr` works only with PMU
passthrough.

### 5.4 Cloud Instances

| Cloud | Instance | V2 | V3.1 | V3 | mbw/llcocc |
|-------|----------|:---:|:---:|:---:|:----------:|
| AWS | Bare metal (`.metal`) | ✓ | ✓ | ✓ | ✓ |
| AWS | Graviton 4 `.metal` | ✓ | ✓ | ✓ | ✓ (K6.19+) |
| AWS | Standard EC2 | ✓ | ✓ | ✓ | ✗ (no resctrl) |
| Azure | Bare metal (Ev5) | ✓ | ✓ | ✓ | ✓ |
| GCP | Sole-tenant node | ✓ | ✓ | ✓ | ✓ |

---

## 6. Deployment Complexity Comparison

| Step | V2 | V3.1 | V3 |
|------|:---:|:---:|:---:|
| Install build deps | 1 pkg | 0 | 5 pkgs |
| Compile | `make` (~2s) | — | `make` (~10s) |
| Generate vmlinux.h | — | — | `make vmlinux` |
| Install runtime deps | 0 | 2 pkgs | 0 (static binary) |
| Mount resctrl | Manual | Manual | Manual |
| Run | `sudo ./intp-c-abi` | `sudo ./run-intp-bpftrace.sh` | `sudo ./intp-ebpf-ring` |
| Total time to first output | ~1 min | ~2 min | ~3 min |

---

## 7. Privilege Requirements

| Capability | V2 | V3.1 | V3 | Purpose |
|-----------|:---:|:---:|:---:|---------|
| `CAP_PERFMON` | llcmr | All | All | perf_event_open / BPF attach |
| `CAP_BPF` | — | All | All | BPF program load |
| `CAP_SYS_RESOURCE` | — | — | ring buffer | mmap ring buffer |
| `CAP_DAC_OVERRIDE` | resctrl | resctrl | resctrl | Write to resctrl tasks file |
| root (euid 0) | Optional | Required | Required | Simplest; covers all caps |

**Reducing privilege (V2 only):** V2 can run as non-root for 5/7
metrics (netp, nets, blk, cpu + llcmr if paranoid ≤ 1). Only
resctrl-backed metrics need root/CAP_DAC_OVERRIDE.

---

## 8. Known Cross-Platform Issues

| Issue | Affected | Workaround |
|-------|----------|------------|
| `nets` RX latency undercount (V3) | V3 all platforms | kretprobe PARM1 limitation; documented in DESIGN.md §10.1 |
| `llcmr` returns 0 in VM | V2/V3.1/V3 without PMU | Enable PMU passthrough or use `.metal` instances |
| `mbw` unavailable on Naples/Graviton3 | No QoS hardware | Accept 5/7 metrics or use `perf_uncore_imc`/`amd_df` |
| LLC topology per-CCD (AMD) | All variants | IntP sums across `mon_L3_*` domains — handled correctly |
| ARM `perf_hwcache` returns 0 | Older Cortex designs | Use `--no-perf-events` (V3) or accept llcmr=0 |
| `CONFIG_DEBUG_INFO_BTF` absent | V3.1, V3 | Recompile kernel or use V2 instead |

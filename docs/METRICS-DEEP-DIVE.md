# Metrics Deep Dive

Technical documentation of IntP's 7 interference metrics. Covers kernel
probe points, embedded C functions, Normalization formulas, and
hardcoded constants for each metric. The reference implementation is
`variants/v0-stap-2022/intp.stp` (660 lines) -- this document is a line-by-line
walk-through of that script, so future variants can be checked against
the same semantic contract.

## Overview

IntP collects 7 interference metrics from the Linux kernel, every
`interval` seconds (default 1), and writes a tab-separated row to a
procfs node at `/proc/systemtap/stap_*/intestbench`:

| # | name   | meaning                                                       | output unit |
|---|--------|---------------------------------------------------------------|-------------|
| 1 | netp   | Network physical utilization (NIC bandwidth)                  | %           |
| 2 | nets   | Network stack utilization (kernel networking service time)    | %           |
| 3 | blk    | Block I/O utilization (`%util`-equivalent)                    | %           |
| 4 | mbw    | Memory bandwidth utilization (LLC-to-DRAM traffic)            | %           |
| 5 | llcmr  | LLC miss ratio (cache misses / cache references)              | %           |
| 6 | llcocc | LLC occupancy (bytes of last-level cache occupied)            | %           |
| 7 | cpu    | CPU utilization (user + system time)                          | %           |

All seven values are clamped to `99` to keep the field two characters
wide; reported as `%02d` integers (no fractional part). Each section
below documents the kernel interface, the SystemTap probe points, the
embedded C functions, the Normalization formula, and any hardcoded
constants.

The line numbers cited refer to `variants/v0-stap-2022/intp.stp`.

---

## 1. netp -- network physical utilization

### Probe points

| line | probe                          | what it captures                                  |
|------|--------------------------------|---------------------------------------------------|
| 153  | `netfilter.ip.local_out`       | bytes egressing from a tracked PID's flows        |
| 161  | `netfilter.ip.local_in`        | bytes ingressing on a flow seen earlier on egress |

A flow is keyed by `(saddr, daddr, dport)` (line 156). Each TX packet
records its length into the `net_tput` aggregate; each RX packet on a
known reverse flow does the same.

### Normalization

`print_netphy_report()` (line 239):

```text
tput_eq    = sum(net_tput) / runtime_procfs       # bytes per second
util_x100  = (tput_eq * 10000) / 125_000_000      # 100 * (bps / 1Gbps)
util       = util_x100 / 100                      # integer percent
```

### Hardcoded constants

- **`125_000_000` (line 242)** -- 1 Gbps in bytes/sec (1e9 / 8). Hardcoded
  to a 1 GbE NIC. Higher-speed NICs (10/25/100 GbE) under-report
  proportionally; this is one of the original limitations the hybrid-c
  and ebpf-ring variants address by detecting the real link speed from
  `/sys/class/net/<iface>/speed`.

### Known limitations

- Only IPv4 traffic that traverses `netfilter.ip.local_in/out` is
  counted. Bridged, container-host, and AF_XDP paths bypass these hooks.
- TX uses tracked-PID filter; RX uses the reverse-flow table only.
  Latency between TX and RX establishment can drop the first RX bytes.
- Util is hard-clamped to `99` (line 248).

---

## 2. nets -- network stack utilization

### Probe points

| line | probe                                              | role                                |
|------|----------------------------------------------------|-------------------------------------|
| 171  | `kernel.function("__dev_queue_xmit")`              | TX path: stamp `t0` per skb         |
| 178  | `kernel.trace("net_dev_xmit")`                     | TX path: compute latency on dispatch|
| 195  | `kernel.function("__napi_schedule_irqoff")`        | RX path: stamp `t0` per napi struct |
| 200  | `kernel.function("napi_complete_done")`            | RX path: compute latency on poll end|

The script measures **per-packet kernel service time** by stamping the
SKB on entry (`__dev_queue_xmit`) and reading the stamp at NIC dispatch
(`net_dev_xmit`); RX uses the napi structure as the key. Two stats
aggregates accumulate `(t_end - t_start)` per packet on each side.

### Normalization

`print_netstack_report()` (line 211):

```text
rcv_util   = (avg_rcv_lat  * net_rcv_req)  / 1e9 / 1000     # convert ns*count -> seconds
sent_util  = (avg_sent_lat * net_sent_req) / 1e9 / 1000
util       = rcv_util + sent_util + (rcv_abs + sent_abs) / 100
```

The numerator `avg_lat * count` is total time spent in the stack; the
denominator implicit here is `interval` (1 s by default), so a result
of `100%` means the stack was busy for one full second within the
sampling window, summed over RX and TX.

### Hardcoded constants

- **`/1000/1000/1000`** (line 216) -- ns -> s conversion using fixed-point
  arithmetic; SystemTap has no float at probe scope.
- The implicit denominator is `runtime_procfs * 1 s`; assumes one
  sample-per-second cadence.

### Known limitations

- Both kprobes (`__dev_queue_xmit`, `__napi_schedule_irqoff`,
  `napi_complete_done`) are *internal* kernel symbols. They have moved
  or been inlined across kernel versions, which is one of the main
  fragility sources for stap-2022 across kernel 5.x and 6.x. hybrid-c cannot
  replicate per-packet kernel service time and falls back to a softirq
  ratio (status=DEGRADED, see `variants/v2-hybrid-c/DESIGN.md` section 3).
  bpftrace/ebpf-ring reintroduce per-packet timing via `napi:napi_poll` tracepoints.
- `$skb` and `$n` dereferences require kernel debuginfo to resolve.

---

## 3. blk -- block I/O utilization

### Probe points

| line | probe                              | what it captures                          |
|------|------------------------------------|-------------------------------------------|
| 101  | `kernel.trace("block_rq_complete")`| every completed bio request, with timing  |

For every completed request the script reads three fields off `$rq`:

- `$rq->__data_len` -- bytes transferred (used for throughput)
- `$rq->start_time_ns` -- when the request was created
- `$rq->io_start_time_ns` -- when the device started serving it

From these it derives queue time (`io_start - start`) and service time
(`now - io_start`).

### Normalization

`print_block_report()` (line 121):

```text
ops_dep    = block_op_dep / runtime_procfs           # ops per second
svctm_avg  = avg(block_srv_time) / runtime_procfs    # nanoseconds per op
svctm_ms   = svctm_avg / 1e6                         # ms per op
util       = (svctm_ms * ops_dep) / 100              # %util in iostat sense
```

This matches the iostat `%util` formula: average service time times
ops/sec, expressed as a percentage of an idealised serial device. >100%
saturates at 99 (line 138).

### Known limitations

- All block devices are aggregated; no per-device breakdown.
- `block_rq_complete` exists in modern kernels (it's a stable
  tracepoint), so this metric is portable; hybrid-c uses
  `/proc/diskstats` field 13 (`io_ticks`) instead, which gives the
  same `%util` semantics without a kprobe.

---

## 4. mbw -- memory bandwidth utilization

### Probe points

| lines     | mechanism                                                 |
|-----------|-----------------------------------------------------------|
| 405-440   | `perf_kernel_start()` opens kernel-side perf events       |
| 487-497   | `perf_global_start()` opens four uncore IMC counters      |
| 507-530   | `print_mem_report()` reads + normalises                   |

The four uncore events are `(cpu, type=14, config)` tuples:

| cpu | type | config | event             |
|-----|------|--------|-------------------|
| 0   | 14   | 0x0304 | uncore_imc / channel 0 read or write |
| 0   | 14   | 0x0c04 | uncore_imc / channel 0 read or write |
| 1   | 14   | 0x0304 | uncore_imc / channel 1 read or write |
| 1   | 14   | 0x0c04 | uncore_imc / channel 1 read or write |

`type=14` is whatever `PERF_TYPE_UNCORE_IMC` resolved to on the
2022-era development host -- it is a *runtime-discovered* PMU type, not
a stable enum, so this number is implicit hardware coupling.

### Embedded C plumbing

- `perf_kernel_start(cpu, task, type, config)` (line 405) calls
  `perf_event_create_kernel_counter()`, returning the `struct
  perf_event *` cast to `long`.
- `perf_kernel_read(event)` (line 450) calls
  `perf_event_read_value()` and returns the raw counter.
- `perf_kernel_reset(event)` (line 482) writes `local64_set(&ev->count,
  0)` to clear without closing.
- `perf_kernel_stop(event)` (line 443) calls
  `perf_event_release_kernel()`.

These are stap-2022's main coupling to internal kernel ABI; everything in
`variants/v3-ebpf-ring` is built around replacing them with libbpf-attached
perf events that the verifier validates.

### Normalization

`print_mem_report()` (line 507):

```text
bw_bytes_per_s  = sum(uncore_imc_ctr) * 64 / runtime_procfs   # 64-byte cache line per event
bw_norm         = (bw_bytes_per_s * 10000) / 34_000_000_000   # *100/34 GB/s
```

### Hardcoded constants

- **`* 64` (line 512)** -- one IMC event = one 64-byte cache line of
  memory traffic. Correct on Intel for the type=14 events used.
- **`/ 34_000_000_000` (line 514)** -- 34 GB/s, the ad-hoc maximum
  bandwidth used to normalise. This was the calibrated peak of the
  development machine; on any other machine the percentage is wrong.
  hybrid-c onwards detects max bandwidth from dmidecode or accepts a
  `--mem-bw-max-bps` override.

### Known limitations

- Hard-coded for two channels at fixed config codes -- modern Xeon SP
  has 6-8 channels per socket. Multi-socket and multi-channel server
  setups under-count.
- IMC events on AMD and ARM use entirely different PMUs; this metric
  does **not** work outside Intel without source modification.
- Per Sohal et al. (RTNS 2022), MBM (the resctrl alternative used by
  stap-nohelper through ebpf-ring) over-reports up to 2x on certain Skylake errata; uncore IMC
  is more accurate when calibrated.

---

## 5. llcmr -- LLC miss ratio

### Probe points

| line | probe                                                              | what it captures   |
|------|--------------------------------------------------------------------|--------------------|
| 543  | `perf.type(3).config(0x000002).process(@1)`                        | LLC loads          |
| 544  | `perf.type(3).config(0x010002).process(@1)`                        | LLC load misses    |

`type=3` is `PERF_TYPE_HW_CACHE`. The `config` field encodes
`(cache_id | op_id<<8 | result_id<<16)`:

- `0x000002` = `(LL=2, OP_READ=0, RESULT_ACCESS=0)`  -> LLC load access
- `0x010002` = `(LL=2, OP_READ=0, RESULT_MISS=1)`    -> LLC load miss

These are stable Linux perf encodings (see `<linux/perf_event.h>`),
which is why all seven variants can use them.

### Normalization

`print_cache_report()` (line 546):

```text
miss_ratio = (load_misses * 10000 / loads) / 100   # integer percent
```

### Hardcoded constants

None. The metric only depends on the perf abstraction layer, so it is
the most portable of the seven.

### Known limitations

- ARM `PERF_COUNT_HW_CACHE_LL` is mapped on Neoverse but returns 0 on
  many Cortex designs; that is why hybrid-c/ebpf-ring add a vendor-specific
  `perf_raw` fallback (Intel `0x412E/0x4F2E`, AMD `0x06/0x04`,
  ARM `0x37/0x32`).

---

## 6. llcocc -- LLC occupancy

### Probe points and embedded C

This is stap-2022's most invasive metric and the one that broke first on
kernel 6.8 (see `KERNEL-6.8-CHANGES.md`).

| line     | element                                                         |
|----------|-----------------------------------------------------------------|
| 44       | `perf_kernel_start(-1, _pid, 9, 1)`                             |
| 327-403  | embedded C: MSR access, RMID read                               |
| 464-479  | `perf_rmid_read(event)` exposed as a SystemTap function         |
| 537-593  | `print_llc_report()` aggregates and normalises                  |

The chain is:

1. `perf_kernel_start(cpu=-1, task=PID, type=9, config=1)` opens an
   Intel CQM perf event. `type=9` was `PERF_TYPE_INTEL_CQM` on the
   pre-6.8 kernel.
2. The kernel allocates an RMID (Resource Monitoring ID) and stores
   it in `pe->hw.cqm_rmid`.
3. `perf_rmid_read(event)` calls the embedded `rmid_read()` (line
   376), which:
   - reads the `cqm_rmid` field directly from `struct hw_perf_event`,
   - fans out via `on_each_cpu_mask()` to a helper that does
     `wrmsr(MSR_IA32_QM_EVTSEL, 1, rmid); rdmsrl(MSR_IA32_QM_CTR,
     val);` (lines 366-367),
   - aggregates the per-CPU values atomically.

Constants in the embedded C:

- `MSR_IA32_QM_CTR  = 0x0c8e` (line 341)
- `MSR_IA32_QM_EVTSEL = 0x0c8d` (line 342)
- `QOS_L3_OCCUP_EVENT_ID = 0x01` (line 343)

These were duplicated in stap-2022 because old kernel headers had them in
`<asm/intel_rdt.h>` rather than `<asm/msr-index.h>`. Kernel 6.8 moved
the canonical definitions into `<asm/msr-index.h>` and **removed
`cqm_rmid` from `struct hw_perf_event`** -- breaking stap-2022 and forcing
the `intp-6.8.stp` v0.1 (stap-nollc) workaround that disables the metric.

### Normalization

`print_llc_report()` (line 573):

```text
total_bytes  = sum(llc_occ_samples) * 49152          # CMT scaling factor
util_pct     = (total_bytes * 10000 / 34_000_000) / 100
```

### Hardcoded constants

- **`* 49152` (line 581)** -- comment in source says
  `"// 27033    //24576"`, three different values tried during
  bring-up. The "right" CMT scale factor is read from
  `/sys/fs/resctrl/info/L3_MON/cqm_scale_factor` on modern hardware;
  stap-2022 hard-codes a value that worked for the 2022 dev box.
- **`/ 34_000_000` (line 582)** -- assumed LLC size in bytes (34 MB).
  Real Cascade Lake / Ice Lake LLCs range 27.5-60 MB per socket; stap-nohelper
  uses a configurable `LLC_SIZE_KB` (default 30720 KB), hybrid-c through ebpf-ring detect
  per socket from `/sys/devices/system/cpu/cpu0/cache/index3/size`.

### Known limitations

- Requires kernel <= 6.6 (CQM perf-event API).
- Requires Intel server CPU with CMT (Haswell-EP and newer Xeon).
- Requires kernel debuginfo to resolve `pe->hw.cqm_rmid`.
- Not portable to AMD, ARM, or kernel 6.8+; this is the single hardest
  metric in IntP's portability story and is the reason stap-nohelper introduces
  the resctrl helper daemon pattern that hybrid-c/bpftrace/ebpf-ring inherit.

---

## 7. cpu -- CPU utilization

### Probe points

| line | probe                                  | what it captures                |
|------|----------------------------------------|---------------------------------|
| 261  | `perf.sw.cpu_clock!, timer.profile`    | one tick per profile sample     |

`perf.sw.cpu_clock!` requests `PERF_TYPE_SOFTWARE / cpu_clock`, with a
fall-through (`!`) to `timer.profile` if the perf event cannot be
opened (e.g. virt environments without PMU). Per tick:

- if `tid()` is in `mpids`, the tick is attributed user vs kernel via
  `user_mode()`,
- the global `ticks` aggregate is always incremented.

### Normalization

`print_cpu_report()` (line 272):

```text
all       = count(ticks)
u_pct100  = count(uticks) * 10000 / all
k_pct100  = count(kticks) * 10000 / all
util      = u_pct100/100 + k_pct100/100        # integer percent, clamped to 99
```

This is the fraction of profile-tick samples on which the tracked TID
was running, split into user vs kernel mode and summed.

### Known limitations

- `timer.profile` fires once per profile interval per online CPU, so
  the tick rate scales with the host's CPU count; the ratio is
  invariant under that scaling.
- In VMs without PMU passthrough, `perf.sw.cpu_clock` falls through to
  `timer.profile`, which has lower resolution but stays correct.

---

## 8. The `intestbench` procfs sink

The output sink (line 595) is read on demand via `cat
/proc/systemtap/stap_*/intestbench`; on each read it calls all seven
report functions and emits:

```text
netp	nets	blk	mbw	llcmr	llcocc	cpu
%02d	%02d	%02d	%02d	%02d	%02d	%02d
```

stap-nohelper prepends a `time_ms` column (line 592 of
`variants/v1-stap-nohelper/intp-resctrl.stp`); hybrid-c through ebpf-ring keep the original 7-column
TSV for IADA pipeline compatibility but add a `# v2 backends:` /
`# v3 ebpf-core --` header line declaring which backend produced each
column.

## 9. Cross-variant semantic equivalence

Each later variant must produce, for the same workload on the same
host, *numerically equivalent* output for the metrics it implements.
The shared `validate-cross-variant.sh` script asserts this, and the
metric semantics defined above are the contract being checked. When a
later variant cannot match stap-2022 byte-for-byte (most often `nets` on hybrid-c,
`llcmr` on bpftrace sampling) it must declare that gap with an explicit
`status=degraded` and `note` field; see `variants/v2-hybrid-c/DESIGN.md`
section 4 and `variants/v3.1-bpftrace/README.md` "Known limitations" for the
authoritative gap list.

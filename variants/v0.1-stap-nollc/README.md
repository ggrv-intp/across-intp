# V0.1 (stap-nollc) -- Updated IntP for Kernel 6.8+ (LLC Disabled)

This is the minimal kernel 6.8 adaptation of IntP. It patches the original
SystemTap script to compile on kernel 6.8+ by:

1. **Removing the `cqm_rmid` access**: The `get_llc_occupancy()` embedded C
   function no longer tries to read the `cqm_rmid` field from
   `struct hw_perf_event`. That field (and the `intel_cqm` perf PMU driver
   that populated it) was actually removed from mainline in kernel 4.14
   (Nov 2017, commit `c39a0e2c8850`); kernel 6.8 is simply the point at
   which no mainstream distro still ships the vendor backport, so the
   failure becomes inescapable. LLC occupancy (llcocc) returns 0 in this
   variant.

2. **Removing MSR redefinitions**: Several MSR constants that IntP redefined
   now conflict with kernel headers. The redefinitions are removed and the
   kernel's own definitions are used.

3. **CONFIG_MODVERSIONS workaround**: On kernels with CONFIG_MODVERSIONS=y,
   the SystemTap module may fail to load due to CRC mismatches. Build with
   `--skip-badvars` or see docs for kernel config workaround.

## Metrics Status

| Metric | Status |
|--------|--------|
| netp   | Working |
| nets   | Working |
| blk    | Working |
| mbw    | Working |
| llcmr  | Working |
| llcocc | **Returns 0** (disabled) |
| cpu    | Working |

## Files

- `intp-6.8.stp` -- Patched SystemTap script
- `test-intp-6.8.sh` -- Test script for validation
- `docs/KERNEL-6.8-NOTES.md` -- Detailed notes on kernel changes
- `docs/SYSTEMTAP-MODULE-ISSUE.md` -- CONFIG_MODVERSIONS fix

## Usage

```bash
sudo stap -g intp-6.8.stp <PID> <interval_ms>
```

## Limitations

- LLC occupancy is not available (returns 0)
- Still requires SystemTap, debuginfo, and guru mode
- Still loads a kernel module (crash risk remains)

For the full 7/7 metric stack on kernel 6.8+, see `variants/v1.1-stap-modern/`
(SystemTap + userspace helper) or the eBPF/procfs variants
(`variants/v3-ebpf-ring/`, `variants/v3.1-bpftrace/`, `variants/v2-hybrid-c/`).

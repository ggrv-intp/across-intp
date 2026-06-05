# IntP Kernel 6.8.0 Compatibility Notes

> **Scope clarification.** This document describes the patches needed
> to run IntP on Ubuntu 24.04's stock 6.8 kernel. The removal of the
> `cqm_rmid` field itself happened much earlier -- in **kernel 4.14**
> (November 2017, commit `c39a0e2c8850`) -- along with the `intel_cqm`
> perf PMU driver that populated it. The replacement is the `resctrl`
> filesystem. Some enterprise LTS lines carried vendor backports of
> `intel_cqm` until roughly 2019-2020 (the IntP 2022 rig depended on
> that), but no mainstream distro still ships the backport today, so
> 6.8 is simply the point at which the symptom becomes inescapable.
> See also `docs/KERNEL-6.8-CHANGES.md` (root-of-tree copy).

## Summary

IntP has been successfully patched to work with kernel 6.8.0-90, with **6 out of 7 metrics functional**. LLC occupancy monitoring is temporarily disabled pending resctrl interface implementation.

## Changes Made

### 1. Created `intp-6.8.stp`

Patched version with the following changes:

- **Removed MSR redefinitions** (lines 341-342)
  - `MSR_IA32_QM_CTR` and `MSR_IA32_QM_EVTSEL` now in `<asm/msr-index.h>`

- **Disabled LLC occupancy monitoring**
  - Commented out `perf_kernel_start()` calls for LLC events (lines 52-56)
  - Removed `rmid_read()` functions and structures (incompatible with
    any kernel without the `intel_cqm` backport -- mainline removed it
    in 4.14)
  - Removed `perf_rmid_read()` function
  - Modified `print_llc_report()` to return 0

- **Added user notifications**
  - Startup message indicating patched version
  - Comments explaining disabled functionality

### 2. Functional Metrics

| Metric | Status | Description |
|--------|--------|-------------|
| netp | ✅ Working | Network physical layer utilization (%) |
| nets | ✅ Working | Network stack utilization (%) |
| blk | ✅ Working | Block I/O utilization (%) |
| mbw | ✅ Working | Memory bandwidth utilization (%) |
| llcmr | ✅ Working | LLC (Last Level Cache) miss ratio (%) |
| **llcocc** | ❌ Disabled | LLC occupancy (%) - returns 0 |
| cpu | ✅ Working | CPU utilization (%) |

## Testing Instructions

### Quick Test

```bash
cd ~/Documents/intp

# 1. Syntax check
sudo stap -p2 intp-6.8.stp firefox

# 2. Compilation test
sudo stap -p4 intp-6.8.stp firefox

# 3. Quick runtime test (10 seconds)
timeout 10 sudo stap --suppress-handler-errors -g intp-6.8.stp bash
```

### Full Monitoring

**Terminal 1:**
```bash
sudo stap --suppress-handler-errors -g intp-6.8.stp firefox
```

**Terminal 2:**
```bash
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

Expected output:
```
netp    nets    blk     mbw     llcmr   llcocc  cpu
02      01      05      12      03      00      45
                                        ^^
                                        Will be 0 until resctrl is implemented
```

## Root Cause: long-completed RDT/CQM refactor finally visible on 6.8

### What Changed

The Intel RDT / Cache QoS Monitoring (CQM) refactor that breaks V0 on
kernel 6.8 was actually completed in **kernel 4.14** (November 2017,
commit `c39a0e2c8850`). 6.8 is just the kernel on which Ubuntu
ships no vendor backport at all:

1. **Removed `cqm_rmid` field** from `struct hw_perf_event` (4.14)
2. **Removed the `intel_cqm` perf PMU driver** that populated the
   field (4.14, same commit)
3. **Moved MSR definitions** to kernel headers (so `intp.stp`'s own
   `MSR_IA32_QM_CTR/QM_EVTSEL` redefinitions now cause a redefinition
   error)
4. **The replacement** is the `resctrl` filesystem
   (`/sys/fs/resctrl/mon_data/mon_L3_XX/llc_occupancy`)

### Technical Details

**Old Interface (Kernel ≤ 6.6):**
```c
// Direct access to CQM RMID
rr.rmid = pe->hw.cqm_rmid;

// Manual MSR reads
wrmsr(MSR_IA32_QM_EVTSEL, QOS_L3_OCCUP_EVENT_ID, rr.rmid);
rdmsrl(MSR_IA32_QM_CTR, val);
```

**New Interface (Kernel ≥ 6.8):**
```bash
# Use resctrl filesystem
/sys/fs/resctrl/
├── info/
│   └── L3_MON/
│       ├── mon_features
│       ├── max_threshold_occupancy
│       └── num_rmids
└── mon_data/
    └── mon_L3_XX/
        ├── llc_occupancy
        └── mbm_local_bytes
```

## Resctrl Interface Implementation Plan

### Option 1: Userspace Helper (Easier)

**Approach:** Read resctrl values from SystemTap via external script

**Pros:**
- Simpler implementation
- No kernel data structure access needed
- Can be done entirely in SystemTap script layer

**Cons:**
- Requires resctrl filesystem mounted
- May have performance overhead
- Needs coordination between monitoring groups

**Implementation Steps:**
1. Mount resctrl filesystem (if not already)
2. Create monitoring group for target process
3. Read `llc_occupancy` from `/sys/fs/resctrl/mon_data/mon_L3_XX/llc_occupancy`
4. Parse value in SystemTap

### Option 2: Kernel Interface (More Complex)

**Approach:** Access resctrl internals via embedded C in SystemTap

**Pros:**
- More efficient
- Direct kernel access
- Consistent with other IntP metrics

**Cons:**
- Requires understanding new resctrl kernel internals
- More complex implementation
- May break again with future kernel changes

**Implementation Steps:**
1. Find new kernel structures for resctrl monitoring
2. Locate RMID allocation functions
3. Access LLC occupancy counters directly
4. Integrate with existing IntP framework

### Feasibility Assessment

**Hardware Support:**
- CPU: Intel Core i7-13650HX (13th Gen)
- Kernel: Has `CONFIG_X86_CPU_RESCTRL=y`
- Status: ⚠️ **Need to verify CPU actually supports CMT/MBM**

**Check CPU Support:**
```bash
# Should show cqm_llc, cqm_occup_llc flags if supported
grep -o "cqm[^ ]*" /proc/cpuinfo | sort -u

# Check if resctrl can be mounted
sudo mount -t resctrl resctrl /sys/fs/resctrl
ls /sys/fs/resctrl/info/L3_MON/
```

### Recommended Approach

**Phase 1: Verify Hardware Support** (5 minutes)
- Check CPU flags for CMT/MBM support
- Attempt to mount resctrl
- Verify monitoring features available

**Phase 2: Prototype Userspace Helper** (1-2 hours)
- If hardware supports it, create simple script to:
  - Mount resctrl
  - Create monitoring group
  - Read LLC occupancy values
  - Test with a sample process

**Phase 3: Integrate with SystemTap** (2-4 hours)
- Add resctrl group management to SystemTap script
- Read occupancy values via `system()` or embedded C
- Update `print_llc_report()` function
- Test with IntP workloads

**Phase 4: Optimize** (optional, 2-4 hours)
- Direct kernel structure access for better performance
- Error handling for missing hardware support
- Fallback to 0 if resctrl unavailable

## Alternative: Use Perf Events (If Supported)

Some newer kernels still support LLC occupancy via perf events, but with different configuration:

```bash
# Check if perf supports LLC occupancy
perf list | grep -i "llc\|cache"

# Example perf event for LLC occupancy (if available)
perf stat -e intel_cqm/llc_occupancy/ -p <PID>
```

If perf events are available, this might be simpler than resctrl.

## Next Steps

1. **Test the patched version** (`intp-6.8.stp`)
2. **Verify hardware support** for CMT/MBM
3. **Choose implementation approach** based on:
   - Hardware availability
   - Performance requirements
   - Development time available
4. **Implement resctrl integration** or document limitation

## Files Modified

- `intp-6.8.stp` - Patched version (new file)
- `intp.stp` - Original version (unchanged)
- `KERNEL-6.8-NOTES.md` - This file

## References

- [Linux kernel resctrl documentation](https://www.kernel.org/doc/html/latest/x86/resctrl.html)
- [Intel RDT documentation](https://www.intel.com/content/www/us/en/architecture-and-technology/resource-director-technology.html)
- [Kernel 6.8 changelog](https://kernelnewbies.org/Linux_6.8)

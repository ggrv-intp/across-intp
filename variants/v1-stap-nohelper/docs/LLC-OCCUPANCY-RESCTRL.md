# LLC Occupancy Monitoring via resctrl Interface

## Overview

The original IntP used Intel's Cache Monitoring Technology (CMT) via perf events to monitor Last Level Cache (LLC) occupancy per process. This was disabled in kernel 6.8.0+ because the `cqm_rmid` field was removed from `struct hw_perf_event`.

This document explains:
1. Why LLC occupancy monitoring was disabled
2. What hardware is required to re-enable it
3. How to use the resctrl-based implementation

## Why LLC Occupancy is Disabled in intp-6.8.stp

### The Technical Change

In kernels before 6.8.0, IntP used this approach:
```c
// Create perf event for Intel CQM (Cache QoS Monitoring)
pe.type = 9;  // PERF_TYPE_INTEL_CQM
pe.config = 1;  // LLC occupancy event

// The kernel stored the RMID in the perf event structure
struct hw_perf_event {
    ...
    u32 cqm_rmid;  // <-- THIS FIELD WAS REMOVED IN 6.8.0
    ...
};
```

The kernel then:
1. Assigned an RMID (Resource Monitoring ID) to track the process
2. Programmed MSR_IA32_QM_EVTSEL with the RMID and event type
3. Read LLC occupancy from MSR_IA32_QM_CTR

### What Changed in Kernel 6.8.0

Intel Resource Director Technology (RDT) monitoring was consolidated into the **resctrl filesystem interface**. The old perf-based CQM interface was removed because:

1. resctrl provides a cleaner, more flexible interface
2. It supports additional RDT features (MBA, CAT)
3. It allows resource allocation, not just monitoring
4. The perf interface was considered deprecated

### The New Approach: resctrl Filesystem

The resctrl interface (`/sys/fs/resctrl/`) is now the standard way to access RDT features:

```
/sys/fs/resctrl/
├── info/
│   └── L3_MON/
│       ├── mon_features      # "llc_occupancy", "mbm_total_bytes", etc.
│       ├── num_rmids         # Number of available RMIDs
│       └── max_threshold_occupancy
├── mon_groups/
│   └── intp/                 # Custom monitoring group
│       ├── tasks             # PIDs to monitor (write here)
│       └── mon_data/
│           └── mon_L3_00/
│               └── llc_occupancy  # LLC bytes used (read here)
└── tasks                     # Default group tasks
```

## Hardware Requirements

**LLC occupancy monitoring requires Intel RDT hardware support.**

### Supported CPUs

| CPU Family | Support | Notes |
|------------|---------|-------|
| Intel Xeon E5 v1 (Haswell-EP) | ✓ | First generation with CMT |
| Intel Xeon E5 v2 (Broadwell-EP) | ✓ | Full RDT support |
| Intel Xeon Scalable 1st Gen (Skylake-SP) | ✓ | Full RDT + MBA |
| Intel Xeon Scalable 2nd Gen (Cascade Lake) | ✓ | Full RDT + MBA |
| Intel Xeon Scalable 3rd Gen (Ice Lake-SP) | ✓ | Enhanced RDT |
| Intel Xeon Scalable 4th Gen (Sapphire Rapids) | ✓ | Enhanced RDT |
| Intel Core i9-X (HEDT) | ✓ | i9-7900X, i9-10900X, etc. |
| Intel Core i5/i7/i9 (Consumer) | ✗ | **NOT supported** |
| AMD EPYC | ~ | Different implementation (L3 PMC) |

### NOT Supported

Most consumer and laptop CPUs **do not** support LLC occupancy monitoring:
- Intel Core i5/i7/i9 (mobile and desktop, non-X variants)
- Intel Core Ultra series
- Intel Atom/Celeron/Pentium
- All AMD Ryzen (consumer)

### Check Your Hardware

```bash
# Check for RDT CPU flags
grep -E "cqm|cat_l3|mba" /proc/cpuinfo | head -1

# Expected output for supported hardware:
# cqm cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local cat_l3 mba

# Check QoS capability MSR (requires msr-tools)
sudo modprobe msr
sudo rdmsr -p 0 0xC8F  # Returns 0 if not supported
```

## IntP Files for LLC Monitoring

| File | Description | Hardware Required |
|------|-------------|-------------------|
| [intp-6.8.stp](intp-6.8.stp) | Standard IntP, LLC occupancy disabled | Any Intel CPU |
| [intp-resctrl.stp](intp-resctrl.stp) | IntP with resctrl LLC monitoring | Intel Xeon with RDT |
| [intp-resctrl-helper.sh](intp-resctrl-helper.sh) | Helper daemon for resctrl | Intel Xeon with RDT |

## Using intp-resctrl.stp (For Supported Hardware)

### Step 1: Verify Hardware Support

```bash
./intp-resctrl-helper.sh status
```

This will show:
- Whether your CPU supports CQM
- Whether resctrl is mounted
- Current monitoring status

### Step 2: Start the Helper Daemon

```bash
sudo ./intp-resctrl-helper.sh start
```

The helper daemon:
- Mounts the resctrl filesystem
- Creates a monitoring group for IntP
- Periodically reads LLC occupancy
- Writes data for SystemTap to read

### Step 3: Run IntP with resctrl

```bash
sudo stap -g -B CONFIG_MODVERSIONS=y intp-resctrl.stp firefox
```

### Step 4: View Results

```bash
watch -n2 cat /proc/systemtap/stap_*/intestbench
```

### Step 5: Stop When Done

```bash
sudo ./intp-resctrl-helper.sh stop
```

## For Systems WITHOUT RDT Support

If your CPU doesn't support RDT (like the i7-13650HX), you have these options:

### Option 1: Use LLC Miss Ratio Instead

The `intp-6.8.stp` script still monitors **LLC miss ratio**, which is a useful proxy for cache interference:

- **High miss ratio** → Process is likely being evicted from cache (interference)
- **Low miss ratio** → Good cache utilization

```bash
# Use the standard intp-6.8.stp
./run-intp.sh firefox
```

### Option 2: Use Cloud Instances with RDT

Cloud providers offer Xeon instances with full RDT support:

| Provider | Instance Types |
|----------|---------------|
| AWS | c5, m5, r5, c6i, m6i (metal or .large+) |
| Google Cloud | n2, c2, m2 |
| Azure | Dv3, Ev3, Fsv2 |

### Option 3: Estimate from Other Metrics

LLC occupancy can be roughly correlated with:
- Memory bandwidth (high BW often means cache thrashing)
- LLC miss ratio over time
- Working set size of the application

## Technical Details: How resctrl Works

### Resource Monitoring IDs (RMIDs)

The hardware uses RMIDs to track cache usage per entity:

1. Each monitoring group gets an RMID
2. When a task runs, its memory accesses are tagged with the RMID
3. Hardware counters track LLC occupancy per RMID
4. Software reads MSR_IA32_QM_CTR to get the count

### resctrl Interface

The kernel's resctrl driver abstracts this:

```bash
# Create a monitoring group
mkdir /sys/fs/resctrl/mon_groups/myapp

# Add a process to monitor
echo $PID > /sys/fs/resctrl/mon_groups/myapp/tasks

# Read LLC occupancy (in bytes)
cat /sys/fs/resctrl/mon_groups/myapp/mon_data/mon_L3_00/llc_occupancy
```

### Memory Bandwidth Monitoring

If your CPU supports MBM (Memory Bandwidth Monitoring), you can also read:

```bash
# Total memory bandwidth (bytes)
cat /sys/fs/resctrl/mon_groups/myapp/mon_data/mon_L3_00/mbm_total_bytes

# Local memory bandwidth (same NUMA node)
cat /sys/fs/resctrl/mon_groups/myapp/mon_data/mon_L3_00/mbm_local_bytes
```

## Summary

| Your Situation | What to Use |
|----------------|-------------|
| Consumer CPU (i5/i7/i9 laptop/desktop) | `intp-6.8.stp` (LLC miss ratio only) |
| Intel Xeon with RDT | `intp-resctrl.stp` + helper (full LLC occupancy) |
| Cloud instance (AWS c5, etc.) | `intp-resctrl.stp` + helper (full LLC occupancy) |
| Research on cache interference | LLC miss ratio is often more useful than occupancy |

## References

- [Intel RDT Linux Documentation](https://www.kernel.org/doc/html/latest/x86/resctrl.html)
- [resctrl User Interface](https://www.kernel.org/doc/Documentation/x86/intel_rdt_ui.txt)
- [Intel 64 and IA-32 SDM Vol. 3, Chapter 17](https://software.intel.com/content/www/us/en/develop/articles/intel-sdm.html) - Platform QoS Monitoring

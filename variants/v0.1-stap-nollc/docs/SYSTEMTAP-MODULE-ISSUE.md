# SystemTap Module Loading Issue - SOLVED ✅

## Problem Summary

SystemTap 5.2 (compiled from source) successfully compiles IntP scripts but fails at module insertion with:

```
ERROR: Couldn't insert module '/tmp/stapXXX/stap_*.ko': Invalid module format
WARNING: /usr/local/bin/staprun exited with status: 1
Pass 5: run failed.  [man error::pass5]
```

## Root Cause

Ubuntu 24.04's kernel 6.8.0-90 requires module symbol versioning (`CONFIG_MODVERSIONS=y`), but **SystemTap deliberately disables this in guru mode** (see `buildrun.cxx` line ~137):

```cpp
// PR10280: suppress symbol versioning to restrict to exact kernel version
if (s.guru_mode)
    make_cmd.push_back("CONFIG_MODVERSIONS=");
// Note: can re-enable from command line with "-B CONFIG_MODVERSIONS=y".
```

This is an intentional design decision to ensure modules only load on the exact kernel they were compiled for, but it breaks on modern kernels that strictly enforce MODVERSIONS.

## Solution ✅

**Add `-B CONFIG_MODVERSIONS=y` to the stap command line:**

```bash
# Run IntP with the MODVERSIONS fix
sudo stap -g -B CONFIG_MODVERSIONS=y intp-6.8.stp firefox

# Test with bash
sudo stap -g -B CONFIG_MODVERSIONS=y --skip-badvars intp-6.8.stp bash
```

The `-B` flag passes configuration options to the kernel module build system, re-enabling symbol versioning.

## Quick Start

```bash
# Navigate to IntP directory
cd ~/Documents/intp

# Run IntP monitoring Firefox with all fixes applied
sudo stap -g -B CONFIG_MODVERSIONS=y intp-6.8.stp firefox
```

## Technical Details

### Kernel Configuration

Ubuntu 24.04's kernel 6.8.0-90 has strict module verification enabled:

```
CONFIG_MODULE_SIG=y          # Module signing required
CONFIG_MODULE_SIG_ALL=y      # All modules must be signed  
CONFIG_MODVERSIONS=y         # Symbol versioning required
```

The module signing requirement is relaxed (modules load with taint warning), but **MODVERSIONS** is strictly enforced.

### How MODVERSIONS Works

MODVERSIONS adds CRC checksums to symbol references in kernel modules. When a module tries to use a kernel function, the kernel checks that the module's CRC matches the kernel's CRC for that symbol. This ensures:

1. Modules are compatible with the exact kernel version
2. ABI changes are detected and modules fail safely
3. Mismatched modules can't corrupt kernel memory

### SystemTap's Behavior

By default in guru mode (`-g`), SystemTap passes `CONFIG_MODVERSIONS=` (empty) to kbuild, which disables symbol versioning. This was done to:

- Restrict modules to the exact kernel version
- Simplify module compatibility

However, modern kernels like 6.8.0 **require** MODVERSIONS and reject modules without it.

### Diagnosis Commands

```bash
# Check kernel MODVERSIONS setting
grep MODVERSIONS /boot/config-$(uname -r)
# Output: CONFIG_MODVERSIONS=y

# Check a working module's vermagic
modinfo nvidia | grep vermagic
# Output: vermagic: 6.8.0-90-generic SMP preempt mod_unload modversions

# Check if a SystemTap module has MODVERSIONS data
sudo modprobe --dump-modversions /tmp/stapXXX/stap_*.ko
# Without -B CONFIG_MODVERSIONS=y: "No data available"
# With -B CONFIG_MODVERSIONS=y: Shows CRC checksums
```

## Alternative Solutions

### Option 1: Shell Alias (Recommended)

Add to `~/.bashrc`:

```bash
alias stap-intp='sudo stap -g -B CONFIG_MODVERSIONS=y'
```

Then run:

```bash
stap-intp intp-6.8.stp firefox
```

### Option 2: Wrapper Script

Create `run-intp.sh`:

```bash
#!/bin/bash
sudo stap -g -B CONFIG_MODVERSIONS=y "$@"
```

### Option 3: SystemTap Configuration

You can add custom kbuild flags to `~/.systemtap/rc` but this doesn't work for `-B` flags. The command line is the only reliable method.

## Files

- `intp-6.8.stp` - Patched IntP for kernel 6.8.0 (MSR fixes, LLC disabled)
- `KERNEL-6.8-NOTES.md` - Kernel compatibility analysis
- `SYSTEMTAP-MODULE-ISSUE.md` - This file

## Status

- ✅ SystemTap 5.2 installed from source
- ✅ IntP patched for kernel 6.8.0 API changes  
- ✅ MSR permission issues resolved (LLC occupancy disabled)
- ✅ **Module loading WORKING with `-B CONFIG_MODVERSIONS=y`**
- ⏳ LLC occupancy via resctrl interface (future enhancement)

# IntP Installation Guide for Ubuntu 24.04 Desktop

**IntP** is a SystemTap-based tool for measuring application interference in Linux systems. This guide covers installation on Ubuntu 24.04 LTS, including the necessary kernel downgrade to ensure debug symbol availability.

---

## Table of Contents

1. [Prerequisites and System Requirements](#prerequisites-and-system-requirements)
2. [Understanding the Kernel Compatibility Issue](#understanding-the-kernel-compatibility-issue)
3. [Phase 1: Prepare the Environment (From Working Kernel)](#phase-1-prepare-the-environment-from-working-kernel)
4. [Phase 2: Install Compatible Kernel](#phase-2-install-compatible-kernel)
5. [Phase 3: Clean Up Incompatible Kernels](#phase-3-clean-up-incompatible-kernels-optional)
6. [Phase 4: Configure GRUB Boot Options](#phase-4-configure-grub-boot-options)
7. [Phase 5: Boot into Compatible Kernel](#phase-5-boot-into-compatible-kernel)
8. [Phase 6: Install SystemTap and Debug Symbols](#phase-6-install-systemtap-and-debug-symbols)
9. [Phase 6A: Build SystemTap from Source](#phase-6a-build-systemtap-from-source)
10. [Phase 7: Install and Run IntP](#phase-7-install-and-run-intp)
11. [Troubleshooting](#troubleshooting)
12. [Reverting to Original Kernel](#reverting-to-original-kernel)

---

## Prerequisites and System Requirements

### Test System Configuration

This guide was developed and tested on the following system:

| Component | Specification |
|-----------|---------------|
| OS | Ubuntu 24.04.3 LTS (Noble Numbat) |
| Architecture | x86_64 |
| Original Kernel | 6.14.0-37-generic |
| CPU | 13th Gen Intel i7-13650HX (20 cores) |
| GPU | NVIDIA GeForce RTX 4050 Max-Q / Intel UHD Graphics |
| RAM | 32 GB |
| Storage | NVMe SSD (~900 GB available) |

### Required Privileges

All installation steps require root privileges. You can either:

- Prefix commands with `sudo`
- Switch to root shell: `sudo -i`

---

## Understanding the Kernel Compatibility Issue

### The Problem

IntP requires SystemTap with kernel debug symbols (`linux-image-*-dbgsym` packages). There are **two** compatibility issues in Ubuntu 24.04:

**Issue 1: Debug Symbol Availability**

- **Kernel 6.14.x and newer**: Debug symbol packages are often unavailable or delayed in repositories
- **Kernel 6.8.x**: Debug symbols are reliably available in the `noble-debug` repository

**Issue 2: SystemTap Version Compatibility**

- **Ubuntu 24.04 packaged SystemTap**: Version 4.9-5.0, supports kernels up to ~6.6
- **Kernel 6.8.x**: Requires SystemTap 5.1+ due to kernel API changes (mmap_sem → mmap_lock, get_user_pages_remote signature changes, etc.)
- **Symptom**: Compilation errors mentioning `mmap_sem`, `get_user_pages_remote`, "kernel version outside tested range"

### The Solution

We will:

1. Install a compatible kernel (6.8.x series) alongside your current kernel
2. Pre-install NVIDIA drivers for the new kernel while still in the working kernel
3. Configure GRUB to boot into the compatible kernel by default
4. Install or build SystemTap (version 5.1+) and debug symbols in the compatible kernel

This approach ensures you can always boot back into your original working kernel if issues arise.

**Note**: If you want to avoid building SystemTap from source, you could use kernel 6.5.x or earlier, though debug symbol availability may be limited.

---

## Phase 1: Prepare the Environment (From Working Kernel)

Perform these steps from your currently working kernel (6.14.x).

### Important: Check Secure Boot Status

Secure Boot can prevent unsigned kernel modules (including SystemTap-generated modules) from loading. Check your status:

```bash
mokutil --sb-state
```

If Secure Boot is enabled, you have two options:

1. **Disable Secure Boot** in BIOS/UEFI (simplest for development/testing)
2. **Sign your modules** (more complex, required for production systems)

For IntP development and testing, disabling Secure Boot is recommended.

### Step 1.1: Update System

```bash
sudo apt update
sudo apt upgrade -y
```

### Step 1.2: Install Essential Build Tools

```bash
sudo apt install -y build-essential dkms linux-headers-$(uname -r)
```

### Step 1.3: Check Available Kernel Versions

Search for available 6.8.x kernels:

```bash
apt-cache search linux-image-6.8 | grep generic | head -20
```

Expected output (versions may vary):

```
linux-image-6.8.0-31-generic - Signed kernel image generic
linux-image-6.8.0-35-generic - Signed kernel image generic
linux-image-6.8.0-38-generic - Signed kernel image generic
linux-image-6.8.0-40-generic - Signed kernel image generic
linux-image-6.8.0-41-generic - Signed kernel image generic
linux-image-6.8.0-45-generic - Signed kernel image generic
linux-image-6.8.0-49-generic - Signed kernel image generic
linux-image-6.8.0-50-generic - Signed kernel image generic
linux-image-6.8.0-90-generic - Signed kernel image generic
```

### Step 1.4: Verify Debug Symbol Availability

Before installing a kernel, verify its debug symbols exist:

```bash
# Enable debug repository first (see Phase 2)
# Then check for a specific version:
apt-cache search linux-image-6.8.0-90-generic-dbgsym
```

---

## Phase 2: Install Compatible Kernel

### Step 2.1: Install Debug Repository Keyring (MUST BE FIRST)

**Important**: The keyring must be installed BEFORE adding the repository, otherwise `apt update` will fail with GPG errors.

```bash
sudo apt install -y ubuntu-dbgsym-keyring
```

If the above fails, manually import the key:

```bash
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys F2EDC64DC5AEE1F6B9C621F0C8CAB6595FDFF622
```

### Step 2.2: Enable Debug Symbol Repository

Create the debug repository configuration:

```bash
sudo tee /etc/apt/sources.list.d/ddebs.list << 'EOF'
deb http://ddebs.ubuntu.com noble main restricted universe multiverse
deb http://ddebs.ubuntu.com noble-updates main restricted universe multiverse
deb http://ddebs.ubuntu.com noble-proposed main restricted universe multiverse
EOF
```

### Step 2.3: Update Package Lists

```bash
sudo apt update
```

Verify the repository is working (should show no errors related to ddebs.ubuntu.com).

### Step 2.4: Verify Debug Symbols Are Accessible

Confirm you can find debug symbol packages:

```bash
# This should return results now
apt-cache search linux-image-6.8.0-90-generic-dbgsym
```

Expected output:
```
linux-image-6.8.0-90-generic-dbgsym - Signed kernel image generic
```

If no results appear, the repository is not properly configured. Review steps 2.1-2.3.

### Step 2.5: Find the Best Compatible Kernel with NVIDIA Support

For systems with NVIDIA GPUs, you need a kernel that has BOTH debug symbols AND NVIDIA driver modules available. Check available options:

```bash
# Check your current NVIDIA driver version
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# List kernels with NVIDIA support (example for driver 580)
apt-cache search "^linux-modules-nvidia-580-open-6.8.0-.*-generic$" | grep -E "6.8.0-[0-9]+-generic" | sort -V

# Verify debug symbols exist for the latest kernel
apt-cache search "linux-image-unsigned-6.8.0-.*-generic-dbgsym" | sort -V | tail -5
```

**Recommended**: Use kernel **6.8.0-90-generic** as it has both NVIDIA 580 support and debug symbols.

**Important**: Verify ALL required packages exist:

```bash
# Check all required packages for 6.8.0-90-generic
apt-cache policy linux-image-6.8.0-90-generic \
  linux-image-unsigned-6.8.0-90-generic-dbgsym \
  linux-modules-nvidia-580-open-6.8.0-90-generic | grep -E "^(linux-|  Candidate:)"
```

All three should show available candidate versions.

### Step 2.6: Install the Compatible Kernel with NVIDIA Support

```bash
# Set the target kernel version
TARGET_KERNEL="6.8.0-90-generic"

# Install kernel, headers, modules, NVIDIA support, and debug symbols
sudo apt install -y \
    linux-image-${TARGET_KERNEL} \
    linux-headers-${TARGET_KERNEL} \
    linux-modules-${TARGET_KERNEL} \
    linux-modules-extra-${TARGET_KERNEL} \
    linux-modules-nvidia-580-open-${TARGET_KERNEL} \
    linux-image-unsigned-${TARGET_KERNEL}-dbgsym

# Note: Adjust nvidia-580-open to nvidia-580 if using proprietary driver
# Check your driver with: dpkg -l | grep nvidia-driver
```

### Step 2.7: Verify Kernel Installation

```bash
# List installed kernels
dpkg -l | grep "linux-image-[0-9]" | grep "^ii"
```

Expected output should show both kernels:

```text
ii  linux-image-6.14.0-37-generic   6.14.0-37.37~24.04.1   amd64   Signed kernel image generic
ii  linux-image-6.8.0-90-generic    6.8.0-90.91            amd64   Signed kernel image generic
```

### Step 2.8: Verify NVIDIA Modules

```bash
# Verify NVIDIA modules exist for the new kernel
ls -la /lib/modules/6.8.0-90-generic/kernel/nvidia* 2>/dev/null && echo "NVIDIA modules: OK" || echo "NVIDIA modules: MISSING"
```

Should show NVIDIA kernel module directories and print "NVIDIA modules: OK".

---

## Phase 3: Clean Up Incompatible Kernels (Optional)

If you accidentally installed a kernel version that doesn't have NVIDIA support (like 6.8.0-64), remove it now to avoid boot issues.

### Step 3.1: Check for Unsupported Kernel Versions

```bash
# List all installed 6.8.0 kernels
dpkg -l | grep "linux-image-6.8.0" | grep "^ii"

# Check which ones have NVIDIA module support
apt-cache search "^linux-modules-nvidia-580-open-6.8.0-.*-generic$" | grep -E "6.8.0-[0-9]+-generic"
```

If you see a kernel installed that doesn't have NVIDIA support, remove it.

### Step 3.2: Remove Unsupported Kernel (if needed)

Example: Removing 6.8.0-64-generic (which lacks NVIDIA 580 support):

```bash
# Remove all packages for the unsupported kernel
sudo apt purge \
  linux-image-6.8.0-64-generic \
  linux-headers-6.8.0-64-generic \
  linux-headers-6.8.0-64 \
  linux-modules-6.8.0-64-generic \
  linux-modules-extra-6.8.0-64-generic

# Clean up dependencies
sudo apt autoremove --purge

# Update GRUB to remove boot entries
sudo update-grub
```

### Step 3.3: Verify Final Kernel Setup

```bash
# Verify only supported kernels remain
dpkg -l | grep "linux-image-[0-9]" | grep "^ii"

# Verify NVIDIA modules exist for your target kernel
ls -la /lib/modules/6.8.0-90-generic/kernel/nvidia* 2>/dev/null && echo "✓ NVIDIA modules ready" || echo "✗ NVIDIA modules missing"
```

Expected output:

```text
ii  linux-image-6.14.0-37-generic   6.14.0-37.37~24.04.1   amd64   Signed kernel image generic
ii  linux-image-6.8.0-90-generic    6.8.0-90.91            amd64   Signed kernel image generic
✓ NVIDIA modules ready
```

---

## Phase 4: Configure GRUB Boot Options

### Step 4.1: Backup Current GRUB Configuration

```bash
sudo cp /etc/default/grub /etc/default/grub.backup
```

### Step 4.2: Find the Menu Entry for Target Kernel

List all GRUB menu entries with indices:

```bash
sudo awk -F\' '/menuentry / {print i++, $2}' /boot/grub/grub.cfg
```

Example output:

```text
0 Ubuntu
1 Ubuntu, with Linux 6.14.0-37-generic
2 Ubuntu, with Linux 6.14.0-37-generic (recovery mode)
3 Ubuntu, with Linux 6.8.0-90-generic                    ← YOUR TARGET
4 Ubuntu, with Linux 6.8.0-90-generic (recovery mode)
5 memtest86+
...
```

Find your target kernel (6.8.0-90-generic) in the list.

### Step 4.3: Understanding GRUB Menu Structure

Your GRUB menu has this structure:

```
Main Menu:
  0: Ubuntu (default entry)
  1: Advanced options for Ubuntu (submenu) ←─ Contains all kernels
        ├─ Ubuntu, with Linux 6.14.0-37-generic
        ├─ Ubuntu, with Linux 6.14.0-37-generic (recovery)
        ├─ Ubuntu, with Linux 6.8.0-90-generic          ← TARGET
        └─ Ubuntu, with Linux 6.8.0-90-generic (recovery)
  2: memtest86+
  ...
```

To boot a specific kernel in the submenu, you need to specify the path.

#### Option A: Use Menu Path (Recommended - Descriptive)

Format: `"Submenu Name>Kernel Name"`

```
"Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-90-generic"
```

#### Option B: Use Numeric Index (Shorter)

Format: `"submenu_index>item_index_within_submenu"`

The submenu "Advanced options for Ubuntu" is the 2nd item (index **1**).

Within the submenu, count the kernels:

- Index 0: 6.14.0-37-generic
- Index 1: 6.14.0-37-generic (recovery)
- Index 2: 6.8.0-90-generic ← This is your target

So the numeric path is: `"1>2"`

### Step 4.4: Configure GRUB Default

Edit GRUB configuration:

```bash
sudo nano /etc/default/grub
```

**Option A: Use Menu Path (Recommended)**

Change the `GRUB_DEFAULT` line:

```bash
# Comment out the old setting
#GRUB_DEFAULT=0

# Set to the specific kernel (adjust version as needed)
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-90-generic"
```

**Option B: Use Numeric Index**

```bash
# If the kernel is the 3rd entry under Advanced options (index 2)
GRUB_DEFAULT="1>2"
```

**Option C: Always Use Last Booted Kernel**

```bash
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
```

### Step 4.5: Optional - Show GRUB Menu

If GRUB menu is hidden, you may want to show it temporarily:

```bash
# Show menu for 10 seconds
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=10
```

### Step 4.6: Update GRUB

Apply the changes:

```bash
sudo update-grub
```

Verify the configuration:

```bash
grep GRUB_DEFAULT /etc/default/grub
```

---

## Phase 5: Boot into Compatible Kernel

### Step 5.1: Reboot System

```bash
sudo reboot
```

### Step 5.2: Verify Kernel Version

After reboot, verify you are running the correct kernel:

```bash
uname -r
```

Expected output:

```
6.8.0-90-generic
```

### Step 5.3: Verify NVIDIA Driver

```bash
nvidia-smi
```

The driver should load correctly. If it shows an error, see [Troubleshooting](#troubleshooting).

### Step 5.4: Verify System Functionality

Before proceeding, ensure basic system functionality:

```bash
# Check display manager is running
systemctl status gdm3

# Check GPU is recognized
lspci | grep -i nvidia

# Check if GUI is working (should already be visible)
echo $XDG_SESSION_TYPE
```

---

## Phase 6: Install SystemTap and Debug Symbols

Perform these steps after booting into the compatible kernel (6.8.x).

### Step 6.1: Verify Current Kernel

```bash
uname -r
# Should output: 6.8.0-90-generic (or your chosen version)
```

### Step 6.2: Install SystemTap

```bash
sudo apt install -y systemtap systemtap-runtime
```

### Step 6.3: Install Debug Symbols

```bash
# Install debug symbols for the running kernel
sudo apt install -y linux-image-$(uname -r)-dbgsym
```

**Note**: This package is large (several hundred MB to over 1 GB). Installation may take several minutes.

### Step 6.4: Install Additional Dependencies

```bash
sudo apt install -y \
    make \
    g++ \
    python3 \
    gettext \
    libdw-dev \
    libelf-dev
```

### Step 6.5: Run stap-prep

The `stap-prep` script checks for missing dependencies:

```bash
sudo stap-prep
```

Follow any instructions it provides to install missing packages.

### Step 6.6: Verify SystemTap Installation

Run a simple test:

```bash
sudo stap -e 'probe begin { log("hello world") exit() }'
```

Expected output:

```
hello world
```

**IMPORTANT**: If you encounter compilation errors with messages like:

- `error: 'struct mm_struct' has no member named 'mmap_sem'`
- `error: passing argument 1 of 'get_user_pages_remote' from incompatible pointer type`
- `Kernel version 6.8.0 is outside tested range 2.6.32 ... 6.6-rc1`

This means the version of SystemTap installed from Ubuntu repositories is **too old** for kernel 6.8.x. The Ubuntu 24.04 SystemTap package (version 4.9-5.0) was built for older kernels and is incompatible with kernel 6.8.0's API changes.

**Solution**: You must build SystemTap from source. Proceed to [Phase 6A: Build SystemTap from Source](#phase-6a-build-systemtap-from-source) before continuing.

Continue to Step 6.7 only if the test succeeds.

### Step 6.7: Additional SystemTap Test

Run a more comprehensive test:

```bash
sudo stap -v -e 'probe kernel.function("do_sys_openat2") { log("openat2 called") exit() }'
```

This tests kernel function probing capability.

**Note**: If the function doesn't exist, you can list available functions:

```bash
sudo stap -l 'kernel.function("*open*")' | head -20
```

---

## Phase 6A: Build SystemTap from Source

**Only follow this phase if Step 6.6 failed with kernel compatibility errors.**

The SystemTap version in Ubuntu 24.04 repositories (typically 4.9 or 5.0) does not support kernel 6.8.x API changes. You need SystemTap 5.1 or newer, which supports kernels up to 6.12-rc.

### Step 6A.1: Install Build Dependencies

```bash
sudo apt install -y \
    build-essential \
    git \
    gettext \
    autoconf \
    automake \
    pkg-config \
    libdw-dev \
    libelf-dev \
    libssl-dev \
    libsqlite3-dev \
    libnss3-dev \
    libnspr4-dev \
    libavahi-client-dev \
    libxml2-dev \
    python3-dev \
    python3-setuptools \
    libreadline-dev \
    zlib1g-dev
```

### Step 6A.2: Remove Old SystemTap

```bash
sudo apt remove --purge systemtap systemtap-runtime
sudo apt autoremove
```

### Step 6A.3: Clone SystemTap Source

```bash
cd ~/Documents
git clone https://sourceware.org/git/systemtap.git
cd systemtap
```

### Step 6A.4: Check and Checkout Latest Release

```bash
# List available tags/releases
git tag | grep "^release-" | tail -10

# Checkout the latest stable release (adjust version as needed)
# As of January 2026, version 5.2 supports kernels up to 6.12-rc
git checkout release-5.2
```

If release-5.2 doesn't exist, use the latest available release tag or main branch:

```bash
# Use main development branch (bleeding edge)
git checkout main
```

### Step 6A.5: Configure Build

```bash
./configure \
    --prefix=/usr/local \
    --disable-docs \
    --disable-publican \
    --enable-sqlite \
    --enable-virt
```

Expected output should end with a configuration summary showing enabled features.

### Step 6A.6: Compile SystemTap

```bash
make -j$(nproc)
```

**Note**: Compilation may take 5-15 minutes depending on your system.

### Step 6A.7: Install SystemTap

```bash
sudo make install
```

### Step 6A.8: Verify Installation

```bash
# Check version (should be 5.1 or newer)
stap --version

# Verify it's using the new installation
which stap
# Should output: /usr/local/bin/stap
```

Expected output for version:

```
Systemtap translator/driver (version 5.2/0.190, release-5.2)
...
tested kernel versions: 3.10 ... 6.12-rc
enabled features: AVAHI BPF PYTHON3 LIBSQLITE3 LIBXML2 NLS NSS READLINE
```

### Step 6A.9: Run Test Again

```bash
sudo stap -e 'probe begin { log("hello world from SystemTap 5.x") exit() }'
```

Expected output:

```
hello world from SystemTap 5.x
```

If this succeeds, SystemTap is now compatible with kernel 6.8.x. **Return to Step 6.7** to continue testing.

---

## Phase 7: Install and Run IntP

### Step 7.1: Clone or Copy IntP

If you have the IntP files locally:

```bash
cd ~/Documents
mkdir -p intp
cd intp
# Copy your IntP files here (intp.stp, etc.)
```

Or clone from repository:

```bash
cd ~/Documents
git clone https://github.com/projectintp/intp.git
cd intp
```

### Step 7.2: Verify IntP Script

Check that `intp.stp` exists and is readable:

```bash
ls -la intp.stp
head -20 intp.stp
```

### Step 7.3: Run IntP

Open **Terminal 1** and start IntP monitoring:

```bash
# Replace "ApplicationName" with the actual application name to monitor
# Example: "firefox", "python3", "java", etc.
sudo stap --suppress-handler-errors -g intp.stp ApplicationName
```

The script will wait for the specified application to start.

### Step 7.4: View IntP Output

Open **Terminal 2** and view the monitoring output:

```bash
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

### Step 7.5: Understanding IntP Output

IntP provides the following metrics:

| Metric | Description |
|--------|-------------|
| netp | Network physical layer utilization (%) |
| nets | Network stack utilization (%) |
| blk | Block I/O utilization (%) |
| mbw | Memory bandwidth utilization (%) |
| llcmr | LLC (Last Level Cache) miss ratio (%) |
| llcocc | LLC occupancy (%) |
| cpu | CPU utilization (%) |

Example output:

```
netp    nets    blk     mbw     llcmr   llcocc  cpu
02      01      05      12      03      08      45
```

### Step 7.6: Example - Monitor Firefox

Terminal 1:

```bash
sudo stap --suppress-handler-errors -g intp.stp firefox
```

Terminal 2:

```bash
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

Then start Firefox, and IntP will begin monitoring.

---

## Troubleshooting

### Problem: NVIDIA Driver Not Loading After Kernel Change

**Symptoms**: Black screen, low resolution, or `nvidia-smi` fails

**Solution 1**: Boot into original kernel and rebuild modules

1. Reboot and hold `Shift` (BIOS) or `Escape` (UEFI) to show GRUB menu
2. Select "Advanced options for Ubuntu"
3. Choose your original kernel (6.14.x)
4. Rebuild NVIDIA modules:

```bash
sudo dkms autoinstall -k 6.8.0-90-generic
sudo update-initramfs -u -k 6.8.0-90-generic
```

5. Reboot into the 6.8.x kernel

**Solution 2**: Use Recovery Mode

If you get a black screen and cannot access GRUB:

1. Force shutdown (hold power button)
2. Power on and immediately hold `Shift` or repeatedly press `Escape`
3. In GRUB, select "Advanced options for Ubuntu"
4. Select the kernel with "(recovery mode)"
5. Choose "root - Drop to root shell prompt"
6. Remount filesystem as read-write:

```bash
mount -o remount,rw /
```

7. Rebuild NVIDIA modules or switch to original kernel

**Solution 3**: Use nouveau driver temporarily

```bash
# Remove nvidia from blacklist temporarily
sudo mv /etc/modprobe.d/blacklist-nvidia.conf /etc/modprobe.d/blacklist-nvidia.conf.bak
sudo update-initramfs -u
sudo reboot
```

### Problem: Debug Symbols Package Not Found

**Symptoms**: `apt install linux-image-*-dbgsym` fails

**Solution**: 

1. Verify debug repository is enabled:

```bash
cat /etc/apt/sources.list.d/ddebs.list
```

2. Update and search again:

```bash
sudo apt update
apt-cache search $(uname -r) | grep dbgsym
```

3. Try a different 6.8.x kernel version with available symbols

### Problem: SystemTap Test Fails with Compilation Errors

**Symptoms**: `stap -e 'probe begin...'` produces errors like:

```text
error: 'struct mm_struct' has no member named 'mmap_sem'
error: passing argument 1 of 'get_user_pages_remote' from incompatible pointer type
error: 'struct hlist_head' has no member named 'next'
Kernel version 6.8.0 is outside tested range 2.6.32 ... 6.6-rc1
WARNING: kbuild exited with status: 2
Pass 4: compilation failed.
```

**Root Cause**: SystemTap version from Ubuntu repositories (4.9-5.0) is too old for kernel 6.8.x. Kernel 6.8 introduced API changes that are not supported by older SystemTap versions.

**Solution**: Build SystemTap 5.1+ from source following [Phase 6A: Build SystemTap from Source](#phase-6a-build-systemtap-from-source).

### Problem: SystemTap Test Fails - Debug Symbols Mismatch

**Symptoms**: `stap -e 'probe begin...'` produces errors about missing symbols (not compilation errors)

**Common fixes**:

```bash
# Ensure debug symbols match exactly
dpkg -l | grep linux-image.*dbgsym

# The version must match exactly
uname -r
# vs
dpkg -l linux-image-*-dbgsym | awk '{print $3}'

# Reinstall debug symbols
sudo apt install --reinstall linux-image-$(uname -r)-dbgsym
```

### Problem: IntP Fails with Embedded C Errors (Kernel 6.8.0)

**Symptoms**: Compilation errors when running IntP:

```text
error: "MSR_IA32_QM_CTR" redefined
error: "MSR_IA32_QM_EVTSEL" redefined
error: 'struct hw_perf_event' has no member named 'cqm_rmid'
Pass 4: compilation failed.
```

**Root Cause**: Kernel 6.8.0 introduced breaking changes to Intel Cache QoS Monitoring (CQM) / Resource Director Technology (RDT):

1. **MSR definitions moved**: `MSR_IA32_QM_CTR` and `MSR_IA32_QM_EVTSEL` are now in kernel headers (`asm/msr-index.h`)
2. **CQM struct changed**: The `cqm_rmid` field was removed from `struct hw_perf_event` as part of resctrl refactoring
3. **Interface changed**: LLC occupancy monitoring now uses the resctrl filesystem interface instead of direct perf events

**Solutions**:

**Option A: Modify IntP for Kernel 6.8.0** (Advanced - Requires C programming)

1. Remove MSR redefinitions (lines 341-342 in intp.stp)
2. Replace `cqm_rmid` access with new resctrl API (major rewrite required)
3. Use resctrl filesystem (`/sys/fs/resctrl/`) for LLC occupancy monitoring

**Option B: Use Kernel 6.5.x Instead** (Recommended if debug symbols available)

Kernel 6.5.x still uses the old CQM interface that IntP expects:

```bash
# Check available 6.5.x kernels with debug symbols
apt-cache search linux-image-6.5.0.*generic-dbgsym

# Install if available (example for 6.5.0-XX)
sudo apt install \
    linux-image-6.5.0-XX-generic \
    linux-headers-6.5.0-XX-generic \
    linux-image-unsigned-6.5.0-XX-generic-dbgsym
```

**Option C: Disable LLC Occupancy Monitoring** (Partial functionality)

Modify `intp.stp` to skip LLC occupancy (keep LLC miss ratio only):

- Comment out lines 43-45 (LLC perf event creation)
- Comment out line 605 (`cache_occ = print_llc_report()`)
- This loses one metric but keeps the rest functional

**Note**: The IntP script was designed for kernels 3.x-6.6. Kernel 6.8.0+ requires significant updates to support the new resctrl interface. For full functionality on kernel 6.8.0, the script needs to be ported to use `/sys/fs/resctrl/mon_data/` instead of direct perf event access.

### Problem: Permission Denied

**Symptoms**: IntP fails to run even with sudo

**Solution**:

```bash
# Ensure secure boot is not blocking unsigned modules
mokutil --sb-state

# If enabled, you may need to enroll a key or disable secure boot
```

### Problem: GRUB Not Showing Menu

**Solution**:

```bash
# Hold Shift during boot for BIOS systems
# Hold Escape during boot for UEFI systems

# Or edit GRUB to always show menu:
sudo nano /etc/default/grub
# Set:
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=10

sudo update-grub
```

---

## Reverting to Original Kernel

If you need to return to your original kernel:

### Temporary (Single Boot)

1. Reboot and hold `Shift` (BIOS) or `Escape` (UEFI)
2. Select "Advanced options for Ubuntu"
3. Choose your original kernel (6.14.x)

### Permanent

```bash
# Edit GRUB configuration
sudo nano /etc/default/grub

# Change back to default
GRUB_DEFAULT=0

# Update GRUB
sudo update-grub

# Reboot
sudo reboot
```

### Remove Installed Kernel (Optional)

```bash
# List installed kernels
dpkg -l | grep linux-image

# Remove specific kernel (be careful!)
sudo apt remove linux-image-6.8.0-90-generic linux-headers-6.8.0-90-generic

# Update GRUB
sudo update-grub
```

---

## Quick Reference Card

### Essential Commands

| Task | Command |
|------|---------|
| Check kernel version | `uname -r` |
| List installed kernels | `dpkg -l \| grep linux-image` |
| Check NVIDIA driver | `nvidia-smi` |
| Check DKMS status | `dkms status` |
| Test SystemTap | `sudo stap -e 'probe begin { log("test") exit() }'` |
| Run IntP | `sudo stap --suppress-handler-errors -g intp.stp AppName` |
| View IntP output | `watch -n2 -d cat /proc/systemtap/stap_*/intestbench` |
| Update GRUB | `sudo update-grub` |

### Important File Locations

| File | Purpose |
|------|---------|
| `/etc/default/grub` | GRUB configuration |
| `/boot/grub/grub.cfg` | Generated GRUB menu |
| `/etc/apt/sources.list.d/ddebs.list` | Debug symbols repository |
| `/proc/systemtap/stap_*/intestbench` | IntP output |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | January 2026 | Initial guide for Ubuntu 24.04 with kernel 6.8.x compatibility |

---

## Contributors

- Original IntP: [@mclsylva](https://github.com/mclsylva), [@superflit](https://github.com/superflit)
- Ubuntu 24.04 Guide: Adapted from Debian and Red Hat installation guides

---

## License

This documentation follows the IntP project license. See the main repository for details.

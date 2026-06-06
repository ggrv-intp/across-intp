# bench/setup -- Hetzner Server Auction bootstrap

End-to-end recipe for taking a freshly-rented Hetzner SB box (Xeon Gold 5412U)
from the Rescue System to a fully provisioned dual-OS testbed for the IntP
experiments.

## What this directory contains

| File                          | Purpose                                                     |
| ----------------------------- | ----------------------------------------------------------- |
| `installimage-jammy.conf`     | Hetzner installimage config: Ubuntu 22.04 onto `nvme0n1`    |
| `installimage-noble.conf`     | Hetzner installimage config: Ubuntu 24.04 onto `nvme1n1`    |
| `setup-host.sh`               | Auto-detecting bootstrap script for either OS               |
| `setup-host-legacy.sh`        | Minimal idempotent bootstrap for the U22 / kernel 5.15 leg of the legacy-V0 campaign |

## Read flow (docs -> findings)

Use this chain when moving from setup instructions to evidence and analysis:

1. Repository overview: `README.md`
2. Bench orchestration and outputs: `bench/README.md`
3. Findings index: `bench/findings/README.md`
4. V0 baseline diagnosis: `bench/findings/v0-baseline-failure-diagnosis.md`
5. V1 reliability diagnosis: `bench/findings/v1-modernization-reliability-findings.md`

## Why two disks, two OSes

V0 (the original SystemTap probe) relies on the `cqm_rmid` field in
`struct hw_perf_event`, which kernel 6.8 removed. So the V0 baseline must
run on a kernel <= 6.7. V0.1..V3 are designed against 6.8.

Rather than juggle GRUB entries on a single disk, we use the box's two NVMe
drives: `nvme0n1` for the V0 baseline OS (Ubuntu 22.04 + HWE 6.5, newest
pre-6.8 with full Sapphire Rapids uncore IMC support), `nvme1n1` for the
modern OS (Ubuntu 24.04 + 6.8 stock). Switching between them is a boot-order
toggle in Hetzner Robot.

## Workflow

### 1. Reboot the box into the Rescue System

In Hetzner Robot, activate "Rescue system (English)", then reboot. SSH into
the rescue ramdisk as `root` using the IP and the password Robot showed you.

### 2. Image the V0 baseline disk (nvme0n1)

From rescue:

```bash
# Edit the SSHKEYS_URL or SSHKEYS line if you want unattended ssh access on
# first boot of the installed system.
$EDITOR /tmp/installimage-jammy.conf   # or paste it inline

# (transfer the config from this repo or paste it directly)
installimage -a -c /tmp/installimage-jammy.conf
```

`-a` is "automatic mode" -- it runs to completion without the curses UI.
The install takes ~5 minutes. When it finishes, type `reboot` to drop out
of rescue and into the freshly installed Ubuntu 22.04.

If `nvme0n1` is not the actual device for slot 1 on your unit, check
`lsblk` in rescue and adjust `DRIVE1` in the config.

### 3. First boot of Ubuntu 22.04 -- bootstrap

```bash
# Now SSH'd into the installed 22.04
apt-get update && apt-get install -y git
git clone <this-repo-url> ~/intp
sudo bash ~/intp/bench/setup/setup-host.sh
```

This pass installs HWE 6.5, holds it via `apt-mark`, points GRUB at it, and
exits asking for a reboot.

```bash
sudo reboot
```

### 4. Second boot -- on kernel 6.5 -- finish bootstrap

```bash
uname -r          # should now report 6.5.0-XX-generic
sudo bash ~/intp/bench/setup/setup-host.sh
```

This pass installs SystemTap 5.2 from source plus matching debuginfo, the
bench-script dependencies (stress-ng, perf, sysstat, etc.), optional Docker
+ qemu for the container/VM envs, mounts resctrl, sets
`perf_event_paranoid=-1`, builds v2, and runs a smoke test of `stap`.

Ubuntu 22.04's packaged SystemTap 4.6 does not build cleanly against the
Jammy HWE 6.5 kernel used for the V0 baseline, so the bootstrap upgrades only
the SystemTap toolchain, not the V0 probe itself.

You can now run the V0 sweep:

```bash
sudo ~/intp/bench/run-intp-bench.sh --variants v0 --env bare \
    --output-dir ~/results/v1-baseline
```

### 5. Reboot back into rescue, image the modern disk (nvme1n1)

In Robot, activate the Rescue System again and reboot. Then:

```bash
# sanity-check the disk names before writing the second install
lsblk -d -o NAME,SIZE,MODEL

# copy the Noble config from your workstation if needed
scp bench/setup/installimage-noble.conf root@<server-ip>:/tmp/

# optionally paste your public key into SSHKEYS or SSHKEYS_URL
$EDITOR /tmp/installimage-noble.conf

# validate in the curses UI first if you want to inspect the parsed fields
installimage -c /tmp/installimage-noble.conf

# then run unattended
installimage -a -c /tmp/installimage-noble.conf
reboot
```

This config targets only `nvme1n1`. It includes its own UEFI ESP and installs
GRUB only onto that disk, so it does not overwrite the `nvme0n1` baseline.
Before the reboot after imaging, set the boot disk to `nvme1n1` in Robot if
you want the next boot to land directly in Ubuntu 24.04.

### 6. First (and only) boot of Ubuntu 24.04 -- bootstrap

```bash
apt-get update && apt-get install -y git
git clone <this-repo-url> ~/intp
sudo bash ~/intp/bench/setup/setup-host.sh
```

24.04 ships with kernel 6.8, no pinning needed. The script installs
SystemTap (V0.1/V1), bpftrace (V3.1), the libbpf+clang+pahole toolchain (V3),
mounts resctrl, builds v2 and v3, and self-tests each.

```bash
sudo ~/intp/bench/run-intp-bench.sh \
    --variants v0.1,v1,v2,v3.1,v3 \
    --env bare,container \
    --output-dir ~/results/modern
```

### 7. Switching between OSes during the experiment campaign

In Hetzner Robot:

1. Open the server in Robot.
2. Change the next boot disk / boot order to the target NVMe.
3. Reboot the machine.

Operationally:

- Set the boot disk to `nvme0n1` and reboot to enter Ubuntu 22.04 for V0.
- Set the boot disk to `nvme1n1` and reboot to enter Ubuntu 24.04 for V0.1..V3.

This is disk-switching rather than a shared on-screen GRUB menu: each OS is
installed independently on its own drive with its own bootloader.

Keep the two `results/` trees side by side. The plotter merges them when
pointed at a parent directory.

## Optional flags

`setup-host.sh` accepts:

| Flag                | Effect                                                              |
| ------------------- | ------------------------------------------------------------------- |
| `--profile legacy`  | Force the 22.04 / V0 path even if `/etc/os-release` says otherwise. |
| `--profile modern`  | Force the 24.04 / V0.1..V3 path.                                      |
| `--no-optional`     | Skip Docker + qemu + cloud-utils (smaller install).                 |
| `--no-build`        | Skip `make` of v2 / v3.                                             |
| `--no-debuginfo`    | Skip the ddebs repo and matching dbgsym package. SystemTap probes
                       lose access to a lot of internal symbols; only use this if you
                       intend to run C-ABI/bpftrace/ebpf-ring only.                  |

## Sanity check after step 4 / step 6

The script's self-test prints a summary like:

```
[hh:mm:ss]   stap        OK
[hh:mm:ss]   v2          OK (cpu=procfs blk=tracepoint mbw=imc llcocc=resctrl ...)
[hh:mm:ss]   resctrl     OK
[hh:mm:ss]   BTF         OK              (modern only)
[hh:mm:ss]   paranoid    -1
```

Anything reporting `FAIL` or `missing` will narrow the variant set you
can run -- e.g. no BTF means bpftrace / ebpf-ring will refuse to attach.

## Legacy U22 host (legacy-V0 campaign)

When the operator boots the box into the Ubuntu 22.04 / kernel 5.15
disk for the V0 measurement leg, the full `setup-host.sh` is overkill
and risks touching things the legacy host should not change.
`setup-host-legacy.sh` is the minimal idempotent helper for that leg.

```bash
# 1. Confirm you're on the right kernel.
uname -r                                        # expect 5.15.*

# 2. Bootstrap: SystemTap >= 4.6, kernel-headers + dbgsym for the
#    running kernel, perf_event_paranoid=-1 and kernel.sysrq=1 in
#    /etc/sysctl.d/99-intp-legacy.conf, and a checkout of the
#    legacy-v0-campaign branch.
sudo bash bench/setup/setup-host-legacy.sh

# 3. Run the host-side preflight against V0 specifically.
shared/intp-preflight.sh --variant v0

# 4. Smoke test: one V0 rep against a short stress-ng workload.
INTP_BENCH_V0_DEEP_CLEANUP_EVERY=1 \
  bench/run-intp-bench.sh \
    --stages solo --variants v0 --envs bare \
    --workloads app10_search --reps 1 --duration 30
```

What `setup-host-legacy.sh` deliberately does not do: touch GRUB or
boot order, install bpftrace / libbpf-dev (ebpf-ring / bpftrace are not in scope
on the legacy host), or build any of the modern variants. It is safe
to re-run; every step is a check-then-apply.

## Things this script deliberately does *not* do

- **No firewall changes**: container / VM env may need iptables tweaks if
  you run iperf-style network workloads with strict policies. We assume an
  open Hetzner SB without UFW.
- **No NTP setup**: rely on the distribution default (systemd-timesyncd).
  The bench script timestamps with monotonic plus wallclock; small drift
  doesn't affect within-run analysis.
- **No tuned profile**: Hetzner SB boxes don't ship with `tuned`. If you
  want predictable CPU frequency, set `cpupower frequency-set -g performance`
  before each run -- not done here because it changes the experimental
  conditions and should be opt-in.
- **No Hetzner Robot API automation**: triggering rescue mode and boot
  device toggles is a 2-click action in the web UI; scripting it would
  pull in the Robot API key as a dependency and isn't worth it for two
  reboots over the entire campaign.

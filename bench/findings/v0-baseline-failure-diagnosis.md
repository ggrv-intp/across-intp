# v0 (stap-2022) Baseline — Compilation failure diagnosis

**Diagnosis date:** 2026-04-30
**Host:** intp-v1-baseline
**Kernel:** 6.5.0-45-generic (`6.5.0-45.45~22.04.1` Ubuntu HWE)
**OS:** Ubuntu 22.04.5 LTS
**CPU:** Intel Xeon Gold 5412U (Sapphire Rapids, 1 socket, 24 cores / 48 threads, 256 GB ECC RAM)

---

## Context

The v0 (stap-2022) baseline campaign was executed on this host with archived data
in `v1-full-campaign-all-envs/`. Reviewing the results showed that
every stap-2022 run produced `samples=0` and every metric in
`aggregate-means.tsv` was marked as `--`.

Investigation of the profiler logs (`profiler.stap.log`) revealed
that the failure occurred **before any data collection**, during the
SystemTap module compilation phase (Pass 4).

---

## Diagnostic check results

```
# SystemTap version
stap --version 2>&1 | head -1
→ Systemtap translator/driver (version 5.2/0.186, release-5.2)   ✅

# SystemTap 5.2 binary built from source
ls -la /usr/local/bin/stap
→ -rwxr-xr-x 1 root root 71784736 Apr 30 13:27 /usr/local/bin/stap   ✅

# Presence of cqm_rmid in the running kernel headers
grep -r cqm_rmid /usr/src/linux-headers-$(uname -r)/
→ cqm_rmid ABSENT in headers -- V0 DOES NOT COMPILE   ❌

# MSR_IA32_QM in headers (cause redefinition conflict in the probe)
grep "MSR_IA32_QM" /usr/src/linux-headers-$(uname -r)/arch/x86/include/asm/msr-index.h
→ #define MSR_IA32_QM_EVTSEL  0xc8d
  #define MSR_IA32_QM_CTR     0xc8e   ⚠️ already defined by the kernel

# SystemTap smoke test (minimal probe)
echo 'probe begin { println("stap ok"); exit() }' | sudo stap -
→ stap ok   ✅
```

---

## Root cause

The `cqm_rmid` field of `struct hw_perf_event`, used by stap-2022 to bind
an Intel RDT RMID to a kernel perf event, **was removed or
refactored** in Ubuntu HWE's
`linux-headers-6.5.0-45.45~22.04.1`.

stap-2022 assumes direct access to that internal field in two probe
locations:

```c
rr.rmid = pe->hw.cqm_rmid;         // line 85 of the stap-generated C
if (pe->hw.cqm_rmid == rr.rmid)    // line 95
```

Without `cqm_rmid`, the C compiler rejects the module. On top of
that, the MSRs `MSR_IA32_QM_CTR` and `MSR_IA32_QM_EVTSEL` are
already defined in `arch/x86/include/asm/msr-index.h`, causing an
additional **redefinition error** when SystemTap tries to redeclare
them in the generated code.

The result is four fatal errors at Pass 4, identical across **all**
logs of every stap-2022 run (bare, container, vm):

```
error: "MSR_IA32_QM_CTR" redefined [-Werror]
error: "MSR_IA32_QM_EVTSEL" redefined [-Werror]
error: 'struct hw_perf_event' has no member named 'cqm_rmid'   (x2)
Pass 4: compilation failed.  [man error::pass4]
```

**Historical note:** the HWE 6.5.0-45 is not the first kernel on which
`cqm_rmid` is missing. The field (and the `intel_cqm` perf PMU driver
that populated it) was removed from mainline in **kernel 4.14**
(November 2017, commit `c39a0e2c8850`); the replacement is the
`resctrl` filesystem. The IntP 2022 rig only worked because some
enterprise LTS lines carried vendor backports of `intel_cqm` until
roughly 2019-2020, or because the rig used a hand-compiled kernel that
restored the driver. On Ubuntu 22.04's stock 5.15 kernel the field is
already absent; the HWE 6.5 used here is simply the point at which the
failure becomes inescapable because no mainstream distro still ships
the backport. None of those paths are portable today.

---

## What was not the cause

| Hypothesis | Ruled out by |
|---|---|
| Missing debug symbols | No debuginfo/DWARF messages in logs; dbgsym 6.5.0-45 installed |
| Outdated SystemTap (4.6) | stap 5.2 built from source, in `/usr/local/bin/stap` |
| Incompatible hardware | `capabilities.env` confirms RDT/CQM available; `stap ok` works |
| Transient failure / noise | Identical, deterministic error across every repetition and env |

---

## Conclusion for the paper

stap-2022 **cannot compile** on this kernel without modifications to the
probe, regardless of how many times it is re-run. The `cqm_rmid`
field was removed as part of the perf/RDT internal-interface
refactor that Canonical incorporated into the HWE package
`6.5.0-45.45~22.04.1`, even though the version number 6.5 still
falls within the documented "supported" range.

This directly motivates:

- **v0.1 (stap-nollc)**: minimal patch that removes the `cqm_rmid` dependency and
  the MSR conflict, at the cost of dropping `llcocc`.
- **v1 (stap-nohelper)**: 7-metric coverage restored via `/sys/fs/resctrl`, with no
  dependency on internal `hw_perf_event` fields.
- **v2 (C-ABI)/v3.1 (bpftrace)/v3 (ebpf-ring)**: SystemTap-free approaches that are immune to this
  kind of ABI drift.

The campaign archived under `v1-full-campaign-all-envs/` should be
cited in the paper as **evidence of stap-2022 portability breakage**, not
as performance data.

---

## Internal references

- Failure logs: `v1-full-campaign-all-envs/**/profiler.stap.log` (line 19+)
- Sample index: `v1-full-campaign-all-envs/index.tsv` (every stap-2022 row has `samples=0`)
- Aggregates: `v1-full-campaign-all-envs/aggregate-means.tsv` (every stap-2022 column is `--`)
- Problem documentation: `docs/KERNEL-6.8-CHANGES.md`
- Resolving patch: `variants/v0.1-stap-nollc/intp-6.8.stp`
- Baseline bootstrap: `bench/setup/setup-host.sh`, function `install_legacy_stack()`

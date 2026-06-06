/*
 * intp_agg.bpf.h -- types shared between the BPF-side programs
 * (intp_agg.bpf.c) and the userspace loader (intp_agg.c) for V3.2.
 *
 * V3.2 has no per-event records; everything the BPF side wants to report
 * lands as an atomic increment into one of two counter maps:
 *
 *   agg_global  : BPF_MAP_TYPE_PERCPU_ARRAY, max_entries=1
 *                 a single struct intp_counters per CPU; userspace sums
 *                 across CPUs at poll time.
 *   agg_per_pid : BPF_MAP_TYPE_HASH, max_entries=INTP_AGG_HASH_MAX
 *                 keyed by TGID; populated only when not in system-wide
 *                 mode. Optional consumer via --per-pid-output.
 *
 * On the BPF side, __u32/__u64 come from vmlinux.h which the translation
 * unit has already included before this header. Userspace TUs get them
 * from <linux/types.h> instead; we pull that in here under the guard
 * below so callers don't have to remember.
 */

#ifndef INTP_AGG_BPF_H
#define INTP_AGG_BPF_H

#ifndef __VMLINUX_H__
#include <linux/types.h>
#endif

/* Kept small so the in-kernel PID filter loop stays under the 5.8 verifier's
 * instruction budget on the first pass. Same value as V3. */
#define INTP_MAX_PIDS        64

/* Upper bound on tracked TGIDs in the per-PID hash. Sized to cover the
 * paper's workloads: stress-ng tops out around 32 stressors and HiBench
 * peaks at a few hundred Spark executor TGIDs. Bump (with verifier in
 * mind) if a future workload needs more. */
#define INTP_AGG_HASH_MAX    8192

/* Config map: userspace pushes one record into the single-entry array
 * before attaching programs. Same struct as V3 -- only the consumer side
 * differs in V3.2. */
struct intp_config {
    __u32 target_pids[INTP_MAX_PIDS];
    __u32 num_target_pids;
    __u8  system_wide;
    __u8  _pad0;
    __u16 _pad1;
};

/*
 * Per-CPU / per-PID counter struct.
 *
 * Fields are __u64 because every increment is via __sync_fetch_and_add()
 * and the kernel-side BPF verifier wants atomic-on-64-bit guarantees.
 * Trailing _pad pushes the struct out to a cache-line boundary so two
 * adjacent per-CPU slots never share a line under false-sharing pressure.
 *
 * Field semantics:
 *   netp_tx_bytes / netp_rx_bytes : bytes transmitted / received summed
 *      over the interval. netp = (tx+rx)/interval / nic_max * 100.
 *   nets_tx_lat_ns_sum / nets_tx_lat_n : softirq vec=2 NET_TX time and
 *      its count. nets_rx_lat_ns_sum / nets_rx_lat_n : same for vec=3.
 *      Userspace combines into nets = sum / (interval_ns).
 *   blk_svctm_ns_sum / blk_ops / blk_bytes : block I/O service time
 *      and request count + bytes. blk = svctm / interval_ns * 100.
 *   cpu_on_ns_sum : aggregate on-CPU ns of filtered tasks; userspace
 *      normalizes against (interval_ns * num_cores).
 *   llc_refs / llc_misses : already scaled by perf_event sample_period
 *      so the ratio stays correct regardless of the period chosen.
 */
struct intp_counters {
    __u64 netp_tx_bytes;
    __u64 netp_rx_bytes;
    __u64 nets_tx_lat_ns_sum;
    __u64 nets_tx_lat_n;
    __u64 nets_rx_lat_ns_sum;
    __u64 nets_rx_lat_n;
    __u64 blk_svctm_ns_sum;
    __u64 blk_ops;
    __u64 blk_bytes;
    __u64 cpu_on_ns_sum;
    __u64 llc_refs;
    __u64 llc_misses;
    /* Cache-line pad. Keep at 4 to push the struct to 128 bytes on x86
     * (12 fields * 8 = 96, +4*8 = 128). Do not remove without rechecking
     * false-sharing analysis. */
    __u64 _pad[4];
};

#endif /* INTP_AGG_BPF_H */

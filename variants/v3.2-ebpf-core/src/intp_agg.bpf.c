/*
 * intp_agg.bpf.c -- kernel-side programs for IntP V3.2.
 *
 * V3.2 is the in-kernel-aggregating variant of V3. Where V3 pushes one
 * record per event into a 16 MiB BPF_MAP_TYPE_RINGBUF and burns a
 * userspace consumer in a polling loop to drain it (see SBAC-PAD 2026
 * paper, §V-B: 194-416x context-switch amplification structurally
 * coupled to that consumer), V3.2 accumulates the same per-event signal
 * directly into per-CPU/per-PID counter maps. Userspace polls those
 * maps once per --interval and emits one TSV row -- no ring-buffer
 * draining, no `ring_buffer__poll`, no consumer-wakeup feedback loop.
 *
 * This commit (C02) defines the counter maps and shared helpers. Probes
 * land in C03 (netp), C05 (blk/cpu/llcmr), and C06 (nets via softirq).
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

#include "intp_agg.bpf.h"

char LICENSE[] SEC("license") = "Dual MIT/GPL";

/* ------------------------------------------------------------------ Maps */

/* Config map: same shape as V3. Userspace populates this once at
 * attach time; probes read it on every invocation via intp_cfg(). */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_config);
} intp_cfg_map SEC(".maps");

/* Global counter map: one struct intp_counters per CPU at key=0. Each
 * probe does an __sync_fetch_and_add() into the current-CPU slot; the
 * userspace poller sums slots across all CPUs at sampling time. This is
 * the iprof pattern (Goege thesis ch. 3.3, Becker et al. UCC Companion
 * 2024) and what eliminates the ring-buffer consumer entirely. */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_global SEC(".maps");

/* Per-TGID counter map. Updated only when intp_cfg.system_wide == 0
 * (and the TGID passes the filter). Lets users break out a per-process
 * contribution via --per-pid-output. In system-wide mode we leave this
 * empty -- agg_global already covers everything on the box. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, INTP_AGG_HASH_MAX);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_per_pid SEC(".maps");

/* Single-slot per-CPU template of zeros, used to seed new entries in
 * agg_per_pid without putting a struct intp_counters on the BPF stack
 * (the struct is 128 bytes; the verifier accepts it, but pushing it
 * through every probe inflates instruction count). Userspace doesn't
 * touch this; the BPF side reads from it under BPF_NOEXIST insertion. */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_zero SEC(".maps");

/* Per-request issue timestamp, keyed by (dev<<32)|sector for block
 * svctm. Same shape as V3. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __type(key, __u64);
    __type(value, __u64);
} rq_start SEC(".maps");

/* Per-task on-CPU start timestamp, keyed by tid. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 32768);
    __type(key, __u32);
    __type(value, __u64);
} task_oncpu_start SEC(".maps");

/* Dynamically-tracked TGIDs of processes descended from any of the
 * configured target PIDs. Populated from two places:
 *
 *   1. Userspace seeds it at attach time by walking /proc to enumerate
 *      pre-existing descendants. Workloads like stress-ng spawn their
 *      stressor children before the profiler attaches; without the seed
 *      those children are invisible to the PID filter even though their
 *      parent is in target_pids.
 *
 *   2. The sched_process_fork tracepoint adds child TGIDs whenever a
 *      task already in the filter (config or this map) forks. New forks
 *      after attach therefore stay tracked without requiring polling.
 *
 * sched_process_exit removes thread-leader TGIDs on process exit so the
 * map doesn't grow unbounded. value is just a presence flag. Same map
 * as V3 -- the filter machinery is unchanged in V3.2. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);
    __type(value, __u8);
} descendant_tgids SEC(".maps");

/* -------------------------------------------------------------- Helpers */

static __always_inline struct intp_config *intp_cfg(void)
{
    __u32 key = 0;
    return bpf_map_lookup_elem(&intp_cfg_map, &key);
}

static __always_inline int is_system_wide(void)
{
    struct intp_config *cfg = intp_cfg();
    return !cfg || cfg->system_wide;
}

/* Returns 1 if pid is to be observed under the current config.
 *
 * Lookup order: (a) system_wide short-circuit, (b) static target_pids
 * array from the config map, (c) dynamic descendant_tgids hash map.
 * Same logic as V3. */
static __always_inline int pid_in_filter(struct intp_config *cfg, __u32 pid)
{
    if (!cfg)              return 1;
    if (cfg->system_wide)  return 1;

    __u32 n = cfg->num_target_pids;
    if (n > INTP_MAX_PIDS) n = INTP_MAX_PIDS;

    for (__u32 i = 0; i < INTP_MAX_PIDS; i++) {
        if (i >= n) break;
        if (cfg->target_pids[i] == pid) return 1;
    }

    __u8 *p = bpf_map_lookup_elem(&descendant_tgids, &pid);
    if (p) return 1;
    return 0;
}

/* Short-circuit form using the current task's TGID. */
static __always_inline int should_monitor_current(void)
{
    struct intp_config *cfg = intp_cfg();
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    return pid_in_filter(cfg, pid);
}

/* Return the per-CPU agg_global slot for the calling probe. NULL on
 * lookup failure (which is unreachable for PERCPU_ARRAY[key=0] in
 * practice, but the verifier insists). */
static __always_inline struct intp_counters *agg_global_slot(void)
{
    __u32 key = 0;
    return bpf_map_lookup_elem(&agg_global, &key);
}

/* Return (and lazily create) the per-TGID slot. The lazy-create path
 * seeds from agg_zero rather than putting a 128-byte struct on the
 * probe stack. The BPF_NOEXIST insert can race across CPUs; the
 * subsequent lookup is authoritative. */
static __always_inline struct intp_counters *
agg_per_pid_slot(__u32 tgid)
{
    struct intp_counters *p = bpf_map_lookup_elem(&agg_per_pid, &tgid);
    if (p) return p;

    __u32 zk = 0;
    struct intp_counters *z = bpf_map_lookup_elem(&agg_zero, &zk);
    if (!z) return NULL;

    bpf_map_update_elem(&agg_per_pid, &tgid, z, BPF_NOEXIST);
    return bpf_map_lookup_elem(&agg_per_pid, &tgid);
}

/* =====================================================================
 * netp -- network physical utilization
 *
 * Identical probe sites to V3 (tracepoint:net:net_dev_xmit and
 * tracepoint:net:netif_receive_skb) but the destination is the counter
 * maps instead of bpf_ringbuf_reserve. Loopback skip is preserved
 * verbatim: single-host workloads otherwise double-count and inflate
 * netp ≥2x relative to the per-NIC sysfs ground-truth.
 * ===================================================================== */

static __always_inline int tp_dev_is_lo(void *ctx, unsigned int data_loc)
{
    /* tracepoint __data_loc fields encode (length << 16) | offset.
     * Resolve the string by adding the offset to ctx, then read 4 bytes. */
    unsigned int offset = data_loc & 0xFFFFu;
    char buf[4] = {};
    bpf_probe_read_kernel_str(buf, sizeof(buf), (char *)ctx + offset);
    return buf[0] == 'l' && buf[1] == 'o' && buf[2] == '\0';
}

SEC("tracepoint/net/net_dev_xmit")
int tp_net_dev_xmit(struct trace_event_raw_net_dev_xmit *ctx)
{
    /* netp is a DEVICE-level metric (physical NIC utilization) -- the same
     * thing V2 reads from /sys/class/net non-lo byte counters. Count it
     * host-wide and do NOT gate on should_monitor_current(): TCP xmit/recv
     * runs largely in softirq / deferred context (TSQ, ACK-clocked) where the
     * current task is unrelated to the monitored cgroup, so PID-gating here
     * silently dropped veth/TSO TCP traffic entirely -- the v3.2
     * netp=0-on-tcp_v_tcp_veth artifact (UB22/UB24 validity notes). 'lo' stays
     * excluded to avoid the single-host xmit+recv 2x double-count. nets
     * (softirq) is already device-level for the same reason; this brings netp
     * into line with it and with V2. */
    if (tp_dev_is_lo(ctx, ctx->__data_loc_name)) return 0;

    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;

    __u32 len = BPF_CORE_READ(ctx, len);
    __sync_fetch_and_add(&g->netp_tx_bytes, len);

    /* Best-effort per-PID slot only when the current task actually matches the
     * filter (process-context sends, e.g. UDP sendto). Softirq-driven bytes
     * are still captured host-wide in the global counter above. */
    if (!is_system_wide() && should_monitor_current()) {
        __u32 tgid = bpf_get_current_pid_tgid() >> 32;
        struct intp_counters *p = agg_per_pid_slot(tgid);
        if (p) __sync_fetch_and_add(&p->netp_tx_bytes, len);
    }
    return 0;
}

SEC("tracepoint/net/netif_receive_skb")
int tp_netif_receive_skb(struct trace_event_raw_net_dev_template *ctx)
{
    /* RX always runs in softirq context, so the current task is whoever was
     * interrupted -- never reliably the monitored workload. netp is therefore
     * counted DEVICE-level (host-wide, 'lo' excluded), exactly like the TX
     * side and like V2's non-lo sysfs counters; PID-gating it here is what
     * dropped veth TCP RX. See tp_net_dev_xmit for the full rationale. */
    if (tp_dev_is_lo(ctx, ctx->__data_loc_name)) return 0;

    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;

    __u32 len = BPF_CORE_READ(ctx, len);
    __sync_fetch_and_add(&g->netp_rx_bytes, len);

    if (!is_system_wide() && should_monitor_current()) {
        __u32 tgid = bpf_get_current_pid_tgid() >> 32;
        struct intp_counters *p = agg_per_pid_slot(tgid);
        if (p) __sync_fetch_and_add(&p->netp_rx_bytes, len);
    }
    return 0;
}

/* =====================================================================
 * blk -- block I/O utilization
 *
 * issue stashes the start ts keyed by (dev<<32)|sector; complete looks
 * it up and increments svctm_sum / blk_ops / blk_bytes. Same probe sites
 * and same in-flight key as V3 -- only the destination of the closed
 * event changes.
 * ===================================================================== */

SEC("tracepoint/block/block_rq_issue")
int tp_block_rq_issue(struct trace_event_raw_block_rq *ctx)
{
    __u64 dev_sec = ((__u64)BPF_CORE_READ(ctx, dev) << 32)
                   | BPF_CORE_READ(ctx, sector);
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&rq_start, &dev_sec, &ts, BPF_ANY);
    return 0;
}

SEC("tracepoint/block/block_rq_complete")
int tp_block_rq_complete(struct trace_event_raw_block_rq_completion *ctx)
{
    if (!should_monitor_current()) return 0;

    __u64 dev_sec = ((__u64)BPF_CORE_READ(ctx, dev) << 32)
                   | BPF_CORE_READ(ctx, sector);
    __u64 now = bpf_ktime_get_ns();
    __u64 svctm = 0;
    __u64 *start_ts = bpf_map_lookup_elem(&rq_start, &dev_sec);
    if (start_ts) {
        svctm = now - *start_ts;
        bpf_map_delete_elem(&rq_start, &dev_sec);
    }

    __u32 bytes = BPF_CORE_READ(ctx, nr_sector) * 512;

    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;
    __sync_fetch_and_add(&g->blk_svctm_ns_sum, svctm);
    __sync_fetch_and_add(&g->blk_ops, 1);
    __sync_fetch_and_add(&g->blk_bytes, bytes);

    if (!is_system_wide()) {
        __u32 tgid = bpf_get_current_pid_tgid() >> 32;
        struct intp_counters *p = agg_per_pid_slot(tgid);
        if (p) {
            __sync_fetch_and_add(&p->blk_svctm_ns_sum, svctm);
            __sync_fetch_and_add(&p->blk_ops, 1);
            __sync_fetch_and_add(&p->blk_bytes, bytes);
        }
    }
    return 0;
}

/* =====================================================================
 * cpu -- CPU utilization via sched_switch
 *
 * On every sched_switch we close the outgoing task's on-CPU interval
 * (delta = now - task_oncpu_start[prev_pid]) and start the incoming
 * task's interval (task_oncpu_start[next_pid] = now). The delta lands
 * in cpu_on_ns_sum.
 * ===================================================================== */

SEC("tracepoint/sched/sched_switch")
int tp_sched_switch(struct trace_event_raw_sched_switch *ctx)
{
    struct intp_config *cfg = intp_cfg();

    __u32 prev_pid = BPF_CORE_READ(ctx, prev_pid);
    __u32 next_pid = BPF_CORE_READ(ctx, next_pid);
    __u64 now      = bpf_ktime_get_ns();

    __u64 *start_ts = bpf_map_lookup_elem(&task_oncpu_start, &prev_pid);
    if (start_ts && pid_in_filter(cfg, prev_pid)) {
        __u64 delta = now - *start_ts;
        struct intp_counters *g = agg_global_slot();
        if (g) __sync_fetch_and_add(&g->cpu_on_ns_sum, delta);

        if (!cfg || !cfg->system_wide) {
            struct intp_counters *p = agg_per_pid_slot(prev_pid);
            if (p) __sync_fetch_and_add(&p->cpu_on_ns_sum, delta);
        }
    }
    if (start_ts)
        bpf_map_delete_elem(&task_oncpu_start, &prev_pid);

    if (next_pid != 0)
        bpf_map_update_elem(&task_oncpu_start, &next_pid, &now, BPF_ANY);
    return 0;
}

/* =====================================================================
 * nets -- network stack service time via softirq tracepoints
 *
 * On modern kernels (>=6.x) napi_poll is inlined; kprobes don't attach.
 * irq:softirq_entry / softirq_exit fire for every NET_TX (vec=2) and
 * NET_RX (vec=3) dispatch and capture the actual CPU time spent in
 * the network bottom half -- same signal V2 reads from /proc/stat
 * and V3.1 captures via bpftrace tracepoints.
 *
 * Per-CPU keyed because softirqs are non-preemptible on a CPU, so the
 * entry/exit pair always lives on the same CPU.
 * ===================================================================== */

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, __u64);
} softirq_tx_start SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, __u64);
} softirq_rx_start SEC(".maps");

SEC("tracepoint/irq/softirq_entry")
int tp_softirq_entry(struct trace_event_raw_softirq *ctx)
{
    __u32 vec = BPF_CORE_READ(ctx, vec);
    if (vec != 2 && vec != 3) return 0;
    __u32 cpu = bpf_get_smp_processor_id();
    __u64 ts  = bpf_ktime_get_ns();
    if (vec == 2)
        bpf_map_update_elem(&softirq_tx_start, &cpu, &ts, BPF_ANY);
    else
        bpf_map_update_elem(&softirq_rx_start, &cpu, &ts, BPF_ANY);
    return 0;
}

SEC("tracepoint/irq/softirq_exit")
int tp_softirq_exit(struct trace_event_raw_softirq *ctx)
{
    __u32 vec = BPF_CORE_READ(ctx, vec);
    if (vec != 2 && vec != 3) return 0;
    __u32 cpu = bpf_get_smp_processor_id();
    __u64 now = bpf_ktime_get_ns();

    __u64 *start_ts;
    if (vec == 2)
        start_ts = bpf_map_lookup_elem(&softirq_tx_start, &cpu);
    else
        start_ts = bpf_map_lookup_elem(&softirq_rx_start, &cpu);
    if (!start_ts) return 0;
    __u64 delta = now - *start_ts;

    if (vec == 2)
        bpf_map_delete_elem(&softirq_tx_start, &cpu);
    else
        bpf_map_delete_elem(&softirq_rx_start, &cpu);

    /* softirqs run in interrupted context; current task is whoever was
     * preempted by the interrupt. Per-PID attribution is structurally
     * impossible at this site, so we only update agg_global. This
     * matches V3's per-event model: the netif_receive_skb event there
     * also lands under the interrupted task's PID approximately. */
    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;
    if (vec == 2) {
        __sync_fetch_and_add(&g->nets_tx_lat_ns_sum, delta);
        __sync_fetch_and_add(&g->nets_tx_lat_n, 1);
    } else {
        __sync_fetch_and_add(&g->nets_rx_lat_ns_sum, delta);
        __sync_fetch_and_add(&g->nets_rx_lat_n, 1);
    }
    return 0;
}

/* =====================================================================
 * llcmr -- LLC miss ratio via perf_event BPF programs
 *
 * Userspace opens two perf_event counters (HW_CACHE_L3 references and
 * misses) per CPU with a sample period and attaches these programs to
 * each. Each overflow increments llc_refs (or llc_misses) by
 * sample_period, so the ratio stays correct regardless of the period.
 *
 * NOTE on reading sample_period from ctx: BPF_CORE_READ() on
 * bpf_perf_event_data hits the wrong offset and returns 0 (verified
 * on V3 / Sapphire Rapids / kernel 6.8). Direct field access is the
 * verifier-blessed path.
 * ===================================================================== */

SEC("perf_event")
int perf_llc_refs(struct bpf_perf_event_data *ctx)
{
    if (!should_monitor_current()) return 0;

    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;
    __sync_fetch_and_add(&g->llc_refs, ctx->sample_period);

    if (!is_system_wide()) {
        __u32 tgid = bpf_get_current_pid_tgid() >> 32;
        struct intp_counters *p = agg_per_pid_slot(tgid);
        if (p) __sync_fetch_and_add(&p->llc_refs, ctx->sample_period);
    }
    return 0;
}

SEC("perf_event")
int perf_llc_misses(struct bpf_perf_event_data *ctx)
{
    if (!should_monitor_current()) return 0;

    struct intp_counters *g = agg_global_slot();
    if (!g) return 0;
    __sync_fetch_and_add(&g->llc_misses, ctx->sample_period);

    if (!is_system_wide()) {
        __u32 tgid = bpf_get_current_pid_tgid() >> 32;
        struct intp_counters *p = agg_per_pid_slot(tgid);
        if (p) __sync_fetch_and_add(&p->llc_misses, ctx->sample_period);
    }
    return 0;
}

/* =====================================================================
 * fork tracking -- keep descendant_tgids in sync with the workload tree
 *
 * Same semantics as V3: the parent's TGID is in the filter, so when it
 * forks, the child's TGID is added to descendant_tgids. exit removes
 * the thread-leader. Required for any workload that spawns children
 * after we attach (stress-ng --cache 24, Spark executors, etc.).
 * ===================================================================== */

SEC("tracepoint/sched/sched_process_fork")
int tp_sched_process_fork(struct trace_event_raw_sched_process_fork *ctx)
{
    struct intp_config *cfg = intp_cfg();
    if (!cfg || cfg->system_wide) return 0;

    __u32 parent_tgid = bpf_get_current_pid_tgid() >> 32;
    if (!pid_in_filter(cfg, parent_tgid)) return 0;

    __u32 child_tgid = (__u32)ctx->child_pid;
    __u8  one        = 1;
    bpf_map_update_elem(&descendant_tgids, &child_tgid, &one, BPF_ANY);
    return 0;
}

SEC("tracepoint/sched/sched_process_exit")
int tp_sched_process_exit(struct trace_event_raw_sched_process_template *ctx)
{
    (void)ctx;
    /* Process exit (vs. thread exit) is signalled by the leader exiting
     * last: leader has pid == tgid. Threads exiting earlier have
     * pid != tgid; ignore those so we keep the entry alive while
     * sibling threads are still running. */
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 pid  = (__u32)pt;
    if (pid != tgid) return 0;
    bpf_map_delete_elem(&descendant_tgids, &tgid);
    /* Also clean up the per-PID counter slot so the hash stays bounded. */
    bpf_map_delete_elem(&agg_per_pid, &tgid);
    return 0;
}

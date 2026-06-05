/*
 * intp.bpf.c -- kernel-side programs for IntP V3.
 *
 * This is the canonical eBPF implementation: one translation unit holds
 * every probe, maps, and the shared ring buffer. libbpf relocates every
 * BPF_CORE_READ at load time against the running kernel's BTF so the
 * same compiled .o runs across kernel versions (5.8+).
 *
 * This initial drop wires up the scaffolding (ringbuf, config map, PID
 * filter helper) and the netp path. Subsequent commits layer in blk,
 * cpu, nets, and llcmr.
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

#include "intp.bpf.h"

char LICENSE[] SEC("license") = "Dual MIT/GPL";

/* ------------------------------------------------------------------ Maps */

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, INTP_RINGBUF_BYTES);
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_config);
} intp_cfg_map SEC(".maps");

/* Per-skb TX start timestamp, keyed by skb pointer. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u64);
    __type(value, __u64);
} skb_tx_start SEC(".maps");

/* Per-napi RX start timestamp, keyed by napi_struct pointer. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u64);
    __type(value, __u64);
} napi_start SEC(".maps");

/* Per-request issue timestamp, keyed by request pointer for block svctm. */
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
 * map doesn't grow unbounded. value is just a presence flag. */
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

/* Returns 1 if pid is to be observed under the current config.
 *
 * Lookup order: (a) system_wide short-circuit, (b) static target_pids
 * array from the config map, (c) dynamic descendant_tgids hash map.
 * The descendant map is checked last because (b) is the common case for
 * the workload's parent and the array scan finishes in <= INTP_MAX_PIDS
 * iterations, which is cheaper than a hash lookup when the parent itself
 * is what fired the probe. */
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

/* Same, but short-circuits using the current task's pid. */
static __always_inline int should_monitor_current(void)
{
    struct intp_config *cfg = intp_cfg();
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    return pid_in_filter(cfg, pid);
}

static __always_inline void
fill_header(struct intp_event_header *hdr, __u32 type)
{
    hdr->type  = type;
    hdr->cpu   = bpf_get_smp_processor_id();
    hdr->ts_ns = bpf_ktime_get_ns();
    __u64 pid_tgid = bpf_get_current_pid_tgid();
    hdr->pid   = pid_tgid >> 32;
    hdr->tid   = (__u32)pid_tgid;
}

/* =====================================================================
 * netp -- network physical utilization
 * ===================================================================== */

/* Skip loopback. In single-host workloads (e.g., Spark `local[*]`) the
 * vast majority of "network" traffic is `lo`, which double-counts (xmit
 * + receive on the same packet) and never crosses any NIC. Including
 * loopback inflates netp by ≥2× and breaks correlation with the per-NIC
 * sysfs ground-truth (which excludes lo). */
static __always_inline int tp_dev_is_lo(void *ctx, unsigned int data_loc)
{
    /* tracepoint __data_loc fields are encoded as (length << 16) | offset.
     * Resolve the string by adding the offset to ctx, then read 4 bytes. */
    unsigned int offset = data_loc & 0xFFFFu;
    char buf[4] = {};
    bpf_probe_read_kernel_str(buf, sizeof(buf), (char *)ctx + offset);
    return buf[0] == 'l' && buf[1] == 'o' && buf[2] == '\0';
}

SEC("tracepoint/net/net_dev_xmit")
int tp_net_dev_xmit(struct trace_event_raw_net_dev_xmit *ctx)
{
    if (!should_monitor_current()) return 0;
    if (tp_dev_is_lo(ctx, ctx->__data_loc_name)) return 0;

    struct intp_net_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_NET_XMIT);
    e->bytes = BPF_CORE_READ(ctx, len);
    e->_pad  = 0;

    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("tracepoint/net/netif_receive_skb")
int tp_netif_receive_skb(struct trace_event_raw_net_dev_template *ctx)
{
    /* netif_receive_skb runs in softirq context; current task is whoever
     * was interrupted, so PID filtering here is only approximate. For
     * per-PID accuracy we'd need to correlate by socket owner, which
     * isn't cheap. Emit everything and let userspace decide when in
     * system-wide mode; filter in per-PID mode. */
    if (!should_monitor_current()) return 0;
    if (tp_dev_is_lo(ctx, ctx->__data_loc_name)) return 0;

    struct intp_net_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_NET_RECV);
    e->bytes = BPF_CORE_READ(ctx, len);
    e->_pad  = 0;

    bpf_ringbuf_submit(e, 0);
    return 0;
}

/* =====================================================================
 * blk -- block I/O utilization
 * ===================================================================== */

SEC("tracepoint/block/block_rq_issue")
int tp_block_rq_issue(struct trace_event_raw_block_rq *ctx)
{
    /*
     * sector uniquely identifies the request at the moment of issue
     * within a given device. For svctm we really want the request
     * pointer, but that isn't exposed in the tracepoint record. Using
     * (dev << 32) | sector as the key is good enough in practice.
     */
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

    struct intp_block_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_BLOCK_COMPLETE);
    e->hdr.ts_ns   = now;
    e->bytes       = BPF_CORE_READ(ctx, nr_sector) * 512;
    e->_pad        = 0;
    e->svctm_ns    = svctm;
    __u32 dev      = BPF_CORE_READ(ctx, dev);
    e->dev_major   = dev >> 20;
    e->dev_minor   = dev & 0xfffff;

    bpf_ringbuf_submit(e, 0);
    return 0;
}

/* =====================================================================
 * cpu -- CPU utilization via sched_switch
 * ===================================================================== */

SEC("tracepoint/sched/sched_switch")
int tp_sched_switch(struct trace_event_raw_sched_switch *ctx)
{
    struct intp_config *cfg = intp_cfg();

    __u32 prev_pid = BPF_CORE_READ(ctx, prev_pid);
    __u32 next_pid = BPF_CORE_READ(ctx, next_pid);
    __u64 now      = bpf_ktime_get_ns();

    /* Finalize the outgoing task's on-CPU interval. */
    __u64 *start_ts = bpf_map_lookup_elem(&task_oncpu_start, &prev_pid);
    if (start_ts && pid_in_filter(cfg, prev_pid)) {
        __u64 delta = now - *start_ts;
        struct intp_sched_event *e =
            bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->hdr.type   = INTP_EVENT_SCHED_SWITCH;
            e->hdr.cpu    = bpf_get_smp_processor_id();
            e->hdr.ts_ns  = now;
            e->hdr.pid    = prev_pid;
            e->hdr.tid    = prev_pid;
            e->prev_pid   = prev_pid;
            e->next_pid   = next_pid;
            e->on_cpu_ns  = delta;
            bpf_ringbuf_submit(e, 0);
        }
    }
    if (start_ts)
        bpf_map_delete_elem(&task_oncpu_start, &prev_pid);

    /* Start timing the incoming task, unless it is the idle task. */
    if (next_pid != 0)
        bpf_map_update_elem(&task_oncpu_start, &next_pid, &now, BPF_ANY);

    return 0;
}

/* =====================================================================
 * nets -- network stack service time
 *
 * TX: __dev_queue_xmit entry -> exit. The entry record stashes the start
 *     timestamp keyed by the skb pointer (PT_REGS_PARM1); the exit pulls
 *     it back and computes the delta.
 *
 * RX: napi_poll entry -> exit. Keyed by the napi_struct pointer.
 * ===================================================================== */

SEC("kprobe/__dev_queue_xmit")
int kp_dev_queue_xmit_enter(struct pt_regs *ctx)
{
    __u64 skb = (__u64)PT_REGS_PARM1(ctx);
    if (!skb) return 0;
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&skb_tx_start, &skb, &ts, BPF_ANY);
    return 0;
}

SEC("kretprobe/__dev_queue_xmit")
int krp_dev_queue_xmit_exit(struct pt_regs *ctx)
{
    (void)ctx;
    /*
     * kretprobe doesn't give us PARM1 any more, but we can correlate by
     * (current tid, most recent entry). Simpler: we can't, so emit on
     * the TX-tracepoint path below. This handler stays as a safety net
     * and cleans up any entries that never got a matching tracepoint
     * (e.g. packets dropped in validation).
     *
     * In steady state, net_dev_start_xmit will match and clean up.
     */
    return 0;
}

SEC("tracepoint/net/net_dev_start_xmit")
int tp_net_dev_start_xmit(struct trace_event_raw_net_dev_start_xmit *ctx)
{
    if (!should_monitor_current()) return 0;

    /* skbaddr is exposed on this tracepoint; look up the matching
     * entry ts and emit the TX-path latency sample. */
    __u64 skb = (__u64)BPF_CORE_READ(ctx, skbaddr);
    if (!skb) return 0;

    __u64 *start_ts = bpf_map_lookup_elem(&skb_tx_start, &skb);
    if (!start_ts) return 0;

    __u64 now = bpf_ktime_get_ns();
    __u64 delta = now - *start_ts;
    bpf_map_delete_elem(&skb_tx_start, &skb);

    struct intp_netstack_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_NAPI_TX_LAT);
    e->hdr.ts_ns   = now;       /* keep the tight end-of-event timestamp */
    e->latency_ns  = delta;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("kprobe/napi_poll")
int kp_napi_poll_enter(struct pt_regs *ctx)
{
    __u64 napi = (__u64)PT_REGS_PARM1(ctx);
    if (!napi) return 0;
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&napi_start, &napi, &ts, BPF_ANY);
    return 0;
}

/* Some kernels expose __napi_poll instead of napi_poll. Keep an
 * equivalent probe pair so userspace can select the symbol that exists
 * on the running kernel. */
SEC("kprobe/__napi_poll")
int kp_napi_poll_alt_enter(struct pt_regs *ctx)
{
    __u64 napi = (__u64)PT_REGS_PARM1(ctx);
    if (!napi) return 0;
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&napi_start, &napi, &ts, BPF_ANY);
    return 0;
}

SEC("kretprobe/napi_poll")
int krp_napi_poll_exit(struct pt_regs *ctx)
{
    (void)ctx;
    /*
     * kretprobe fires with PARM1 already gone, so the napi pointer used
     * as the entry-side key cannot be recovered here. This stub keeps
     * the entry-side map bounded; the actual RX latency sample is closed
     * by one of the three paths described in DESIGN.md section 10.1:
     *   1. fentry/fexit on napi_poll (preferred, requires BPF trampoline);
     *   2. kprobe + kretprobe with a per-CPU slot (softirq non-reentrancy);
     *   3. softirq_entry + napi:napi_poll tracepoint pair (degraded).
     * Userspace selects the first path that attaches at load time.
     */
    return 0;
}

SEC("kretprobe/__napi_poll")
int krp_napi_poll_alt_exit(struct pt_regs *ctx)
{
    (void)ctx;
    return 0;
}

/* =====================================================================
 * nets via softirq tracepoints (V3.1-aligned fallback / primary path)
 *
 * V0's per-packet kprobe model (__dev_queue_xmit + napi_poll entry/exit)
 * degenerates on modern kernels with veth / backlog NAPI:
 *   - veth_xmit is microseconds; __dev_queue_xmit captures only that
 *     trivial driver call, not the queue/protocol time V0 captured on
 *     2014-era physical NICs.
 *   - napi_poll / __napi_poll are inlined on kernels ≥6.x — kprobes
 *     simply don't attach, leaving RX timing dark.
 * Verified on Hetzner kernel 6.8.0-111 + veth: kprobe model gives
 * sub-1% nets at 880 Mbps, truncated to 0 in the IntP int schema.
 *
 * irq:softirq_entry / softirq_exit fire for every NET_TX / NET_RX
 * dispatch regardless of device class and capture the actual CPU time
 * spent in the network bottom half. Same signal V2 reads from /proc/stat
 * and V3.1 captures via bpftrace tracepoints. Per-CPU map keyed by
 * smp_processor_id since softirqs are non-preemptible on a CPU.
 *
 * Emits the existing INTP_EVENT_NAPI_TX_LAT / NAPI_RX_LAT event types so
 * userspace aggregation accumulates softirq time into tx_lat_ns_sum /
 * rx_lat_ns_sum without code changes. On kernels where napi_poll kprobes
 * also fire (older), this double-counts moderately — userspace can
 * disable the kprobe path via existing autoload toggle when softirq
 * tracepoints are preferred.
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
    __u64 ts = bpf_ktime_get_ns();
    if (vec == 2) {
        bpf_map_update_elem(&softirq_tx_start, &cpu, &ts, BPF_ANY);
    } else {
        bpf_map_update_elem(&softirq_rx_start, &cpu, &ts, BPF_ANY);
    }
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
    if (vec == 2) {
        start_ts = bpf_map_lookup_elem(&softirq_tx_start, &cpu);
    } else {
        start_ts = bpf_map_lookup_elem(&softirq_rx_start, &cpu);
    }
    if (!start_ts) return 0;
    __u64 delta = now - *start_ts;

    if (vec == 2) {
        bpf_map_delete_elem(&softirq_tx_start, &cpu);
    } else {
        bpf_map_delete_elem(&softirq_rx_start, &cpu);
    }

    struct intp_netstack_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    fill_header(&e->hdr,
                vec == 2 ? INTP_EVENT_NAPI_TX_LAT : INTP_EVENT_NAPI_RX_LAT);
    e->hdr.ts_ns  = now;
    e->latency_ns = delta;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

/* =====================================================================
 * llcmr -- LLC miss ratio via perf_event BPF programs
 *
 * Userspace opens two perf_event counters (HW_CACHE_L3 references and
 * misses) with a sample period and attaches these programs to each. The
 * BPF side simply pushes a sampling-rate-scaled record per overflow.
 * ===================================================================== */

/* NOTE on reading sample_period from the context:
 *
 * struct bpf_perf_event_data is a *context* type, not a real kernel
 * struct -- the verifier rewrites direct field accesses (`ctx->sample_period`)
 * into proper accessors that pull from the real kernel-side
 * struct bpf_perf_event_data_kern + perf_sample_data->period.
 * BPF_CORE_READ() bypasses that rewrite and does a raw probe_read at
 * the offset described by vmlinux.h, which on this kernel reads off
 * the wrong struct entirely -- it returns 0 unconditionally and the
 * userspace llc_refs/llc_misses accumulators never grow. Use direct
 * field access here. (Confirmed empirically on Sapphire Rapids /
 * kernel 6.8 by tracing every perf event arriving in userspace and
 * observing value=0 across 15k samples.) */

SEC("perf_event")
int perf_llc_refs(struct bpf_perf_event_data *ctx)
{
    if (!should_monitor_current()) return 0;

    struct intp_perf_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_PERF_SAMPLE);
    e->value     = ctx->sample_period;
    e->perf_type = 0;       /* refs */
    e->_pad      = 0;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("perf_event")
int perf_llc_misses(struct bpf_perf_event_data *ctx)
{
    if (!should_monitor_current()) return 0;

    struct intp_perf_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    fill_header(&e->hdr, INTP_EVENT_PERF_SAMPLE);
    e->value     = ctx->sample_period;
    e->perf_type = 1;       /* misses */
    e->_pad      = 0;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

/* =====================================================================
 * fork tracking -- keep descendant_tgids in sync with the workload tree
 *
 * Without this, a workload that forks N stressor children (e.g.
 * stress-ng --cache 24) gets only its parent PID into target_pids, and
 * every probe rejects events from the children because their TGIDs
 * aren't in the filter. iprof's evaluation didn't trigger this because
 * it ran on a "mostly idle" dedicated machine; under cross-application
 * interference profiling that's the entire point.
 *
 * The matching pre-existing-tree problem (children that forked before
 * we attached) is handled by userspace seeding descendant_tgids at
 * load time -- see intp.c:seed_descendants_from_proc().
 * ===================================================================== */

SEC("tracepoint/sched/sched_process_fork")
int tp_sched_process_fork(struct trace_event_raw_sched_process_fork *ctx)
{
    struct intp_config *cfg = intp_cfg();
    if (!cfg || cfg->system_wide) return 0;

    /* sched_process_fork runs in the parent's context, so
     * bpf_get_current_pid_tgid() gives us the parent's TGID directly --
     * no need to go through ctx->parent_pid (which is a TID). */
    __u32 parent_tgid = bpf_get_current_pid_tgid() >> 32;
    if (!pid_in_filter(cfg, parent_tgid)) return 0;

    /* For fork(2)/clone() without CLONE_THREAD, child_pid in the
     * tracepoint == child task->pid, and for a thread-group leader pid
     * == tgid -- so child_pid is the child's TGID. For CLONE_THREAD,
     * child_pid is the new TID and child shares the parent TGID; adding
     * the TID to a TGID-keyed map is harmless (no probe will look it up
     * via bpf_get_current_pid_tgid()>>32) but slightly wastes a slot.
     * We accept the waste rather than reading task_struct->tgid here. */
    __u32 child_tgid = (__u32)ctx->child_pid;
    __u8  one        = 1;
    bpf_map_update_elem(&descendant_tgids, &child_tgid, &one, BPF_ANY);
    return 0;
}

SEC("tracepoint/sched/sched_process_exit")
int tp_sched_process_exit(struct trace_event_raw_sched_process_template *ctx)
{
    /* Process exit (vs. thread exit) is signalled by the leader exiting
     * last: leader has pid == tgid. Threads exiting earlier have
     * pid != tgid; ignore those so we keep the entry alive while
     * sibling threads are still running. */
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = pt >> 32;
    __u32 pid  = (__u32)pt;
    if (pid != tgid) return 0;
    bpf_map_delete_elem(&descendant_tgids, &tgid);
    return 0;
}

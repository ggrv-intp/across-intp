/*
 * intp.bpf.h -- types shared between the BPF-side programs (intp.bpf.c)
 * and the userspace loader (intp.c).
 *
 * On the BPF side, __u32/__u64 come from vmlinux.h which the translation
 * unit has already included before this header. Userspace TUs get them
 * from <linux/types.h> instead; we pull that in here under the guard
 * below so callers don't have to remember.
 */

#ifndef INTP_BPF_H
#define INTP_BPF_H

#ifndef __VMLINUX_H__
#include <linux/types.h>
#endif

/* Kept small so the in-kernel PID filter loop stays under the 5.8 verifier's
 * instruction budget even on the first pass. Userspace may monitor more
 * PIDs via cgroup paths if needed. */
#define INTP_MAX_PIDS        64
#define INTP_RINGBUF_BYTES   (16 * 1024 * 1024)

enum intp_event_type {
    INTP_EVENT_NET_XMIT       = 1,
    INTP_EVENT_NET_RECV       = 2,
    INTP_EVENT_NAPI_TX_LAT    = 3,   /* kernel TX service time (ns)    */
    INTP_EVENT_NAPI_RX_LAT    = 4,   /* NAPI poll service time (ns)    */
    INTP_EVENT_BLOCK_COMPLETE = 5,
    INTP_EVENT_SCHED_SWITCH   = 6,
    INTP_EVENT_PERF_SAMPLE    = 7,   /* LLC refs/misses increment      */
};

/*
 * Every record starts with this header so the userspace consumer can
 * dispatch on type without knowing the sub-struct layout up front.
 */
struct intp_event_header {
    __u32 type;         /* enum intp_event_type         */
    __u32 cpu;
    __u64 ts_ns;        /* bpf_ktime_get_ns()           */
    __u32 pid;
    __u32 tid;
};

/* Network xmit / recv: raw byte count of one packet. */
struct intp_net_event {
    struct intp_event_header hdr;
    __u32 bytes;
    __u32 _pad;
};

/* Kernel TX/RX path latency sample. */
struct intp_netstack_event {
    struct intp_event_header hdr;
    __u64 latency_ns;
};

/* Block I/O completion: one request_queue round-trip. */
struct intp_block_event {
    struct intp_event_header hdr;
    __u32 bytes;
    __u32 _pad;
    __u64 svctm_ns;     /* issue -> complete service time */
    __u32 dev_major;
    __u32 dev_minor;
};

/* Per-task on-CPU time recorded at the sched_switch that ends it. */
struct intp_sched_event {
    struct intp_event_header hdr;
    __u32 prev_pid;
    __u32 next_pid;
    __u64 on_cpu_ns;
};

/* Each sample from an attached perf_event counter. */
struct intp_perf_event {
    struct intp_event_header hdr;
    __u64 value;            /* sample period (events per record)      */
    __u32 perf_type;        /* 0 = LLC refs, 1 = LLC misses           */
    __u32 _pad;
};

/*
 * Config map: userspace pushes one record into the single-entry array
 * before attaching programs. The BPF side reads it on every event.
 *
 *   system_wide = 1 -> monitor everything, ignore target_pids.
 *   system_wide = 0 -> only emit events whose current PID is in
 *                      target_pids[0 .. num_target_pids).
 */
struct intp_config {
    __u32 target_pids[INTP_MAX_PIDS];
    __u32 num_target_pids;
    __u8  system_wide;
    __u8  _pad0;
    __u16 _pad1;
};

#endif /* INTP_BPF_H */

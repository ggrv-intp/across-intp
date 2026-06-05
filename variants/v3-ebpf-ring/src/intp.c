/*
 * intp.c -- userspace main for IntP V3 (eBPF / CO-RE / libbpf).
 *
 * Responsibilities:
 *   1.  Parse CLI flags (intp_args.c).
 *   2.  Detect hardware/environment capabilities (detect.c).
 *   3.  Open the BPF skeleton, set ring-buffer size, load.
 *   4.  Push the target PID list into the config map.
 *   5.  Attach tracepoints and kprobes.
 *   6.  For llcmr: open PERF_TYPE_HW_CACHE counters per CPU and attach
 *       the perf_event BPF programs to them.
 *   7.  For mbw / llcocc: create a resctrl mon_group and assign PIDs.
 *   8.  Main loop: poll the ring buffer; every --interval seconds, emit
 *       a sample record (TSV / JSON / Prometheus) and reset counters.
 *   9.  On SIGINT/SIGTERM: tear everything down cleanly.
 *
 * Output format (default TSV) is byte-compatible with V0's intp.stp so
 * downstream consumers (IADA) need no changes.
 */

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <dirent.h>
#include <errno.h>
#include <linux/perf_event.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "intp.bpf.h"
#include "intp.skel.h"
#include "intp_args.h"

#include "../detect/detect.h"
#include "../resctrl/resctrl.h"

#define GROUP_NAME "intp-v3"

static volatile sig_atomic_t g_running = 1;
static void on_signal(int sig) { (void)sig; g_running = 0; }

static int kernel_has_symbol(const char *sym)
{
    FILE *f = fopen("/proc/kallsyms", "r");
    if (!f) return 0;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        /* format: <addr> <type> <name> */
        char name[256] = {0};
        if (sscanf(line, "%*s %*c %255s", name) == 1) {
            if (strcmp(name, sym) == 0) {
                fclose(f);
                return 1;
            }
        }
    }

    fclose(f);
    return 0;
}

/* Populate the descendant_tgids BPF map with every transitive descendant
 * of root_pid currently visible in /proc. Mirror of v3.1's
 * ResctrlReader._collect_descendants -- workloads such as stress-ng
 * --cache 24 fork their stressor children before the profiler attaches,
 * and without this seed the in-kernel PID filter rejects all child
 * activity. dir_fd-based traversal keeps the open-file count bounded.
 *
 * Returns the number of descendants successfully written into the map
 * (excluding root_pid itself, which is already in target_pids). */
static int seed_descendants_from_proc(int map_fd, pid_t root_pid, int verbose)
{
    if (map_fd < 0 || root_pid <= 0) return 0;

    /* BFS queue stays small since stress-ng-class workloads top out at
     * ~32 stressors and HiBench peaks ~few hundred Spark executor
     * threads (which share TGID anyway, so they collapse to one entry). */
    enum { QMAX = 4096 };
    pid_t queue[QMAX];
    int head = 0, tail = 0;
    queue[tail++] = root_pid;

    int written = 0;
    while (head < tail) {
        pid_t pid = queue[head++];

        char taskdir[64];
        snprintf(taskdir, sizeof(taskdir), "/proc/%d/task", (int)pid);
        DIR *td = opendir(taskdir);
        if (!td) continue;

        struct dirent *e;
        while ((e = readdir(td)) != NULL) {
            if (e->d_name[0] == '.') continue;
            /* Worst case: "/proc/" + INT_MIN (11 chars w/ sign) + "/task/"
             * + NAME_MAX (255) + "/children" + NUL = 288. Round up to
             * 320 to satisfy -Wformat-truncation under -Werror without
             * relying on the runtime fact that /proc/<pid>/task/<tid>
             * names are short numeric strings. */
            char children_path[320];
            snprintf(children_path, sizeof(children_path),
                     "/proc/%d/task/%s/children", (int)pid, e->d_name);
            FILE *cf = fopen(children_path, "r");
            if (!cf) continue;
            int child;
            while (fscanf(cf, "%d", &child) == 1) {
                if (child <= 0) continue;
                if (tail < QMAX) queue[tail++] = (pid_t)child;
                if (child == (int)root_pid) continue;
                __u32 key = (__u32)child;
                __u8  one = 1;
                if (bpf_map_update_elem(map_fd, &key, &one, BPF_ANY) == 0) {
                    written++;
                } else if (verbose) {
                    fprintf(stderr,
                            "warn: descendant_tgids update failed for tgid=%u: %s\n",
                            key, strerror(errno));
                }
            }
            fclose(cf);
        }
        closedir(td);
    }
    return written;
}

/* ------------------------------------------------------------------ state */

typedef struct {
    /* netp */
    unsigned long long tx_bytes;
    unsigned long long rx_bytes;
    /* nets */
    unsigned long long tx_lat_ns_sum;
    unsigned long long tx_lat_n;
    unsigned long long rx_lat_ns_sum;
    unsigned long long rx_lat_n;
    /* blk */
    unsigned long long blk_svctm_ns_sum;
    unsigned long long blk_ops;
    unsigned long long blk_bytes;
    /* cpu */
    unsigned long long cpu_on_ns_sum;
    /* llcmr */
    unsigned long long llc_refs;
    unsigned long long llc_misses;
    /* ring buffer loss bookkeeping */
    unsigned long long dropped_events;
} intp_state_t;

typedef struct {
    double netp;
    double nets;
    double blk;
    double mbw;
    double llcmr;
    double llcocc;
    double cpu;
} intp_sample_t;

/* ------------------------------------------------------------------ ring buffer */

static intp_state_t *g_state;    /* pointed to by handle_event ctx */
static int g_trace;

static const char *evt_name(__u32 t)
{
    switch (t) {
    case INTP_EVENT_NET_XMIT:       return "net_xmit";
    case INTP_EVENT_NET_RECV:       return "net_recv";
    case INTP_EVENT_NAPI_TX_LAT:    return "tx_lat";
    case INTP_EVENT_NAPI_RX_LAT:    return "rx_lat";
    case INTP_EVENT_BLOCK_COMPLETE: return "blk_done";
    case INTP_EVENT_SCHED_SWITCH:   return "sched";
    case INTP_EVENT_PERF_SAMPLE:    return "perf";
    default:                        return "?";
    }
}

static int handle_event(void *ctx, void *data, size_t size)
{
    (void)ctx;
    if (size < sizeof(struct intp_event_header)) return 0;
    struct intp_event_header *hdr = data;

    if (g_trace) {
        if (hdr->type == INTP_EVENT_PERF_SAMPLE
            && size >= sizeof(struct intp_perf_event)) {
            struct intp_perf_event *p = data;
            fprintf(stderr,
                    "[trace] %s pid=%u tid=%u cpu=%u ts=%llu value=%llu type=%u\n",
                    evt_name(hdr->type), hdr->pid, hdr->tid, hdr->cpu,
                    (unsigned long long)hdr->ts_ns,
                    (unsigned long long)p->value, p->perf_type);
        } else {
            fprintf(stderr, "[trace] %s pid=%u tid=%u cpu=%u ts=%llu\n",
                    evt_name(hdr->type), hdr->pid, hdr->tid, hdr->cpu,
                    (unsigned long long)hdr->ts_ns);
        }
    }

    switch (hdr->type) {
    case INTP_EVENT_NET_XMIT:
        if (size >= sizeof(struct intp_net_event))
            g_state->tx_bytes += ((struct intp_net_event *)data)->bytes;
        break;
    case INTP_EVENT_NET_RECV:
        if (size >= sizeof(struct intp_net_event))
            g_state->rx_bytes += ((struct intp_net_event *)data)->bytes;
        break;
    case INTP_EVENT_NAPI_TX_LAT:
        if (size >= sizeof(struct intp_netstack_event)) {
            g_state->tx_lat_ns_sum +=
                ((struct intp_netstack_event *)data)->latency_ns;
            g_state->tx_lat_n++;
        }
        break;
    case INTP_EVENT_NAPI_RX_LAT:
        if (size >= sizeof(struct intp_netstack_event)) {
            g_state->rx_lat_ns_sum +=
                ((struct intp_netstack_event *)data)->latency_ns;
            g_state->rx_lat_n++;
        }
        break;
    case INTP_EVENT_BLOCK_COMPLETE:
        if (size >= sizeof(struct intp_block_event)) {
            struct intp_block_event *b = data;
            g_state->blk_ops++;
            g_state->blk_bytes        += b->bytes;
            g_state->blk_svctm_ns_sum += b->svctm_ns;
        }
        break;
    case INTP_EVENT_SCHED_SWITCH:
        if (size >= sizeof(struct intp_sched_event))
            g_state->cpu_on_ns_sum +=
                ((struct intp_sched_event *)data)->on_cpu_ns;
        break;
    case INTP_EVENT_PERF_SAMPLE:
        if (size >= sizeof(struct intp_perf_event)) {
            struct intp_perf_event *p = data;
            if (p->perf_type == 0) g_state->llc_refs   += p->value;
            else                   g_state->llc_misses += p->value;
        }
        break;
    }
    return 0;
}

/* ------------------------------------------------------------------ perf_event for llcmr */

typedef struct {
    int *fds;
    int  n_fds;
    struct bpf_link **links;
} perf_attach_t;

static long sys_perf_event_open(struct perf_event_attr *a,
                                pid_t pid, int cpu, int group_fd,
                                unsigned long flags)
{
    return syscall(__NR_perf_event_open, a, pid, cpu, group_fd, flags);
}

static int open_cache_counters(struct bpf_program *prog,
                               unsigned long cache_result,
                               perf_attach_t *out,
                               int n_cpus, int verbose)
{
    out->fds   = calloc(n_cpus, sizeof(int));
    out->links = calloc(n_cpus, sizeof(struct bpf_link *));
    out->n_fds = 0;
    if (!out->fds || !out->links) return -1;

    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type   = PERF_TYPE_HW_CACHE;
    attr.size   = sizeof(attr);
    attr.config = (PERF_COUNT_HW_CACHE_LL)
                | (PERF_COUNT_HW_CACHE_OP_READ << 8)
                | (cache_result << 16);
    /* sample_period was 10000 — too high for cache-friendly workloads that
     * never accumulate enough events within the 1Hz sample interval, leaving
     * llcmr=0 even though the counter is being incremented. Lower to 1000
     * so even ~1k LLC events/sec triggers at least one BPF invocation per
     * interval. The accumulated value is still scaled by sample_period in
     * userspace, so the absolute count stays correct. */
    attr.sample_period = 1000;
    attr.wakeup_events = 1;
    attr.disabled      = 0;

    int opened = 0;
    for (int cpu = 0; cpu < n_cpus; cpu++) {
        int fd = (int)sys_perf_event_open(&attr, -1, cpu, -1, 0UL);
        if (fd < 0) {
            if (verbose)
                fprintf(stderr,
                        "warn: perf_event_open on cpu %d failed: %s\n",
                        cpu, strerror(errno));
            continue;
        }
        struct bpf_link *link = bpf_program__attach_perf_event(prog, fd);
        if (!link) {
            if (verbose)
                fprintf(stderr,
                        "warn: attach perf_event on cpu %d failed: %s\n",
                        cpu, strerror(errno));
            close(fd);
            continue;
        }
        out->fds[opened]   = fd;
        out->links[opened] = link;
        opened++;
    }
    out->n_fds = opened;
    return opened > 0 ? 0 : -1;
}

static void close_cache_counters(perf_attach_t *p)
{
    if (!p) return;
    for (int i = 0; i < p->n_fds; i++) {
        if (p->links[i]) bpf_link__destroy(p->links[i]);
        if (p->fds[i] >= 0) close(p->fds[i]);
    }
    free(p->fds);
    free(p->links);
    p->fds = NULL;
    p->links = NULL;
    p->n_fds = 0;
}

/* ------------------------------------------------------------------ cgroup -> PID list */

static int read_cgroup_pids(const char *cgroup, pid_t *out, int max)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/cgroup.procs", cgroup);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int n = 0, pid;
    while (n < max && fscanf(f, "%d", &pid) == 1) out[n++] = (pid_t)pid;
    fclose(f);
    return n;
}

/* ------------------------------------------------------------------ metric math */

static double safe_pct(double num, double den)
{
    if (den <= 0.0) return 0.0;
    double p = num / den * 100.0;
    if (p < 0.0)   p = 0.0;
    if (p > 100.0) p = 100.0;
    return p;
}

static void compute_sample(const intp_state_t *st,
                           const system_capabilities_t *caps,
                           double interval_sec,
                           int num_cores,
                           intp_sample_t *out)
{
    memset(out, 0, sizeof(*out));

    /* netp: (tx+rx bytes/sec) / max_nic_bps */
    long max_nic = caps->nic_speed_bps > 0 ? caps->nic_speed_bps : 125000000L;
    double bytes_per_sec = (double)(st->tx_bytes + st->rx_bytes) / interval_sec;
    out->netp = safe_pct(bytes_per_sec, (double)max_nic);

    /* nets: time spent in kernel network stack / interval */
    double net_lat_total = (double)(st->tx_lat_ns_sum + st->rx_lat_ns_sum);
    double interval_ns   = interval_sec * 1e9;
    out->nets = safe_pct(net_lat_total, interval_ns);

    /* blk: device-busy time / interval */
    out->blk = safe_pct((double)st->blk_svctm_ns_sum, interval_ns);

    /* cpu: sum(on-cpu-ns) / (interval * ncores) */
    double cpu_ns_available = interval_ns * (num_cores > 0 ? num_cores : 1);
    out->cpu = safe_pct((double)st->cpu_on_ns_sum, cpu_ns_available);

    /* llcmr: misses / refs */
    out->llcmr = safe_pct((double)st->llc_misses, (double)st->llc_refs);

    /* mbw and llcocc are filled in by the caller (need resctrl handle). */
}

/* ------------------------------------------------------------------ output */

static void emit_tsv_header(FILE *out,
                            const system_capabilities_t *caps,
                            int no_perf, int no_resctrl,
                            const char *nets_mode)
{
    fprintf(out,
        "# v3 ebpf-core -- netp:tracepoint nets:%s blk:tracepoint"
        " cpu:sched_switch llcmr:%s mbw:%s llcocc:%s\n",
        nets_mode,
        no_perf     ? "off" : "perf_event",
        no_resctrl  ? "off" : "resctrl",
        no_resctrl  ? "off" : "resctrl");
    fprintf(out, "# kernel %d.%d env=%s\n",
            caps->kernel_major, caps->kernel_minor,
            caps->env == ENV_CONTAINER ? "container" :
            caps->env == ENV_VM        ? "vm" : "bare-metal");
    fprintf(out, "netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n");
    fflush(out);
}

static void emit_tsv(FILE *out, const intp_sample_t *s)
{
    /* %02d formatting mirrors V0 (zero-padded integer percent). */
    fprintf(out, "%02d\t%02d\t%02d\t%02d\t%02d\t%02d\t%02d\n",
            (int)(s->netp   + 0.5),
            (int)(s->nets   + 0.5),
            (int)(s->blk    + 0.5),
            (int)(s->mbw    + 0.5),
            (int)(s->llcmr  + 0.5),
            (int)(s->llcocc + 0.5),
            (int)(s->cpu    + 0.5));
    fflush(out);
}

static void emit_json(FILE *out, const intp_sample_t *s, double t_sec)
{
    fprintf(out,
        "{\"t\":%.3f,\"netp\":%.2f,\"nets\":%.2f,\"blk\":%.2f,"
        "\"mbw\":%.2f,\"llcmr\":%.2f,\"llcocc\":%.2f,\"cpu\":%.2f}\n",
        t_sec, s->netp, s->nets, s->blk, s->mbw, s->llcmr, s->llcocc, s->cpu);
    fflush(out);
}

static void emit_prometheus(FILE *out, const intp_sample_t *s)
{
    fprintf(out,
        "intp_v3{metric=\"netp\"} %.2f\n"
        "intp_v3{metric=\"nets\"} %.2f\n"
        "intp_v3{metric=\"blk\"} %.2f\n"
        "intp_v3{metric=\"mbw\"} %.2f\n"
        "intp_v3{metric=\"llcmr\"} %.2f\n"
        "intp_v3{metric=\"llcocc\"} %.2f\n"
        "intp_v3{metric=\"cpu\"} %.2f\n",
        s->netp, s->nets, s->blk, s->mbw, s->llcmr, s->llcocc, s->cpu);
    fflush(out);
}

/* ------------------------------------------------------------------ main */

static int libbpf_quiet(enum libbpf_print_level lvl, const char *fmt, va_list ap)
{
    if (lvl == LIBBPF_WARN) return vfprintf(stderr, fmt, ap);
    return 0;
}

int main(int argc, char **argv)
{
    intp_args_t args;
    int r = intp_args_parse(argc, argv, &args);
    if (r == 1) return 0;
    if (r < 0)  return 1;

    system_capabilities_t caps;
    detect_all(&caps);

    /* Apply hardware overrides from CLI (0 = keep autodetected value). */
    if (args.nic_speed_bps_override > 0)
        caps.nic_speed_bps = args.nic_speed_bps_override;
    if (args.mem_bw_max_bps_override > 0)
        caps.mem_bw_max_bps = args.mem_bw_max_bps_override;
    if (args.llc_size_bytes_override > 0)
        caps.llc_size_bytes = args.llc_size_bytes_override;

    if (args.list_capabilities) {
        print_capabilities(&caps, stdout);
        return 0;
    }

    if (!args.verbose) libbpf_set_print(libbpf_quiet);

    /* If --cgroup was given, resolve its procs into the pid list (unless
     * --pids was also specified, which takes precedence). */
    if (args.cgroup && args.num_pids == 0) {
        args.num_pids = read_cgroup_pids(args.cgroup, args.pids, INTP_MAX_PIDS);
        if (args.num_pids == 0) {
            fprintf(stderr,
                "warning: no pids read from cgroup '%s' -- falling back to system-wide\n",
                args.cgroup);
        }
    }

    /* ------- open + load BPF skeleton ------- */
    struct intp_bpf *skel = intp_bpf__open();
    if (!skel) {
        fprintf(stderr, "failed to open BPF skeleton: %s\n", strerror(errno));
        return 1;
    }

    if (args.ringbuf_mib > 0) {
        bpf_map__set_max_entries(skel->maps.events,
                                 (unsigned int)(args.ringbuf_mib * 1024 * 1024));
    }

    if (args.no_perf_events) {
        bpf_program__set_autoload(skel->progs.perf_llc_refs,   false);
        bpf_program__set_autoload(skel->progs.perf_llc_misses, false);
    }

    /* Select exactly one NAPI RX kprobe target symbol when available.
     * Some kernels expose napi_poll, others __napi_poll, and forcing a
     * missing one causes intp_bpf__attach() to fail the whole profiler. */
    bpf_program__set_autoload(skel->progs.kp_napi_poll_enter,      false);
    bpf_program__set_autoload(skel->progs.krp_napi_poll_exit,      false);
    bpf_program__set_autoload(skel->progs.kp_napi_poll_alt_enter,  false);
    bpf_program__set_autoload(skel->progs.krp_napi_poll_alt_exit,  false);

    const char *nets_mode = "degraded(tx-only-no-napi-symbol)";
    int has_napi_poll = kernel_has_symbol("napi_poll");
    int has___napi_poll = kernel_has_symbol("__napi_poll");
    if (has_napi_poll) {
        bpf_program__set_autoload(skel->progs.kp_napi_poll_enter, true);
        bpf_program__set_autoload(skel->progs.krp_napi_poll_exit, true);
        nets_mode = "kprobe:napi_poll";
    } else if (has___napi_poll) {
        bpf_program__set_autoload(skel->progs.kp_napi_poll_alt_enter, true);
        bpf_program__set_autoload(skel->progs.krp_napi_poll_alt_exit, true);
        nets_mode = "kprobe:__napi_poll";
    } else if (args.verbose) {
        fprintf(stderr,
                "warn: neither napi_poll nor __napi_poll found; nets RX latency path disabled\n");
    }

    if (intp_bpf__load(skel)) {
        fprintf(stderr, "failed to load BPF: %s\n", strerror(errno));
        intp_bpf__destroy(skel);
        return 1;
    }

    /* ------- push config into the BPF map ------- */
    struct intp_config cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.system_wide      = args.num_pids == 0 ? 1 : 0;
    cfg.num_target_pids  = args.num_pids > INTP_MAX_PIDS
                              ? INTP_MAX_PIDS : args.num_pids;
    for (int i = 0; i < (int)cfg.num_target_pids; i++)
        cfg.target_pids[i] = (unsigned int)args.pids[i];

    unsigned int cfg_key = 0;
    if (bpf_map__update_elem(skel->maps.intp_cfg_map, &cfg_key, sizeof(cfg_key),
                             &cfg, sizeof(cfg), BPF_ANY) != 0) {
        fprintf(stderr, "failed to write intp_config: %s\n", strerror(errno));
        intp_bpf__destroy(skel);
        return 1;
    }

    /* ------- attach tracepoints / kprobes ------- */
    if (intp_bpf__attach(skel)) {
        fprintf(stderr, "failed to attach BPF programs: %s\n", strerror(errno));
        intp_bpf__destroy(skel);
        return 1;
    }

    /* ------- seed descendant_tgids from /proc -------
     * Pre-existing fork tree: children spawned before attach won't fire
     * the sched_process_fork tracepoint, so we walk /proc once here to
     * capture them. Skipped in system_wide mode where the filter is a
     * no-op anyway. */
    if (!cfg.system_wide && cfg.num_target_pids > 0) {
        int desc_fd = bpf_map__fd(skel->maps.descendant_tgids);
        int total = 0;
        for (__u32 i = 0; i < cfg.num_target_pids; i++) {
            total += seed_descendants_from_proc(
                desc_fd, (pid_t)cfg.target_pids[i], args.verbose);
        }
        if (args.verbose) {
            fprintf(stderr,
                    "info: descendant_tgids seeded with %d pre-existing tgid(s)\n",
                    total);
        }
    }

    /* ------- perf_event programs for llcmr ------- */
    perf_attach_t perf_refs = {0}, perf_miss = {0};
    if (!args.no_perf_events) {
        int n_cpus = detect_num_cores();
        if (open_cache_counters(skel->progs.perf_llc_refs,
                                PERF_COUNT_HW_CACHE_RESULT_ACCESS,
                                &perf_refs, n_cpus, args.verbose) != 0
            && args.verbose) {
            fprintf(stderr, "warn: no LLC-refs counters opened\n");
        }
        if (open_cache_counters(skel->progs.perf_llc_misses,
                                PERF_COUNT_HW_CACHE_RESULT_MISS,
                                &perf_miss, n_cpus, args.verbose) != 0
            && args.verbose) {
            fprintf(stderr, "warn: no LLC-miss counters opened\n");
        }
    }

    /* ------- resctrl for mbw / llcocc -------
     * With explicit --pid (or --cgroup): create our own mon_group and assign
     * those tasks. Counters reflect only the targeted workload.
     * Without targets (system-wide mode): point at the resctrl root group.
     * The root group already contains every task on the box by default, so
     * its mon_data measures aggregate bandwidth/occupancy across the whole
     * system — including any co-runner injecting interference. */
    resctrl_group_t *rg = NULL;
    if (!args.no_resctrl && caps.resctrl_usable) {
        if (args.num_pids > 0) {
            rg = resctrl_create_group(GROUP_NAME);
            if (rg && resctrl_assign_pid_threads(rg, args.pids, args.num_pids) != 0
                && args.verbose)
                fprintf(stderr, "warn: failed to assign PIDs to resctrl group\n");
        } else {
            rg = resctrl_use_root_group();
            if (!rg && args.verbose)
                fprintf(stderr, "warn: resctrl root group not readable; "
                                "mbw/llcocc will be 0\n");
        }
    }

    /* ------- ring buffer ------- */
    intp_state_t state;
    memset(&state, 0, sizeof(state));
    g_state = &state;
    g_trace = args.trace;

    struct ring_buffer *rb =
        ring_buffer__new(bpf_map__fd(skel->maps.events),
                         handle_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "failed to create ring_buffer: %s\n", strerror(errno));
        close_cache_counters(&perf_refs);
        close_cache_counters(&perf_miss);
        resctrl_destroy_group(rg);
        intp_bpf__destroy(skel);
        return 1;
    }

    /* ------- output header + main loop ------- */
    int is_tsv  = strcmp(args.output_fmt, "tsv") == 0;
    int is_json = strcmp(args.output_fmt, "json") == 0;
    int is_prom = strcmp(args.output_fmt, "prometheus") == 0;
    if (is_tsv && args.want_header)
        emit_tsv_header(stdout, &caps, args.no_perf_events, args.no_resctrl,
                        nets_mode);

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);

    struct timespec start, tick;
    clock_gettime(CLOCK_MONOTONIC, &start);
    tick = start;

    const long interval_ms = (long)(args.interval_sec * 1000.0);
    const int  poll_ms     = interval_ms < 200 ? (int)interval_ms : 200;

    while (g_running) {
        ring_buffer__poll(rb, poll_ms);

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double tick_elapsed = (double)(now.tv_sec  - tick.tv_sec)
                            + (double)(now.tv_nsec - tick.tv_nsec) / 1e9;
        if (tick_elapsed < args.interval_sec) continue;

        intp_sample_t sample;
        compute_sample(&state, &caps, tick_elapsed, caps.num_cores, &sample);

        if (rg) {
            sample.mbw    = resctrl_read_mbm_delta(rg, &caps, tick_elapsed);
            sample.llcocc = resctrl_read_llcocc(rg, &caps);
        }

        if (is_tsv)  emit_tsv(stdout, &sample);
        if (is_json) {
            double t = (double)(now.tv_sec  - start.tv_sec)
                     + (double)(now.tv_nsec - start.tv_nsec) / 1e9;
            emit_json(stdout, &sample, t);
        }
        if (is_prom) emit_prometheus(stdout, &sample);

        memset(&state, 0, sizeof(state));
        tick = now;

        if (args.duration_sec > 0.0) {
            double run = (double)(now.tv_sec  - start.tv_sec)
                       + (double)(now.tv_nsec - start.tv_nsec) / 1e9;
            if (run >= args.duration_sec) break;
        }
    }

    /* ------- cleanup ------- */
    ring_buffer__free(rb);
    close_cache_counters(&perf_refs);
    close_cache_counters(&perf_miss);
    resctrl_destroy_group(rg);
    intp_bpf__destroy(skel);
    return 0;
}

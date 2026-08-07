/*
 * intp_agg.c -- userspace main for IntP V3.2.
 *
 * V3.2 has no per-event records. The kernel side accumulates everything
 * into per-CPU and per-PID counter maps; the main loop here is just
 * "sleep --interval, read maps, compute deltas, emit one TSV row." No
 * ring_buffer__poll, no event handler dispatch, no consumer-wakeup loop.
 * That structural change is what is supposed to eliminate the
 * 194-416x context-switch amplification V3 incurs (paper §V-B).
 *
 * Lifecycle:
 *   1.  Parse CLI flags (intp_agg_args.c).
 *   2.  Detect hardware/environment capabilities (detect.c).
 *   3.  Open the BPF skeleton, push config, load.
 *   4.  Attach tracepoints (and, in C05+, kprobes / perf_event probes).
 *   5.  For mbw / llcocc: create a resctrl mon_group, assign PIDs.
 *   6.  Main loop: clock_nanosleep --interval, snapshot agg_global,
 *       diff against previous, emit one row.
 *   7.  On SIGINT/SIGTERM: tear everything down cleanly.
 *
 * Output format mirrors V3 (TSV column order netp/nets/blk/mbw/llcmr/
 * llcocc/cpu) so downstream consumers (IADA) need no changes. C07
 * adds the trailing mbw_raw_mbps column.
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

#include "intp_agg.bpf.h"
#include "intp_agg.skel.h"
#include "intp_agg_args.h"

#include "../detect/detect.h"
#include "../resctrl/resctrl.h"

#define GROUP_NAME "intp-v3.2"

static volatile sig_atomic_t g_running = 1;
static void on_signal(int sig) { (void)sig; g_running = 0; }

/* ------------------------------------------------------------------ /proc walker */

/* Populate descendant_tgids with every transitive descendant of root_pid
 * currently visible in /proc. Mirror of V3 seed_descendants_from_proc(). */
static int seed_descendants_from_proc(int map_fd, pid_t root_pid, int verbose)
{
    if (map_fd < 0 || root_pid <= 0) return 0;

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
    out->fds   = calloc((size_t)n_cpus, sizeof(int));
    out->links = calloc((size_t)n_cpus, sizeof(struct bpf_link *));
    out->n_fds = 0;
    if (!out->fds || !out->links) return -1;

    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type   = PERF_TYPE_HW_CACHE;
    attr.size   = sizeof(attr);
    attr.config = (PERF_COUNT_HW_CACHE_LL)
                | (PERF_COUNT_HW_CACHE_OP_READ << 8)
                | (cache_result << 16);
    /* Match V3: sample_period 1000 so even ~1k LLC events/sec trigger
     * at least one BPF invocation per interval. Accumulator scales by
     * sample_period in the kernel-side increment, so the absolute count
     * stays correct. */
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

/* ------------------------------------------------------------------ aggregate snapshot */

/* Read agg_global across all CPUs and sum into out. The PERCPU_ARRAY
 * lookup returns one struct intp_counters per possible CPU; we never
 * zero those slots (probes are atomic; clearing under them is racy and
 * unnecessary because userspace tracks the previous snapshot). */
static int read_global_aggregate(struct intp_agg_bpf *skel,
                                 struct intp_counters *out)
{
    int n_cpus = libbpf_num_possible_cpus();
    if (n_cpus <= 0) return -1;

    struct intp_counters *per_cpu = calloc((size_t)n_cpus, sizeof(*per_cpu));
    if (!per_cpu) return -1;

    __u32 key = 0;
    int fd = bpf_map__fd(skel->maps.agg_global);
    if (bpf_map_lookup_elem(fd, &key, per_cpu) != 0) {
        free(per_cpu);
        return -1;
    }

    memset(out, 0, sizeof(*out));
    for (int i = 0; i < n_cpus; i++) {
        out->netp_tx_bytes      += per_cpu[i].netp_tx_bytes;
        out->netp_rx_bytes      += per_cpu[i].netp_rx_bytes;
        out->nets_tx_lat_ns_sum += per_cpu[i].nets_tx_lat_ns_sum;
        out->nets_tx_lat_n      += per_cpu[i].nets_tx_lat_n;
        out->nets_rx_lat_ns_sum += per_cpu[i].nets_rx_lat_ns_sum;
        out->nets_rx_lat_n      += per_cpu[i].nets_rx_lat_n;
        out->blk_svctm_ns_sum   += per_cpu[i].blk_svctm_ns_sum;
        out->blk_ops            += per_cpu[i].blk_ops;
        out->blk_bytes          += per_cpu[i].blk_bytes;
        out->cpu_on_ns_sum      += per_cpu[i].cpu_on_ns_sum;
        out->llc_refs           += per_cpu[i].llc_refs;
        out->llc_misses         += per_cpu[i].llc_misses;
    }
    free(per_cpu);
    return 0;
}

/* delta = cur - prev, field-by-field, saturating on underflow (can
 * happen if cur was read while a probe was mid-add on another CPU --
 * extremely rare in practice; saturate to 0 instead of negative). */
static void counters_diff(const struct intp_counters *cur,
                          const struct intp_counters *prev,
                          struct intp_counters *delta)
{
#define SUB(field) \
    delta->field = (cur->field >= prev->field) ? (cur->field - prev->field) : 0
    SUB(netp_tx_bytes);
    SUB(netp_rx_bytes);
    SUB(nets_tx_lat_ns_sum);
    SUB(nets_tx_lat_n);
    SUB(nets_rx_lat_ns_sum);
    SUB(nets_rx_lat_n);
    SUB(blk_svctm_ns_sum);
    SUB(blk_ops);
    SUB(blk_bytes);
    SUB(cpu_on_ns_sum);
    SUB(llc_refs);
    SUB(llc_misses);
#undef SUB
}

/* ------------------------------------------------------------------ metric math */

typedef struct {
    double netp;
    double nets;
    double blk;
    double mbw;          /* % normalized */
    double llcmr;
    double llcocc;
    double cpu;
    double mbw_raw_mbps; /* paralleled in C07 -- 0.0 until then */
} intp_sample_t;

static double safe_pct(double num, double den)
{
    if (den <= 0.0) return 0.0;
    double p = num / den * 100.0;
    if (p < 0.0)   p = 0.0;
    if (p > 100.0) p = 100.0;
    return p;
}

static void compute_sample(const struct intp_counters *d,
                           const system_capabilities_t *caps,
                           double interval_sec,
                           int num_cores,
                           intp_sample_t *out)
{
    memset(out, 0, sizeof(*out));

    long max_nic = caps->nic_speed_bps > 0 ? caps->nic_speed_bps : 125000000L;
    double bytes_per_sec =
        (double)(d->netp_tx_bytes + d->netp_rx_bytes) / interval_sec;
    out->netp = safe_pct(bytes_per_sec, (double)max_nic);

    double net_lat_total =
        (double)(d->nets_tx_lat_ns_sum + d->nets_rx_lat_ns_sum);
    double interval_ns   = interval_sec * 1e9;
    out->nets = safe_pct(net_lat_total, interval_ns);

    out->blk = safe_pct((double)d->blk_svctm_ns_sum, interval_ns);

    double cpu_ns_available = interval_ns * (num_cores > 0 ? num_cores : 1);
    out->cpu = safe_pct((double)d->cpu_on_ns_sum, cpu_ns_available);

    out->llcmr = safe_pct((double)d->llc_misses, (double)d->llc_refs);

    /* mbw / llcocc filled by caller (resctrl handle). */
}

/* ------------------------------------------------------------------ output */

static void emit_tsv_header(FILE *out,
                            const system_capabilities_t *caps,
                            int no_perf, int no_resctrl,
                            int no_raw_mbw, int clip_mbw)
{
    fprintf(out,
        "# v3.2 eBPF-COREregate -- netp:tracepoint nets:softirq blk:tracepoint"
        " cpu:sched_switch llcmr:%s mbw:%s llcocc:%s\n",
        no_perf     ? "off" : "perf_event",
        no_resctrl  ? "off" : "resctrl",
        no_resctrl  ? "off" : "resctrl");
    fprintf(out, "# kernel %d.%d env=%s\n",
            caps->kernel_major, caps->kernel_minor,
            caps->env == ENV_CONTAINER ? "container" :
            caps->env == ENV_VM        ? "vm" : "bare-metal");
    fprintf(out, "# mbw_pct = (mbm_total_bytes_delta / interval) / "
                 "mem_bw_max_bps * 100  (clip_mbw=%s)\n",
            clip_mbw ? "on (legacy V3 cap-at-99)" : "off (raw, may exceed 100)");
    if (!no_raw_mbw)
        fprintf(out, "# mbw_raw_mbps = (mbm_total_bytes_delta / interval) "
                     "/ 1e6  (diagnostic, see docs/V3-OVERHEAD-FINDINGS.md §3)\n");
    if (no_raw_mbw)
        fprintf(out, "netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\n");
    else
        fprintf(out, "netp\tnets\tblk\tmbw\tllcmr\tllcocc\tcpu\tmbw_raw_mbps\n");
    fflush(out);
}

static void emit_tsv(FILE *out, const intp_sample_t *s, int no_raw_mbw)
{
    fprintf(out, "%02d\t%02d\t%02d\t%02d\t%02d\t%02d\t%02d",
            (int)(s->netp   + 0.5),
            (int)(s->nets   + 0.5),
            (int)(s->blk    + 0.5),
            (int)(s->mbw    + 0.5),
            (int)(s->llcmr  + 0.5),
            (int)(s->llcocc + 0.5),
            (int)(s->cpu    + 0.5));
    if (!no_raw_mbw)
        fprintf(out, "\t%.0f", s->mbw_raw_mbps);
    fputc('\n', out);
    fflush(out);
}

static void emit_json(FILE *out, const intp_sample_t *s, double t_sec,
                      int no_raw_mbw)
{
    fprintf(out,
        "{\"t\":%.3f,\"netp\":%.2f,\"nets\":%.2f,\"blk\":%.2f,"
        "\"mbw\":%.2f,\"llcmr\":%.2f,\"llcocc\":%.2f,\"cpu\":%.2f",
        t_sec, s->netp, s->nets, s->blk, s->mbw, s->llcmr, s->llcocc, s->cpu);
    if (!no_raw_mbw)
        fprintf(out, ",\"mbw_raw_mbps\":%.2f", s->mbw_raw_mbps);
    fprintf(out, "}\n");
    fflush(out);
}

static void emit_prometheus(FILE *out, const intp_sample_t *s, int no_raw_mbw)
{
    fprintf(out,
        "intp_v3_2{metric=\"netp\"} %.2f\n"
        "intp_v3_2{metric=\"nets\"} %.2f\n"
        "intp_v3_2{metric=\"blk\"} %.2f\n"
        "intp_v3_2{metric=\"mbw\"} %.2f\n"
        "intp_v3_2{metric=\"llcmr\"} %.2f\n"
        "intp_v3_2{metric=\"llcocc\"} %.2f\n"
        "intp_v3_2{metric=\"cpu\"} %.2f\n",
        s->netp, s->nets, s->blk, s->mbw, s->llcmr, s->llcocc, s->cpu);
    if (!no_raw_mbw)
        fprintf(out, "intp_v3_2{metric=\"mbw_raw_mbps\"} %.2f\n",
                s->mbw_raw_mbps);
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

    /* --cgroup resolves into the pid list unless --pids overrides. */
    if (args.cgroup && args.num_pids == 0) {
        args.num_pids = read_cgroup_pids(args.cgroup, args.pids, INTP_MAX_PIDS);
        if (args.num_pids == 0) {
            fprintf(stderr,
                "warning: no pids read from cgroup '%s' -- falling back to system-wide\n",
                args.cgroup);
        }
    }

    /* ------- open + load BPF skeleton ------- */
    struct intp_agg_bpf *skel = intp_agg_bpf__open();
    if (!skel) {
        fprintf(stderr, "failed to open BPF skeleton: %s\n", strerror(errno));
        return 1;
    }

    if (args.no_perf_events) {
        bpf_program__set_autoload(skel->progs.perf_llc_refs,   false);
        bpf_program__set_autoload(skel->progs.perf_llc_misses, false);
    }

    if (intp_agg_bpf__load(skel)) {
        fprintf(stderr, "failed to load BPF: %s\n", strerror(errno));
        intp_agg_bpf__destroy(skel);
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
        intp_agg_bpf__destroy(skel);
        return 1;
    }

    /* ------- attach tracepoints ------- */
    if (intp_agg_bpf__attach(skel)) {
        fprintf(stderr, "failed to attach BPF programs: %s\n", strerror(errno));
        intp_agg_bpf__destroy(skel);
        return 1;
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

    /* ------- seed descendant_tgids from /proc ------- */
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

    /* ------- resctrl for mbw / llcocc -------
     * Same selection logic as V3: targeted -> own mon_group, system-wide
     * -> root group. */
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

    /* ------- output header ------- */
    int is_tsv  = strcmp(args.output_fmt, "tsv") == 0;
    int is_json = strcmp(args.output_fmt, "json") == 0;
    int is_prom = strcmp(args.output_fmt, "prometheus") == 0;
    if (is_tsv && args.want_header)
        emit_tsv_header(stdout, &caps, args.no_perf_events, args.no_resctrl,
                        args.no_raw_mbw, args.clip_mbw);

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* ------- main polling loop ------- */
    int mbw_warned = 0;
    struct intp_counters prev = {0}, cur = {0};
    if (read_global_aggregate(skel, &prev) != 0) {
        fprintf(stderr, "failed to read agg_global: %s\n", strerror(errno));
        resctrl_destroy_group(rg);
        intp_agg_bpf__destroy(skel);
        return 1;
    }
    struct timespec start, prev_t, now_t;
    clock_gettime(CLOCK_MONOTONIC, &start);
    prev_t = start;

    while (g_running) {
        struct timespec wait = {
            .tv_sec  = (time_t)args.interval_sec,
            .tv_nsec = (long)((args.interval_sec
                              - (double)(time_t)args.interval_sec) * 1e9)
        };
        if (wait.tv_sec == 0 && wait.tv_nsec == 0) wait.tv_nsec = 1000000;
        while (nanosleep(&wait, &wait) < 0 && errno == EINTR && g_running)
            continue;
        if (!g_running) break;

        if (read_global_aggregate(skel, &cur) != 0) break;
        clock_gettime(CLOCK_MONOTONIC, &now_t);

        double interval_real = (double)(now_t.tv_sec  - prev_t.tv_sec)
                             + (double)(now_t.tv_nsec - prev_t.tv_nsec) * 1e-9;
        if (interval_real <= 0.0) interval_real = args.interval_sec;

        struct intp_counters delta;
        counters_diff(&cur, &prev, &delta);

        intp_sample_t sample;
        compute_sample(&delta, &caps, interval_real, caps.num_cores, &sample);

        if (rg) {
            double pct = 0.0, raw = 0.0;
            resctrl_read_mbm_pct_and_raw(rg, &caps, interval_real,
                                         args.clip_mbw, &pct, &raw);
            sample.mbw          = pct;
            sample.mbw_raw_mbps = raw;
            sample.llcocc       = resctrl_read_llcocc(rg, &caps);

            /* Warn-once when the unclipped percent exceeds 100. Either
             * mem_bw_max_bps is misconfigured (the systematic V3 bug
             * documented in docs/V3-OVERHEAD-FINDINGS.md §3) or sustained DDR throughput is
             * genuinely above the configured ceiling. Either way the
             * analyst needs to recheck --mem-bw-max-bps; we keep
             * emitting the raw value so they can. */
            if (!args.clip_mbw && pct > 100.0 && !mbw_warned) {
                fprintf(stderr,
                    "warn: mbw exceeded ceiling at t=%.2fs "
                    "(raw=%.0f MB/s, ceiling=%ld MB/s) "
                    "-- recheck --mem-bw-max-bps\n",
                    (double)(now_t.tv_sec - start.tv_sec) +
                    (double)(now_t.tv_nsec - start.tv_nsec) / 1e9,
                    raw,
                    caps.mem_bw_max_bps / 1000000L);
                mbw_warned = 1;
            }
        }

        if (is_tsv)  emit_tsv(stdout, &sample, args.no_raw_mbw);
        if (is_json) {
            double t = (double)(now_t.tv_sec  - start.tv_sec)
                     + (double)(now_t.tv_nsec - start.tv_nsec) / 1e9;
            emit_json(stdout, &sample, t, args.no_raw_mbw);
        }
        if (is_prom) emit_prometheus(stdout, &sample, args.no_raw_mbw);

        prev   = cur;
        prev_t = now_t;

        if (args.duration_sec > 0.0) {
            double run = (double)(now_t.tv_sec  - start.tv_sec)
                       + (double)(now_t.tv_nsec - start.tv_nsec) / 1e9;
            if (run >= args.duration_sec) break;
        }
    }

    /* ------- cleanup ------- */
    close_cache_counters(&perf_refs);
    close_cache_counters(&perf_miss);
    resctrl_destroy_group(rg);
    intp_agg_bpf__destroy(skel);
    return 0;
}

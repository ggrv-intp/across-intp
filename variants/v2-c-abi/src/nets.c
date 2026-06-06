/*
 * nets.c -- network stack utilization (always DEGRADED).
 *
 *   1. nets_softirqs   /proc/softirqs NET_TX+NET_RX delta combined with
 *                      /proc/stat softirq jiffies. Estimates the fraction
 *                      of CPU time spent processing network softirqs.
 *   2. nets_throughput /proc/net/dev throughput * fixed per-packet service
 *                      time (1us/packet typical). Coarser approximation.
 *
 * IntP V0 measures this via kprobes on dev_queue_xmit and napi paths to
 * get true per-packet service time. V2 cannot replicate that without
 * kernel instrumentation; both backends are documented approximations
 * and report status=DEGRADED.
 */

#include "backend.h"
#include "detect.h"
#include "procutil.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---- backend 1: softirq-time fraction ---------------------------------- */

static struct {
    int           valid;
    unsigned long prev_net_tx;
    unsigned long prev_net_rx;
    unsigned long prev_total_softirqs;     /* sum of all softirq columns... */
    /* /proc/stat does not split softirq time per-vector, so we approximate
     * by scaling system softirq jiffies by the (NET_TX+NET_RX)/all ratio
     * derived from /proc/softirqs counts. */
    unsigned long prev_softirq_jiffies;
    unsigned long prev_total_jiffies;
} sf;

static int read_softirq_jiffies(unsigned long *out, unsigned long *total)
{
    /* /proc/stat fields after "cpu  ":
     *  user nice system idle iowait irq softirq steal guest guest_nice
     *  index  0    1    2    3     4    5     6     7     8     9         */
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return -1;
    char line[512];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    fclose(f);
    unsigned long u, ni, sy, id, io, ir, sf2, st, gu, gn;
    int n = sscanf(line, "cpu  %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
                   &u, &ni, &sy, &id, &io, &ir, &sf2, &st, &gu, &gn);
    if (n < 7) return -1;
    if (n < 8)  st = 0;
    if (n < 9)  gu = 0;
    if (n < 10) gn = 0;
    *out   = sf2;
    *total = u + ni + sy + id + io + ir + sf2 + st + gu + gn;
    return 0;
}

/* Read total softirq count from the "TOTAL" row when present (recent kernels)
 * or by approximation: sum of NET_TX+NET_RX is enough to know the *fraction*. */
static int sum_all_softirqs(unsigned long *total_count)
{
    FILE *f = fopen("/proc/softirqs", "r");
    if (!f) return -1;
    char line[8192];
    unsigned long total = 0;
    /* skip header */
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    while (fgets(line, sizeof(line), f)) {
        const char *p = strchr(line, ':');
        if (!p) continue;
        p++;
        while (*p) {
            while (*p == ' ' || *p == '\t') p++;
            if (!*p || *p == '\n') break;
            char *end;
            unsigned long v = strtoul(p, &end, 10);
            if (end == p) break;
            total += v;
            p = end;
        }
    }
    fclose(f);
    *total_count = total;
    return 0;
}

static int softirq_probe(void)
{
    FILE *f = fopen("/proc/softirqs", "r");
    if (!f) return -1;
    fclose(f);
    f = fopen("/proc/stat", "r");
    if (!f) return -1;
    fclose(f);
    return 0;
}

static int softirq_init(void)
{
    if (procutil_read_net_softirqs(&sf.prev_net_tx, &sf.prev_net_rx) != 0)
        return -1;
    if (sum_all_softirqs(&sf.prev_total_softirqs) != 0) return -1;
    if (read_softirq_jiffies(&sf.prev_softirq_jiffies,
                             &sf.prev_total_jiffies) != 0) return -1;
    sf.valid = 1;
    return 0;
}

static int softirq_read(metric_sample_t *out, double interval_sec)
{
    if (!sf.valid || interval_sec <= 0) return -1;
    unsigned long net_tx = 0, net_rx = 0;
    unsigned long total_si = 0, sj = 0, tj = 0;
    if (procutil_read_net_softirqs(&net_tx, &net_rx) != 0) return -1;
    if (sum_all_softirqs(&total_si) != 0) return -1;
    if (read_softirq_jiffies(&sj, &tj) != 0) return -1;

    unsigned long d_net   = (net_tx + net_rx)
                           - (sf.prev_net_tx + sf.prev_net_rx);
    unsigned long d_total = total_si - sf.prev_total_softirqs;
    unsigned long d_sj    = sj - sf.prev_softirq_jiffies;
    unsigned long d_tj    = tj - sf.prev_total_jiffies;

    sf.prev_net_tx          = net_tx;
    sf.prev_net_rx          = net_rx;
    sf.prev_total_softirqs  = total_si;
    sf.prev_softirq_jiffies = sj;
    sf.prev_total_jiffies   = tj;

    double net_fraction = (d_total > 0)
        ? (double)d_net / (double)d_total : 0.0;
    /* /proc/stat aggregates jiffies across all CPUs (line "cpu " is the sum),
     * so d_sj/d_tj is already system-wide-normalized to [0..1] regardless of
     * core count. To align the metric with V0 (which sums per-event service
     * time across all CPUs without dividing by num_cores), multiply by the
     * core count — recovering total CPU-seconds-in-softirq comparable to V0's
     * cumulative latency model. */
    int num_cores = detect_cached()->num_cores;
    if (num_cores <= 0) num_cores = 1;
    double softirq_pct  = (d_tj > 0)
        ? (double)d_sj / (double)d_tj * 100.0 * (double)num_cores : 0.0;

    double v = net_fraction * softirq_pct;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_DEGRADED;
    out->backend_id = "procfs_softirq";
    out->note       = "approximation_no_kprobes";
    return 0;
}

static void softirq_cleanup(void) { sf.valid = 0; }

/* ---- backend 2: throughput * fixed per-packet service time ------------- */

static struct {
    int                valid;
    unsigned long      prev_packets_sum;
    int                num_cores;
} tp;

/* True if the interface should be excluded from the aggregate.
 *
 * For *stack* utilization we WANT loopback (HDFS pseudo-distributed, single-host
 * IPC, container --network=host) — those packets do go through the network
 * stack and consume softirq/NAPI time. Bridges and veths still get filtered
 * because their packets are already counted on the underlying physical NIC. */
static int iface_is_virtual(const char *name)
{
    if (!name || !name[0]) return 1;
    if (strncmp(name, "docker", 6) == 0) return 1;
    if (strncmp(name, "br-",    3) == 0) return 1;
    if (strncmp(name, "virbr",  5) == 0) return 1;
    if (strncmp(name, "veth",   4) == 0) return 1;
    return 0;
}

static int sum_phys_packets(unsigned long *out_sum)
{
    netdev_entry_t es[32];
    int n = procutil_read_netdev(es, 32);
    if (n < 0) return -1;
    unsigned long sum = 0;
    for (int i = 0; i < n; i++) {
        if (iface_is_virtual(es[i].iface)) continue;
        sum += es[i].rx_packets + es[i].tx_packets;
    }
    *out_sum = sum;
    return 0;
}

static int throughput_probe(void)
{
    /* Usable whenever /proc/net/dev is readable (any Linux). */
    netdev_entry_t e[1];
    return procutil_read_netdev(e, 1) >= 0 ? 0 : -1;
}

static int throughput_init(void)
{
    if (sum_phys_packets(&tp.prev_packets_sum) != 0) return -1;
    tp.num_cores = detect_cached()->num_cores;
    if (tp.num_cores <= 0) tp.num_cores = 1;
    tp.valid = 1;
    return 0;
}

static int throughput_read(metric_sample_t *out, double interval_sec)
{
    if (!tp.valid || interval_sec <= 0) return -1;
    unsigned long pkts = 0;
    if (sum_phys_packets(&pkts) != 0) return -1;
    long delta = (long)(pkts - tp.prev_packets_sum);
    tp.prev_packets_sum = pkts;
    if (delta < 0) delta = 0;

    /* Assume 1 microsecond of CPU service time per packet. Total CPU-seconds
     * spent processing packets in 1s = pps * 1e-6. Express as percent of one
     * second-of-CPU-time = pps * 1e-6 * 100. Aligned with V0: do NOT divide
     * by num_cores — the metric represents cumulative wall-clock spent in
     * the network stack summed across all CPUs (matches V0 net stack util). */
    double pps          = (double)delta / interval_sec;
    double v            = pps * 1.0e-6 * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_DEGRADED;
    out->backend_id = "procfs_throughput";
    out->note       = "throughput_estimate";
    return 0;
}

static void throughput_cleanup(void) { tp.valid = 0; }

static backend_t b_softirq = {
    .backend_id  = "procfs_softirq",
    .description = "/proc/softirqs NET_TX+NET_RX fraction of /proc/stat softirq time",
    .probe = softirq_probe, .init = softirq_init,
    .read  = softirq_read,   .cleanup = softirq_cleanup,
};

static backend_t b_throughput = {
    .backend_id  = "procfs_throughput",
    .description = "/proc/net/dev packets/sec aggregated * 1us/packet estimate",
    .probe = throughput_probe, .init = throughput_init,
    .read  = throughput_read,   .cleanup = throughput_cleanup,
};

static metric_t m = {
    .metric_name = "nets",
    .backends    = { &b_softirq, &b_throughput },
    .n_backends  = 2,
};

metric_t *metric_nets(void) { return &m; }

/*
 * procutil.c -- procfs / sysfs parsing helpers.
 */

#include "procutil.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int procutil_read_file(const char *path, char *buf, size_t bufsize)
{
    if (!path || !buf || bufsize == 0) return -1;
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, bufsize - 1, f);
    fclose(f);
    buf[n] = '\0';
    return (int)n;
}

long procutil_read_long(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v = -1;
    if (fscanf(f, "%ld", &v) != 1) v = -1;
    fclose(f);
    return v;
}

int procutil_read_diskstats(diskstats_entry_t *entries, size_t max)
{
    FILE *f = fopen("/proc/diskstats", "r");
    if (!f) return -1;
    char line[512];
    size_t n = 0;
    while (fgets(line, sizeof(line), f) && n < max) {
        unsigned int maj, min;
        char name[32];
        unsigned long r_compl, r_merg, r_sect, r_ms;
        unsigned long w_compl, w_merg, w_sect, w_ms;
        unsigned long inflight, io_ticks, tiq;
        int matched = sscanf(line,
            "%u %u %31s %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
            &maj, &min, name,
            &r_compl, &r_merg, &r_sect, &r_ms,
            &w_compl, &w_merg, &w_sect, &w_ms,
            &inflight, &io_ticks, &tiq);
        if (matched < 13) continue;
        diskstats_entry_t *e = &entries[n++];
        snprintf(e->name, sizeof(e->name), "%s", name);
        e->reads_completed  = r_compl;
        e->writes_completed = w_compl;
        e->read_ms          = r_ms;
        e->write_ms         = w_ms;
        e->io_ticks         = io_ticks;
        e->time_in_queue    = tiq;
    }
    fclose(f);
    return (int)n;
}

int procutil_read_netdev(netdev_entry_t *entries, size_t max)
{
    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) return -1;
    char line[512];
    /* Skip the two header lines. */
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }

    size_t n = 0;
    while (fgets(line, sizeof(line), f) && n < max) {
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = ' ';
        char iface[32];
        unsigned long rx_b, rx_p, rx_e, rx_d, rx_f, rx_fr, rx_c, rx_m;
        unsigned long tx_b, tx_p, tx_e, tx_d, tx_f, tx_co, tx_ca, tx_co2;
        int matched = sscanf(line,
            "%31s %lu %lu %lu %lu %lu %lu %lu %lu "
            "%lu %lu %lu %lu %lu %lu %lu %lu",
            iface,
            &rx_b, &rx_p, &rx_e, &rx_d, &rx_f, &rx_fr, &rx_c, &rx_m,
            &tx_b, &tx_p, &tx_e, &tx_d, &tx_f, &tx_co, &tx_ca, &tx_co2);
        if (matched < 17) continue;
        netdev_entry_t *e = &entries[n++];
        snprintf(e->iface, sizeof(e->iface), "%s", iface);
        e->rx_bytes   = rx_b;
        e->rx_packets = rx_p;
        e->tx_bytes   = tx_b;
        e->tx_packets = tx_p;
    }
    fclose(f);
    return (int)n;
}

int procutil_read_net_softirqs(unsigned long *net_tx, unsigned long *net_rx)
{
    if (!net_tx || !net_rx) return -1;
    FILE *f = fopen("/proc/softirqs", "r");
    if (!f) return -1;
    char line[8192];
    *net_tx = 0;
    *net_rx = 0;
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        const char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        unsigned long *target = NULL;
        if (strncmp(p, "NET_TX:", 7) == 0) {
            target = net_tx;
            p += 7;
        } else if (strncmp(p, "NET_RX:", 7) == 0) {
            target = net_rx;
            p += 7;
        } else {
            continue;
        }
        unsigned long sum = 0;
        while (*p) {
            while (*p && isspace((unsigned char)*p)) p++;
            if (!*p || *p == '\n') break;
            char *end;
            unsigned long v = strtoul(p, &end, 10);
            if (end == p) break;
            sum += v;
            p = end;
        }
        *target = sum;
        found++;
        if (found == 2) break;
    }
    fclose(f);
    return found == 2 ? 0 : -1;
}

int procutil_read_proc_stat(pid_t pid,
                            unsigned long *utime,
                            unsigned long *stime)
{
    if (!utime || !stime) return -1;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    char buf[4096];
    int n = procutil_read_file(path, buf, sizeof(buf));
    if (n <= 0) return -1;

    /* Field 2 (comm) may contain spaces and parens; locate the rightmost ')'.
     * After ')' the fields are:
     *   state  ppid  pgrp  session  tty_nr  tpgid  flags
     *   minflt cminflt majflt cmajflt  utime  stime  ...
     * '%*lu' (assignment suppression + length modifier) is not portable, so
     * we read into throwaway variables instead. */
    char *rp = strrchr(buf, ')');
    if (!rp) return -1;
    rp++;

    char          state;
    int           ppid, pgrp, session, tty_nr, tpgid;
    unsigned int  flags;
    unsigned long minflt, cminflt, majflt, cmajflt, ut, st;
    int matched = sscanf(rp,
        " %c %d %d %d %d %d %u %lu %lu %lu %lu %lu %lu",
        &state, &ppid, &pgrp, &session, &tty_nr, &tpgid,
        &flags, &minflt, &cminflt, &majflt, &cmajflt, &ut, &st);
    if (matched != 13) return -1;
    *utime = ut;
    *stime = st;
    return 0;
}

int procutil_read_stat_total(unsigned long *total_jiffies,
                             unsigned long *idle_jiffies)
{
    if (!total_jiffies) return -1;
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return -1;
    char line[512];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    fclose(f);

    /* "cpu  user nice sys idle iowait irq softirq steal guest guest_nice" */
    unsigned long u, ni, sy, id, io, ir, sf, st, gu, gn;
    int matched = sscanf(line,
        "cpu  %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
        &u, &ni, &sy, &id, &io, &ir, &sf, &st, &gu, &gn);
    if (matched < 4) return -1;
    if (matched < 10) {
        if (matched < 5) io = 0;
        if (matched < 6) ir = 0;
        if (matched < 7) sf = 0;
        if (matched < 8) st = 0;
        if (matched < 9) gu = 0;
        gn = 0;
    }
    unsigned long total = u + ni + sy + id + io + ir + sf + st + gu + gn;
    *total_jiffies = total;
    if (idle_jiffies) *idle_jiffies = id + io;
    return 0;
}

int procutil_read_proc_io(pid_t pid,
                          unsigned long long *read_bytes,
                          unsigned long long *write_bytes)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/io", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    unsigned long long rb = 0, wb = 0;
    int got = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "read_bytes: %llu",  &rb) == 1) got++;
        if (sscanf(line, "write_bytes: %llu", &wb) == 1) got++;
    }
    fclose(f);
    if (got < 2) return -1;
    if (read_bytes)  *read_bytes  = rb;
    if (write_bytes) *write_bytes = wb;
    return 0;
}

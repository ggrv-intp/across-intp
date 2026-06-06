/*
 * procutil.h -- procfs/sysfs parsing helpers.
 *
 * Each function is side-effect-free and reads the entire target file.
 * Intended for use by the metric backends and the unit tests.
 */

#ifndef INTP_PROCUTIL_H
#define INTP_PROCUTIL_H

#include <stddef.h>
#include <sys/types.h>

int  procutil_read_file(const char *path, char *buf, size_t bufsize);
long procutil_read_long(const char *path);   /* -1 on failure */

typedef struct {
    char           name[32];
    unsigned long  reads_completed;
    unsigned long  writes_completed;
    unsigned long  read_ms;
    unsigned long  write_ms;
    unsigned long  io_ticks;          /* field 13: weighted busy time (ms) */
    unsigned long  time_in_queue;
} diskstats_entry_t;

/* Returns count of entries, or -1 on error. */
int procutil_read_diskstats(diskstats_entry_t *entries, size_t max);

typedef struct {
    char           iface[32];
    unsigned long  rx_bytes, tx_bytes;
    unsigned long  rx_packets, tx_packets;
} netdev_entry_t;

int procutil_read_netdev(netdev_entry_t *entries, size_t max);

/* Sum NET_TX and NET_RX softirq columns across all CPUs. */
int procutil_read_net_softirqs(unsigned long *net_tx,
                               unsigned long *net_rx);

/* Read /proc/<pid>/stat utime + stime in jiffies. */
int procutil_read_proc_stat(pid_t pid,
                            unsigned long *utime,
                            unsigned long *stime);

/* Read aggregate /proc/stat first line. total includes user+nice+sys+
 * idle+iowait+irq+softirq+steal+guest+guest_nice. */
int procutil_read_stat_total(unsigned long *total_jiffies,
                             unsigned long *idle_jiffies);

/* /proc/<pid>/io for read_bytes / write_bytes. */
int procutil_read_proc_io(pid_t pid,
                          unsigned long long *read_bytes,
                          unsigned long long *write_bytes);

#endif /* INTP_PROCUTIL_H */

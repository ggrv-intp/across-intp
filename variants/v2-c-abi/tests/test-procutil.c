/*
 * test-procutil.c -- exercise procutil parsers against the live /proc.
 */

#include "procutil.h"

#include <stdio.h>
#include <unistd.h>

#define ASSERT(cond)                                                    \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr,                                             \
                    "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            return 1;                                                   \
        }                                                               \
    } while (0)

int main(void)
{
    char buf[128];
    int n = procutil_read_file("/proc/uptime", buf, sizeof(buf));
    ASSERT(n > 0);

    long v = procutil_read_long("/proc/sys/kernel/pid_max");
    ASSERT(v > 0);

    diskstats_entry_t ds[32];
    int nd = procutil_read_diskstats(ds, 32);
    ASSERT(nd >= 0);  /* zero entries is valid on diskless test runners */

    netdev_entry_t nets[16];
    int nn = procutil_read_netdev(nets, 16);
    ASSERT(nn >= 1);  /* loopback at minimum */

    unsigned long net_tx = 0, net_rx = 0;
    int sr = procutil_read_net_softirqs(&net_tx, &net_rx);
    ASSERT(sr == 0);

    unsigned long total = 0, idle = 0;
    ASSERT(procutil_read_stat_total(&total, &idle) == 0);
    ASSERT(total > idle);

    unsigned long ut = 0, st = 0;
    ASSERT(procutil_read_proc_stat(getpid(), &ut, &st) == 0);
    /* utime+stime can legitimately be 0 for very fresh processes. */

    printf("test-procutil: OK (disks=%d ifaces=%d total_jiffies=%lu)\n",
           nd, nn, total);
    return 0;
}

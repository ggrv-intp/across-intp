/*
 * cpu.c -- CPU utilization, two backends.
 *
 *   cpu_procfs_pid     per-PID via /proc/<pid>/stat utime+stime, normalized
 *                      by /proc/stat total jiffies delta. Selected when
 *                      target has at least one PID.
 *   cpu_procfs_system  system-wide /proc/stat (1 - idle/total). Always
 *                      probeable; the fallback when no PIDs given.
 */

#include "backend.h"
#include "procutil.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static struct {
    int valid;
    unsigned long sum_proc_jiffies;   /* utime+stime summed across PIDs */
    unsigned long total_jiffies;
} pid_state;

static struct {
    int valid;
    unsigned long total_jiffies;
    unsigned long idle_jiffies;
} sys_state;

static int cpu_pid_probe(void)
{
    const intp_target_t *t = intp_target_get();
    return (t && t->n_pids > 0) ? 0 : -1;
}

static unsigned long sum_pid_jiffies(void)
{
    const intp_target_t *t = intp_target_get();
    unsigned long sum = 0;
    for (int i = 0; i < t->n_pids; i++) {
        unsigned long u = 0, s = 0;
        if (procutil_read_proc_stat(t->pids[i], &u, &s) == 0)
            sum += (u + s);
    }
    return sum;
}

static int cpu_pid_init(void)
{
    pid_state.sum_proc_jiffies = sum_pid_jiffies();
    if (procutil_read_stat_total(&pid_state.total_jiffies, NULL) != 0)
        return -1;
    pid_state.valid = 1;
    return 0;
}

static int cpu_pid_read(metric_sample_t *out, double interval_sec)
{
    (void)interval_sec;
    if (!pid_state.valid) return -1;

    unsigned long pj = sum_pid_jiffies();
    unsigned long tj = 0;
    if (procutil_read_stat_total(&tj, NULL) != 0) return -1;

    long dpj = (long)(pj - pid_state.sum_proc_jiffies);
    long dtj = (long)(tj - pid_state.total_jiffies);
    pid_state.sum_proc_jiffies = pj;
    pid_state.total_jiffies    = tj;

    double v = 0.0;
    if (dtj > 0 && dpj >= 0)
        v = ((double)dpj / (double)dtj) * 100.0 *
            (double)(intp_target_get()->n_pids ? 1 : 1);
    /* Per-PID fraction is relative to all CPUs; scale by num_cores so the
     * value is "% of one CPU" consistent with V0 (which is per-task time).
     * Actually V0 reports per-CPU%; but here we report system-relative. Keep
     * as fraction of total CPU time; document in DESIGN.md. */

    if (v < 0.0)   v = 0.0;
    if (v > 100.0) v = 100.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "procfs_pid";
    out->note       = NULL;
    return 0;
}

static void cpu_pid_cleanup(void)
{
    pid_state.valid = 0;
}

static int cpu_sys_probe(void)
{
    unsigned long t = 0, i = 0;
    return procutil_read_stat_total(&t, &i) == 0 ? 0 : -1;
}

static int cpu_sys_init(void)
{
    if (procutil_read_stat_total(&sys_state.total_jiffies,
                                 &sys_state.idle_jiffies) != 0)
        return -1;
    sys_state.valid = 1;
    return 0;
}

static int cpu_sys_read(metric_sample_t *out, double interval_sec)
{
    (void)interval_sec;
    if (!sys_state.valid) return -1;
    unsigned long total = 0, idle = 0;
    if (procutil_read_stat_total(&total, &idle) != 0) return -1;
    long dt = (long)(total - sys_state.total_jiffies);
    long di = (long)(idle  - sys_state.idle_jiffies);
    sys_state.total_jiffies = total;
    sys_state.idle_jiffies  = idle;
    double v = (dt > 0) ? (1.0 - (double)di / (double)dt) * 100.0 : 0.0;
    if (v < 0.0)   v = 0.0;
    if (v > 100.0) v = 100.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "procfs_system";
    out->note       = NULL;
    return 0;
}

static void cpu_sys_cleanup(void) { sys_state.valid = 0; }

static backend_t cpu_pid_backend = {
    .backend_id  = "procfs_pid",
    .description = "per-PID utime+stime via /proc/<pid>/stat",
    .probe       = cpu_pid_probe,
    .init        = cpu_pid_init,
    .read        = cpu_pid_read,
    .cleanup     = cpu_pid_cleanup,
};

static backend_t cpu_sys_backend = {
    .backend_id  = "procfs_system",
    .description = "system-wide /proc/stat (1 - idle/total)",
    .probe       = cpu_sys_probe,
    .init        = cpu_sys_init,
    .read        = cpu_sys_read,
    .cleanup     = cpu_sys_cleanup,
};

static metric_t m = {
    .metric_name = "cpu",
    .backends    = { &cpu_pid_backend, &cpu_sys_backend },
    .n_backends  = 2,
};

metric_t *metric_cpu(void) { return &m; }

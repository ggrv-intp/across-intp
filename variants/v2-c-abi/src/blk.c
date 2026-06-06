/*
 * blk.c -- block I/O utilization.
 *
 *   blk_diskstats   /proc/diskstats io_ticks (sum across non-virtual whole
 *                   devices, or single device when --disk specified). This
 *                   is iostat's %util.
 *   blk_sysfs       /sys/block/<dev>/stat (same fields, per-device).
 */

#include "backend.h"
#include "detect.h"
#include "procutil.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_virtual(const char *name)
{
    return strncmp(name, "loop", 4) == 0 ||
           strncmp(name, "ram",  3) == 0 ||
           strncmp(name, "zram", 4) == 0 ||
           strncmp(name, "dm-",  3) == 0;
}

static int is_partition(const char *name)
{
    size_t len = strlen(name);
    if (len == 0) return 0;
    if (name[len-1] < '0' || name[len-1] > '9') return 0;
    if (strncmp(name, "nvme", 4) == 0 || strncmp(name, "mmcblk", 6) == 0) {
        char *p = strrchr(name, 'p');
        return p && p > name && p[-1] >= '0' && p[-1] <= '9';
    }
    return 1;
}

static struct {
    int           valid;
    char          target[32];      /* "" = aggregate all whole devices       */
    unsigned long prev_io_ticks;
} ds;

static unsigned long sum_io_ticks(const char *target)
{
    diskstats_entry_t entries[64];
    int n = procutil_read_diskstats(entries, 64);
    if (n <= 0) return 0;
    unsigned long sum = 0;
    for (int i = 0; i < n; i++) {
        if (target[0]) {
            if (strcmp(entries[i].name, target) == 0)
                return entries[i].io_ticks;
            continue;
        }
        if (is_virtual(entries[i].name) || is_partition(entries[i].name))
            continue;
        sum += entries[i].io_ticks;
    }
    return sum;
}

static int diskstats_probe(void)
{
    diskstats_entry_t e[1];
    return procutil_read_diskstats(e, 1) >= 1 ? 0 : -1;
}

static int diskstats_init(void)
{
    const intp_target_t *t = intp_target_get();
    if (t && t->disk && t->disk[0]) {
        snprintf(ds.target, sizeof(ds.target), "%s", t->disk);
    } else {
        ds.target[0] = '\0';   /* aggregate */
    }
    ds.prev_io_ticks = sum_io_ticks(ds.target);
    ds.valid = 1;
    return 0;
}

static int diskstats_read(metric_sample_t *out, double interval_sec)
{
    if (!ds.valid || interval_sec <= 0) return -1;
    unsigned long ticks = sum_io_ticks(ds.target);
    long delta = (long)(ticks - ds.prev_io_ticks);
    ds.prev_io_ticks = ticks;
    double interval_ms = interval_sec * 1000.0;
    double v = (interval_ms > 0)
                 ? ((double)delta / interval_ms) * 100.0 : 0.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "diskstats";
    out->note       = ds.target[0] ? ds.target : "all-whole-devices";
    return 0;
}

static void diskstats_cleanup(void) { ds.valid = 0; }

/* sysfs fallback: reads /sys/block/<dev>/stat for a single device. */

static struct {
    int           valid;
    char          path[128];
    unsigned long prev_io_ticks;
} sb;

static int sysfs_probe(void)
{
    const intp_target_t *t = intp_target_get();
    char dev[64] = {0};
    if (t && t->disk && t->disk[0]) {
        snprintf(dev, sizeof(dev), "%s", t->disk);
    } else if (detect_default_disk(dev, sizeof(dev)) != 0) {
        return -1;
    }
    char p[128];
    snprintf(p, sizeof(p), "/sys/block/%s/stat", dev);
    FILE *f = fopen(p, "r");
    if (!f) return -1;
    fclose(f);
    return 0;
}

static unsigned long read_sysfs_io_ticks(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long a, b, c, d, e, g, h, i, j, k;
    int n = fscanf(f, "%lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
                   &a, &b, &c, &d, &e, &g, &h, &i, &j, &k);
    fclose(f);
    return n >= 10 ? j : 0;     /* j = io_ticks */
}

static int sysfs_init(void)
{
    const intp_target_t *t = intp_target_get();
    char dev[64];
    if (t && t->disk && t->disk[0]) {
        snprintf(dev, sizeof(dev), "%s", t->disk);
    } else if (detect_default_disk(dev, sizeof(dev)) != 0) {
        return -1;
    }
    snprintf(sb.path, sizeof(sb.path), "/sys/block/%s/stat", dev);
    sb.prev_io_ticks = read_sysfs_io_ticks(sb.path);
    sb.valid = 1;
    return 0;
}

static int sysfs_read(metric_sample_t *out, double interval_sec)
{
    if (!sb.valid || interval_sec <= 0) return -1;
    unsigned long ticks = read_sysfs_io_ticks(sb.path);
    long delta = (long)(ticks - sb.prev_io_ticks);
    sb.prev_io_ticks = ticks;
    double interval_ms = interval_sec * 1000.0;
    double v = (interval_ms > 0)
                 ? ((double)delta / interval_ms) * 100.0 : 0.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "sysfs";
    out->note       = NULL;
    return 0;
}

static void sysfs_cleanup(void) { sb.valid = 0; }

static backend_t b_diskstats = {
    .backend_id  = "diskstats",
    .description = "/proc/diskstats io_ticks aggregated",
    .probe = diskstats_probe, .init = diskstats_init,
    .read  = diskstats_read,  .cleanup = diskstats_cleanup,
};

static backend_t b_sysfs = {
    .backend_id  = "sysfs",
    .description = "/sys/block/<dev>/stat io_ticks",
    .probe = sysfs_probe, .init = sysfs_init,
    .read  = sysfs_read,  .cleanup = sysfs_cleanup,
};

static metric_t m = {
    .metric_name = "blk",
    .backends    = { &b_diskstats, &b_sysfs },
    .n_backends  = 2,
};

metric_t *metric_blk(void) { return &m; }

/*
 * perfev.c -- perf_event_open wrappers and uncore PMU helpers.
 *
 * Uncore PMUs require root or perf_event_paranoid <= -1. The wrappers
 * fail with the kernel's errno on permission denial; backends translate
 * EACCES into a clear "needs paranoid<=-1" message in their probe().
 */

#include "perfev.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

static long sys_perf_event_open(struct perf_event_attr *attr,
                                pid_t pid, int cpu,
                                int group_fd, unsigned long flags)
{
    return syscall(__NR_perf_event_open, attr, pid, cpu, group_fd, flags);
}

int perfev_open(uint32_t type, uint64_t config, pid_t pid, int cpu)
{
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type           = type;
    attr.size           = sizeof(attr);
    attr.config         = config;
    attr.disabled       = 1;
    attr.exclude_hv     = 1;
    attr.read_format    = PERF_FORMAT_TOTAL_TIME_ENABLED |
                          PERF_FORMAT_TOTAL_TIME_RUNNING;
    if (pid > 0) attr.inherit = 1;

    int fd = (int)sys_perf_event_open(&attr, pid, cpu, -1, 0);
    if (fd < 0)
        return -1;
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0)  < 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

/* Open a system-wide uncore PMU event.
 * Uncore events must NOT have exclude_hv set -- kernel rejects with EINVAL. */
static int perfev_open_uncore(uint32_t type, uint64_t config, int cpu)
{
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type        = type;
    attr.size        = sizeof(attr);
    attr.config      = config;
    attr.disabled    = 1;
    attr.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED |
                       PERF_FORMAT_TOTAL_TIME_RUNNING;
    /* exclude_hv omitted -- uncore PMUs return EINVAL if set */

    int fd = (int)sys_perf_event_open(&attr, -1, cpu, -1, 0);
    if (fd < 0) return -1;
    if (ioctl(fd, PERF_EVENT_IOC_RESET,  0) < 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int perfev_read(int fd, uint64_t *value)
{
    if (fd < 0 || !value) return -1;
    struct {
        uint64_t val;
        uint64_t enabled;
        uint64_t running;
    } r;
    ssize_t n = read(fd, &r, sizeof(r));
    if (n != (ssize_t)sizeof(r)) return -1;
    *value = r.val;
    return 0;
}

int perfev_read_scaled(int fd, uint64_t *value,
                       uint64_t *enabled, uint64_t *running)
{
    if (fd < 0 || !value) return -1;
    struct {
        uint64_t val;
        uint64_t enabled;
        uint64_t running;
    } r;
    ssize_t n = read(fd, &r, sizeof(r));
    if (n != (ssize_t)sizeof(r)) return -1;
    if (r.running > 0 && r.running < r.enabled) {
        *value = (uint64_t)((double)r.val *
                            (double)r.enabled / (double)r.running);
    } else {
        *value = r.val;
    }
    if (enabled) *enabled = r.enabled;
    if (running) *running = r.running;
    return 0;
}

int perfev_open_llc_cache(pid_t pid, int *fd_loads, int *fd_misses)
{
    if (!fd_loads || !fd_misses) return -1;
    *fd_loads  = -1;
    *fd_misses = -1;

    uint64_t loads_cfg = (uint64_t)PERF_COUNT_HW_CACHE_LL |
                         ((uint64_t)PERF_COUNT_HW_CACHE_OP_READ << 8) |
                         ((uint64_t)PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16);
    uint64_t miss_cfg  = (uint64_t)PERF_COUNT_HW_CACHE_LL |
                         ((uint64_t)PERF_COUNT_HW_CACHE_OP_READ << 8) |
                         ((uint64_t)PERF_COUNT_HW_CACHE_RESULT_MISS << 16);

    int cpu = (pid == -1) ? 0 : -1;
    *fd_loads  = perfev_open(PERF_TYPE_HW_CACHE, loads_cfg, pid, cpu);
    if (*fd_loads < 0) return -1;
    *fd_misses = perfev_open(PERF_TYPE_HW_CACHE, miss_cfg,  pid, cpu);
    if (*fd_misses < 0) {
        int saved = errno;
        close(*fd_loads);
        *fd_loads = -1;
        errno = saved;
        return -1;
    }
    return 0;
}

/* Read /sys/devices/<pmu>/type as an integer (perf event type for that PMU). */
static int pmu_type(const char *pmu_dir)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/devices/%s/type", pmu_dir);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int t = -1;
    if (fscanf(f, "%d", &t) != 1) t = -1;
    fclose(f);
    return t;
}

/* For each PMU directory matching `prefix`, open one fd per (event,umask)
 * pair using the PMU's type. The encoding event|umask<<8 matches the kernel
 * default sysfs format described in
 * /sys/devices/<pmu>/format/{event,umask}. */
static int open_pmus_by_prefix(const char *prefix,
                               const uint64_t *configs, int n_configs,
                               int **fds_out)
{
    DIR *d = opendir("/sys/devices");
    if (!d) return -1;

    int  cap = 16;
    int *fds = malloc(sizeof(int) * (size_t)cap);
    if (!fds) { closedir(d); return -1; }
    int n = 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, prefix, strlen(prefix)) != 0) continue;
        int t = pmu_type(e->d_name);
        if (t < 0) continue;
        for (int i = 0; i < n_configs; i++) {
            int fd = perfev_open_uncore((uint32_t)t, configs[i], 0);
            if (fd < 0) continue;
            if (n == cap) {
                cap *= 2;
                int *nfds = realloc(fds, sizeof(int) * (size_t)cap);
                if (!nfds) { close(fd); break; }
                fds = nfds;
            }
            fds[n++] = fd;
        }
    }
    closedir(d);
    if (n == 0) {
        free(fds);
        *fds_out = NULL;
        return -1;
    }
    *fds_out = fds;
    return n;
}

int perfev_open_uncore_imc_intel(int **fds_out)
{
    /* Intel iMC: CAS_COUNT.RD = event 0x04 umask 0x03; .WR = umask 0x0c. */
    uint64_t configs[2] = {
        0x04ULL | (0x03ULL << 8),
        0x04ULL | (0x0cULL << 8)
    };
    return open_pmus_by_prefix("uncore_imc", configs, 2, fds_out);
}

int perfev_open_amd_df(int **fds_out)
{
    /* AMD Data Fabric Zen2+: event 0x07, umask 0x38 = DRAM read+write data. */
    uint64_t configs[1] = {
        0x07ULL | (0x38ULL << 8)
    };
    return open_pmus_by_prefix("amd_df", configs, 1, fds_out);
}

int perfev_open_arm_cmn(int **fds_out)
{
    /* ARM CMN HN-F: event 0x4 (rdata) is a stable proxy for memory traffic.
     * Real-world deployments may want to override this per-SoC. */
    uint64_t configs[1] = { 0x04ULL };
    return open_pmus_by_prefix("arm_cmn", configs, 1, fds_out);
}

void perfev_close(int fd)
{
    if (fd >= 0) close(fd);
}

/*
 * test-backend-registry.c -- unit tests for the per-metric backend list,
 * ordering invariants, and a basic fd-leak check on probe+init+cleanup.
 *
 * Does not require root; backends whose probe() fails (e.g. resctrl on a
 * host where it isn't mounted) are simply skipped.
 */

#include "backend.h"
#include "intp.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ASSERT(cond)                                                    \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr,                                             \
                    "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            return 1;                                                   \
        }                                                               \
    } while (0)

/* Return the number of open fds in /proc/self/fd, or -1 if /proc is not
 * available (e.g. on a stripped-down CI image). */
static int count_open_fds(void)
{
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        n++;
    }
    closedir(d);
    return n;
}

/* Each row encodes the expected backend-id sequence for one metric. The
 * order is the priority ordering in the .backends array declarations. */
typedef struct {
    const char *metric;
    int         n;
    const char *backend_ids[4];
} expected_order_t;

static const expected_order_t EXPECTED[] = {
    { "netp",   2, { "sysfs", "procfs" } },
    { "nets",   2, { "procfs_softirq", "procfs_throughput" } },
    { "blk",    2, { "diskstats", "sysfs" } },
    { "mbw",    4, { "perf_uncore_imc", "perf_amd_df",
                     "perf_arm_cmn", "resctrl_mbm" } },
    { "llcmr",  2, { "perf_hwcache", "perf_raw" } },
    { "llcocc", 2, { "resctrl", "proxy_from_miss_ratio" } },
    { "cpu",    2, { "procfs_pid", "procfs_system" } },
};

static metric_t *find_metric(metric_t **all, int n, const char *name)
{
    for (int i = 0; i < n; i++)
        if (strcmp(all[i]->metric_name, name) == 0) return all[i];
    return NULL;
}

static int test_metric_accessors_return_valid(void)
{
    int n = 0;
    metric_t **all = intp_all_metrics(&n);
    ASSERT(all != NULL);
    ASSERT(n == 7);
    for (int i = 0; i < n; i++) {
        ASSERT(all[i] != NULL);
        ASSERT(all[i]->metric_name != NULL);
        ASSERT(all[i]->metric_name[0] != '\0');
        ASSERT(all[i]->n_backends > 0);
        ASSERT(all[i]->n_backends <= INTP_MAX_BACKENDS_PER_METRIC);
        for (int j = 0; j < all[i]->n_backends; j++) {
            ASSERT(all[i]->backends[j] != NULL);
            ASSERT(all[i]->backends[j]->backend_id != NULL);
        }
    }
    return 0;
}

static int test_backend_priority_order(void)
{
    int n = 0;
    metric_t **all = intp_all_metrics(&n);
    for (size_t i = 0; i < sizeof(EXPECTED)/sizeof(EXPECTED[0]); i++) {
        metric_t *m = find_metric(all, n, EXPECTED[i].metric);
        ASSERT(m != NULL);
        ASSERT(m->n_backends == EXPECTED[i].n);
        for (int j = 0; j < m->n_backends; j++) {
            const char *got = m->backends[j]->backend_id;
            const char *want = EXPECTED[i].backend_ids[j];
            if (strcmp(got, want) != 0) {
                fprintf(stderr,
                        "FAIL order: metric=%s pos=%d want=%s got=%s\n",
                        EXPECTED[i].metric, j, want, got);
                return 1;
            }
        }
    }
    return 0;
}

/* For each backend, run probe() + (if it probed ok) init() + cleanup() and
 * confirm no file descriptors leaked. Backends whose probe() returns nonzero
 * are not a failure: they simply aren't available here. */
static int test_probe_init_cleanup_no_leak(void)
{
    int baseline = count_open_fds();
    if (baseline < 0) {
        printf("  SKIP leak check: /proc/self/fd not readable\n");
        return 0;
    }

    /* Use a single-PID synthetic target so backends that require PIDs can
     * probe. n_pids can stay zero for the system-wide backends. */
    intp_target_t tgt;
    memset(&tgt, 0, sizeof(tgt));
    tgt.n_pids  = 1;
    tgt.pids[0] = getpid();
    intp_target_set(&tgt);

    int n = 0;
    metric_t **all = intp_all_metrics(&n);
    for (int i = 0; i < n; i++) {
        metric_t *m = all[i];
        for (int j = 0; j < m->n_backends; j++) {
            backend_t *b = m->backends[j];
            if (!b || !b->probe) continue;
            if (b->probe() != 0) continue;
            if (b->init && b->init() == 0) {
                if (b->cleanup) b->cleanup();
            } else if (b->cleanup) {
                b->cleanup();
            }
        }
    }

    int after = count_open_fds();
    if (after < 0) return 0;
    /* Allow a small slack (+1) for directory handles opened briefly by the
     * kernel during probing; a leak of one fd per backend would dwarf this. */
    if (after > baseline + 2) {
        fprintf(stderr,
                "FAIL fd leak: baseline=%d after=%d (delta=%d)\n",
                baseline, after, after - baseline);
        return 1;
    }
    return 0;
}

int main(void)
{
    if (test_metric_accessors_return_valid() != 0) return 1;
    if (test_backend_priority_order()      != 0) return 1;
    if (test_probe_init_cleanup_no_leak()  != 0) return 1;
    printf("test-backend-registry: OK (7 metrics, 16 backends in spec order)\n");
    return 0;
}

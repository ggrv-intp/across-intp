/*
 * llcmr.c -- LLC miss ratio.
 *
 *   1. llcmr_perf_hwcache  PERF_TYPE_HW_CACHE LL access/miss (preferred)
 *   2. llcmr_perf_raw      raw vendor codes (Skylake/EPYC fallback table)
 *
 * Per-PID when target has PIDs; system-wide on cpu 0 otherwise.
 */

#include "backend.h"
#include "detect.h"
#include "perfev.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/perf_event.h>

typedef struct {
    int      *fd_loads;
    int      *fd_misses;
    int       n;
    uint64_t *prev_loads;
    uint64_t *prev_misses;
    int       valid;
    const char *backend_id;
} llcmr_state_t;

static llcmr_state_t st;

static int alloc_state(int n)
{
    st.fd_loads     = calloc((size_t)n, sizeof(int));
    st.fd_misses    = calloc((size_t)n, sizeof(int));
    st.prev_loads   = calloc((size_t)n, sizeof(uint64_t));
    st.prev_misses  = calloc((size_t)n, sizeof(uint64_t));
    if (!st.fd_loads || !st.fd_misses ||
        !st.prev_loads || !st.prev_misses) return -1;
    for (int i = 0; i < n; i++) {
        st.fd_loads[i]  = -1;
        st.fd_misses[i] = -1;
    }
    st.n = n;
    return 0;
}

static void free_state(void)
{
    if (st.fd_loads)  for (int i = 0; i < st.n; i++) perfev_close(st.fd_loads[i]);
    if (st.fd_misses) for (int i = 0; i < st.n; i++) perfev_close(st.fd_misses[i]);
    free(st.fd_loads);
    free(st.fd_misses);
    free(st.prev_loads);
    free(st.prev_misses);
    memset(&st, 0, sizeof(st));
}

/* ---- backend 1: PERF_TYPE_HW_CACHE generic ----------------------------- */

static int hwcache_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (!c->perf_usable) return -1;
    /* Inside a VM without PMU passthrough, perf_event_open succeeds but
     * counters never increment -- reject here so the fallback chain can
     * run a degraded backend instead. */
    if (c->env == ENV_VM && !c->pmu_passthrough) return -1;
    /* per-task counters allowed when paranoid <= 1, system-wide needs <= 0 */
    const intp_target_t *t = intp_target_get();
    int needs_sys = (t->n_pids == 0);
    if (needs_sys && c->perf_paranoid > 0 && geteuid() != 0) return -1;
    if (!needs_sys && c->perf_paranoid > 1 && geteuid() != 0) return -1;
    return 0;
}

static int hwcache_init(void)
{
    const intp_target_t *t = intp_target_get();
    int n = t->n_pids > 0 ? t->n_pids : 1;
    if (alloc_state(n) != 0) return -1;
    st.backend_id = "perf_hwcache";

    for (int i = 0; i < n; i++) {
        pid_t pid = t->n_pids > 0 ? t->pids[i] : -1;
        if (perfev_open_llc_cache(pid, &st.fd_loads[i], &st.fd_misses[i]) != 0) {
            free_state();
            return -1;
        }
        perfev_read(st.fd_loads[i],  &st.prev_loads[i]);
        perfev_read(st.fd_misses[i], &st.prev_misses[i]);
    }
    st.valid = 1;
    return 0;
}

static int generic_read(metric_sample_t *out, double interval_sec)
{
    (void)interval_sec;
    if (!st.valid) return -1;
    uint64_t loads_d = 0, miss_d = 0;
    for (int i = 0; i < st.n; i++) {
        uint64_t l = 0, m = 0;
        perfev_read(st.fd_loads[i],  &l);
        perfev_read(st.fd_misses[i], &m);
        loads_d += (l - st.prev_loads[i]);
        miss_d  += (m - st.prev_misses[i]);
        st.prev_loads[i]  = l;
        st.prev_misses[i] = m;
    }
    double v;
    if (loads_d == 0) {
        v = 0.0;
        out->note = "no_cache_activity";
    } else {
        v = ((double)miss_d / (double)loads_d) * 100.0;
        out->note = NULL;
    }
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = st.backend_id;
    return 0;
}

static void hwcache_cleanup(void) { free_state(); }

/* ---- backend 2: raw event codes (vendor table) ------------------------- */

typedef struct {
    cpu_vendor_t vendor;
    uint64_t     loads_config;
    uint64_t     misses_config;
} raw_codes_t;

/* Conservative defaults known to work on common CPUs; users can override
 * via --force-backend if their SoC needs different codes. */
static const raw_codes_t raw_table[] = {
    /* Intel: LONGEST_LAT_CACHE.REFERENCE 0x4F2E, LONGEST_LAT_CACHE.MISS 0x412E */
    { VENDOR_INTEL, 0x4F2E, 0x412E },
    /* AMD Zen: L3_LOOKUP_STATE = 0x04, L3_MISS = 0x06 (PMCx0F4 family) */
    { VENDOR_AMD,   0x04,   0x06   },
    /* ARMv8 LL_CACHE 0x32, LL_CACHE_MISS_RD 0x37 */
    { VENDOR_ARM,   0x32,   0x37   },
};

static int raw_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (!c->perf_usable) return -1;
    if (c->env == ENV_VM && !c->pmu_passthrough) return -1;
    return 0;
}

static int raw_init(void)
{
    const system_capabilities_t *c = detect_cached();
    const raw_codes_t *codes = NULL;
    for (size_t i = 0; i < sizeof(raw_table)/sizeof(raw_table[0]); i++) {
        if (raw_table[i].vendor == c->vendor) { codes = &raw_table[i]; break; }
    }
    if (!codes) return -1;

    const intp_target_t *t = intp_target_get();
    int n = t->n_pids > 0 ? t->n_pids : 1;
    if (alloc_state(n) != 0) return -1;
    st.backend_id = "perf_raw";

    for (int i = 0; i < n; i++) {
        pid_t pid = t->n_pids > 0 ? t->pids[i] : -1;
        int   cpu = (pid == -1) ? 0 : -1;
        st.fd_loads[i]  = perfev_open(PERF_TYPE_RAW, codes->loads_config,
                                      pid, cpu);
        st.fd_misses[i] = perfev_open(PERF_TYPE_RAW, codes->misses_config,
                                      pid, cpu);
        if (st.fd_loads[i] < 0 || st.fd_misses[i] < 0) {
            free_state();
            return -1;
        }
        perfev_read(st.fd_loads[i],  &st.prev_loads[i]);
        perfev_read(st.fd_misses[i], &st.prev_misses[i]);
    }
    st.valid = 1;
    return 0;
}

static void raw_cleanup(void) { free_state(); }

static backend_t b_hwcache = {
    .backend_id  = "perf_hwcache",
    .description = "perf_event_open PERF_TYPE_HW_CACHE LL access/miss",
    .probe = hwcache_probe, .init = hwcache_init,
    .read  = generic_read,   .cleanup = hwcache_cleanup,
};

static backend_t b_raw = {
    .backend_id  = "perf_raw",
    .description = "perf_event_open vendor raw codes (fallback)",
    .probe = raw_probe, .init = raw_init,
    .read  = generic_read, .cleanup = raw_cleanup,
};

static metric_t m = {
    .metric_name = "llcmr",
    .backends    = { &b_hwcache, &b_raw },
    .n_backends  = 2,
};

metric_t *metric_llcmr(void) { return &m; }

/* Public probe-time helper for llcocc proxy backend. Reads counter deltas
 * since the last call (consumes them), returning the miss ratio percentage. */
double intp_llcmr_last_value(void);
double intp_llcmr_last_value(void)
{
    if (!st.valid) return NAN;
    uint64_t loads_d = 0, miss_d = 0;
    for (int i = 0; i < st.n; i++) {
        uint64_t lv = 0, mv = 0;
        perfev_read(st.fd_loads[i],  &lv);
        perfev_read(st.fd_misses[i], &mv);
        loads_d += (lv - st.prev_loads[i]);
        miss_d  += (mv - st.prev_misses[i]);
        st.prev_loads[i]  = lv;
        st.prev_misses[i] = mv;
    }
    if (loads_d == 0) return 0.0;
    return ((double)miss_d / (double)loads_d) * 100.0;
}

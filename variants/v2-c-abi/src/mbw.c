/*
 * mbw.c -- memory bandwidth utilization, four-backend hierarchy.
 *
 *   1. mbw_perf_imc      Intel uncore IMC CAS_COUNT.RD/WR (CAP_SYS_ADMIN)
 *   2. mbw_perf_amd_df   AMD Data Fabric DRAM data beats (CAP_SYS_ADMIN)
 *   3. mbw_perf_arm_cmn  ARM CMN HN-F memory traffic (CAP_SYS_ADMIN)
 *   4. mbw_resctrl_mbm   resctrl mbm_total_bytes fallback (when uncore PMU unavailable)
 *
 * Normalization: detected mem_bw_max_bps unless overridden by --mem-bw-max-bps.
 * Each backend reports its source via metric_sample_t.backend_id.
 */

#include "backend.h"
#include "detect.h"
#include "perfev.h"
#include "resctrl.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>

#define MBW_GROUP_PREFIX "intp_v2_mbw"
#define RESCTRL_ROOT_SENTINEL "<root>"

static long resolve_mem_bw_bps(void)
{
    const intp_target_t *t = intp_target_get();
    if (t && t->mem_bw_max_bps_override > 0) return t->mem_bw_max_bps_override;
    return detect_memory_bandwidth_max_bps();
}

/* ---- backend 1: resctrl MBM -------------------------------------------- */

static struct {
    int   valid;
    char  group[64];
    long  prev_bytes;
    long  max_bps;
} mb;

static int resctrl_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (!c->resctrl_usable) return -1;
    if (!c->has_rdt_mbm && !c->has_amd_qos && !c->has_arm_mpam) return -1;
    return 0;
}

static int resctrl_init_(void)
{
    /* With explicit --pid: own mon_group scoped to those tasks.
     * Without --pid: read the resctrl root group (system-wide) so a
     * stress-ng co-runner on neighbouring CPUs is captured. */
    const intp_target_t *t = intp_target_get();
    if (t && t->n_pids > 0) {
        snprintf(mb.group, sizeof(mb.group), "%s_%d", MBW_GROUP_PREFIX, getpid());
        if (resctrl_create_mongroup(mb.group) != 0) return -1;
        resctrl_assign_pids(mb.group, t->pids, (size_t)t->n_pids);
    } else {
        snprintf(mb.group, sizeof(mb.group), "%s", RESCTRL_ROOT_SENTINEL);
        if (resctrl_create_mongroup(mb.group) != 0) return -1;
    }
    long b = resctrl_read_mbm_total(mb.group);
    if (b < 0) return -1;
    mb.prev_bytes = b;
    mb.max_bps    = resolve_mem_bw_bps();
    mb.valid      = 1;
    return 0;
}

static int resctrl_read_(metric_sample_t *out, double interval_sec)
{
    if (!mb.valid || interval_sec <= 0) return -1;
    long now = resctrl_read_mbm_total(mb.group);
    if (now < 0) return -1;
    long delta = now - mb.prev_bytes;
    mb.prev_bytes = now;
    double bps = (double)delta / interval_sec;
    double v   = bps / (double)mb.max_bps * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "resctrl_mbm";
    out->note       = NULL;
    return 0;
}

static void resctrl_cleanup_(void)
{
    if (mb.valid) {
        resctrl_remove_mongroup(mb.group);
        mb.valid = 0;
    }
}

/* ---- shared perf-uncore helper ------------------------------------------ */

typedef int (*open_pmu_fn)(int **fds_out);

static struct {
    int       valid;
    int      *fds;
    int       n_fds;
    uint64_t  prev_total;
    long      max_bps;
    const char *backend_id;
    int       beat_bytes;
} pu;

static int pu_init_with(open_pmu_fn fn, const char *id, int beat_bytes)
{
    int *fds = NULL;
    int  n   = fn(&fds);
    if (n <= 0) return -1;
    pu.fds        = fds;
    pu.n_fds      = n;
    pu.beat_bytes = beat_bytes;
    pu.backend_id = id;
    pu.max_bps    = resolve_mem_bw_bps();
    pu.prev_total = 0;
    for (int i = 0; i < n; i++) {
        uint64_t v = 0;
        perfev_read(fds[i], &v);
        pu.prev_total += v;
    }
    pu.valid = 1;
    return 0;
}

static int pu_read(metric_sample_t *out, double interval_sec)
{
    if (!pu.valid || interval_sec <= 0) return -1;
    uint64_t total = 0;
    for (int i = 0; i < pu.n_fds; i++) {
        uint64_t v = 0;
        perfev_read(pu.fds[i], &v);
        total += v;
    }
    uint64_t delta = total - pu.prev_total;
    pu.prev_total  = total;
    double bytes_per_sec = (double)delta * (double)pu.beat_bytes / interval_sec;
    double v = bytes_per_sec / (double)pu.max_bps * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = pu.backend_id;
    out->note       = NULL;
    return 0;
}

static void pu_cleanup(void)
{
    if (!pu.valid) return;
    for (int i = 0; i < pu.n_fds; i++) perfev_close(pu.fds[i]);
    free(pu.fds);
    pu.fds   = NULL;
    pu.n_fds = 0;
    pu.valid = 0;
}

/* ---- backend 2: Intel uncore IMC --------------------------------------- */

static int imc_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (c->vendor != VENDOR_INTEL)     return -1;
    if (!c->perf_uncore_imc)           return -1;
    if (c->perf_paranoid > -1 && geteuid() != 0) return -1;
    return 0;
}

static int imc_init(void)  { return pu_init_with(perfev_open_uncore_imc_intel,
                                                  "perf_uncore_imc", 64); }

/* ---- backend 3: AMD Data Fabric ---------------------------------------- */

static int amd_df_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (c->vendor != VENDOR_AMD) return -1;
    if (!c->perf_amd_df)          return -1;
    if (c->perf_paranoid > -1 && geteuid() != 0) return -1;
    return 0;
}

static int amd_df_init(void) { return pu_init_with(perfev_open_amd_df,
                                                    "perf_amd_df", 64); }

/* ---- backend 4: ARM CMN ------------------------------------------------ */

static int arm_cmn_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (c->vendor != VENDOR_ARM) return -1;
    if (!c->perf_arm_cmn)         return -1;
    if (c->perf_paranoid > -1 && geteuid() != 0) return -1;
    return 0;
}

static int arm_cmn_init(void) { return pu_init_with(perfev_open_arm_cmn,
                                                     "perf_arm_cmn", 64); }

/* ---- registration ------------------------------------------------------ */

static backend_t b_resctrl = {
    .backend_id  = "resctrl_mbm",
    .description = "resctrl mbm_total_bytes summed across L3 domains",
    .probe = resctrl_probe, .init = resctrl_init_,
    .read  = resctrl_read_, .cleanup = resctrl_cleanup_,
};
static backend_t b_imc = {
    .backend_id  = "perf_uncore_imc",
    .description = "Intel uncore IMC CAS_COUNT.RD+WR (CAP_SYS_ADMIN)",
    .probe = imc_probe, .init = imc_init,
    .read  = pu_read,    .cleanup = pu_cleanup,
};
static backend_t b_amd_df = {
    .backend_id  = "perf_amd_df",
    .description = "AMD Data Fabric DRAM data beats (CAP_SYS_ADMIN)",
    .probe = amd_df_probe, .init = amd_df_init,
    .read  = pu_read,       .cleanup = pu_cleanup,
};
static backend_t b_arm_cmn = {
    .backend_id  = "perf_arm_cmn",
    .description = "ARM CMN HN-F memory traffic (CAP_SYS_ADMIN)",
    .probe = arm_cmn_probe, .init = arm_cmn_init,
    .read  = pu_read,        .cleanup = pu_cleanup,
};

static metric_t m = {
    .metric_name = "mbw",
    .backends    = { &b_imc, &b_amd_df, &b_arm_cmn, &b_resctrl },
    .n_backends  = 4,
};

metric_t *metric_mbw(void) { return &m; }

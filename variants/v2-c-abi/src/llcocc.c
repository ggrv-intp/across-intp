/*
 * llcocc.c -- LLC occupancy.
 *
 *   1. llcocc_resctrl   resctrl llc_occupancy summed across L3 domains
 *   2. llcocc_proxy     reuse llcmr value as a coarse occupancy indicator
 *                       (status PROXY, backend_id "proxy_from_miss_ratio")
 *
 * The proxy is only a directional signal: a process with many LLC misses
 * is contending for cache, but the value is not directly comparable to
 * occupancy in bytes. It exists so consumers always receive a non-NaN
 * value when at least perf is available.
 */

#include "backend.h"
#include "detect.h"
#include "resctrl.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern double intp_llcmr_last_value(void);  /* defined in llcmr.c */

#define OCC_GROUP_PREFIX "intp_v2_occ"
#define RESCTRL_ROOT_SENTINEL "<root>"

static struct {
    int   valid;
    char  group[64];
    long  llc_size_bytes;
} st;

static long resolve_llc_bytes(void)
{
    const intp_target_t *t = intp_target_get();
    if (t && t->llc_size_bytes_override > 0) return t->llc_size_bytes_override;
    long b = detect_cached()->llc_size_bytes;
    return b > 0 ? b * detect_cached()->num_sockets : 0;
}

/* ---- backend 1: resctrl llc_occupancy ---------------------------------- */

static int resctrl_probe(void)
{
    const system_capabilities_t *c = detect_cached();
    if (!c->resctrl_usable) return -1;
    if (!c->has_rdt_cmt && !c->has_amd_qos && !c->has_arm_mpam) return -1;
    if (resolve_llc_bytes() <= 0) return -1;
    return 0;
}

static int resctrl_init_(void)
{
    /* Same logic as mbw.c: scoped mon_group when --pid is set, root group
     * otherwise, so co-runners are visible when the profiler runs system-wide. */
    const intp_target_t *t = intp_target_get();
    if (t && t->n_pids > 0) {
        snprintf(st.group, sizeof(st.group), "%s_%d", OCC_GROUP_PREFIX, getpid());
        if (resctrl_create_mongroup(st.group) != 0) return -1;
        resctrl_assign_pids(st.group, t->pids, (size_t)t->n_pids);
    } else {
        snprintf(st.group, sizeof(st.group), "%s", RESCTRL_ROOT_SENTINEL);
        if (resctrl_create_mongroup(st.group) != 0) return -1;
    }
    long b = resctrl_read_llc_occupancy(st.group);
    if (b < 0) return -1;
    st.llc_size_bytes = resolve_llc_bytes();
    st.valid = 1;
    return 0;
}

static int resctrl_read_(metric_sample_t *out, double interval_sec)
{
    (void)interval_sec;
    if (!st.valid || st.llc_size_bytes <= 0) return -1;
    long b = resctrl_read_llc_occupancy(st.group);
    if (b < 0) return -1;
    double v = (double)b / (double)st.llc_size_bytes * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;
    out->value      = v;
    out->status     = METRIC_STATUS_OK;
    out->backend_id = "resctrl";
    out->note       = NULL;
    return 0;
}

static void resctrl_cleanup_(void)
{
    if (st.valid) {
        resctrl_remove_mongroup(st.group);
        st.valid = 0;
    }
}

/* ---- backend 2: proxy from llcmr --------------------------------------- */

static int proxy_probe(void)
{
    /* Proxy is usable when llcmr's primary backend is. We avoid reaching
     * into llcmr's probe directly; instead we require perf availability,
     * which is necessary for any miss-ratio backend. */
    const system_capabilities_t *c = detect_cached();
    return c->perf_usable ? 0 : -1;
}

static int proxy_init(void) { return 0; }

static int proxy_read(metric_sample_t *out, double interval_sec)
{
    (void)interval_sec;
    double miss = intp_llcmr_last_value();
    if (isnan(miss)) return -1;
    if (miss < 0.0)  miss = 0.0;
    if (miss > 99.0) miss = 99.0;
    out->value      = miss;
    out->status     = METRIC_STATUS_PROXY;
    out->backend_id = "proxy_from_miss_ratio";
    out->note       = "directional_only";
    return 0;
}

static void proxy_cleanup(void) { }

static backend_t b_resctrl = {
    .backend_id  = "resctrl",
    .description = "resctrl llc_occupancy summed across L3 domains",
    .probe = resctrl_probe, .init = resctrl_init_,
    .read  = resctrl_read_, .cleanup = resctrl_cleanup_,
};

static backend_t b_proxy = {
    .backend_id  = "proxy_from_miss_ratio",
    .description = "directional-only proxy: llcmr percentage",
    .probe = proxy_probe, .init = proxy_init,
    .read  = proxy_read,   .cleanup = proxy_cleanup,
};

static metric_t m = {
    .metric_name = "llcocc",
    .backends    = { &b_resctrl, &b_proxy },
    .n_backends  = 2,
};

metric_t *metric_llcocc(void) { return &m; }

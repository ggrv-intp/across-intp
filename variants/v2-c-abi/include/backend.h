/*
 * backend.h -- Backend interface and registry for V2 metrics.
 *
 * A backend is a (probe, init, read, cleanup) tuple that knows how to
 * collect one metric through one specific kernel interface. Multiple
 * backends per metric form an ordered fallback chain.
 *
 * Lifecycle:
 *   probe()   -- 0 if usable on this host (cheap, no side effects)
 *   init()    -- 0 on success, allocates resources (fds, mon_groups, ...)
 *   read()    -- fills *out, returns 0 on success
 *   cleanup() -- releases all resources, must be safe to call twice
 */

#ifndef INTP_BACKEND_H
#define INTP_BACKEND_H

#include "intp.h"

typedef struct backend {
    const char *backend_id;             /* short identifier in output         */
    const char *description;            /* human-readable, for --list-backends */
    int  (*probe)(void);
    int  (*init)(void);
    int  (*read)(metric_sample_t *out, double interval_sec);
    void (*cleanup)(void);
} backend_t;

/* Target binding -- set by main before metric_init_all().                    */
typedef struct {
    pid_t       pids[INTP_MAX_PIDS];
    int         n_pids;
    const char *cgroup_path;            /* may be NULL                        */
    const char *iface;                  /* may be NULL = autodetect           */
    const char *disk;                   /* may be NULL = autodetect           */
    long        nic_speed_bps_override; /* 0 = use detection                  */
    long        mem_bw_max_bps_override;/* 0 = use detection                  */
    long        llc_size_bytes_override;/* 0 = use detection                  */
} intp_target_t;

void intp_target_set(const intp_target_t *t);
const intp_target_t *intp_target_get(void);

/* All seven metrics -- accessors returning the singleton metric_t.            */
metric_t *metric_netp(void);
metric_t *metric_nets(void);
metric_t *metric_blk(void);
metric_t *metric_mbw(void);
metric_t *metric_llcmr(void);
metric_t *metric_llcocc(void);
metric_t *metric_cpu(void);

/* Registry helpers used by main. */
metric_t **intp_all_metrics(int *n_out);

/* Probe and select active backend. Returns 0 if at least one metric bound. */
int  metric_select_backend(metric_t *m);

/* Initialize the previously-selected backend. */
int  metric_init(metric_t *m);

/* Read latest sample using the active backend (or returns UNAVAILABLE).      */
void metric_read(metric_t *m, metric_sample_t *out, double interval_sec);

/* Cleanup all backends that were init'd. Idempotent. */
void metric_cleanup(metric_t *m);

/* Override selection for --force-backend. Returns 0 if id matched. */
int  metric_force_backend(metric_t *m, const char *backend_id);

/* Disable a metric entirely (--disable-metric). */
void metric_disable(metric_t *m);

/* Public helpers shared with the unit tests -- safe to call at startup. */
int  intp_parse_pid_list(const char *spec, pid_t *out, int max);
int  intp_find_pids_by_comm(const char *comm, pid_t *out, int max);
long netp_resolve_speed(const char *iface, int *assumed_out);

#endif /* INTP_BACKEND_H */

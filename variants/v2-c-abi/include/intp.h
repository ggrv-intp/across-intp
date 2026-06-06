/*
 * intp.h -- Public types for the V2 hybrid IntP profiler.
 *
 * V2 collects 7 interference metrics through stable Linux kernel ABIs only:
 *   netp, nets, blk, mbw, llcmr, llcocc, cpu
 *
 * Each metric has an ordered list of backends (resctrl, perf_event_open,
 * procfs, sysfs, ...). At startup the runtime probes each backend in order
 * and binds the first one that succeeds. Backend results are surfaced via
 * metric_sample_t so consumers can distinguish "real reading" from
 * "degraded approximation" or "proxy from another metric".
 */

#ifndef INTP_H
#define INTP_H

#include <stdio.h>
#include <stddef.h>
#include <sys/types.h>

#define INTP_MAX_BACKENDS_PER_METRIC 4
#define INTP_MAX_PIDS                256
#define INTP_VERSION                 "v2-0.1"

typedef enum {
    METRIC_STATUS_OK,            /* primary backend, value reliable           */
    METRIC_STATUS_UNAVAILABLE,   /* no backend usable on this system          */
    METRIC_STATUS_DEGRADED,      /* using fallback or approximation           */
    METRIC_STATUS_PROXY          /* value derived from a related metric       */
} metric_status_t;

typedef struct {
    double          value;       /* percentage [0,100] or rate as documented  */
    metric_status_t status;
    const char     *backend_id;  /* "resctrl", "perf_uncore_imc", etc.        */
    const char     *note;        /* human-readable diagnostic, may be NULL    */
} metric_sample_t;

/* Forward decl: defined in backend.h */
struct backend;

typedef struct {
    const char       *metric_name;                              /* "mbw", ... */
    struct backend   *backends[INTP_MAX_BACKENDS_PER_METRIC];   /* primary first */
    int               n_backends;
    struct backend   *active;                                   /* selected at probe time */
} metric_t;

#endif /* INTP_H */

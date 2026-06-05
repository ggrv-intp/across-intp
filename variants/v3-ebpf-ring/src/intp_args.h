/*
 * intp_args.h -- command-line arguments for intp-ebpf.
 */

#ifndef INTP_V3_ARGS_H
#define INTP_V3_ARGS_H

#include <stdio.h>
#include <sys/types.h>

#include "intp.bpf.h"     /* INTP_MAX_PIDS */

typedef struct {
    pid_t  pids[INTP_MAX_PIDS];
    int    num_pids;
    const char *cgroup;

    double interval_sec;    /* default 1.0 */
    double duration_sec;    /* -1 = infinite */

    const char *output_fmt; /* "tsv" | "json" | "prometheus" */
    int    want_header;     /* TSV header on by default */

    int    ringbuf_mib;     /* 0 = use compile-time default */
    int    no_perf_events;
    int    no_resctrl;
    int    list_capabilities;

    int    verbose;
    int    trace;

    long   nic_speed_bps_override;   /* 0 = autodetect */
    long   mem_bw_max_bps_override;  /* 0 = autodetect */
    long   llc_size_bytes_override;  /* 0 = autodetect */
} intp_args_t;

/* Parse argv into args. Returns 0 on success, -1 on usage error, 1 if
 * help was requested (caller should exit 0 after). */
int  intp_args_parse(int argc, char **argv, intp_args_t *out);

/* Print usage text to stream (fd). */
void intp_args_usage(const char *prog, FILE *out);

#endif /* INTP_V3_ARGS_H */

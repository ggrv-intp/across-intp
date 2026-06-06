/*
 * intp_agg_args.h -- command-line arguments for intp-eBPF-CORE (V3.2).
 *
 * Mostly identical to V3's intp_args.h with these deltas:
 *   - removed: --ringbuf-size (no ring buffer in V3.2)
 *   - removed: --trace        (no per-event records to trace)
 *   - added:   --clip-mbw     (default off; cap mbw_pct at 99 like V3)
 *   - added:   --no-raw-mbw   (default off; suppress mbw_raw_mbps column)
 */

#ifndef INTP_V32_ARGS_H
#define INTP_V32_ARGS_H

#include <stdio.h>
#include <sys/types.h>

#include "intp_agg.bpf.h"     /* INTP_MAX_PIDS */

typedef struct {
    pid_t  pids[INTP_MAX_PIDS];
    int    num_pids;
    const char *cgroup;

    double interval_sec;    /* default 1.0 */
    double duration_sec;    /* -1 = infinite */

    const char *output_fmt; /* "tsv" | "json" | "prometheus" */
    int    want_header;     /* TSV header on by default */

    int    no_perf_events;
    int    no_resctrl;
    int    list_capabilities;

    int    verbose;

    /* V3.2-only knobs. */
    int    clip_mbw;        /* 1 = legacy V3 cap-at-99 clipping (default off) */
    int    no_raw_mbw;      /* 1 = suppress mbw_raw_mbps column (default off) */
    const char *per_pid_output;  /* NULL or path to per-TGID TSV stream */

    long   nic_speed_bps_override;   /* 0 = autodetect */
    long   mem_bw_max_bps_override;  /* 0 = autodetect */
    long   llc_size_bytes_override;  /* 0 = autodetect */
} intp_args_t;

/* Parse argv into args. Returns 0 on success, -1 on usage error, 1 if
 * help was requested (caller should exit 0 after). */
int  intp_args_parse(int argc, char **argv, intp_args_t *out);

/* Print usage text to stream (fd). */
void intp_args_usage(const char *prog, FILE *out);

#endif /* INTP_V32_ARGS_H */

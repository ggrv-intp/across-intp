/*
 * resctrl.h -- resctrl helper for V3.2.
 *
 * V3.2 collects software metrics via in-kernel eBPF aggregation, but
 * hardware metrics (mbw, llcocc) still go through the resctrl
 * filesystem: eBPF cannot touch the RDT/MPAM MSRs under the kernel
 * verifier. Same operational model as V3 (one mon_group per run, PIDs
 * written into tasks file, counters summed across mon_L3_* domains).
 *
 * V3.2 deltas vs. V3:
 *   - resctrl_read_mbm_pct_and_raw() reads both percent AND raw MB/s
 *     in a single counter step, so the userspace caller can emit both
 *     the normalized column (clipped or unclipped per --clip-mbw) and
 *     the new mbw_raw_mbps trailing column without double-advancing
 *     the prev_mbm_bytes counter.
 *   - The clip-at-100 behavior is OPT-IN (clip_at_100 flag), not the
 *     hard default the V3 helper hard-codes. The paper documents
 *     (section IV-E) that V3's silent clip is what produces the bimodal
 *     discrete pattern 96/80/64/48/32/16/0 -- not measurement.
 */

#ifndef INTP_V3_RESCTRL_H
#define INTP_V3_RESCTRL_H

#include <stddef.h>
#include <sys/types.h>

#include "detect.h"

#define RESCTRL_PATH_MAX    384
#define RESCTRL_MAX_DOMAINS 32

typedef struct resctrl_group resctrl_group_t;

/* Mount /sys/fs/resctrl if needed. Returns 0 on success, -1 otherwise. */
int resctrl_ensure_mounted(void);

/* Create (or adopt) a monitoring group and return an opaque handle.
 * The handle tracks the previous mbm sample so resctrl_read_mbm_delta()
 * can compute a delta across intervals. Returns NULL on failure. */
resctrl_group_t *resctrl_create_group(const char *name);

/* Return a handle pointing at the resctrl root group (system-wide).
 * The root group's tasks file already contains every task on the
 * system by default, so its mon_data reflects aggregate bandwidth and
 * occupancy. Use this when running without --pid to detect interference
 * anywhere on the box. The destroy path is a no-op for the root handle. */
resctrl_group_t *resctrl_use_root_group(void);

/* Assign PIDs to the group's tasks file. Safe to call again to add more. */
int resctrl_assign_pids(resctrl_group_t *g, const pid_t *pids, size_t n_pids);

/* Assign every thread (TID) of every PID to the group. Needed because
 * resctrl's tasks file is populated per-tid, not per-pid, and by default
 * new threads inherit from CTRL_MON rather than the mon_group. */
int resctrl_assign_pid_threads(resctrl_group_t *g,
                               const pid_t *pids, size_t n_pids);

/* Read MBM and compute normalized utilization over the interval.
 *   returned value: (delta_bytes / interval_sec) / max_bw_bps * 100
 * On first call returns 0.0 (no previous sample to diff against).
 * interval_sec is the wall-clock interval since the last call by the caller.
 * caps is used for max bandwidth and whether MBM is available.
 *
 * Hard-clips at 100% for backwards compatibility with V3 consumers.
 * V3.2 prefers resctrl_read_mbm_pct_and_raw() instead. */
double resctrl_read_mbm_delta(resctrl_group_t *g,
                              const system_capabilities_t *caps,
                              double interval_sec);

/* V3.2 combined reader: computes BOTH the percent (clipped or unclipped
 * per the clip_at_100 flag) and the raw MB/s in a single counter step,
 * so callers can emit both columns without double-advancing the
 * prev_mbm_bytes counter.
 *
 * Returns 0 on success; *out_pct and *out_mbps are written.
 * Returns -1 on failure (e.g., MBM unavailable). On first call after
 * group creation *out_pct = 0.0 and *out_mbps = 0.0 (no diff yet). */
int resctrl_read_mbm_pct_and_raw(resctrl_group_t *g,
                                 const system_capabilities_t *caps,
                                 double interval_sec,
                                 int clip_at_100,
                                 double *out_pct,
                                 double *out_mbps);

/* Current LLC occupancy as percentage of LLC size in caps. Returns 0.0
 * if llcocc is unavailable. */
double resctrl_read_llcocc(resctrl_group_t *g,
                           const system_capabilities_t *caps);

/* Raw readers (sum across mon_L3_* domains). -1 on error. */
long resctrl_raw_mbm_total(const resctrl_group_t *g);
long resctrl_raw_llcocc(const resctrl_group_t *g);

/* Tear down the monitoring group: removes /sys/fs/resctrl/mon_groups/<name>
 * and frees the handle. Safe to call with NULL. */
void resctrl_destroy_group(resctrl_group_t *g);

/* RMID accounting (for capability reporting). */
int resctrl_max_rmids(void);
int resctrl_rmids_in_use(void);

#endif /* INTP_V3_RESCTRL_H */

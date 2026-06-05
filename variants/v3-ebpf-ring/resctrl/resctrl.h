/*
 * resctrl.h -- resctrl helper for V3.
 *
 * V3 collects software metrics through eBPF, but hardware metrics (mbw,
 * llcocc) must go through the resctrl filesystem: eBPF cannot touch the
 * RDT/MPAM MSRs under the kernel verifier. The helper here creates a
 * mon_group, assigns PIDs into it, and sums counter files across all
 * mon_L3_* domains at every sample.
 *
 * API shape mirrors what the V3 spec asks for:
 *   resctrl_create_group()      -- allocate a handle + mon_group dir
 *   resctrl_assign_pids()       -- push PIDs into the group's tasks file
 *   resctrl_read_mbm_delta()    -- normalized utilization %, delta since last call
 *   resctrl_read_llcocc()       -- normalized occupancy %, current reading
 *   resctrl_destroy_group()     -- rmdir + free
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
 * caps is used for max bandwidth and whether MBM is available. */
double resctrl_read_mbm_delta(resctrl_group_t *g,
                              const system_capabilities_t *caps,
                              double interval_sec);

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

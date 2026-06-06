/*
 * perfev.h -- perf_event_open(2) wrappers used by llcmr and mbw backends.
 */

#ifndef INTP_PERFEV_H
#define INTP_PERFEV_H

#include <stdint.h>
#include <sys/types.h>

/* Open a perf event. pid/cpu rules per perf_event_open(2). Returns fd,
 * or -1 with errno set. The returned fd is enabled+reset. */
int perfev_open(uint32_t type, uint64_t config, pid_t pid, int cpu);

/* Read raw counter value. */
int perfev_read(int fd, uint64_t *value);

/* Read with enabled/running times for multiplexing-aware scaling.
 *   scaled = value * enabled / running   (when running > 0). */
int perfev_read_scaled(int fd, uint64_t *value,
                       uint64_t *enabled, uint64_t *running);

/* Convenience: open LL cache "loads" and "misses" for the given target.
 * pid > 0 for per-task; pid == -1 for system-wide (cpu must be set).
 * On failure both fd_loads and fd_misses are -1, return -1. */
int perfev_open_llc_cache(pid_t pid, int *fd_loads, int *fd_misses);

/* Convenience: open Intel uncore IMC CAS_COUNT.RD and .WR on every
 * uncore_imc_* PMU. Allocates fds_out via malloc; caller frees both
 * fds_out (after closing each fd). Returns number of fds (== 2 * channels)
 * or -1 on failure. */
int perfev_open_uncore_imc_intel(int **fds_out);

/* Convenience: open AMD Data Fabric DRAM events on every amd_df PMU. */
int perfev_open_amd_df(int **fds_out);

/* Convenience: open ARM CMN HN-F memory controller events. */
int perfev_open_arm_cmn(int **fds_out);

void perfev_close(int fd);

#endif /* INTP_PERFEV_H */

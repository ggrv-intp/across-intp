/*
 * test-target.c -- unit tests for target parsing and override propagation.
 *
 * Covers:
 *   - intp_parse_pid_list("1,2,3") -> 3 PIDs, correct values
 *   - intp_find_pids_by_comm(<own comm>) includes our own pid
 *   - nic_speed_bps_override flows through netp_resolve_speed
 */

#include "backend.h"
#include "intp.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define ASSERT(cond)                                                    \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr,                                             \
                    "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            return 1;                                                   \
        }                                                               \
    } while (0)

static int test_parse_pid_list(void)
{
    pid_t pids[INTP_MAX_PIDS];
    int n = intp_parse_pid_list("1,2,3", pids, INTP_MAX_PIDS);
    ASSERT(n == 3);
    ASSERT(pids[0] == 1);
    ASSERT(pids[1] == 2);
    ASSERT(pids[2] == 3);

    /* Trailing garbage stops parsing without changing already-parsed PIDs. */
    n = intp_parse_pid_list("42,abc", pids, INTP_MAX_PIDS);
    ASSERT(n == 1);
    ASSERT(pids[0] == 42);

    /* Zero/negative PIDs are rejected. */
    n = intp_parse_pid_list("0,1", pids, INTP_MAX_PIDS);
    ASSERT(n == 0);
    return 0;
}

/* Read /proc/self/comm so the test does not depend on "bash" being present. */
static int read_self_comm(char *buf, size_t buf_size)
{
    FILE *f = fopen("/proc/self/comm", "r");
    if (!f) return -1;
    if (!fgets(buf, (int)buf_size, f)) { fclose(f); return -1; }
    fclose(f);
    size_t n = strlen(buf);
    while (n && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';
    return 0;
}

static int test_find_pids_by_comm(void)
{
    char comm[64];
    if (read_self_comm(comm, sizeof(comm)) != 0 || !comm[0]) {
        printf("  SKIP find_pids_by_comm: /proc/self/comm unreadable\n");
        return 0;
    }
    pid_t pids[INTP_MAX_PIDS];
    int n = intp_find_pids_by_comm(comm, pids, INTP_MAX_PIDS);
    ASSERT(n >= 1);
    int found = 0;
    pid_t me = getpid();
    for (int i = 0; i < n; i++)
        if (pids[i] == me) { found = 1; break; }
    ASSERT(found);
    return 0;
}

static int test_nic_speed_override(void)
{
    intp_target_t tgt;
    memset(&tgt, 0, sizeof(tgt));
    tgt.nic_speed_bps_override = 10000000000L;   /* 10 Gb/s */
    intp_target_set(&tgt);

    int assumed = -1;
    long bps = netp_resolve_speed("eth0", &assumed);
    ASSERT(bps == 10000000000L);
    ASSERT(assumed == 0);

    /* Clearing the override should fall through to detection (and when the
     * named iface does not exist, to the DEFAULT_BPS assumed path). */
    memset(&tgt, 0, sizeof(tgt));
    intp_target_set(&tgt);
    assumed = -1;
    bps = netp_resolve_speed("__no_such_iface__", &assumed);
    ASSERT(bps > 0);
    ASSERT(assumed == 1);
    return 0;
}

int main(void)
{
    if (test_parse_pid_list()       != 0) return 1;
    if (test_find_pids_by_comm()    != 0) return 1;
    if (test_nic_speed_override()   != 0) return 1;
    printf("test-target: OK (pid-list, comm match, nic-speed override)\n");
    return 0;
}

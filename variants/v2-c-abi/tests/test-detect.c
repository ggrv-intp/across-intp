/*
 * test-detect.c -- minimal sanity checks for detect.c.
 *
 * These tests run on whatever system is doing the build; they assert
 * invariants (e.g. detect_num_cores() > 0) rather than specific hardware.
 */

#include "detect.h"

#include <stdio.h>
#include <string.h>

#define ASSERT(cond)                                                    \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr,                                             \
                    "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            return 1;                                                   \
        }                                                               \
    } while (0)

int main(void)
{
    cpu_vendor_t v = detect_cpu_vendor();
    ASSERT(v == VENDOR_INTEL || v == VENDOR_AMD ||
           v == VENDOR_ARM   || v == VENDOR_UNKNOWN);

    const char *model = detect_cpu_model();
    ASSERT(model != NULL);
    ASSERT(strlen(model) > 0);

    ASSERT(detect_num_cores() >= 1);
    ASSERT(detect_num_sockets() >= 1);

    int paranoid = detect_perf_paranoid_level();
    ASSERT(paranoid >= -1 && paranoid <= 4);

    int ma = 0, mi = 0;
    ASSERT(detect_kernel_version(&ma, &mi) == 0);
    ASSERT(ma > 0);

    system_capabilities_t caps;
    detect_all(&caps);
    ASSERT(caps.num_cores >= 1);
    ASSERT(strlen(caps.cpu_model) > 0);
    ASSERT(strlen(caps.default_iface) > 0);

    /* mem_bw_max_bps must be positive (default fallback if no detection). */
    ASSERT(caps.mem_bw_max_bps > 0);

    printf("test-detect: OK (vendor=%d cores=%d kernel=%d.%d)\n",
           (int)v, caps.num_cores, ma, mi);
    return 0;
}

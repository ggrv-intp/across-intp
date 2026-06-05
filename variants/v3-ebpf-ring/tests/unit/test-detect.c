/*
 * test-detect.c -- smoke tests for detect.c.
 *
 * Purely host-side: no BPF involvement. We check that detect_all()
 * returns plausible values on any Linux host (cores >= 1, a default
 * iface, a kernel version, etc.). Detailed per-platform checks are
 * out of scope.
 *
 * Build (from variants/v3-ebpf-ring/):
 *   cc -I detect -I src -o tests/unit/test-detect \
 *      tests/unit/test-detect.c detect/detect.c
 */

#include "detect.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OK(expr, msg) do { \
    if (!(expr)) { fprintf(stderr, "FAIL: %s  (%s)\n", msg, #expr); return 1; } \
    printf("ok: %s\n", msg); \
} while (0)

int main(void)
{
    system_capabilities_t c;
    detect_all(&c);

    OK(c.num_cores >= 1,              "detects >=1 core");
    OK(c.num_sockets >= 1,            "detects >=1 socket");
    OK(c.kernel_major >= 3,           "kernel version looks sane");
    OK(c.vendor != VENDOR_UNKNOWN
       || strlen(c.cpu_model) > 0,    "vendor or model populated");
    OK(c.llc_size_bytes >= 0,         "LLC size non-negative");
    OK(c.mem_bw_max_bps >  0,         "memory bandwidth has a default");
    OK(strlen(c.default_iface) > 0,   "default iface populated");

    /* Cached accessor returns the same content. */
    const system_capabilities_t *cc = detect_cached();
    OK(cc != NULL,                    "detect_cached returns non-NULL");
    OK(cc->num_cores == c.num_cores,  "cached matches fresh read");

    /* Printing should not crash. */
    print_capabilities(&c, stdout);
    return 0;
}

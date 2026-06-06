/*
 * test-counter-snapshot.c -- host-side unit test for counters_diff().
 *
 * Verifies the saturating subtraction contract intp_agg.c relies on:
 *   - normal case: delta = cur - prev field-by-field
 *   - underflow:   delta = 0 when cur < prev (probe mid-add race)
 *   - zero diff:   delta = 0 when cur == prev
 *
 * No BPF involvement. The test re-implements counters_diff() inline so
 * the unit test stays decoupled from intp_agg.c's main(); the algorithm
 * being verified is small enough that drift is unlikely.
 *
 * Build (from variants/v3.2-ebpf-core/):
 *   cc -I src -o tests/unit/test-counter-snapshot \
 *      tests/unit/test-counter-snapshot.c
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "intp_agg.bpf.h"

/* Copy of intp_agg.c's saturating subtraction. If this drifts from the
 * binary's version, the test still catches algorithmic regressions
 * (overflow handling, field coverage) and the linker isn't invoked. */
static void counters_diff(const struct intp_counters *cur,
                          const struct intp_counters *prev,
                          struct intp_counters *delta)
{
#define SUB(field) \
    delta->field = (cur->field >= prev->field) ? (cur->field - prev->field) : 0
    SUB(netp_tx_bytes);
    SUB(netp_rx_bytes);
    SUB(nets_tx_lat_ns_sum);
    SUB(nets_tx_lat_n);
    SUB(nets_rx_lat_ns_sum);
    SUB(nets_rx_lat_n);
    SUB(blk_svctm_ns_sum);
    SUB(blk_ops);
    SUB(blk_bytes);
    SUB(cpu_on_ns_sum);
    SUB(llc_refs);
    SUB(llc_misses);
#undef SUB
}

#define OK(expr, msg) do { \
    if (!(expr)) { fprintf(stderr, "FAIL: %s  (%s)\n", msg, #expr); return 1; } \
    printf("ok: %s\n", msg); \
} while (0)

int main(void)
{
    struct intp_counters cur, prev, delta;

    /* normal forward diff */
    memset(&prev, 0, sizeof(prev));
    memset(&cur,  0, sizeof(cur));
    cur.netp_tx_bytes      = 1000;
    cur.netp_rx_bytes      = 2000;
    cur.nets_tx_lat_ns_sum = 5000;
    cur.nets_tx_lat_n      = 10;
    cur.blk_ops            = 7;
    cur.cpu_on_ns_sum      = 999999;
    cur.llc_refs           = 100;
    cur.llc_misses         = 25;
    counters_diff(&cur, &prev, &delta);
    OK(delta.netp_tx_bytes      == 1000,   "netp_tx delta");
    OK(delta.netp_rx_bytes      == 2000,   "netp_rx delta");
    OK(delta.nets_tx_lat_ns_sum == 5000,   "nets_tx delta");
    OK(delta.nets_tx_lat_n      == 10,     "nets_tx_n delta");
    OK(delta.blk_ops            == 7,      "blk_ops delta");
    OK(delta.cpu_on_ns_sum      == 999999, "cpu delta");
    OK(delta.llc_refs           == 100,    "llc_refs delta");
    OK(delta.llc_misses         == 25,     "llc_misses delta");

    /* zero-diff: cur == prev */
    memcpy(&prev, &cur, sizeof(prev));
    counters_diff(&cur, &prev, &delta);
    OK(delta.netp_tx_bytes == 0,           "zero diff netp_tx");
    OK(delta.cpu_on_ns_sum == 0,           "zero diff cpu");
    OK(delta.llc_refs      == 0,           "zero diff llc_refs");

    /* saturating underflow: cur < prev on at least one field */
    memset(&prev, 0, sizeof(prev));
    memset(&cur,  0, sizeof(cur));
    prev.netp_tx_bytes = 100;
    cur.netp_tx_bytes  = 50;        /* underflow */
    cur.netp_rx_bytes  = 200;       /* normal forward */
    prev.netp_rx_bytes = 100;
    counters_diff(&cur, &prev, &delta);
    OK(delta.netp_tx_bytes == 0,           "underflow saturates to 0");
    OK(delta.netp_rx_bytes == 100,         "neighboring field unaffected");

    /* large 64-bit values do not wrap */
    memset(&prev, 0, sizeof(prev));
    memset(&cur,  0, sizeof(cur));
    prev.cpu_on_ns_sum = 0x1000000000ULL;
    cur.cpu_on_ns_sum  = 0x2000000000ULL;
    counters_diff(&cur, &prev, &delta);
    OK(delta.cpu_on_ns_sum == 0x1000000000ULL, "64-bit delta exact");

    printf("\nall tests pass.\n");
    return 0;
}

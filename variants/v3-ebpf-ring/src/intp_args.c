/*
 * intp_args.c -- argument parser for intp-ebpf.
 */

#include "intp_args.h"

#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_pid_list(const char *spec, pid_t *out, int max)
{
    if (!spec || !out || max <= 0) return 0;
    int n = 0;
    const char *p = spec;
    while (*p && n < max) {
        char *end;
        long v = strtol(p, &end, 10);
        if (end == p || v <= 0) break;
        out[n++] = (pid_t)v;
        if (*end == ',') p = end + 1;
        else             p = end;
    }
    return n;
}

void intp_args_usage(const char *prog, FILE *out)
{
    fprintf(out,
        "Usage: %s [options]\n"
        "\n"
        "Target selection:\n"
        "  --pids PID[,PID...]     monitor specific PIDs (default: system-wide)\n"
        "  --cgroup PATH           monitor PIDs listed in <PATH>/cgroup.procs\n"
        "\n"
        "Sampling:\n"
        "  --interval SECONDS      sampling interval (default 1.0)\n"
        "  --duration SECONDS      total run time (default infinite)\n"
        "  --output FORMAT         tsv (default) | json | prometheus\n"
        "  --no-header             suppress TSV column header\n"
        "\n"
        "eBPF configuration:\n"
        "  --ringbuf-size MiB      ring buffer size (default 16)\n"
        "  --no-perf-events        disable llcmr perf_event programs\n"
        "  --no-resctrl            disable resctrl (skip mbw, llcocc)\n"
        "  --list-capabilities     print detected capabilities and exit\n"
        "\n"
        "Hardware overrides:\n"
        "  --nic-speed-bps N       NIC speed in bytes/sec (default: autodetect)\n"
        "  --mem-bw-max-bps N      max memory bandwidth in bytes/sec (default: autodetect)\n"
        "  --llc-size-bytes N      total LLC size in bytes (default: autodetect)\n"
        "\n"
        "Verbosity:\n"
        "  --verbose               enable libbpf verifier log\n"
        "  --trace                 print each event as it arrives\n"
        "\n"
        "  -h, --help              show this help\n",
        prog);
}

int intp_args_parse(int argc, char **argv, intp_args_t *out)
{
    if (!out) return -1;
    memset(out, 0, sizeof(*out));

    out->interval_sec = 1.0;
    out->duration_sec = -1.0;
    out->output_fmt   = "tsv";
    out->want_header  = 1;
    out->ringbuf_mib  = 0;     /* 0 = default in main */

    enum {
        O_PIDS = 1000, O_CGROUP, O_INTERVAL, O_DURATION, O_OUTPUT,
        O_NO_HEADER, O_RINGBUF, O_NO_PERF, O_NO_RES, O_LIST_CAPS,
        O_VERBOSE, O_TRACE, O_NIC_SPEED, O_MEM_BW, O_LLC_SIZE
    };

    static struct option long_opts[] = {
        { "pids",              required_argument, NULL, O_PIDS },
        { "cgroup",            required_argument, NULL, O_CGROUP },
        { "interval",          required_argument, NULL, O_INTERVAL },
        { "duration",          required_argument, NULL, O_DURATION },
        { "output",            required_argument, NULL, O_OUTPUT },
        { "no-header",         no_argument,       NULL, O_NO_HEADER },
        { "ringbuf-size",      required_argument, NULL, O_RINGBUF },
        { "no-perf-events",    no_argument,       NULL, O_NO_PERF },
        { "no-resctrl",        no_argument,       NULL, O_NO_RES },
        { "list-capabilities", no_argument,       NULL, O_LIST_CAPS },
        { "verbose",           no_argument,       NULL, O_VERBOSE },
        { "trace",             no_argument,       NULL, O_TRACE },
        { "nic-speed-bps",     required_argument, NULL, O_NIC_SPEED },
        { "mem-bw-max-bps",    required_argument, NULL, O_MEM_BW },
        { "llc-size-bytes",    required_argument, NULL, O_LLC_SIZE },
        { "help",              no_argument,       NULL, 'h' },
        { 0, 0, 0, 0 }
    };

    int c;
    while ((c = getopt_long(argc, argv, "h", long_opts, NULL)) != -1) {
        switch (c) {
        case O_PIDS:
            out->num_pids = parse_pid_list(optarg, out->pids, INTP_MAX_PIDS);
            if (out->num_pids == 0) {
                fprintf(stderr, "invalid --pids '%s'\n", optarg);
                return -1;
            }
            break;
        case O_CGROUP:
            out->cgroup = optarg;
            break;
        case O_INTERVAL:
            out->interval_sec = atof(optarg);
            if (out->interval_sec <= 0.0) {
                fprintf(stderr, "--interval must be > 0\n");
                return -1;
            }
            break;
        case O_DURATION:
            out->duration_sec = atof(optarg);
            break;
        case O_OUTPUT:
            out->output_fmt = optarg;
            break;
        case O_NO_HEADER:
            out->want_header = 0;
            break;
        case O_RINGBUF: {
            int m = atoi(optarg);
            if (m <= 0 || m > 1024) {
                fprintf(stderr, "--ringbuf-size must be 1..1024 MiB\n");
                return -1;
            }
            out->ringbuf_mib = m;
            break;
        }
        case O_NO_PERF:    out->no_perf_events    = 1; break;
        case O_NO_RES:     out->no_resctrl        = 1; break;
        case O_LIST_CAPS:  out->list_capabilities = 1; break;
        case O_VERBOSE:    out->verbose           = 1; break;
        case O_TRACE:      out->trace             = 1; break;
        case O_NIC_SPEED:  out->nic_speed_bps_override  = atol(optarg); break;
        case O_MEM_BW:     out->mem_bw_max_bps_override = atol(optarg); break;
        case O_LLC_SIZE:   out->llc_size_bytes_override = atol(optarg); break;
        case 'h':
            intp_args_usage(argv[0], stdout);
            return 1;
        default:
            intp_args_usage(argv[0], stderr);
            return -1;
        }
    }

    if (strcmp(out->output_fmt, "tsv") != 0 &&
        strcmp(out->output_fmt, "json") != 0 &&
        strcmp(out->output_fmt, "prometheus") != 0) {
        fprintf(stderr, "--output must be tsv | json | prometheus\n");
        return -1;
    }
    return 0;
}

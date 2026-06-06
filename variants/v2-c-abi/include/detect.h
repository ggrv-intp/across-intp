/*
 * detect.h -- Hardware and environment capability detection for V2.
 *
 * Detection is read-only (cpuinfo, sysfs, /proc, optional dmidecode). It
 * never modifies kernel state. Results are cached in system_capabilities_t
 * so backends and main can share a single detection pass.
 */

#ifndef INTP_DETECT_H
#define INTP_DETECT_H

#include <stdio.h>

typedef enum {
    VENDOR_INTEL,
    VENDOR_AMD,
    VENDOR_ARM,
    VENDOR_UNKNOWN
} cpu_vendor_t;

typedef enum {
    ENV_BAREMETAL,
    ENV_CONTAINER,
    ENV_VM,
    ENV_UNKNOWN
} exec_env_t;

/* CPU and topology */
cpu_vendor_t  detect_cpu_vendor(void);
const char   *detect_cpu_model(void);
int           detect_num_sockets(void);
int           detect_num_cores(void);

/* RDT / resctrl capabilities */
int  detect_rdt_cmt(void);            /* Intel Cache Monitoring Technology   */
int  detect_rdt_mbm(void);            /* Memory Bandwidth Monitoring         */
int  detect_amd_qos(void);            /* AMD Platform QoS (Rome+)            */
int  detect_arm_mpam(void);           /* ARM MPAM (kernel 6.19+)             */
int  detect_resctrl_mounted(void);    /* /sys/fs/resctrl mounted             */
int  detect_resctrl_mountable(void);  /* can mount it ourselves              */

/* perf_event_open capabilities */
int  detect_perf_available(void);
int  detect_perf_paranoid_level(void);  /* -1..4, or 4 if unreadable          */
int  detect_perf_uncore_imc(void);      /* /sys/devices/uncore_imc_*          */
int  detect_perf_amd_df(void);          /* /sys/devices/amd_df                */
int  detect_perf_arm_cmn(void);         /* /sys/devices/arm_cmn_*             */

/* Kernel and environment */
int          detect_kernel_version(int *major, int *minor);
exec_env_t   detect_execution_environment(void);
int          detect_pmu_passthrough(void);

/* Hardware constants (rate-limit normalization) */
long  detect_nic_speed_bps(const char *iface);  /* -1 if unknown               */
long  detect_llc_size_bytes(void);
long  detect_memory_bandwidth_max_bps(void);
const char *detect_default_iface(void);
int   detect_default_disk(char *out, size_t out_sz);

typedef struct {
    cpu_vendor_t vendor;
    char         cpu_model[128];
    int          num_sockets;
    int          num_cores;

    int has_rdt_cmt;
    int has_rdt_mbm;
    int has_amd_qos;
    int has_arm_mpam;
    int resctrl_usable;

    int perf_usable;
    int perf_paranoid;
    int perf_uncore_imc;
    int perf_amd_df;
    int perf_arm_cmn;

    exec_env_t env;
    int        pmu_passthrough;       /* only meaningful if env == ENV_VM     */

    int  kernel_major;
    int  kernel_minor;

    long nic_speed_bps;               /* -1 if unknown                        */
    long llc_size_bytes;
    long mem_bw_max_bps;
    char default_iface[64];
    char default_disk[64];
} system_capabilities_t;

void detect_all(system_capabilities_t *caps);
void print_capabilities(const system_capabilities_t *caps, FILE *out);

/* Cached after first detect_all() so backends can read without re-detecting. */
const system_capabilities_t *detect_cached(void);

#endif /* INTP_DETECT_H */

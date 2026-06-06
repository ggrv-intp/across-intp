/*
 * detect.c -- runtime capability detection (V3).
 *
 * Mirrors V2's detection logic (same interfaces). Kept as a separate copy
 * so V3 can be built in isolation without a shared library. The two files
 * should be kept in sync when either variant's detection evolves.
 */

#include "detect.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define V3_VERSION "v3-0.1"

static system_capabilities_t g_caps;
static int                   g_caps_ready;

static int file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

static int dir_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int read_first_line(const char *path, char *buf, size_t bufsz)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(buf, (int)bufsz, f)) { fclose(f); return -1; }
    fclose(f);
    size_t n = strlen(buf);
    while (n && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
        buf[--n] = '\0';
    return 0;
}

static int read_long_file(const char *path, long *out)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int matched = fscanf(f, "%ld", out);
    fclose(f);
    return matched == 1 ? 0 : -1;
}

static const char *cpuinfo_text(void)
{
    static char buf[16384];
    static int  loaded;
    if (loaded) return buf;
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) { buf[0] = '\0'; loaded = 1; return buf; }
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = '\0';
    fclose(f);
    loaded = 1;
    return buf;
}

static int cpu_flag_present(const char *flag)
{
    const char *txt  = cpuinfo_text();
    const char *line = strstr(txt, "\nflags");
    if (!line) line  = strstr(txt, "\nFeatures");
    if (!line) return 0;
    const char *eol = strchr(line + 1, '\n');
    if (!eol) eol = line + strlen(line);
    size_t len = strlen(flag);
    for (const char *p = line; p < eol; p++) {
        if ((p == line || isspace((unsigned char)p[-1])) &&
            strncmp(p, flag, len) == 0 &&
            (p + len == eol || isspace((unsigned char)p[len]))) {
            return 1;
        }
    }
    return 0;
}

cpu_vendor_t detect_cpu_vendor(void)
{
    const char *txt = cpuinfo_text();
    if (strstr(txt, "GenuineIntel")) return VENDOR_INTEL;
    if (strstr(txt, "AuthenticAMD")) return VENDOR_AMD;
    if (strstr(txt, "ARM") || strstr(txt, "aarch64") ||
        strstr(txt, "CPU implementer"))
        return VENDOR_ARM;
    return VENDOR_UNKNOWN;
}

const char *detect_cpu_model(void)
{
    static char model[128];
    if (model[0]) return model;

    const char *txt  = cpuinfo_text();
    const char *line = strstr(txt, "model name");
    if (!line) line  = strstr(txt, "Model");
    if (!line) line  = strstr(txt, "Hardware");
    if (!line) { snprintf(model, sizeof(model), "unknown"); return model; }
    const char *colon = strchr(line, ':');
    if (!colon) { snprintf(model, sizeof(model), "unknown"); return model; }
    colon++;
    while (*colon == ' ' || *colon == '\t') colon++;
    const char *eol = strchr(colon, '\n');
    size_t len = eol ? (size_t)(eol - colon) : strlen(colon);
    if (len >= sizeof(model)) len = sizeof(model) - 1;
    memcpy(model, colon, len);
    model[len] = '\0';
    return model;
}

int detect_num_sockets(void)
{
    const char *txt = cpuinfo_text();
    int seen[128] = {0};
    int max = 0;
    const char *p = txt;
    while ((p = strstr(p, "physical id")) != NULL) {
        const char *colon = strchr(p, ':');
        if (!colon) break;
        int id = atoi(colon + 1);
        if (id >= 0 && id < (int)(sizeof(seen)/sizeof(seen[0]))) {
            if (!seen[id]) { seen[id] = 1; max++; }
        }
        p = colon;
    }
    return max > 0 ? max : 1;
}

int detect_num_cores(void)
{
    int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? n : 1;
}

static int resctrl_feature_listed(const char *needle)
{
    FILE *f = fopen("/sys/fs/resctrl/info/L3_MON/mon_features", "r");
    if (!f) return 0;
    char line[128];
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, needle)) { found = 1; break; }
    }
    fclose(f);
    return found;
}

int detect_rdt_cmt(void)
{
    if (resctrl_feature_listed("llc_occupancy")) return 1;
    return cpu_flag_present("cqm_occup_llc") || cpu_flag_present("cqm_llc");
}

int detect_rdt_mbm(void)
{
    if (resctrl_feature_listed("mbm_total_bytes")) return 1;
    return cpu_flag_present("cqm_mbm_total") || cpu_flag_present("cqm_mbm_local");
}

int detect_amd_qos(void)
{
    if (detect_cpu_vendor() != VENDOR_AMD) return 0;
    return detect_rdt_cmt() || detect_rdt_mbm();
}

int detect_arm_mpam(void)
{
    if (detect_cpu_vendor() != VENDOR_ARM) return 0;
    return dir_exists("/sys/fs/resctrl/info/L3_MON") ||
           dir_exists("/sys/fs/resctrl/info/MB_MON");
}

int detect_resctrl_mounted(void)
{
    return dir_exists("/sys/fs/resctrl/info") ||
           dir_exists("/sys/fs/resctrl/mon_groups");
}

int detect_resctrl_mountable(void)
{
    if (detect_resctrl_mounted()) return 1;
    if (geteuid() != 0)            return 0;
    if (!dir_exists("/sys/fs/resctrl")) return 0;
    if (mount("resctrl", "/sys/fs/resctrl", "resctrl", 0, NULL) == 0) {
        umount("/sys/fs/resctrl");
        return 1;
    }
    return 0;
}

int detect_perf_available(void)
{
    return file_exists("/proc/sys/kernel/perf_event_paranoid");
}

int detect_perf_paranoid_level(void)
{
    long v = 4;
    if (read_long_file("/proc/sys/kernel/perf_event_paranoid", &v) < 0)
        return 4;
    return (int)v;
}

static int dir_glob_present(const char *parent, const char *prefix)
{
    DIR *d = opendir(parent);
    if (!d) return 0;
    struct dirent *e;
    int found = 0;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, prefix, strlen(prefix)) == 0) {
            found = 1;
            break;
        }
    }
    closedir(d);
    return found;
}

int detect_perf_uncore_imc(void) { return dir_glob_present("/sys/devices", "uncore_imc"); }
int detect_perf_amd_df(void)     { return dir_exists("/sys/devices/amd_df") ||
                                          dir_glob_present("/sys/devices", "amd_df"); }
int detect_perf_arm_cmn(void)    { return dir_glob_present("/sys/devices", "arm_cmn"); }

int detect_kernel_version(int *major, int *minor)
{
    struct utsname u;
    if (uname(&u) != 0) return -1;
    int ma = 0, mi = 0;
    if (sscanf(u.release, "%d.%d", &ma, &mi) != 2) return -1;
    if (major) *major = ma;
    if (minor) *minor = mi;
    return 0;
}

exec_env_t detect_execution_environment(void)
{
    if (file_exists("/sys/hypervisor/type") || cpu_flag_present("hypervisor")) {
        if (!file_exists("/.dockerenv") && !file_exists("/run/.containerenv"))
            return ENV_VM;
    }
    if (file_exists("/.dockerenv") || file_exists("/run/.containerenv"))
        return ENV_CONTAINER;

    char buf[256];
    FILE *f = fopen("/proc/1/cgroup", "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f)) {
            if (strstr(buf, "docker") || strstr(buf, "containerd") ||
                strstr(buf, "lxc")    || strstr(buf, "kubepods")) {
                fclose(f);
                return ENV_CONTAINER;
            }
        }
        fclose(f);
    }
    return ENV_BAREMETAL;
}

static long pmu_probe_cycles(void)
{
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type         = PERF_TYPE_HARDWARE;
    attr.size         = sizeof(attr);
    attr.config       = PERF_COUNT_HW_CPU_CYCLES;
    attr.disabled     = 1;
    attr.exclude_hv   = 1;
    attr.exclude_idle = 1;

    int fd = (int)syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0UL);
    if (fd < 0) return -1;
    if (ioctl(fd, PERF_EVENT_IOC_RESET,  0) < 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) < 0) {
        close(fd);
        return -1;
    }

    struct timespec t0, now;
    if (clock_gettime(CLOCK_MONOTONIC, &t0) != 0) { close(fd); return -1; }
    volatile unsigned long sink = 0;
    do {
        for (int i = 0; i < 1000; i++) sink += (unsigned long)i;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) break;
    } while ((now.tv_sec  - t0.tv_sec)  * 1000000000L +
             (now.tv_nsec - t0.tv_nsec) < 10000000L);
    (void)sink;

    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) < 0) { close(fd); return -1; }
    uint64_t cycles = 0;
    ssize_t n = read(fd, &cycles, sizeof(cycles));
    close(fd);
    if (n != (ssize_t)sizeof(cycles)) return -1;
    return (long)cycles;
}

int detect_pmu_passthrough(void)
{
    if (detect_execution_environment() != ENV_VM) return 1;
    if (!detect_perf_available()) return 0;
    long cycles = pmu_probe_cycles();
    if (cycles < 0)    return 0;
    if (cycles < 1000) return 0;
    return 1;
}

long detect_nic_speed_bps(const char *iface)
{
    if (!iface || !*iface) return -1;
    char path[256];
    snprintf(path, sizeof(path), "/sys/class/net/%.63s/speed", iface);
    long mbps = 0;
    if (read_long_file(path, &mbps) < 0 || mbps <= 0)
        return -1;
    return mbps * 1000000L / 8;   /* Mbps -> bytes/sec */
}

long detect_llc_size_bytes(void)
{
    const char *base = "/sys/devices/system/cpu/cpu0/cache";
    DIR *d = opendir(base);
    if (!d) return 0;

    int  best_level = 0;
    long best_bytes = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "index", 5) != 0) continue;

        char path[320];
        snprintf(path, sizeof(path), "%s/%.63s/level", base, e->d_name);
        long lvl = 0;
        if (read_long_file(path, &lvl) < 0) continue;
        if (lvl <= best_level) continue;

        snprintf(path, sizeof(path), "%s/%.63s/size", base, e->d_name);
        char raw[64];
        if (read_first_line(path, raw, sizeof(raw)) < 0) continue;

        char *end;
        long n = strtol(raw, &end, 10);
        if (n <= 0) continue;
        long bytes = n;
        if (*end == 'K' || *end == 'k') bytes *= 1024L;
        else if (*end == 'M' || *end == 'm') bytes *= 1024L * 1024L;
        else continue;

        best_level = (int)lvl;
        best_bytes = bytes;
    }
    closedir(d);
    return best_bytes;
}

long detect_memory_bandwidth_max_bps(void)
{
    if (geteuid() == 0) {
        FILE *p = popen("dmidecode --type 17 2>/dev/null", "r");
        if (p) {
            long max_mt = 0;
            int  channels = 0;
            char line[256];
            while (fgets(line, sizeof(line), p)) {
                long mt = 0;
                if (sscanf(line, " Configured Memory Speed: %ld MT/s", &mt) == 1 ||
                    sscanf(line, " Speed: %ld MT/s", &mt) == 1) {
                    if (mt > max_mt) max_mt = mt;
                }
                if (strstr(line, "Locator:") && !strstr(line, "Bank Locator"))
                    channels++;
            }
            pclose(p);
            if (max_mt > 0 && channels > 0)
                return (long)max_mt * 8L * channels;
        }
    }
    return 51200000000L;   /* DDR4-3200 dual channel default */
}

const char *detect_default_iface(void)
{
    static char iface[64];
    if (iface[0]) return iface;

    char fallback[64] = {0};
    DIR *d = opendir("/sys/class/net/");
    if (!d) { snprintf(iface, sizeof(iface), "eth0"); return iface; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        if (strcmp(e->d_name, "lo") == 0) continue;
        if (!fallback[0])
            snprintf(fallback, sizeof(fallback), "%.63s", e->d_name);

        char path[320];
        snprintf(path, sizeof(path),
                 "/sys/class/net/%.63s/operstate", e->d_name);
        char state[32] = {0};
        if (read_first_line(path, state, sizeof(state)) == 0 &&
            strcmp(state, "up") == 0) {
            snprintf(iface, sizeof(iface), "%.63s", e->d_name);
            closedir(d);
            return iface;
        }
    }
    closedir(d);
    snprintf(iface, sizeof(iface), "%s", fallback[0] ? fallback : "eth0");
    return iface;
}

int detect_default_disk(char *out, size_t out_sz)
{
    FILE *f = fopen("/proc/diskstats", "r");
    if (!f) return -1;

    char line[512];
    char best[64] = {0};
    while (fgets(line, sizeof(line), f)) {
        unsigned int maj, min;
        char name[64];
        if (sscanf(line, "%u %u %63s", &maj, &min, name) != 3) continue;
        if (strncmp(name, "loop", 4) == 0) continue;
        if (strncmp(name, "ram",  3) == 0) continue;
        if (strncmp(name, "zram", 4) == 0) continue;
        if (strncmp(name, "dm-",  3) == 0) continue;
        size_t len = strlen(name);
        if (len > 0 && name[len-1] >= '0' && name[len-1] <= '9') {
            char *p = strrchr(name, 'p');
            if (p && p > name && p[-1] >= '0' && p[-1] <= '9')
                continue;
            if (strncmp(name, "nvme",   4) != 0 &&
                strncmp(name, "mmcblk", 6) != 0)
                continue;
        }
        snprintf(best, sizeof(best), "%s", name);
        break;
    }
    fclose(f);
    if (!best[0]) return -1;
    snprintf(out, out_sz, "%s", best);
    return 0;
}

void detect_all(system_capabilities_t *caps)
{
    if (!caps) return;
    memset(caps, 0, sizeof(*caps));

    caps->vendor      = detect_cpu_vendor();
    snprintf(caps->cpu_model, sizeof(caps->cpu_model), "%s", detect_cpu_model());
    caps->num_sockets = detect_num_sockets();
    caps->num_cores   = detect_num_cores();

    caps->has_rdt_cmt    = detect_rdt_cmt();
    caps->has_rdt_mbm    = detect_rdt_mbm();
    caps->has_amd_qos    = detect_amd_qos();
    caps->has_arm_mpam   = detect_arm_mpam();
    caps->resctrl_usable = detect_resctrl_mounted() || detect_resctrl_mountable();

    caps->perf_usable     = detect_perf_available();
    caps->perf_paranoid   = detect_perf_paranoid_level();
    caps->perf_uncore_imc = detect_perf_uncore_imc();
    caps->perf_amd_df     = detect_perf_amd_df();
    caps->perf_arm_cmn    = detect_perf_arm_cmn();

    caps->env             = detect_execution_environment();
    caps->pmu_passthrough = detect_pmu_passthrough();
    detect_kernel_version(&caps->kernel_major, &caps->kernel_minor);

    snprintf(caps->default_iface, sizeof(caps->default_iface),
             "%s", detect_default_iface());
    caps->nic_speed_bps  = detect_nic_speed_bps(caps->default_iface);
    caps->llc_size_bytes = detect_llc_size_bytes();
    caps->mem_bw_max_bps = detect_memory_bandwidth_max_bps();
    detect_default_disk(caps->default_disk, sizeof(caps->default_disk));

    g_caps       = *caps;
    g_caps_ready = 1;
}

const system_capabilities_t *detect_cached(void)
{
    if (!g_caps_ready) detect_all(&g_caps);
    return &g_caps;
}

static const char *vendor_name(cpu_vendor_t v)
{
    switch (v) {
    case VENDOR_INTEL:   return "Intel";
    case VENDOR_AMD:     return "AMD";
    case VENDOR_ARM:     return "ARM";
    default:             return "unknown";
    }
}

static const char *env_name(exec_env_t e)
{
    switch (e) {
    case ENV_BAREMETAL: return "bare-metal";
    case ENV_CONTAINER: return "container";
    case ENV_VM:        return "vm";
    default:            return "unknown";
    }
}

void print_capabilities(const system_capabilities_t *c, FILE *out)
{
    if (!c || !out) return;
    fprintf(out, "# IntP V1 (%s) capability report\n", V3_VERSION);
    fprintf(out, "  vendor          %s\n", vendor_name(c->vendor));
    fprintf(out, "  model           %s\n", c->cpu_model);
    fprintf(out, "  sockets/cores   %d / %d\n", c->num_sockets, c->num_cores);
    fprintf(out, "  kernel          %d.%d\n", c->kernel_major, c->kernel_minor);
    fprintf(out, "  environment     %s\n", env_name(c->env));
    const char *pmu_str = "n/a";
    if (c->env == ENV_BAREMETAL || c->env == ENV_VM)
        pmu_str = c->pmu_passthrough ? "yes" : "no";
    fprintf(out, "  pmu_passthrough %s\n", pmu_str);
    fprintf(out, "  resctrl mounted %s\n",
            detect_resctrl_mounted() ? "yes" : "no");
    fprintf(out, "  resctrl usable  %s\n", c->resctrl_usable ? "yes" : "no");
    fprintf(out, "  RDT CMT/MBM     %s / %s\n",
            c->has_rdt_cmt ? "yes" : "no",
            c->has_rdt_mbm ? "yes" : "no");
    fprintf(out, "  AMD QoS         %s\n", c->has_amd_qos  ? "yes" : "no");
    fprintf(out, "  ARM MPAM        %s\n", c->has_arm_mpam ? "yes" : "no");
    fprintf(out, "  perf paranoid   %d (%s)\n", c->perf_paranoid,
            c->perf_paranoid <= -1 ? "uncore allowed" :
            c->perf_paranoid <=  1 ? "per-task allowed"
                                   : "restricted");
    fprintf(out, "  perf uncore IMC %s\n", c->perf_uncore_imc ? "yes" : "no");
    fprintf(out, "  perf AMD DF     %s\n", c->perf_amd_df    ? "yes" : "no");
    fprintf(out, "  perf ARM CMN    %s\n", c->perf_arm_cmn   ? "yes" : "no");
    fprintf(out, "  default iface   %s (%ld bytes/sec)\n",
            c->default_iface, c->nic_speed_bps);
    fprintf(out, "  default disk    %s\n",
            c->default_disk[0] ? c->default_disk : "(none)");
    fprintf(out, "  LLC size        %ld bytes\n", c->llc_size_bytes);
    fprintf(out, "  mem BW max      %ld bytes/sec\n", c->mem_bw_max_bps);
}

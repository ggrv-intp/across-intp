/*
 * resctrl.c -- V3 resctrl helper.
 *
 * Same operational model as V2: one mon_group per run, PIDs written into
 * the tasks file, counters summed across every mon_L3_* domain. The
 * difference is the API shape: V3 consumers want a group *handle* so the
 * helper can track the previous MBM sample and compute a delta each
 * interval without the caller holding state.
 */

#include "resctrl.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define RESCTRL_ROOT "/sys/fs/resctrl"

struct resctrl_group {
    char                name[64];
    char                dir[RESCTRL_PATH_MAX];
    long long           prev_mbm_bytes;   /* -1 = no prior sample */
    int                 is_root;          /* 1 = handle points at RESCTRL_ROOT (no rmdir on destroy) */
};

static int dir_exists(const char *p)
{
    struct stat s;
    return stat(p, &s) == 0 && S_ISDIR(s.st_mode);
}

int resctrl_ensure_mounted(void)
{
    if (dir_exists(RESCTRL_ROOT "/info") ||
        dir_exists(RESCTRL_ROOT "/mon_groups"))
        return 0;
    if (!dir_exists(RESCTRL_ROOT)) return -1;
    if (geteuid() != 0)            return -1;
    if (mount("resctrl", RESCTRL_ROOT, "resctrl", 0, NULL) == 0) return 0;
    return -1;
}

resctrl_group_t *resctrl_create_group(const char *name)
{
    if (!name || !*name)             return NULL;
    if (resctrl_ensure_mounted() != 0) return NULL;

    resctrl_group_t *g = calloc(1, sizeof(*g));
    if (!g) return NULL;
    snprintf(g->name, sizeof(g->name), "%s", name);
    snprintf(g->dir,  sizeof(g->dir),
             "%s/mon_groups/%s", RESCTRL_ROOT, name);

    if (mkdir(g->dir, 0755) != 0 && errno != EEXIST) {
        free(g);
        return NULL;
    }
    g->prev_mbm_bytes = -1;
    g->is_root = 0;
    return g;
}

resctrl_group_t *resctrl_use_root_group(void)
{
    if (resctrl_ensure_mounted() != 0) return NULL;
    /* Root group must already have mon_data populated by the kernel. */
    if (!dir_exists(RESCTRL_ROOT "/mon_data")) return NULL;
    resctrl_group_t *g = calloc(1, sizeof(*g));
    if (!g) return NULL;
    snprintf(g->name, sizeof(g->name), "%s", "<root>");
    snprintf(g->dir,  sizeof(g->dir),  "%s", RESCTRL_ROOT);
    g->prev_mbm_bytes = -1;
    g->is_root = 1;
    return g;
}

int resctrl_assign_pids(resctrl_group_t *g,
                        const pid_t *pids, size_t n_pids)
{
    if (!g || !pids || n_pids == 0) return -1;

    char tasks[RESCTRL_PATH_MAX + 16];
    snprintf(tasks, sizeof(tasks), "%s/tasks", g->dir);

    int accepted = 0;
    for (size_t i = 0; i < n_pids; i++) {
        FILE *f = fopen(tasks, "w");
        if (!f) return -1;
        if (fprintf(f, "%d\n", (int)pids[i]) > 0) accepted++;
        fclose(f);
    }
    return accepted > 0 ? 0 : -1;
}

/* Walk /proc/<pid>/task/<tid>/children breadth-first, collecting every
 * transitive descendant TGID of root. Mirror of the v2 helper and of the
 * v3.1 ResctrlReader._collect_descendants Python helper. Required because
 * resctrl auto-inherits the mon_group across fork only after a task is
 * written into tasks; pre-existing forks (stress-ng stressor children)
 * are otherwise invisible. */
static size_t collect_descendants_via_proc(pid_t root, pid_t *out, size_t cap)
{
    if (!out || cap == 0 || root <= 0) return 0;
    enum { QMAX = 4096 };
    pid_t queue[QMAX];
    size_t qhead = 0, qtail = 0;
    queue[qtail++] = root;

    size_t n = 0;
    while (qhead < qtail && n < cap) {
        pid_t pid = queue[qhead++];
        out[n++] = pid;

        char taskdir[64];
        snprintf(taskdir, sizeof(taskdir), "/proc/%d/task", (int)pid);
        DIR *td = opendir(taskdir);
        if (!td) continue;

        struct dirent *e;
        while ((e = readdir(td)) != NULL) {
            if (e->d_name[0] == '.') continue;
            char children_path[320];
            snprintf(children_path, sizeof(children_path),
                     "/proc/%d/task/%s/children", (int)pid, e->d_name);
            FILE *cf = fopen(children_path, "r");
            if (!cf) continue;
            int child;
            while (fscanf(cf, "%d", &child) == 1) {
                if (child > 0 && qtail < QMAX)
                    queue[qtail++] = (pid_t)child;
            }
            fclose(cf);
        }
        closedir(td);
    }
    return n;
}

int resctrl_assign_pid_threads(resctrl_group_t *g,
                               const pid_t *pids, size_t n_pids)
{
    if (!g || !pids || n_pids == 0) return -1;

    char tasks[RESCTRL_PATH_MAX + 16];
    snprintf(tasks, sizeof(tasks), "%s/tasks", g->dir);

    /* Expand input PID list with every descendant currently visible.
     * Threads of each process are still walked explicitly below because
     * resctrl is per-TID. */
    enum { ALL_CAP = 8192 };
    pid_t *all = calloc(ALL_CAP, sizeof(pid_t));
    if (!all) return -1;
    size_t total = 0;
    for (size_t i = 0; i < n_pids && total < ALL_CAP; i++) {
        total += collect_descendants_via_proc(pids[i],
                                              all + total,
                                              ALL_CAP - total);
    }

    int accepted = 0;
    for (size_t i = 0; i < total; i++) {
        char taskdir[RESCTRL_PATH_MAX];
        snprintf(taskdir, sizeof(taskdir), "/proc/%d/task", (int)all[i]);
        DIR *td = opendir(taskdir);
        if (!td) {
            /* Process exited mid-walk: write the bare TGID, accept what
             * the kernel returns. */
            FILE *f = fopen(tasks, "w");
            if (f) {
                if (fprintf(f, "%d\n", (int)all[i]) > 0) accepted++;
                fclose(f);
            }
            continue;
        }
        struct dirent *e;
        while ((e = readdir(td)) != NULL) {
            if (e->d_name[0] == '.') continue;
            int tid = atoi(e->d_name);
            if (tid <= 0) continue;
            FILE *f = fopen(tasks, "w");
            if (!f) continue;
            if (fprintf(f, "%d\n", tid) > 0) accepted++;
            fclose(f);
        }
        closedir(td);
    }
    free(all);
    return accepted > 0 ? 0 : -1;
}

static int enumerate_domains(const resctrl_group_t *g,
                             const char *filename,
                             char paths[][RESCTRL_PATH_MAX],
                             int max_domains)
{
    char base[RESCTRL_PATH_MAX + 16];
    snprintf(base, sizeof(base), "%s/mon_data", g->dir);

    DIR *d = opendir(base);
    if (!d) return 0;

    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < max_domains) {
        if (strncmp(e->d_name, "mon_L3_", 7) != 0) continue;
        char p[RESCTRL_PATH_MAX];
        snprintf(p, sizeof(p), "%.200s/%.32s/%.64s",
                 base, e->d_name, filename);
        struct stat st;
        if (stat(p, &st) != 0) continue;
        snprintf(paths[n], RESCTRL_PATH_MAX, "%s", p);
        n++;
    }
    closedir(d);
    return n;
}

static long sum_paths(char paths[][RESCTRL_PATH_MAX], int n_paths)
{
    unsigned long long sum = 0;
    int seen = 0;
    for (int i = 0; i < n_paths; i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        unsigned long long v = 0;
        if (fscanf(f, "%llu", &v) == 1) { sum += v; seen = 1; }
        fclose(f);
    }
    return seen ? (long)sum : -1;
}

static long sum_counter(const resctrl_group_t *g, const char *file)
{
    char paths[RESCTRL_MAX_DOMAINS][RESCTRL_PATH_MAX];
    int  n = enumerate_domains(g, file, paths, RESCTRL_MAX_DOMAINS);
    if (n == 0) return -1;
    return sum_paths(paths, n);
}

long resctrl_raw_llcocc(const resctrl_group_t *g)
{
    if (!g) return -1;
    return sum_counter(g, "llc_occupancy");
}

long resctrl_raw_mbm_total(const resctrl_group_t *g)
{
    if (!g) return -1;
    return sum_counter(g, "mbm_total_bytes");
}

double resctrl_read_mbm_delta(resctrl_group_t *g,
                              const system_capabilities_t *caps,
                              double interval_sec)
{
    if (!g || !caps) return 0.0;
    if (!caps->has_rdt_mbm && !caps->has_amd_qos && !caps->has_arm_mpam)
        return 0.0;
    if (interval_sec <= 0.0) return 0.0;

    long now = sum_counter(g, "mbm_total_bytes");
    if (now < 0) return 0.0;

    if (g->prev_mbm_bytes < 0) {
        g->prev_mbm_bytes = now;
        return 0.0;
    }

    long long delta = now - g->prev_mbm_bytes;
    g->prev_mbm_bytes = now;
    if (delta < 0) return 0.0;       /* counter wrap */

    if (caps->mem_bw_max_bps <= 0) return 0.0;
    double bw_bps = (double)delta / interval_sec;
    double util  = bw_bps / (double)caps->mem_bw_max_bps * 100.0;
    if (util < 0.0)   util = 0.0;
    if (util > 100.0) util = 100.0;
    return util;
}

int resctrl_read_mbm_pct_and_raw(resctrl_group_t *g,
                                 const system_capabilities_t *caps,
                                 double interval_sec,
                                 int clip_at_100,
                                 double *out_pct,
                                 double *out_mbps)
{
    if (!g || !caps || !out_pct || !out_mbps) return -1;
    *out_pct  = 0.0;
    *out_mbps = 0.0;

    if (!caps->has_rdt_mbm && !caps->has_amd_qos && !caps->has_arm_mpam)
        return -1;
    if (interval_sec <= 0.0) return -1;

    long now = sum_counter(g, "mbm_total_bytes");
    if (now < 0) return -1;

    if (g->prev_mbm_bytes < 0) {
        g->prev_mbm_bytes = now;
        return 0;        /* first call: no diff yet */
    }

    long long delta = now - g->prev_mbm_bytes;
    g->prev_mbm_bytes = now;
    if (delta < 0) return 0;       /* counter wrap */

    double bw_bps = (double)delta / interval_sec;
    *out_mbps = bw_bps / 1e6;

    if (caps->mem_bw_max_bps > 0) {
        double pct = bw_bps / (double)caps->mem_bw_max_bps * 100.0;
        if (pct < 0.0) pct = 0.0;
        /* V3.2: only cap when clip_at_100 is explicitly set (--clip-mbw).
         * Default is unclipped so analysts see the real reading. The
         * legacy cap value is 99 (not 100) to preserve the V3 behavior
         * exactly when --clip-mbw is requested. */
        if (clip_at_100 && pct > 100.0) pct = 99.0;
        *out_pct = pct;
    }
    return 0;
}

double resctrl_read_llcocc(resctrl_group_t *g,
                           const system_capabilities_t *caps)
{
    if (!g || !caps) return 0.0;
    if (!caps->has_rdt_cmt && !caps->has_amd_qos && !caps->has_arm_mpam)
        return 0.0;
    if (caps->llc_size_bytes <= 0) return 0.0;

    long bytes = sum_counter(g, "llc_occupancy");
    if (bytes < 0) return 0.0;

    double pct = (double)bytes / (double)caps->llc_size_bytes * 100.0;
    if (pct < 0.0)   pct = 0.0;
    if (pct > 100.0) pct = 100.0;
    return pct;
}

void resctrl_destroy_group(resctrl_group_t *g)
{
    if (!g) return;
    if (!g->is_root) rmdir(g->dir);   /* never rmdir RESCTRL_ROOT */
    free(g);
}

int resctrl_max_rmids(void)
{
    FILE *f = fopen(RESCTRL_ROOT "/info/L3_MON/num_rmids", "r");
    if (!f) return -1;
    long v = 0;
    int n = fscanf(f, "%ld", &v);
    fclose(f);
    return n == 1 ? (int)v : -1;
}

int resctrl_rmids_in_use(void)
{
    DIR *d = opendir(RESCTRL_ROOT "/mon_groups");
    if (!d) return -1;
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        count++;
    }
    closedir(d);
    return count;
}

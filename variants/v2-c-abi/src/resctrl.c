/*
 * resctrl.c -- monitoring group lifecycle and counter aggregation.
 *
 * Every backend that uses resctrl (mbw, llcocc) goes through this module.
 * Multi-domain summing matters: modern Xeon SP and EPYC expose one
 * mon_L3_NN per L3 cache instance (per socket on Xeon, per CCX on EPYC).
 */

#include "resctrl.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define RESCTRL_ROOT "/sys/fs/resctrl"

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
    if (!dir_exists(RESCTRL_ROOT))
        return -1;
    if (geteuid() != 0)
        return -1;
    if (mount("resctrl", RESCTRL_ROOT, "resctrl", 0, NULL) == 0)
        return 0;
    return -1;
}

/* Special sentinel: when name is "<root>", target the resctrl root group
 * itself instead of a child mon_group. The root group's tasks file already
 * contains every task by default, so its mon_data captures system-wide
 * bandwidth/occupancy. Lifecycle ops (create/remove/assign) on "<root>"
 * are no-ops, which lets the rest of the v2 code stay name-keyed. */
#define RESCTRL_ROOT_SENTINEL "<root>"

static int is_root_group(const char *name)
{
    return name && strcmp(name, RESCTRL_ROOT_SENTINEL) == 0;
}

static void group_dir(const char *name, char *out, size_t outsz)
{
    if (is_root_group(name))
        snprintf(out, outsz, "%s", RESCTRL_ROOT);
    else
        snprintf(out, outsz, "%s/mon_groups/%s", RESCTRL_ROOT, name);
}

static void group_mon_data(const char *name, char *out, size_t outsz)
{
    if (is_root_group(name))
        snprintf(out, outsz, "%s/mon_data", RESCTRL_ROOT);
    else
        snprintf(out, outsz, "%s/mon_groups/%s/mon_data", RESCTRL_ROOT, name);
}

int resctrl_create_mongroup(const char *name)
{
    if (!name || !*name) return -1;
    if (resctrl_ensure_mounted() != 0) return -1;
    /* Root group is implicit — never mkdir RESCTRL_ROOT. */
    if (is_root_group(name))
        return dir_exists(RESCTRL_ROOT "/mon_data") ? 0 : -1;

    char dir[RESCTRL_PATH_MAX];
    group_dir(name, dir, sizeof(dir));
    if (mkdir(dir, 0755) == 0) return 0;
    if (errno == EEXIST) return 0;
    return -1;
}

/* Collect every transitive descendant TGID of root_pid currently visible
 * in /proc, breadth-first via /proc/<pid>/task/<tid>/children. Returns
 * the count written into out[] (capped at out_cap).
 *
 * Why this exists: resctrl auto-inherits the mon_group on fork only AFTER
 * a task is in the group. Workloads such as stress-ng --cache 24 fork
 * their stressor children before the profiler attaches, so writing only
 * the parent PID into tasks misses every child and mbw/llcocc read 0.
 * Walking the pre-existing tree closes that gap. New forks after this
 * point still inherit through the kernel's normal path. */
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

int resctrl_assign_pids(const char *name,
                        const pid_t *pids,
                        size_t n_pids)
{
    if (!name || !pids || n_pids == 0) return -1;
    /* Root group is system-wide by default; nothing to assign. */
    if (is_root_group(name)) return 0;

    char tasks[RESCTRL_PATH_MAX];
    snprintf(tasks, sizeof(tasks),
             "%s/mon_groups/%s/tasks", RESCTRL_ROOT, name);

    /* Expand each input PID to its transitive descendant tree, then write
     * every thread of every process. Threads aren't auto-tracked when only
     * the leader's TID is written (resctrl is per-TID), so we iterate
     * /proc/<pid>/task entries for each process leader. */
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
        char taskdir[64];
        snprintf(taskdir, sizeof(taskdir), "/proc/%d/task", (int)all[i]);
        DIR *td = opendir(taskdir);
        if (!td) {
            /* Process exited mid-walk: just write the bare TGID and
             * accept whatever the kernel reports back. */
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

int resctrl_enumerate_domains(const char *name,
                              const char *filename,
                              char paths[][RESCTRL_PATH_MAX],
                              int max_domains)
{
    char base[RESCTRL_PATH_MAX];
    group_mon_data(name, base, sizeof(base));

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

long resctrl_sum_paths(char paths[][RESCTRL_PATH_MAX], int n_paths)
{
    unsigned long long sum = 0;
    int seen = 0;
    for (int i = 0; i < n_paths; i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        unsigned long long v = 0;
        if (fscanf(f, "%llu", &v) == 1) {
            sum += v;
            seen = 1;
        }
        fclose(f);
    }
    return seen ? (long)sum : -1;
}

static long sum_counter(const char *name, const char *file)
{
    char paths[RESCTRL_MAX_DOMAINS][RESCTRL_PATH_MAX];
    int  n = resctrl_enumerate_domains(name, file, paths, RESCTRL_MAX_DOMAINS);
    if (n == 0) return -1;
    return resctrl_sum_paths(paths, n);
}

long resctrl_read_llc_occupancy(const char *name)
{
    return sum_counter(name, "llc_occupancy");
}

long resctrl_read_mbm_total(const char *name)
{
    return sum_counter(name, "mbm_total_bytes");
}

long resctrl_read_mbm_local(const char *name)
{
    return sum_counter(name, "mbm_local_bytes");
}

int resctrl_remove_mongroup(const char *name)
{
    /* Never rmdir the root resctrl mountpoint. */
    if (is_root_group(name)) return 0;
    char dir[RESCTRL_PATH_MAX];
    group_dir(name, dir, sizeof(dir));
    if (rmdir(dir) == 0) return 0;
    if (errno == ENOENT) return 0;
    return -1;
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

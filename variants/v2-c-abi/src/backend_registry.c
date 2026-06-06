/*
 * backend_registry.c -- target binding and metric_t lifecycle helpers.
 *
 * Holds the singleton intp_target_t and provides metric_select_backend(),
 * metric_init(), metric_read(), metric_cleanup() used by main.
 */

#include "backend.h"
#include "intp.h"

#include <dirent.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static intp_target_t g_target;

void intp_target_set(const intp_target_t *t)
{
    if (t) g_target = *t;
}

const intp_target_t *intp_target_get(void)
{
    return &g_target;
}

int metric_select_backend(metric_t *m)
{
    if (!m) return -1;
    if (m->n_backends == 0) return -1;
    for (int i = 0; i < m->n_backends; i++) {
        backend_t *b = m->backends[i];
        if (!b || !b->probe) continue;
        if (b->probe() == 0) {
            m->active = b;
            return 0;
        }
    }
    m->active = NULL;
    return -1;
}

int metric_init(metric_t *m)
{
    if (!m) return -1;

    /* Tenta a partir do backend ativo. Se init falhar, avanca para o proximo. */
    int start = 0;
    for (int i = 0; i < m->n_backends; i++) {
        if (m->backends[i] == m->active) { start = i; break; }
    }

    for (int i = start; i < m->n_backends; i++) {
        backend_t *b = m->backends[i];
        if (!b || !b->init) continue;
        /* Se nao e o backend ativo original, re-verifica a probe */
        if (i > start && b->probe && b->probe() != 0) continue;
        if (b->init() == 0) {
            m->active = b;
            return 0;
        }
        if (b->cleanup) b->cleanup();
    }

    m->active = NULL;
    return -1;
}

void metric_read(metric_t *m, metric_sample_t *out, double interval_sec)
{
    if (!out) return;
    out->value      = NAN;
    out->status     = METRIC_STATUS_UNAVAILABLE;
    out->backend_id = "none";
    out->note       = NULL;

    if (!m || !m->active || !m->active->read) return;
    if (m->active->read(out, interval_sec) != 0) {
        out->status     = METRIC_STATUS_UNAVAILABLE;
        out->backend_id = m->active->backend_id;
    }
}

void metric_cleanup(metric_t *m)
{
    if (!m) return;
    for (int i = 0; i < m->n_backends; i++) {
        backend_t *b = m->backends[i];
        if (b && b->cleanup) b->cleanup();
    }
    m->active = NULL;
}

int metric_force_backend(metric_t *m, const char *backend_id)
{
    if (!m || !backend_id) return -1;
    for (int i = 0; i < m->n_backends; i++) {
        backend_t *b = m->backends[i];
        if (b && b->backend_id && strcmp(b->backend_id, backend_id) == 0) {
            if (!b->probe || b->probe() == 0) {
                m->active = b;
                return 0;
            }
            return -1;
        }
    }
    return -1;
}

void metric_disable(metric_t *m)
{
    if (m) m->active = NULL;
}

metric_t **intp_all_metrics(int *n_out)
{
    static metric_t *all[7];
    all[0] = metric_netp();
    all[1] = metric_nets();
    all[2] = metric_blk();
    all[3] = metric_mbw();
    all[4] = metric_llcmr();
    all[5] = metric_llcocc();
    all[6] = metric_cpu();
    if (n_out) *n_out = 7;
    return all;
}

int intp_parse_pid_list(const char *spec, pid_t *out, int max)
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

int intp_find_pids_by_comm(const char *comm, pid_t *out, int max)
{
    if (!comm || !out || max <= 0) return 0;
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d)) != NULL && n < max) {
        if (e->d_type != DT_DIR && e->d_type != DT_UNKNOWN) continue;
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        char path[320], buf[256];
        snprintf(path, sizeof(path), "/proc/%.32s/comm", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (fgets(buf, sizeof(buf), f)) {
            size_t len = strlen(buf);
            while (len && (buf[len-1] == '\n' || buf[len-1] == '\r'))
                buf[--len] = '\0';
            if (strcmp(buf, comm) == 0)
                out[n++] = (pid_t)atoi(e->d_name);
        }
        fclose(f);
    }
    closedir(d);
    return n;
}

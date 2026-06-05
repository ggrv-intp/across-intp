/*
 * intp-helper -- userspace daemon for IntP v1.1 hardware metrics.
 *
 * Owns the uncore IMC perf events and the resctrl mon_group, polls them
 * once per second, and writes the latest values atomically to
 * /tmp/intp-hw-data. The SystemTap script reads that file from a procfs
 * read probe (process context, RCU-safe).
 *
 * See DESIGN.md for the architecture and the rationale (why a separate
 * process is needed for kernel >= 5.15).
 *
 * Build: make
 * Usage: intp-helper <comm-pattern>
 *        e.g. intp-helper stress-ng
 *
 * Defaults (override via env):
 *   INTP_HELPER_DRAM_BW_MBPS  nominal DRAM bandwidth in MB/s (default 281600)
 *   INTP_HELPER_L3_SIZE_KB    L3 cache size in KB (default 46080)
 *   INTP_HELPER_INTERVAL_S    polling interval in seconds (default 1)
 *   INTP_HELPER_DATA_FILE     output path (default /tmp/intp-hw-data)
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <linux/perf_event.h>

/* ---- defaults (Xeon Gold 5412U, Sapphire Rapids) ---------------------- */

#define DEFAULT_DRAM_BW_MBPS 281600u   /* 8x DDR5-4800 */
#define DEFAULT_L3_SIZE_KB    46080u   /* 45 MB */
#define DEFAULT_INTERVAL_S        1
#define DEFAULT_DATA_FILE     "/tmp/intp-hw-data"

/* SPR uncore IMC: 12 channels exposed as PMU types 78..89.
 * Configs: 0x0304 = UNC_M_CAS_COUNT.RD, 0x0c04 = UNC_M_CAS_COUNT.WR. */
#define IMC_TYPE_FIRST          78
#define IMC_TYPE_LAST           89
#define IMC_CONFIG_RD       0x0304u
#define IMC_CONFIG_WR       0x0c04u
#define IMC_CACHE_LINE_BYTES    64u
#define IMC_MAX_EVENTS  ((IMC_TYPE_LAST - IMC_TYPE_FIRST + 1) * 2)

#define RESCTRL_ROOT     "/sys/fs/resctrl"

/* ---- globals (signal-handling only) ----------------------------------- */

static volatile sig_atomic_t shutdown_requested = 0;

static void on_signal(int sig) { (void)sig; shutdown_requested = 1; }

/* ---- log helpers ------------------------------------------------------ */

static void logf_(const char *level, const char *fmt, va_list ap) {
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	fprintf(stderr, "[%02d:%02d:%02d] %s: ", tm.tm_hour, tm.tm_min, tm.tm_sec, level);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
}

static void log_info(const char *fmt, ...) {
	va_list ap; va_start(ap, fmt); logf_("info", fmt, ap); va_end(ap);
}

static void log_warn(const char *fmt, ...) {
	va_list ap; va_start(ap, fmt); logf_("warn", fmt, ap); va_end(ap);
}

/* ---- env helpers ------------------------------------------------------ */

static unsigned long getenv_ul(const char *name, unsigned long fallback) {
	const char *s = getenv(name);
	if (!s || !*s) return fallback;
	char *end;
	errno = 0;
	unsigned long v = strtoul(s, &end, 0);
	if (errno || *end) {
		log_warn("ignoring invalid %s=%s", name, s);
		return fallback;
	}
	return v;
}

/* ---- file I/O helpers ------------------------------------------------- */

/* Read up to len-1 bytes from path; null-terminate. Returns bytes read,
 * or -1 on error (errno set). */
static ssize_t read_file(const char *path, char *buf, size_t len) {
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t n = read(fd, buf, len - 1);
	int saved = errno;
	close(fd);
	if (n < 0) { errno = saved; return -1; }
	buf[n] = '\0';
	return n;
}

/* Append a string to a file (used for resctrl tasks). */
static int append_file(const char *path, const char *data, size_t len) {
	int fd = open(path, O_WRONLY | O_APPEND);
	if (fd < 0) return -1;
	ssize_t n = write(fd, data, len);
	int saved = errno;
	close(fd);
	if (n != (ssize_t)len) { errno = saved; return -1; }
	return 0;
}

/* Atomic file replace: write to <path>.tmp.<pid>, then rename. */
static int atomic_replace(const char *path, const char *data, size_t len) {
	char tmp[512];
	snprintf(tmp, sizeof(tmp), "%s.tmp.%d", path, (int)getpid());
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return -1;
	ssize_t n = write(fd, data, len);
	int saved = errno;
	if (close(fd) < 0 && n >= 0) { saved = errno; n = -1; }
	if (n != (ssize_t)len) { unlink(tmp); errno = saved; return -1; }
	if (rename(tmp, path) < 0) { saved = errno; unlink(tmp); errno = saved; return -1; }
	return 0;
}

/* ---- perf_event_open wrapper ------------------------------------------ */

static long perf_event_open(struct perf_event_attr *attr, pid_t pid, int cpu,
                            int group_fd, unsigned long flags) {
	return syscall(SYS_perf_event_open, attr, pid, cpu, group_fd, flags);
}

/* ---- IMC perf events -------------------------------------------------- */

struct imc_events {
	int fds[IMC_MAX_EVENTS];
	int count;
};

static int imc_open_one(int type, uint64_t config) {
	struct perf_event_attr pe;
	memset(&pe, 0, sizeof(pe));
	pe.type = type;
	pe.size = sizeof(pe);
	pe.config = config;
	pe.disabled = 0;
	pe.inherit = 0;
	int fd = (int)perf_event_open(&pe, -1, 0, -1, 0);
	return fd;
}

static int imc_open_all(struct imc_events *ev) {
	ev->count = 0;
	for (int t = IMC_TYPE_FIRST; t <= IMC_TYPE_LAST; t++) {
		int fd_rd = imc_open_one(t, IMC_CONFIG_RD);
		int fd_wr = imc_open_one(t, IMC_CONFIG_WR);
		if (fd_rd >= 0) ev->fds[ev->count++] = fd_rd;
		if (fd_wr >= 0) ev->fds[ev->count++] = fd_wr;
	}
	if (ev->count == 0) {
		log_warn("no IMC events opened (uncore types %d..%d unavailable); "
		         "mbw will report 0", IMC_TYPE_FIRST, IMC_TYPE_LAST);
		return -1;
	}
	log_info("opened %d uncore IMC events", ev->count);
	return 0;
}

static uint64_t imc_read_sum_cas(const struct imc_events *ev) {
	uint64_t total = 0;
	for (int i = 0; i < ev->count; i++) {
		uint64_t v = 0;
		ssize_t n = read(ev->fds[i], &v, sizeof(v));
		if (n == sizeof(v)) total += v;
	}
	return total;
}

static void imc_close_all(struct imc_events *ev) {
	for (int i = 0; i < ev->count; i++) close(ev->fds[i]);
	ev->count = 0;
}

/* ---- resctrl mon_group ------------------------------------------------ */

struct resctrl_state {
	char mon_group[256];     /* /sys/fs/resctrl/mon_groups/intp-<pid> */
	char tasks_path[320];
	char *occ_paths[64];     /* paths to mon_data/mon_L3_<dom>/llc_occupancy */
	int  occ_count;
	int  enabled;
};

/* Find every llc_occupancy file under mon_group/mon_data/. */
static void resctrl_collect_occ_paths(struct resctrl_state *st) {
	char dir[320];
	snprintf(dir, sizeof(dir), "%s/mon_data", st->mon_group);
	DIR *d = opendir(dir);
	if (!d) return;
	struct dirent *e;
	while ((e = readdir(d)) && st->occ_count < (int)(sizeof(st->occ_paths)/sizeof(st->occ_paths[0]))) {
		if (strncmp(e->d_name, "mon_L3_", 7) != 0) continue;
		char p[512];
		snprintf(p, sizeof(p), "%s/%s/llc_occupancy", dir, e->d_name);
		if (access(p, R_OK) == 0) {
			st->occ_paths[st->occ_count++] = strdup(p);
		}
	}
	closedir(d);
}

static int resctrl_setup(struct resctrl_state *st) {
	memset(st, 0, sizeof(*st));

	/* Probe for resctrl. */
	if (access(RESCTRL_ROOT "/info/L3_MON", R_OK) < 0) {
		log_warn("resctrl L3_MON not available; llcocc will report 0");
		return -1;
	}

	snprintf(st->mon_group, sizeof(st->mon_group),
	         "%s/mon_groups/intp-%d", RESCTRL_ROOT, (int)getpid());

	if (mkdir(st->mon_group, 0755) < 0 && errno != EEXIST) {
		log_warn("mkdir(%s) failed: %s; llcocc will report 0",
		         st->mon_group, strerror(errno));
		st->mon_group[0] = '\0';
		return -1;
	}

	snprintf(st->tasks_path, sizeof(st->tasks_path), "%s/tasks", st->mon_group);
	resctrl_collect_occ_paths(st);

	if (st->occ_count == 0) {
		log_warn("no llc_occupancy files found under %s/mon_data; "
		         "llcocc will report 0", st->mon_group);
		rmdir(st->mon_group);
		st->mon_group[0] = '\0';
		return -1;
	}

	st->enabled = 1;
	log_info("resctrl mon_group=%s with %d L3 domain(s)",
	         st->mon_group, st->occ_count);
	return 0;
}

static void resctrl_add_pid(const struct resctrl_state *st, pid_t pid) {
	if (!st->enabled) return;
	char buf[32];
	int n = snprintf(buf, sizeof(buf), "%d\n", (int)pid);
	if (append_file(st->tasks_path, buf, (size_t)n) < 0) {
		/* PID may have died between scan and add: ESRCH is normal. */
		if (errno != ESRCH && errno != EINVAL) {
			log_warn("add pid %d to mon_group: %s", (int)pid, strerror(errno));
		}
	}
}

static uint64_t resctrl_read_occ_bytes(const struct resctrl_state *st) {
	if (!st->enabled) return 0;
	uint64_t total = 0;
	char buf[64];
	for (int i = 0; i < st->occ_count; i++) {
		if (read_file(st->occ_paths[i], buf, sizeof(buf)) <= 0) continue;
		errno = 0;
		uint64_t v = strtoull(buf, NULL, 10);
		if (!errno) total += v;
	}
	return total;
}

static void resctrl_cleanup(struct resctrl_state *st) {
	for (int i = 0; i < st->occ_count; i++) {
		free(st->occ_paths[i]);
	}
	st->occ_count = 0;
	if (st->mon_group[0]) {
		if (rmdir(st->mon_group) < 0 && errno != ENOENT) {
			log_warn("rmdir(%s): %s", st->mon_group, strerror(errno));
		}
		st->mon_group[0] = '\0';
	}
	st->enabled = 0;
}

/* ---- /proc scanner ---------------------------------------------------- */

struct pidset {
	pid_t *pids;
	int    size;
	int    cap;
};

static void pidset_init(struct pidset *s) { s->pids = NULL; s->size = 0; s->cap = 0; }
static void pidset_free(struct pidset *s) { free(s->pids); pidset_init(s); }
static void pidset_clear(struct pidset *s) { s->size = 0; }

static int pidset_push(struct pidset *s, pid_t p) {
	if (s->size >= s->cap) {
		int nc = s->cap ? s->cap * 2 : 32;
		pid_t *np = realloc(s->pids, nc * sizeof(pid_t));
		if (!np) return -1;
		s->pids = np; s->cap = nc;
	}
	s->pids[s->size++] = p;
	return 0;
}

static int pid_cmp(const void *a, const void *b) {
	pid_t x = *(const pid_t *)a, y = *(const pid_t *)b;
	return (x < y) ? -1 : (x > y);
}

static void pidset_sort(struct pidset *s) {
	qsort(s->pids, s->size, sizeof(pid_t), pid_cmp);
}

static int pidset_contains(const struct pidset *s, pid_t p) {
	int lo = 0, hi = s->size - 1;
	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		if (s->pids[mid] == p) return 1;
		if (s->pids[mid] < p) lo = mid + 1;
		else hi = mid - 1;
	}
	return 0;
}

/* Read /proc/<pid>/comm; strip trailing newline. */
static int read_pid_comm(pid_t pid, char *out, size_t outlen) {
	char path[64];
	snprintf(path, sizeof(path), "/proc/%d/comm", (int)pid);
	ssize_t n = read_file(path, out, outlen);
	if (n <= 0) return -1;
	if (out[n - 1] == '\n') out[n - 1] = '\0';
	return 0;
}

/* Walk /proc, fill `out` with PIDs whose comm contains `pattern`. */
static int scan_proc(const char *pattern, struct pidset *out) {
	pidset_clear(out);
	DIR *d = opendir("/proc");
	if (!d) return -1;
	struct dirent *e;
	char comm[32];
	while ((e = readdir(d)) != NULL) {
		if (!isdigit((unsigned char)e->d_name[0])) continue;
		pid_t pid = (pid_t)strtoul(e->d_name, NULL, 10);
		if (pid <= 0) continue;
		if (read_pid_comm(pid, comm, sizeof(comm)) < 0) continue;
		if (strstr(comm, pattern) == NULL) continue;
		pidset_push(out, pid);
	}
	closedir(d);
	pidset_sort(out);
	return 0;
}

/* ---- main loop -------------------------------------------------------- */

struct config {
	const char  *pattern;
	const char  *data_file;
	unsigned long dram_bw_mbps;
	unsigned long l3_size_kb;
	unsigned int  interval_s;
};

static void usage(const char *argv0) {
	fprintf(stderr,
	        "Usage: %s <comm-pattern>\n"
	        "  Polls uncore IMC and resctrl mon_group every %ds, writing\n"
	        "  values to %s.\n\n"
	        "Env:\n"
	        "  INTP_HELPER_DRAM_BW_MBPS  default %u\n"
	        "  INTP_HELPER_L3_SIZE_KB    default %u\n"
	        "  INTP_HELPER_INTERVAL_S    default %u\n"
	        "  INTP_HELPER_DATA_FILE     default %s\n",
	        argv0, DEFAULT_INTERVAL_S, DEFAULT_DATA_FILE,
	        DEFAULT_DRAM_BW_MBPS, DEFAULT_L3_SIZE_KB,
	        DEFAULT_INTERVAL_S, DEFAULT_DATA_FILE);
}

int main(int argc, char **argv) {
	/* line-buffer stderr so log output flushes promptly when redirected */
	setvbuf(stderr, NULL, _IOLBF, 0);

	if (argc != 2 || argv[1][0] == '-') {
		usage(argv[0]);
		return 2;
	}

	struct config cfg = {
		.pattern      = argv[1],
		.data_file    = getenv("INTP_HELPER_DATA_FILE"),
		.dram_bw_mbps = getenv_ul("INTP_HELPER_DRAM_BW_MBPS", DEFAULT_DRAM_BW_MBPS),
		.l3_size_kb   = getenv_ul("INTP_HELPER_L3_SIZE_KB",   DEFAULT_L3_SIZE_KB),
		.interval_s   = (unsigned)getenv_ul("INTP_HELPER_INTERVAL_S", DEFAULT_INTERVAL_S),
	};
	if (!cfg.data_file || !*cfg.data_file) cfg.data_file = DEFAULT_DATA_FILE;
	if (cfg.interval_s == 0) cfg.interval_s = 1;

	log_info("pattern=\"%s\" data_file=%s dram_bw=%lu MB/s l3=%lu KB interval=%us",
	         cfg.pattern, cfg.data_file, cfg.dram_bw_mbps,
	         cfg.l3_size_kb, cfg.interval_s);

	struct sigaction sa = {0};
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT,  &sa, NULL);

	struct imc_events imc;
	imc_open_all(&imc);   /* graceful: count=0 if all failed */

	struct resctrl_state rs;
	resctrl_setup(&rs);   /* graceful: enabled=0 if unavailable */

	struct pidset cur, prev;
	pidset_init(&cur);
	pidset_init(&prev);

	uint64_t prev_cas = imc.count ? imc_read_sum_cas(&imc) : 0;

	const uint64_t bytes_per_s_full = (uint64_t)cfg.dram_bw_mbps * 1000ull * 1000ull;
	const uint64_t l3_bytes_full    = (uint64_t)cfg.l3_size_kb * 1024ull;

	while (!shutdown_requested) {
		struct timespec ts = { .tv_sec = (time_t)cfg.interval_s, .tv_nsec = 0 };
		while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
			if (shutdown_requested) break;
		}
		if (shutdown_requested) break;

		/* PID discovery */
		if (scan_proc(cfg.pattern, &cur) == 0 && rs.enabled) {
			for (int i = 0; i < cur.size; i++) {
				if (!pidset_contains(&prev, cur.pids[i])) {
					resctrl_add_pid(&rs, cur.pids[i]);
				}
			}
		}
		/* swap */
		struct pidset tmp = prev; prev = cur; cur = tmp;
		pidset_clear(&cur);

		/* mbw: cas delta * 64 bytes / interval / nominal bw */
		unsigned mbw_pct = 0;
		if (imc.count) {
			uint64_t now_cas = imc_read_sum_cas(&imc);
			uint64_t delta_cas = (now_cas >= prev_cas) ? (now_cas - prev_cas) : 0;
			prev_cas = now_cas;
			uint64_t bps = delta_cas * IMC_CACHE_LINE_BYTES / cfg.interval_s;
			if (bytes_per_s_full)
				mbw_pct = (unsigned)((bps * 100ull) / bytes_per_s_full);
			if (mbw_pct >= 100) mbw_pct = 99;
		}

		/* llcocc: total bytes / l3 size */
		unsigned llcocc_pct = 0;
		if (rs.enabled) {
			uint64_t occ = resctrl_read_occ_bytes(&rs);
			if (l3_bytes_full)
				llcocc_pct = (unsigned)((occ * 100ull) / l3_bytes_full);
			if (llcocc_pct >= 100) llcocc_pct = 99;
		}

		/* atomic single-line write: <ns>\t<mbw>\t<llcocc>\n */
		struct timespec now;
		clock_gettime(CLOCK_REALTIME, &now);
		uint64_t ns = (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
		char line[96];
		int len = snprintf(line, sizeof(line), "%" PRIu64 "\t%u\t%u\n",
		                   ns, mbw_pct, llcocc_pct);
		if (atomic_replace(cfg.data_file, line, (size_t)len) < 0) {
			log_warn("write %s: %s", cfg.data_file, strerror(errno));
		}
	}

	log_info("shutdown");
	imc_close_all(&imc);
	resctrl_cleanup(&rs);
	pidset_free(&cur);
	pidset_free(&prev);
	unlink(cfg.data_file);
	return 0;
}

# IntP root Makefile — orchestrates per-variant builds.
#
# Compileable variants (C helpers and/or eBPF binaries):
#   variants/v0.2-stap-legacy   — C helper for V0 stap script (target kernel 5.15 GA)
#   variants/v1.1-stap-modern   — C helper for V1 stap module (target kernel 6.8+)
#   variants/v2-hybrid-c    — hybrid procfs/perf_event_open/resctrl backends
#   variants/v3-ebpf-ring     — libbpf+CO-RE BPF program (needs clang, libbpf-dev)
#   variants/v3.2-ebpf-agg— in-kernel-aggregating libbpf+CO-RE BPF program
#
# Validate-only variants (no compile, runtime interpreters):
#   variants/v3.1-bpftrace      — bpftrace .bt scripts (deps + parse check)
#   variants/v0-stap-2022    — original SystemTap script (parse check only)
#   variants/v0.1-stap-nollc      — kernel-6.8 SystemTap port (parse check only)
#   variants/v1-stap-nohelper     — native stap module (parse check only)
#
# Common targets:
#   make all        build every compileable variant + validate the rest
#   make clean      clean every variant tree
#   make smoke      quick 5s sanity invocation per variant (needs sudo)
#   make preflight  host capability check (no installs); see shared/intp-preflight.sh
#   make help       this message
#
# Per-variant targets (build/clean/smoke individually):
#   make v0.2 v1.1 v2 v3 v3.1 v3.2
#   make clean-v0.2 clean-v1.1 clean-v2 clean-v3 clean-v3.1 clean-v3.2
#   make smoke-v1.1 smoke-v2 smoke-v3 smoke-v3.1 smoke-v3.2
#

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

V02_DIR := $(ROOT)/variants/v0.2-stap-legacy
V11_DIR := $(ROOT)/variants/v1.1-stap-modern
V2_DIR  := $(ROOT)/variants/v2-hybrid-c
V3_DIR  := $(ROOT)/variants/v3-ebpf-ring
V31_DIR := $(ROOT)/variants/v3.1-bpftrace
V32_DIR := $(ROOT)/variants/v3.2-ebpf-agg
V0_STP  := $(ROOT)/variants/v0-stap-2022/intp.stp
V01_STP := $(ROOT)/variants/v0.1-stap-nollc/intp-6.8.stp
V1_STP  := $(ROOT)/variants/v1-stap-nohelper/intp-resctrl.stp
V02_STP_TMPL := $(ROOT)/variants/v0.2-stap-legacy/intp.stp.template

.PHONY: all clean smoke help preflight \
        v0.2 v1.1 v2 v3 v3.1 v3.2 \
        clean-v0.2 clean-v1.1 clean-v2 clean-v3 clean-v3.1 clean-v3.2 \
        smoke-v1.1 smoke-v2 smoke-v3 smoke-v3.1 smoke-v3.2 \
        validate-v0 validate-v0.1 validate-v0.2 validate-v1

all: v0.2 v1.1 v2 v3 v3.1 v3.2 validate-v0 validate-v0.1 validate-v0.2 validate-v1
	@echo "[intp] all variants built/validated"

# ---- preflight (host capability check, no installs) -------------------------
# Reports BUILD/RUN status for every variant + the 7-metric coverage map.
# Pass arguments via PREFLIGHT_ARGS, e.g. `make preflight PREFLIGHT_ARGS="--variants v2,v3 --strict"`.
preflight:
	@bash $(ROOT)/shared/intp-preflight.sh $(PREFLIGHT_ARGS)

# ---- compileable variants ----------------------------------------------------

v0.2:
	$(MAKE) -C $(V02_DIR) all

v1.1:
	$(MAKE) -C $(V11_DIR) all

v2:
	$(MAKE) -C $(V2_DIR) all

v3:
	$(MAKE) -C $(V3_DIR) all

v3.2:
	$(MAKE) -C $(V32_DIR) all

# ---- runtime-interpreted variants -------------------------------------------

v3.1:
	$(MAKE) -C $(V31_DIR) deps validate

# V0/V0.1/V1 are runtime-instrumented SystemTap scripts that read @1 (the
# target program name) at parse time and contain embedded C blocks. So
# `stap -p1 <script>` alone fails twice: once because @1 is unresolved
# ("command line argument out of range"), and again because embedded C
# needs -g (guru mode). We pass a placeholder cmdline argument to satisfy
# @1 and -g to permit the embedded C, both of which are no-ops at parse
# time but required to advance past the parser.
validate-v0:
	@command -v stap >/dev/null 2>&1 || { echo "[v0] skip: stap not installed"; exit 0; }
	@test -f $(V0_STP) && stap -g -p1 $(V0_STP) stress-ng >/dev/null && echo "[v0] parse OK"

validate-v0.1:
	@command -v stap >/dev/null 2>&1 || { echo "[v0.1] skip: stap not installed"; exit 0; }
	@test -f $(V01_STP) && stap -g -p1 $(V01_STP) stress-ng >/dev/null && echo "[v0.1] parse OK"

# v0.2 ships a .stp template that needs `generate-stp.sh` to render the actual
# script (the helper exports IMC PMU type / DRAM BW / L3 size as env vars,
# which generate-stp.sh substitutes into intp.recal.stp). At parse time we just
# bash -n the generator; the .stp template is not stap-parseable on its own.
validate-v0.2:
	@test -f $(V02_STP_TMPL) || { echo "[v0.2] skip: template not found"; exit 0; }
	@bash -n $(V02_DIR)/generate-stp.sh && echo "[v0.2] generator parse OK"

validate-v1:
	@command -v stap >/dev/null 2>&1 || { echo "[v1] skip: stap not installed"; exit 0; }
	@test -f $(V1_STP) && stap -g -p1 $(V1_STP) stress-ng >/dev/null && echo "[v1] parse OK"

# ---- clean ------------------------------------------------------------------

clean: clean-v0.2 clean-v1.1 clean-v2 clean-v3 clean-v3.1 clean-v3.2

clean-v0.2:
	-$(MAKE) -C $(V02_DIR) clean

clean-v1.1:
	-$(MAKE) -C $(V11_DIR) clean

clean-v2:
	-$(MAKE) -C $(V2_DIR) clean

clean-v3:
	-$(MAKE) -C $(V3_DIR) clean

clean-v3.1:
	-$(MAKE) -C $(V31_DIR) clean

clean-v3.2:
	-$(MAKE) -C $(V32_DIR) clean

# ---- smoke (5s runtime sanity) ----------------------------------------------
# All require sudo for perf/BPF/stap. v0/v0.1/v1 are excluded — they need
# kernel-tied stap modules that compile per-host and can't be one-shot here.

smoke: smoke-v2 smoke-v3 smoke-v3.1 smoke-v3.2
	@echo "[intp] smoke OK"

smoke-v1.1: v1.1
	@echo "[v1.1] smoke not applicable (helper, not standalone profiler)"

# v0.2 is helper-only too; the actual run needs the recalibrated .stp generated
# at runtime from the helper-exported env. Smoke just confirms the helper builds.
smoke-v0.2: v0.2
	@echo "[v0.2] smoke not applicable (helper, not standalone profiler)"

smoke-v2: v2
	@$(V2_DIR)/intp-hybrid --interval 1 --duration 5 >/dev/null && echo "[v2] smoke OK"

smoke-v3: v3
	@$(V3_DIR)/intp-ebpf --interval 1 --duration 5 >/dev/null && echo "[v3] smoke OK"

smoke-v3.1:
	@$(V31_DIR)/run-intp-bpftrace.sh --interval 1 --duration 5 >/dev/null \
		&& echo "[v3.1] smoke OK"

smoke-v3.2: v3.2
	@$(V32_DIR)/intp-ebpf-agg --interval 1 --duration 5 >/dev/null && echo "[v3.2] smoke OK"

# ---- help -------------------------------------------------------------------

help:
	@sed -n '1,/^$$/p' $(firstword $(MAKEFILE_LIST))

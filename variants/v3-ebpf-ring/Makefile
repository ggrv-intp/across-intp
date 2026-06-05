# V3 eBPF/CO-RE IntP Makefile
#
# Build pipeline:
#   1. Dump running kernel's BTF into src/vmlinux.h        (bpftool btf dump)
#   2. Compile eBPF programs to portable bytecode          (clang -target bpf)
#   3. Generate libbpf skeleton header from BPF object     (bpftool gen skeleton)
#   4. Compile userspace sources                           (gcc/cc)
#   5. Link userspace binary against libbpf                (-lbpf -lelf -lz -lpthread)
#
# Requirements:
#   - Linux kernel 5.8+ with CONFIG_DEBUG_INFO_BTF=y
#   - clang 11+
#   - libbpf 0.8+, libbpf-dev
#   - bpftool (linux-tools-$(uname -r) or linux-tools-generic)
#   - libelf-dev, zlib1g-dev
#
# Ubuntu 24.04:
#   sudo apt install clang libbpf-dev libelf-dev zlib1g-dev \
#                    linux-tools-common linux-tools-generic

CLANG       ?= clang
CC          ?= gcc

# bpftool discovery.
#
# On Ubuntu, `/usr/sbin/bpftool` is a shell wrapper that dispatches to
# `/usr/lib/linux-tools/$(uname -r)/bpftool` and fails hard if the kernel
# doesn't have a matching `linux-tools-$(uname -r)` package. That's common
# on OEM kernels where only `linux-tools-generic` is installed. If the
# default wrapper can't satisfy itself, we fall back to the newest bpftool
# shipped by any linux-tools package on the host.
BPFTOOL     ?= $(shell \
  if bpftool version >/dev/null 2>&1; then \
    echo bpftool; \
  else \
    ls -1 /usr/lib/linux-tools/*/bpftool 2>/dev/null | sort -V | tail -1; \
  fi)

CFLAGS      ?= -g -O2 -Wall -Wextra -Wpedantic -Werror -Wno-overlength-strings -std=c11 -D_GNU_SOURCE
BPF_CFLAGS  ?= -g -O2 -Wall
LDFLAGS     ?=
LDLIBS      ?= -lbpf -lelf -lz -lpthread

SRC_DIR     := src
RESCTRL_DIR := resctrl
DETECT_DIR  := detect

BPF_SRC     := $(SRC_DIR)/intp.bpf.c
BPF_OBJ     := $(SRC_DIR)/intp.bpf.o
BPF_SKEL    := $(SRC_DIR)/intp.skel.h
VMLINUX_H   := $(SRC_DIR)/vmlinux.h

USER_SRCS   := $(SRC_DIR)/intp.c $(SRC_DIR)/intp_args.c \
               $(RESCTRL_DIR)/resctrl.c $(DETECT_DIR)/detect.c
USER_OBJS   := $(USER_SRCS:.c=.o)

BINARY      := intp-ebpf

INCLUDES    := -I$(SRC_DIR) -I$(RESCTRL_DIR) -I$(DETECT_DIR)

# Map uname -m into the clang BPF target macro the kernel headers expect.
UNAME_M     := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
  BPF_ARCH := x86
else ifeq ($(UNAME_M),aarch64)
  BPF_ARCH := arm64
else ifeq ($(UNAME_M),armv7l)
  BPF_ARCH := arm
else
  BPF_ARCH := $(UNAME_M)
endif
BPF_CFLAGS += -target bpf -D__TARGET_ARCH_$(BPF_ARCH) $(INCLUDES)

.PHONY: all clean deps vmlinux skeleton test test-full

all: deps $(BINARY)

deps:
	@command -v $(CLANG) >/dev/null 2>&1 || { echo "ERROR: clang not installed (apt install clang)"; exit 1; }
	@command -v $(BPFTOOL) >/dev/null 2>&1 || { echo "ERROR: bpftool not installed (apt install linux-tools-generic)"; exit 1; }
	@test -f /sys/kernel/btf/vmlinux || { echo "ERROR: /sys/kernel/btf/vmlinux not found -- kernel needs CONFIG_DEBUG_INFO_BTF=y"; exit 1; }
	@pkg-config --exists libbpf 2>/dev/null || test -f /usr/include/bpf/libbpf.h || { echo "ERROR: libbpf not installed (apt install libbpf-dev)"; exit 1; }

# Step 1: vmlinux.h -- auto-generated from the running kernel's BTF.
$(VMLINUX_H):
	@echo "  BTF      $@"
	@$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@

vmlinux: $(VMLINUX_H)

# Step 2: compile eBPF programs. Emit bytecode that CO-RE relocates at load.
$(BPF_OBJ): $(BPF_SRC) $(VMLINUX_H) $(SRC_DIR)/intp.bpf.h
	@echo "  BPF CC   $@"
	@$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# Step 3: libbpf skeleton header encapsulates load/attach/destroy lifecycle.
$(BPF_SKEL): $(BPF_OBJ)
	@echo "  SKEL     $@"
	@$(BPFTOOL) gen skeleton $< > $@

skeleton: $(BPF_SKEL)

# Step 4: userspace objects depend on the skeleton.
$(SRC_DIR)/intp.o: $(SRC_DIR)/intp.c $(BPF_SKEL) $(SRC_DIR)/intp.bpf.h \
                   $(SRC_DIR)/intp_args.h $(RESCTRL_DIR)/resctrl.h \
                   $(DETECT_DIR)/detect.h
	@echo "  CC       $@"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

$(SRC_DIR)/intp_args.o: $(SRC_DIR)/intp_args.c $(SRC_DIR)/intp_args.h
	@echo "  CC       $@"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

$(RESCTRL_DIR)/resctrl.o: $(RESCTRL_DIR)/resctrl.c $(RESCTRL_DIR)/resctrl.h
	@echo "  CC       $@"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

$(DETECT_DIR)/detect.o: $(DETECT_DIR)/detect.c $(DETECT_DIR)/detect.h
	@echo "  CC       $@"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# Step 5: link. -lbpf pulls in libbpf; elf/z are its transitive dependencies.
$(BINARY): $(USER_OBJS)
	@echo "  LD       $@"
	@$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

test: $(BINARY)
	@bash tests/integration/test-load-attach.sh

test-full: $(BINARY)
	@bash tests/integration/test-load-attach.sh
	@bash tests/integration/test-metrics-accuracy.sh
	@bash tests/integration/test-overhead.sh

clean:
	rm -f $(BPF_OBJ) $(BPF_SKEL) $(VMLINUX_H)
	rm -f $(USER_OBJS) $(BINARY)
	rm -f tests/unit/*.o tests/unit/test-detect

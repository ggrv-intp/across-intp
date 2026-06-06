# V2 hybrid IntP -- procfs/perf_event_open/resctrl backends
# C99, glibc, no external libraries beyond libc + libpthread.

CC      ?= gcc
CSTD    ?= -std=c99
WARN     = -Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Werror
OPT     ?= -O2
CFLAGS  ?= $(CSTD) $(WARN) $(OPT) -D_GNU_SOURCE -Iinclude -Isrc
LDFLAGS ?=
LDLIBS   = -lpthread -lm

TARGET   = intp-hybrid

SRCS = \
	intp-hybrid.c \
	src/detect.c \
	src/resctrl.c \
	src/perfev.c \
	src/procutil.c \
	src/backend_registry.c \
	src/cpu.c \
	src/netp.c \
	src/nets.c \
	src/blk.c \
	src/mbw.c \
	src/llcmr.c \
	src/llcocc.c

OBJS = $(SRCS:.c=.o)

TEST_SRCS = tests/test-detect.c tests/test-procutil.c \
            tests/test-backend-registry.c tests/test-target.c
TEST_BINS = $(TEST_SRCS:.c=)

.PHONY: all clean tests run-tests deb help

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS) $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Each test binary links the procutil/detect objects it exercises.
TEST_DEPS       = src/detect.o src/procutil.o src/resctrl.o
# Tests that exercise the backend registry pull in every metric source.
TEST_DEPS_FULL  = $(TEST_DEPS) src/perfev.o src/backend_registry.o \
                  src/cpu.o src/netp.o src/nets.o src/blk.o \
                  src/mbw.o src/llcmr.o src/llcocc.o

tests: $(TEST_BINS)

tests/test-detect: tests/test-detect.c $(TEST_DEPS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

tests/test-procutil: tests/test-procutil.c $(TEST_DEPS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

tests/test-backend-registry: tests/test-backend-registry.c $(TEST_DEPS_FULL)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

tests/test-target: tests/test-target.c $(TEST_DEPS_FULL)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS) $(LDLIBS)

run-tests: tests
	@for t in $(TEST_BINS); do echo "==> $$t"; ./$$t || exit 1; done

deb: $(TARGET)
	@scripts/build-deb.sh

clean:
	rm -f $(TARGET) $(OBJS) $(TEST_BINS)

help:
	@echo "Targets:"
	@echo "  all           build $(TARGET) (default)"
	@echo "  tests         build unit tests"
	@echo "  run-tests     build and execute unit tests"
	@echo "  deb           build Debian package via scripts/build-deb.sh"
	@echo "  clean         remove build artifacts"

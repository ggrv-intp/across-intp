#!/usr/bin/env bash
# build-deb.sh -- build a Debian package for intp-hybrid.
# Pure-fakeroot dpkg-deb; no debhelper / lintian required.

set -euo pipefail

VERSION=${VERSION:-0.1.0}
ARCH=${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/intp-hybrid

if [[ ! -x "$BIN" ]]; then
    echo "intp-hybrid binary missing -- run 'make' first" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PKG=$WORK/intp-hybrid_${VERSION}_${ARCH}

mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/doc/intp-hybrid"
install -m 0755 "$BIN" "$PKG/usr/bin/intp-hybrid"
install -m 0644 "$ROOT/README.md"  "$PKG/usr/share/doc/intp-hybrid/README.md"
install -m 0644 "$ROOT/DESIGN.md"  "$PKG/usr/share/doc/intp-hybrid/DESIGN.md"

cat >"$PKG/DEBIAN/control" <<EOF
Package: intp-hybrid
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Depends: libc6
Maintainer: IntP V2
Description: Hybrid procfs/perf_event/resctrl interference profiler
 V2 implementation of the IntP interference profiler. Uses only stable
 Linux kernel ABIs (procfs, sysfs, perf_event_open, resctrl, cgroups v0.1).
 Runtime backend selection adapts per metric to the host's hardware,
 kernel version, and execution environment.
EOF

OUT=$ROOT/intp-hybrid_${VERSION}_${ARCH}.deb
dpkg-deb --build "$PKG" "$OUT"
echo "wrote $OUT"

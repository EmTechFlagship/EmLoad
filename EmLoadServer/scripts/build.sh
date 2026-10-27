#!/usr/bin/env bash
#
# Build the emloadserver host for the Macs EmLoad runs on.
#
#   ./EmLoadServer/scripts/build.sh
#   ARCHS="x86_64" ./EmLoadServer/scripts/build.sh
#
# Writes a single executable at EmLoadServer/.build/emloadserver. Intel
# (x86_64) and Apple silicon (arm64) are both requested. The host architecture
# is required; the other slice is included when the toolchain can cross-compile.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"

HOST="$(uname -m)"
if [[ -z "${ARCHS:-}" ]]; then
    ARCHS="x86_64 arm64"
fi
# shellcheck disable=SC2206
ARCH_LIST=($ARCHS)

echo "==> Building emloadserver (Swift $(swift --version 2>/dev/null | head -1 || echo 'unknown'))"
SLICES=()
BUILT_ARCHS=()
for arch in "${ARCH_LIST[@]}"; do
    if swift build -c release --package-path "$PKG" --arch "$arch"; then
        slice="$(swift build -c release --package-path "$PKG" --arch "$arch" --show-bin-path)/emloadserver"
        if [[ -x "$slice" ]] && lipo "$slice" -verify_arch "$arch" >/dev/null 2>&1; then
            SLICES+=("$slice")
            BUILT_ARCHS+=("$arch")
            continue
        fi
    fi
    if [[ "$arch" == "$HOST" ]]; then
        echo "error: SwiftPM did not produce an emloadserver executable for $HOST." >&2
        exit 1
    fi
    echo "warning: skipping emloadserver $arch; $HOST will still be included." >&2
done

if [[ ${#SLICES[@]} -eq 0 ]]; then
    echo "error: no emloadserver architectures were built." >&2
    exit 1
fi

BIN="$PKG/.build/emloadserver"
if [[ ${#SLICES[@]} -eq 1 ]]; then
    cp "${SLICES[0]}" "$BIN"
else
    lipo -create "${SLICES[@]}" -output "$BIN"
fi
chmod 755 "$BIN"
echo "==> emloadserver architectures: ${BUILT_ARCHS[*]}"
echo "==> $BIN"
lipo -info "$BIN"

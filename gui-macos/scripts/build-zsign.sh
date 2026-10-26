#!/usr/bin/env bash
#
# Compile zsign for the Macs EmLoad runs on (Intel x86_64 and Apple silicon
# arm64) and write a single binary. Upstream publishes no Intel macOS build,
# so EmLoad builds this from source and links a private static OpenSSL when
# the system one cannot satisfy an architecture.
#
#   ./gui-macos/scripts/build-zsign.sh -o /path/to/zsign
#   ZSIGN_SRC=/Users/emwilson/zsign ./gui-macos/scripts/build-zsign.sh -o zsign
#   ARCHS="x86_64" ./gui-macos/scripts/build-zsign.sh -o zsign
#
# The host architecture is required. Any other requested architecture that
# cannot be compiled is skipped with a warning.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PKG/.." && pwd)"
CACHE="$PKG/.build/zsign-deps"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"
DEST=""
HOST="$(uname -m)"
MIN_OS="13.0"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || printf '4')"

usage() {
    echo "usage: build-zsign.sh -o /path/to/zsign" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            DEST="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$DEST" ]]; then
    usage
fi

find_zsign_src() {
    local candidate
    local candidates=()
    if [[ -n "${ZSIGN_SRC:-}" ]]; then
        candidates+=("$ZSIGN_SRC")
    fi
    candidates+=(
        "/Users/emwilson/zsign"
        "$HOME/zsign"
        "$REPO/../zsign"
        "$CACHE/zsign-src"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate/build/macos/Makefile" && -f "$candidate/src/zsign.cpp" ]]; then
            printf '%s\n' "$(cd "$candidate" && pwd)"
            return 0
        fi
    done
    return 1
}

ensure_zsign_src() {
    if find_zsign_src; then
        return 0
    fi
    echo "==> Cloning zhlynn/zsign" >&2
    mkdir -p "$CACHE"
    git clone --depth 1 https://github.com/zhlynn/zsign.git "$CACHE/zsign-src"
    find_zsign_src
}

openssl_prefix_for() {
    local arch="$1"
    local prefix lib
    local -a prefixes=()
    if [[ -n "${OPENSSL_PREFIX:-}" ]]; then
        prefixes+=("$OPENSSL_PREFIX")
    fi
    prefixes+=(
        "/opt/homebrew/opt/openssl@3"
        "/usr/local/opt/openssl@3"
        "/opt/homebrew/opt/openssl"
        "/usr/local/opt/openssl"
    )
    for prefix in "${prefixes[@]}"; do
        lib="$prefix/lib/libcrypto.a"
        if [[ ! -f "$lib" ]]; then
            lib="$prefix/lib/libcrypto.dylib"
        fi
        if [[ -f "$lib" ]] && lipo "$lib" -verify_arch "$arch" >/dev/null 2>&1; then
            if [[ -f "$prefix/include/openssl/ssl.h" ]]; then
                printf '%s\n' "$prefix"
                return 0
            fi
        fi
    done
    return 1
}

fetch_openssl() {
    local tarball="$CACHE/openssl-$OPENSSL_VERSION.tar.gz"
    local url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        echo "==> Downloading OpenSSL $OPENSSL_VERSION" >&2
        mkdir -p "$CACHE"
        curl -fL --retry 3 -o "$tarball" "$url"
    fi
    if [[ ! -f "$CACHE/openssl-src/Configure" ]]; then
        mkdir -p "$CACHE/openssl-src"
        tar -xzf "$tarball" -C "$CACHE/openssl-src" --strip-components 1
    fi
}

build_openssl() {
    local arch="$1"
    local prefix="$CACHE/openssl/$arch"
    if [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]]; then
        printf '%s\n' "$prefix"
        return 0
    fi
    fetch_openssl
    local target
    case "$arch" in
        x86_64) target="darwin64-x86_64-cc" ;;
        arm64) target="darwin64-arm64-cc" ;;
        *)
            echo "unsupported OpenSSL arch: $arch" >&2
            return 1
            ;;
    esac
    echo "==> Building OpenSSL $OPENSSL_VERSION ($arch)" >&2
    (
        cd "$CACHE/openssl-src"
        make distclean >/dev/null 2>&1 || true
        ./Configure "$target" \
            no-shared \
            no-tests \
            no-zlib \
            --prefix="$prefix" \
            --libdir=lib \
            -mmacosx-version-min="$MIN_OS"
        make -j"$JOBS" -s
        make install_sw -s
    ) >&2
    printf '%s\n' "$prefix"
}

compile_zsign_arch() {
    local arch="$1"
    local src="$2"
    local out="$3"
    local ssl
    ssl="$(openssl_prefix_for "$arch" || true)"
    if [[ -z "$ssl" ]]; then
        ssl="$(build_openssl "$arch")"
    fi
    local objdir="$CACHE/obj/$arch"
    rm -rf "$objdir"
    mkdir -p "$objdir" "$(dirname "$out")"

    local version
    version="$(git -C "$src" describe --tags --always 2>/dev/null | sed 's/^v//' || true)"
    if [[ -z "$version" ]]; then
        version="0.0.0-dev"
    fi

    local file rel obj
    echo "==> Compiling zsign ($arch) from $src"
    while IFS= read -r file; do
        rel="${file#"$src/src/"}"
        obj="$objdir/${rel}.o"
        mkdir -p "$(dirname "$obj")"
        case "$file" in
            *.cpp)
                clang++ -arch "$arch" -mmacosx-version-min="$MIN_OS" -std=c++11 -O3 \
                    -DZSIGN_VERSION="$version" \
                    -I"$src/src" -I"$src/src/common" -I"$src/src/third-party/zlib" \
                    -I"$ssl/include" \
                    -c "$file" -o "$obj"
                ;;
            *.c)
                clang -arch "$arch" -mmacosx-version-min="$MIN_OS" -O3 \
                    -I"$src/src" -I"$src/src/common" -I"$src/src/third-party/zlib" \
                    -I"$ssl/include" \
                    -c "$file" -o "$obj"
                ;;
        esac
    done < <(
        find "$src/src" -type f \( -name '*.cpp' -o -name '*.c' \) \
            ! -path '*/iowin32.c' \
            | sort
    )

    # shellcheck disable=SC2046
    clang++ -arch "$arch" -mmacosx-version-min="$MIN_OS" \
        $(find "$objdir" -type f -name '*.o' | sort) \
        "$ssl/lib/libssl.a" "$ssl/lib/libcrypto.a" \
        -o "$out"
    if ! lipo "$out" -verify_arch "$arch" >/dev/null 2>&1; then
        echo "error: zsign was not built for $arch" >&2
        return 1
    fi
}

SRC="$(ensure_zsign_src)"
if [[ -z "${ARCHS:-}" ]]; then
    ARCHS="x86_64 arm64"
fi
# shellcheck disable=SC2206
ARCH_LIST=($ARCHS)

SLICES=()
BUILT=()
for arch in "${ARCH_LIST[@]}"; do
    slice="$CACHE/zsign-$arch"
    if compile_zsign_arch "$arch" "$SRC" "$slice"; then
        SLICES+=("$slice")
        BUILT+=("$arch")
    elif [[ "$arch" == "$HOST" ]]; then
        echo "error: zsign failed to build for the host architecture ($HOST)." >&2
        exit 1
    else
        echo "warning: skipping zsign $arch; $HOST will still be included." >&2
    fi
done

if [[ ${#SLICES[@]} -eq 0 ]]; then
    echo "error: no zsign architectures were built." >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
if [[ ${#SLICES[@]} -eq 1 ]]; then
    cp "${SLICES[0]}" "$DEST"
else
    lipo -create "${SLICES[@]}" -output "$DEST"
fi
chmod 755 "$DEST"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$DEST" >/dev/null 2>&1 || \
        echo "warning: ad-hoc signing zsign failed" >&2
fi

echo "==> zsign ($(printf '%s ' "${BUILT[@]}")) -> $DEST"
"$DEST" -v

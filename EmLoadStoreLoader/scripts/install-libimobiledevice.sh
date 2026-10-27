#!/bin/bash
#
# Build libimobiledevice and ideviceinstaller from source, without Homebrew.
#
# Installs into ~/.local/opt/libimobiledevice and links the tools
# (idevicepair, idevice_id, ideviceinfo, ideviceinstaller, ...) into ~/.local/bin.
# Nothing is installed system-wide and no sudo is needed.
#
# Requirements: macOS, Xcode command line tools, curl, Python 3 (used for a
# local CMake install when libzip has to be built).
#
# Usage:
#   scripts/install-libimobiledevice.sh
#
# Optional environment variables:
#   EMLOAD_LIBIMOBILEDEVICE_PREFIX  install prefix (default ~/.local/opt/libimobiledevice)
#   EMLOAD_BUILD_DIR                source/build directory (default ~/.cache/emload/libimobiledevice-build)
#   EMLOAD_JOBS                     parallel build jobs (default: number of CPUs)
#
# Re-running the script is safe: finished components are skipped and an
# interrupted build resumes where it stopped.

set -euo pipefail

PREFIX="${EMLOAD_LIBIMOBILEDEVICE_PREFIX:-$HOME/.local/opt/libimobiledevice}"
BINDIR="$HOME/.local/bin"
WORK="${EMLOAD_BUILD_DIR:-$HOME/.cache/emload/libimobiledevice-build}"
LOGS="$WORK/logs"
JOBS="${EMLOAD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

PKGCONF_VERSION=3.0.10
LIBPLIST_VERSION=2.8.0
GLUE_VERSION=1.3.3
USBMUXD_VERSION=2.1.1
LIBTATSU_VERSION=1.0.5
OPENSSL_VERSION=3.5.9
LIBZIP_VERSION=1.12.1
LIBIMOBILEDEVICE_VERSION=1.4.0
IDEVICEINSTALLER_VERSION=1.2.0

[ "$(uname -s)" = "Darwin" ] || { echo "error: this script only supports macOS" >&2; exit 1; }
for command in curl tar xcrun python3; do
  command -v "$command" >/dev/null || { echo "error: $command is required" >&2; exit 1; }
done

mkdir -p "$PREFIX" "$BINDIR" "$LOGS"

export PATH="$PREFIX/bin:$PATH"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"

section() { printf '\n==> %s\n' "$*"; }

# Run a command quietly, keeping its output in the log directory. On failure,
# print the tail of the log and stop.
run_log() {
  local name="$1"; shift
  if ! "$@" >"$LOGS/$name.log" 2>&1; then
    echo "error: $name failed (full log: $LOGS/$name.log)" >&2
    tail -n 40 "$LOGS/$name.log" >&2
    exit 1
  fi
}

# Download, verify, and unpack a release tarball once.
fetch() {
  local directory="$1" url="$2" checksum="$3"
  local archive="$WORK/$(basename "$url")"
  if [ -d "$WORK/$directory" ]; then
    return 0
  fi
  if [ ! -f "$archive" ]; then
    echo "  downloading $(basename "$url")"
    curl -fsSL --retry 3 --retry-delay 2 -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  echo "$checksum  $archive" | shasum -a 256 -c - >/dev/null 2>&1 \
    || { echo "error: checksum mismatch for $archive" >&2; exit 1; }
  tar -xf "$archive" -C "$WORK"
}

has_pc() { [ -f "$PREFIX/lib/pkgconfig/$1.pc" ]; }

build_autotools() {
  local directory="$1"; shift
  section "$directory"
  ( cd "$WORK/$directory" && run_log "$directory.configure" ./configure --prefix="$PREFIX" --disable-static "$@" )
  ( cd "$WORK/$directory" && run_log "$directory.make" make -j"$JOBS" )
  ( cd "$WORK/$directory" && run_log "$directory.install" make install )
}

# libtatsu requires libcurl with a pkg-config file; macOS ships libcurl but no
# libcurl.pc, so point pkg-config at the SDK copy.
write_libcurl_pc() {
  local sdk version
  sdk="$(xcrun --show-sdk-path)"
  if [ ! -f "$sdk/usr/include/curl/curl.h" ]; then
    echo "error: libcurl headers not found in the macOS SDK" >&2
    exit 1
  fi
  [ -f "$PREFIX/include/curl/curl.h" ] || cp -R "$sdk/usr/include/curl" "$PREFIX/include/curl"
  version="$(awk '/^#define LIBCURL_VERSION "/{ gsub(/"/, "", $3); print $3 }' "$PREFIX/include/curl/curlver.h")"
  cat >"$PREFIX/lib/pkgconfig/libcurl.pc" <<EOF
prefix=$sdk/usr
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=$PREFIX/include

Name: libcurl
URL: https://curl.se/
Description: Library to transfer files with HTTP, FTP, etc.
Version: $version
Libs: -L\${libdir} -lcurl
Libs.private: -lz
Cflags: -I\${includedir}
EOF
}

if [ ! -x "$PREFIX/bin/pkg-config" ]; then
  fetch "pkgconf-$PKGCONF_VERSION" \
    "https://github.com/pkgconf/pkgconf/releases/download/pkgconf-$PKGCONF_VERSION/pkgconf-$PKGCONF_VERSION.tar.xz" \
    9371b2f6372da574d4c6dc96fe9b1463037bcf6afcb6671c1555afde7b17e2de
  build_autotools "pkgconf-$PKGCONF_VERSION" --with-pkg-config-dir="$PREFIX/lib/pkgconfig"
  [ -e "$PREFIX/bin/pkg-config" ] || ln -s pkgconf "$PREFIX/bin/pkg-config"
fi
export PKG_CONFIG="$PREFIX/bin/pkg-config"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

if ! has_pc libplist-2.0; then
  fetch "libplist-$LIBPLIST_VERSION" \
    "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2" \
    b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a
  build_autotools "libplist-$LIBPLIST_VERSION" --without-cython
fi

if ! has_pc libimobiledevice-glue-1.0; then
  fetch "libimobiledevice-glue-$GLUE_VERSION" \
    "https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/$GLUE_VERSION/libimobiledevice-glue-$GLUE_VERSION.tar.bz2" \
    920ce01382a32695f49b23292b4979a03f0afd16c58e8755d8b7f41804acc1a9
  build_autotools "libimobiledevice-glue-$GLUE_VERSION"
fi

if ! has_pc libusbmuxd-2.0; then
  fetch "libusbmuxd-$USBMUXD_VERSION" \
    "https://github.com/libimobiledevice/libusbmuxd/releases/download/$USBMUXD_VERSION/libusbmuxd-$USBMUXD_VERSION.tar.bz2" \
    5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce
  build_autotools "libusbmuxd-$USBMUXD_VERSION"
fi

write_libcurl_pc

if ! has_pc libtatsu-1.0; then
  fetch "libtatsu-$LIBTATSU_VERSION" \
    "https://github.com/libimobiledevice/libtatsu/releases/download/$LIBTATSU_VERSION/libtatsu-$LIBTATSU_VERSION.tar.bz2" \
    536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440
  build_autotools "libtatsu-$LIBTATSU_VERSION"
fi

if ! has_pc openssl; then
  section "openssl $OPENSSL_VERSION"
  case "$(uname -m)" in
    x86_64) SSL_TARGET=darwin64-x86_64-cc ;;
    arm64)  SSL_TARGET=darwin64-arm64-cc ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  fetch "openssl-$OPENSSL_VERSION" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
  ( cd "$WORK/openssl-$OPENSSL_VERSION" \
    && run_log openssl.configure ./Configure "$SSL_TARGET" shared no-tests \
         --prefix="$PREFIX" --openssldir="$PREFIX/etc/ssl" )
  ( cd "$WORK/openssl-$OPENSSL_VERSION" && run_log openssl.make make -j"$JOBS" )
  ( cd "$WORK/openssl-$OPENSSL_VERSION" && run_log openssl.install make install_sw )
fi

if ! has_pc libzip; then
  section "libzip $LIBZIP_VERSION"
  test -x "$WORK/venv/bin/cmake" || {
    section "cmake (build-time only)"
    python3 -m venv "$WORK/venv"
    run_log pip.install "$WORK/venv/bin/pip" install --quiet --upgrade pip cmake
  }
  CMAKE="$WORK/venv/bin/cmake"
  fetch "libzip-$LIBZIP_VERSION" \
    "https://libzip.org/download/libzip-$LIBZIP_VERSION.tar.gz" \
    3b66fe92cbc768d8d4d16e1427bfb7399e15d9c2795c2fc482e7b30a6332a422
  run_log libzip.configure "$CMAKE" -S "$WORK/libzip-$LIBZIP_VERSION" -B "$WORK/libzip-build" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_OPENSSL=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF \
    -DENABLE_COMMONCRYPTO=OFF -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
    -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
  run_log libzip.make "$CMAKE" --build "$WORK/libzip-build" -j"$JOBS"
  run_log libzip.install "$CMAKE" --install "$WORK/libzip-build"
fi

if ! has_pc libimobiledevice-1.0; then
  fetch "libimobiledevice-$LIBIMOBILEDEVICE_VERSION" \
    "https://github.com/libimobiledevice/libimobiledevice/releases/download/$LIBIMOBILEDEVICE_VERSION/libimobiledevice-$LIBIMOBILEDEVICE_VERSION.tar.bz2" \
    23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d
  build_autotools "libimobiledevice-$LIBIMOBILEDEVICE_VERSION" --without-cython
fi

if [ ! -x "$PREFIX/bin/ideviceinstaller" ]; then
  fetch "ideviceinstaller-$IDEVICEINSTALLER_VERSION" \
    "https://github.com/libimobiledevice/ideviceinstaller/releases/download/$IDEVICEINSTALLER_VERSION/ideviceinstaller-$IDEVICEINSTALLER_VERSION.tar.bz2" \
    26115288e50d003bbb7d23c05441c54ea69b255974303bfd44fef6943e042f94
  build_autotools "ideviceinstaller-$IDEVICEINSTALLER_VERSION"
fi

section "linking tools into $BINDIR"
for tool in "$PREFIX"/bin/idevice* "$PREFIX/bin/afcclient" "$PREFIX/bin/iproxy"; do
  [ -x "$tool" ] || continue
  ln -sf "$tool" "$BINDIR/$(basename "$tool")"
done

section "done"
"$PREFIX/bin/ideviceinstaller" --version
"$PREFIX/bin/idevicepair" --version

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BINDIR"; then
  echo
  echo "Add the tools to your PATH, for example:"
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile"
fi

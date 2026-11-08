#!/usr/bin/env bash
#
# Build EmLoad.app for macOS.
#
#   ./gui-macos/scripts/build-app.sh            # native build -> gui-macos/dist/EmLoad.app
#   RUN=1 ./gui-macos/scripts/build-app.sh       # build, sign, and launch
#
# The Swift binary is only a shell. The actual engine is the EmLoadEngine
# Python package, copied into Contents/Resources/engine so the app keeps working
# if the checkout is moved. Python itself (and its pip dependencies) still has
# to be available; see gui-macos/README.md.
#
# The app and the bundled zsign are built for the host Mac and, when the
# toolchain can cross-compile, the other Mac architecture as well. Intel
# (x86_64) and Apple silicon (arm64) are both supported.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PKG/.." && pwd)"
APP_NAME="EmLoad"
APP="$PKG/dist/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ENGINE="$RESOURCES/engine"
IOS_SOURCE="$REPO/EmLoadiOS"

for item in AltStore.xcodeproj AltStore AltWidget Shared SideBackup SideStore Dependencies xcconfigs Makefile Build.xcconfig SideStore.conf; do
    if [[ ! -e "$IOS_SOURCE/$item" ]]; then
        echo "error: EmLoadiOS/$item is required to package the iOS setup builder." >&2
        exit 1
    fi
done
for package in SideSign minimuxer; do
    if [[ ! -f "$IOS_SOURCE/Dependencies/$package/Package.swift" ]]; then
        echo "error: EmLoadiOS/Dependencies/$package is missing. Run 'git -C EmLoadiOS submodule update --init --recursive'." >&2
        exit 1
    fi
done

HOST="$(uname -m)"
if [[ -z "${ARCHS:-}" ]]; then
    ARCHS="x86_64 arm64"
fi
# shellcheck disable=SC2206
ARCH_LIST=($ARCHS)

echo "==> Building EmLoadMac (Swift $(swift --version 2>/dev/null | head -1 || echo 'unknown'))"
SLICES=()
BUILT_ARCHS=()
for arch in "${ARCH_LIST[@]}"; do
    if swift build -c release --package-path "$PKG" --arch "$arch"; then
        slice="$(swift build -c release --package-path "$PKG" --arch "$arch" --show-bin-path)/EmLoadMac"
        if [[ -x "$slice" ]] && lipo "$slice" -verify_arch "$arch" >/dev/null 2>&1; then
            SLICES+=("$slice")
            BUILT_ARCHS+=("$arch")
            continue
        fi
    fi
    if [[ "$arch" == "$HOST" ]]; then
        echo "error: SwiftPM did not produce an EmLoadMac executable for $HOST." >&2
        exit 1
    fi
    echo "warning: skipping EmLoadMac $arch; $HOST will still be included." >&2
done

BIN="$PKG/.build/EmLoadMac"
mkdir -p "$(dirname "$BIN")"
if [[ ${#SLICES[@]} -eq 1 ]]; then
    cp "${SLICES[0]}" "$BIN"
else
    lipo -create "${SLICES[@]}" -output "$BIN"
fi
chmod 755 "$BIN"
echo "==> EmLoadMac architectures: ${BUILT_ARCHS[*]}"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES" "$ENGINE"

cp "$BIN" "$MACOS_DIR/EmLoadMac"
cp "$PKG/Resources/Info.plist" "$CONTENTS/Info.plist"

# Ship the EmLoad iOS Xcode project so the macOS setup page can make a fresh,
# local Xcode build for each install, including from the packaged app.
IOS_PROJECT="$RESOURCES/EmLoadiOS"
mkdir -p "$IOS_PROJECT"
for item in AltStore.xcodeproj AltStore AltWidget Shared SideBackup SideStore Dependencies xcconfigs Makefile Build.xcconfig SideStore.conf; do
    ditto "$IOS_SOURCE/$item" "$IOS_PROJECT/$item"
done
for package in SideSign minimuxer; do
    rm -f "$IOS_PROJECT/Dependencies/$package/.git"
done

# Release builds stamp the full tag (0.1.0-beta2) so the in-app updater can
# tell this copy from a later GitHub pre-release. Local builds leave it unset
# and keep CFBundleShortVersionString.
if [[ -n "${EMLOAD_RELEASE:-}" ]]; then
    echo "==> Stamping release $EMLOAD_RELEASE"
    /usr/libexec/PlistBuddy -c "Delete :EmLoadRelease" "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EmLoadRelease string $EMLOAD_RELEASE" "$CONTENTS/Info.plist"
    if [[ "$EMLOAD_RELEASE" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BASH_REMATCH[1]}" "$CONTENTS/Info.plist"
    fi
fi

# Sidebar brand mark (see UI/BrandMark.swift).
if [[ -f "$PKG/Resources/E.png" ]]; then
    cp "$PKG/Resources/E.png" "$RESOURCES/E.png"
fi

# Ship the engine source with the app. Running from the bundle still needs a
# Python interpreter with requirements.txt installed; PythonLocator prefers the
# checkout's .venv when one is present.
if [[ -d "$REPO/EmLoadEngine" ]]; then
    mkdir -p "$ENGINE/EmLoadEngine"
    rsync -a --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
        "$REPO/EmLoadEngine/" "$ENGINE/EmLoadEngine/"
elif [[ -d "$REPO/emload" ]]; then
    ditto "$REPO/emload" "$ENGINE/emload"
fi
if [[ -f "$REPO/EmLoadEngine/pyproject.toml" ]]; then
    cp "$REPO/EmLoadEngine/pyproject.toml" "$ENGINE/pyproject.toml"
elif [[ -f "$REPO/pyproject.toml" ]]; then
    cp "$REPO/pyproject.toml" "$ENGINE/pyproject.toml"
fi
if [[ -f "$REPO/requirements.txt" ]]; then
    cp "$REPO/requirements.txt" "$ENGINE/requirements.txt"
fi
if [[ -f "$REPO/README.md" ]]; then
    cp "$REPO/README.md" "$ENGINE/README.md"
fi

# Remember the checkout so a development build can still use its .venv and any
# locally installed dependencies.
printf '%s\n' "$REPO" > "$RESOURCES/engine-root.txt"

echo "==> Building zsign (${BUILT_ARCHS[*]})"
ZSIGN_OUT="$RESOURCES/zsign"
ARCHS="${BUILT_ARCHS[*]}" "$HERE/build-zsign.sh" -o "$ZSIGN_OUT"
if [[ -d "$ENGINE/EmLoadEngine" ]]; then
    mkdir -p "$ENGINE/EmLoadEngine/vendor"
    cp "$ZSIGN_OUT" "$ENGINE/EmLoadEngine/vendor/zsign"
    chmod 755 "$ENGINE/EmLoadEngine/vendor/zsign"
else
    mkdir -p "$ENGINE/emload/vendor"
    cp "$ZSIGN_OUT" "$ENGINE/emload/vendor/zsign"
    chmod 755 "$ENGINE/emload/vendor/zsign"
fi

# CLI `emload` looks in Application Support before PATH. Install the same
# binary there so signing works outside the app bundle too. Cross-architecture
# packaging can skip replacing the host's CLI helper.
if [[ "${EMLOAD_SKIP_ZSIGN_INSTALL:-0}" != "1" ]]; then
    ZSIGN_DATA="$HOME/Library/Application Support/EmLoad/bin"
    mkdir -p "$ZSIGN_DATA"
    cp "$ZSIGN_OUT" "$ZSIGN_DATA/zsign"
    chmod 755 "$ZSIGN_DATA/zsign"
    if command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - "$ZSIGN_DATA/zsign" >/dev/null 2>&1 || true
    fi
fi

if [[ -f "$PKG/Resources/EmLoad.icns" ]]; then
    cp "$PKG/Resources/EmLoad.icns" "$RESOURCES/EmLoad.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile EmLoad" "$CONTENTS/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string EmLoad" "$CONTENTS/Info.plist"
fi

# Ad-hoc signing is enough for local use. Apple silicon refuses an unsigned
# bundle; Intel macOS accepts it, but signing keeps one bundle valid on both.
if command -v codesign >/dev/null 2>&1; then
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        echo "warning: ad-hoc signing failed; the app may not launch" >&2
fi

echo "==> Built $APP"
if [[ "${RUN:-0}" == "1" ]]; then
    open "$APP"
fi

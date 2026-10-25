#!/usr/bin/env bash
#
# Build EmLoad.app for macOS.
#
#   ./gui-macos/scripts/build-app.sh            # native build -> gui-macos/dist/EmLoad.app
#   RUN=1 ./gui-macos/scripts/build-app.sh       # build, sign, and launch
#
# The Swift binary is only a shell. The actual engine is the repo's `emload`
# Python package, copied into Contents/Resources/engine so the app keeps working
# if the checkout is moved. Python itself (and its pip dependencies) still has
# to be available; see gui-macos/README.md.
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

if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" != "1" ]]; then
    echo "error: the EmLoad macOS app requires an Apple silicon Mac." >&2
    exit 1
fi

echo "==> Building EmLoadMac (Swift $(swift --version 2>/dev/null | head -1 || echo 'unknown'))"
swift build -c release --package-path "$PKG" --arch arm64
BIN="$(swift build -c release --package-path "$PKG" --arch arm64 --show-bin-path)/EmLoadMac"

if [[ ! -x "$BIN" ]]; then
    echo "error: SwiftPM did not produce an EmLoadMac executable at $BIN" >&2
    exit 1
fi
if ! lipo "$BIN" -verify_arch arm64 >/dev/null 2>&1; then
    echo "error: the built EmLoadMac executable is not Apple silicon (arm64)." >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES" "$ENGINE"

cp "$BIN" "$MACOS_DIR/EmLoadMac"
cp "$PKG/Resources/Info.plist" "$CONTENTS/Info.plist"

# Sidebar brand mark (see UI/BrandMark.swift).
if [[ -f "$PKG/Resources/E.png" ]]; then
    cp "$PKG/Resources/E.png" "$RESOURCES/E.png"
fi

# Ship the engine source with the app. Running from the bundle still needs a
# Python interpreter with requirements.txt installed; PythonLocator prefers the
# checkout's .venv when one is present.
ditto "$REPO/emload" "$ENGINE/emload"
cp "$REPO/pyproject.toml" "$ENGINE/pyproject.toml"
if [[ -f "$REPO/requirements.txt" ]]; then
    cp "$REPO/requirements.txt" "$ENGINE/requirements.txt"
fi
if [[ -f "$REPO/README.md" ]]; then
    cp "$REPO/README.md" "$ENGINE/README.md"
fi

# Remember the checkout so a development build can still use its .venv and any
# locally installed dependencies.
printf '%s\n' "$REPO" > "$RESOURCES/engine-root.txt"

if [[ -f "$PKG/Resources/EmLoad.icns" ]]; then
    cp "$PKG/Resources/EmLoad.icns" "$RESOURCES/EmLoad.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile EmLoad" "$CONTENTS/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string EmLoad" "$CONTENTS/Info.plist"
fi

# Ad-hoc signing is enough for local use and is required by Apple Silicon.
if command -v codesign >/dev/null 2>&1; then
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        echo "warning: ad-hoc signing failed; the app may not launch on Apple Silicon" >&2
fi

echo "==> Built $APP"
if [[ "${RUN:-0}" == "1" ]]; then
    open "$APP"
fi

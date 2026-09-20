#!/usr/bin/env bash
# ==============================================================================
# Build and package script for DSH Bar (macOS Menu Bar App for DeepSeek Harness)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="DSH Bar"
BUNDLE_DIR="build/${APP_NAME}.app"
BINARY_NAME="dsh-bar"
ARCH="$(uname -m)"

echo "==> Building DSH Bar for ${ARCH}..."
mkdir -p build

SDK_PATH="$(xcrun --show-sdk-path)"

xcrun swiftc -O -parse-as-library \
    -sdk "$SDK_PATH" \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/ServiceManager.swift \
    Sources/HotKeyManager.swift \
    Sources/SettingsManager.swift \
    Sources/DashboardWindow.swift \
    -o "build/${BINARY_NAME}"

echo "==> Assembling ${BUNDLE_DIR}..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "build/${BINARY_NAME}" "$BUNDLE_DIR/Contents/MacOS/${BINARY_NAME}"
chmod +x "$BUNDLE_DIR/Contents/MacOS/${BINARY_NAME}"

cp "Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
echo "APPL????" > "$BUNDLE_DIR/Contents/PkgInfo"

if [ -d "Resources" ]; then
    cp -R Resources/* "$BUNDLE_DIR/Contents/Resources/"
fi

echo "==> Signing application..."
xattr -cr "$BUNDLE_DIR"
codesign --force --deep --sign - "$BUNDLE_DIR"
codesign -v "$BUNDLE_DIR"

echo "==> Build successful: ${BUNDLE_DIR}"

# If install argument is provided, copy to /Applications
if [ "${1:-}" = "install" ]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}..."
    rm -rf "$DEST"
    cp -R "$BUNDLE_DIR" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    touch "$DEST"
    echo "==> Successfully installed to ${DEST}!"
fi

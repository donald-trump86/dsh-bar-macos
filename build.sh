#!/usr/bin/env bash
# Build and package DSH Bar as a macOS application bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="DSH Bar"
BUNDLE_DIR="build/${APP_NAME}.app"
BINARY_NAME="dsh-bar"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCHS_VALUE="${ARCHS:-arm64 x86_64}"
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
VERSION="${VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must use MAJOR.MINOR.PATCH format" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "BUILD_NUMBER must contain one to three dot-separated integers" >&2
    exit 1
fi

read -r -a ARCH_LIST <<< "$ARCHS_VALUE"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SOURCE_FILES=(
    Sources/main.swift
    Sources/AppDelegate.swift
    Sources/ServiceManager.swift
    Sources/HotKeyManager.swift
    Sources/SettingsManager.swift
    Sources/DashboardWindow.swift
    Sources/LogWindow.swift
    Sources/DshInstallAssistant.swift
)
COMMON_SWIFT_FLAGS=(
    -O
    -whole-module-optimization
    -parse-as-library
    -module-name DSHBar
    -sdk "$SDK_PATH"
    -framework Cocoa
    -framework Carbon
    -framework ServiceManagement
)

mkdir -p build
rm -rf "$BUNDLE_DIR"
rm -f "build/${BINARY_NAME}" "build/${BINARY_NAME}-arm64" "build/${BINARY_NAME}-x86_64"

ARCH_BINARIES=()
for arch in "${ARCH_LIST[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "Unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac

    output="build/${BINARY_NAME}-${arch}"
    echo "==> Building ${APP_NAME} for ${arch} (macOS ${DEPLOYMENT_TARGET}+)..."
    xcrun swiftc "${COMMON_SWIFT_FLAGS[@]}" \
        -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        "${SOURCE_FILES[@]}" \
        -o "$output"
    ARCH_BINARIES+=("$output")
done

if (( ${#ARCH_BINARIES[@]} == 1 )); then
    cp "${ARCH_BINARIES[0]}" "build/${BINARY_NAME}"
else
    echo "==> Creating universal binary..."
    xcrun lipo -create "${ARCH_BINARIES[@]}" -output "build/${BINARY_NAME}"
fi

echo "==> Assembling ${BUNDLE_DIR}..."
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
cp "build/${BINARY_NAME}" "$BUNDLE_DIR/Contents/MacOS/${BINARY_NAME}"
chmod +x "$BUNDLE_DIR/Contents/MacOS/${BINARY_NAME}"

cp Info.plist "$BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE_DIR/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE_DIR/Contents/PkgInfo"

if [[ -d Resources ]]; then
    cp -R Resources/. "$BUNDLE_DIR/Contents/Resources/"
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
ENTITLEMENTS_ARG=()

xattr -cr "$BUNDLE_DIR"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing with Developer ID: ${SIGNING_IDENTITY}"
    if [[ -f "Packaging/DSHBar.entitlements" ]]; then
        ENTITLEMENTS_ARG=(--entitlements "Packaging/DSHBar.entitlements")
    fi
    codesign --force --options runtime --timestamp \
        ${ENTITLEMENTS_ARG[@]+"${ENTITLEMENTS_ARG[@]}"} \
        --sign "$SIGNING_IDENTITY" \
        "$BUNDLE_DIR"
else
    echo "==> Ad-hoc signing application (not notarized)..."
    codesign --force --sign - "$BUNDLE_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"

echo "==> Build successful: ${BUNDLE_DIR}"
echo "    Version: ${VERSION} (${BUILD_NUMBER})"
echo "    Architectures: $(xcrun lipo -archs "build/${BINARY_NAME}")"
echo "    Signed: ${SIGNING_IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "install" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${DEST}..."
    rm -rf "$DEST"
    cp -R "$BUNDLE_DIR" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    touch "$DEST"
    echo "==> Successfully installed to ${DEST}!"
fi

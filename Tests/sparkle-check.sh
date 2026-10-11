#!/usr/bin/env bash
# Sparkle auto-update integration checks.
#
# Each block targets a failure that is silent at review time: a vendored
# framework missing a nested helper still links, a single-arch binary still
# runs on the build machine, and a mistyped feed URL only shows up months
# later as "you're up to date" on an old install.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
FAILED=0

fail() { echo "FAIL  $1"; FAILED=1; }
pass() { echo "ok    $1"; }

# 1. The vendored framework must be complete. Sparkle drives its install
#    through nested helpers; a trimmed framework links fine and fails at
#    update time with no compile error anywhere.
FW="Vendor/Sparkle.framework/Versions/B"
MISSING=""
for p in "$FW/Sparkle" "$FW/Autoupdate" "$FW/Updater.app" \
         "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" \
         "$FW/Modules/module.modulemap"; do
    [[ -e "$p" ]] || MISSING="$MISSING $p"
done
if [[ -z "$MISSING" ]]; then
    pass "vendored Sparkle.framework contains every nested helper and module map"
else
    fail "Vendor/Sparkle.framework is missing:$MISSING"
fi

# 2. One vendored binary must serve both architectures the build lipo's into
#    the app, or the arm64/x86_64 app silently fails to load Sparkle on one of
#    them.
if [[ -x "$FW/Sparkle" ]]; then
    ARCHS="$(lipo -archs "$FW/Sparkle" 2>/dev/null || true)"
    if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
        pass "vendored Sparkle binary is universal ($ARCHS)"
    else
        fail "vendored Sparkle binary archs are '$ARCHS', expected arm64 + x86_64"
    fi
else
    fail "vendored Sparkle binary not found or not executable"
fi

# 3. CI signs the appcast with the vendored tools, so they must be committed
#    next to the framework — a release must not depend on a network download
#    that only exists on some runners.
TOOLS_MISSING=""
for t in generate_appcast sign_update generate_keys; do
    [[ -x "Vendor/Sparkle/bin/$t" ]] || TOOLS_MISSING="$TOOLS_MISSING $t"
done
if [[ -z "$TOOLS_MISSING" ]]; then
    pass "vendored Sparkle bin tools (generate_appcast, sign_update, generate_keys) present"
else
    fail "Vendor/Sparkle/bin is missing:$TOOLS_MISSING"
fi

# 4. build.sh must link and embed Sparkle. A missing -F or rpath compiles on
#    the build machine and crashes at launch on user machines; a cp -R embed
#    flattens the framework's symlinks and the updater fails at install time.
if grep -q -- '-framework Sparkle' build.sh && grep -q -- '-F "$SCRIPT_DIR/Vendor"' build.sh; then
    pass "build.sh links Sparkle from the vendored framework"
else
    fail "build.sh must compile/link with -F \"$SCRIPT_DIR/Vendor\" and -framework Sparkle"
fi
if grep -q '@loader_path/../Frameworks' build.sh; then
    pass "build.sh records the Frameworks runpath for the packaged app"
else
    fail "build.sh must pass -Xlinker -rpath -Xlinker @loader_path/../Frameworks"
fi
if grep -q 'ditto .*Sparkle\.framework.*Contents/Frameworks' build.sh; then
    pass "build.sh embeds Sparkle.framework with ditto (symlinks preserved)"
else
    fail "build.sh must embed Sparkle.framework into Contents/Frameworks with ditto, not cp -R"
fi

# 5. Nested components must be re-signed inside-out in Sparkle's documented
#    order before the bundle itself is signed, with Downloader.xpc keeping its
#    entitlements. The failure mode is XPC install/verify errors on user
#    machines, invisible to any local run.
L_INST="$(grep -n 'Installer\.xpc' build.sh | head -1 | cut -d: -f1)"
L_DOWN="$(grep -n 'Downloader\.xpc' build.sh | head -1 | cut -d: -f1)"
L_AUTO="$(grep -n 'Autoupdate' build.sh | head -1 | cut -d: -f1)"
L_UPD="$(grep -n 'Updater\.app' build.sh | head -1 | cut -d: -f1)"
if [[ -n "$L_INST" && -n "$L_DOWN" && -n "$L_AUTO" && -n "$L_UPD" \
      && "$L_INST" -lt "$L_DOWN" && "$L_DOWN" -lt "$L_AUTO" && "$L_AUTO" -lt "$L_UPD" ]]; then
    pass "nested Sparkle components are signed inside-out in documented order (Installer → Downloader → Autoupdate → Updater.app)"
else
    fail "build.sh must sign Installer.xpc → Downloader.xpc → Autoupdate → Updater.app → framework in that order (found lines: ${L_INST:-none} ${L_DOWN:-none} ${L_AUTO:-none} ${L_UPD:-none})"
fi
if tr '\n' ' ' < build.sh | grep -q 'Downloader\.xpc[^.]*--preserve-metadata=entitlements\|--preserve-metadata=entitlements[^.]*Downloader\.xpc'; then
    pass "Downloader.xpc re-sign preserves its entitlements"
else
    fail "Downloader.xpc must be re-signed with --preserve-metadata=entitlements"
fi
if grep -E 'codesign[^#]*--deep' build.sh | grep -v -- '--verify' | grep -q .; then
    fail "build.sh must never sign with --deep (verify is fine)"
else
    pass "no codesign sign step uses --deep"
fi

# 6. The update entry point must be compiled into the app, or the menu wiring
#    in later tasks fails to link while everything looks green in checks.
if grep -q 'Sources/UpdateManager\.swift' build.sh; then
    pass "build.sh compiles Sources/UpdateManager.swift"
else
    fail "build.sh must list Sources/UpdateManager.swift in SOURCE_FILES"
fi

# 7. Info.plist is the updater's contract with installed copies: a wrong feed
#    URL or public key still builds and runs but every update silently fails
#    verification or points at nothing. The public key must match the pair
#    whose private half lives in the CI secret SPARKLE_PRIVATE_ED_KEY.
PB=/usr/libexec/PlistBuddy
plist_get() { "$PB" -c "Print :$1" Info.plist 2>/dev/null; }

FEED="$(plist_get SUFeedURL)"
if [[ "$FEED" == "https://donald-trump86.github.io/dsh-bar-macos/appcast.xml" ]]; then
    pass "SUFeedURL points at the GitHub Pages appcast"
else
    fail "SUFeedURL must be https://donald-trump86.github.io/dsh-bar-macos/appcast.xml (got '${FEED:-unset}')"
fi

PUBKEY="$(plist_get SUPublicEDKey)"
if [[ "$PUBKEY" == "bvSoqEB8kgZpyVHBw1OJ5C99IggFVqmOddXaup/Hwv0=" ]]; then
    pass "SUPublicEDKey matches the generated EdDSA key pair"
else
    fail "SUPublicEDKey must be bvSoqEB8kgZpyVHBw1OJ5C99IggFVqmOddXaup/Hwv0= (got '${PUBKEY:-unset}') — it must match the CI secret's key pair"
fi

for kv in "SUEnableAutomaticChecks:true" "SUAutomaticallyUpdate:false" "SUShowReleaseNotes:true"; do
    KEY="${kv%%:*}"; WANT="${kv##*:}"
    GOT="$(plist_get "$KEY")"
    if [[ "$GOT" == "$WANT" ]]; then
        pass "$KEY is $WANT"
    else
        fail "$KEY must be $WANT (got '${GOT:-unset}')"
    fi
done

INTERVAL="$(plist_get SUScheduledCheckInterval)"
if [[ "$INTERVAL" == "86400" ]]; then
    pass "SUScheduledCheckInterval is 86400 (daily background check)"
else
    fail "SUScheduledCheckInterval must be 86400 (got '${INTERVAL:-unset}')"
fi

exit $FAILED

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

exit $FAILED

#!/usr/bin/env bash
# The update entry point compiles against the real vendored Sparkle API, and
# the status menu actually reaches it. The failure this catches: Sparkle's
# Objective-C surface drifts from what UpdateManager.swift calls — the app
# still builds against stale assumptions and breaks at update time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
FAILED=0

fail() { echo "FAIL  $1"; FAILED=1; }
pass() { echo "ok    $1"; }

# 1. Typecheck the wrapper against the vendored framework's module map. This
#    is the only proof that init signatures and property names match the
#    shipped 2.10.0 headers, without a full app build to find out. The module
#    cache is pinned outside $HOME for the same reason build.sh pins its own:
#    the default location is not writable in sandboxed or containerized runs.
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/dshbar-sparkle-api-modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
if xcrun swiftc -typecheck -parse-as-library \
        -module-name SparkleAPICheck \
        -F Vendor \
        Sources/UpdateManager.swift 2>/tmp/sparkle-api-check.err; then
    pass "UpdateManager.swift typechecks against the vendored Sparkle API"
else
    fail "UpdateManager.swift does not compile against vendored Sparkle:"
    sed 's/^/      /' /tmp/sparkle-api-check.err
fi

# 2. The menu item must reach the wrapper, with an explicit target. A missing
#    target turns the item into a dead click — no error, no update check.
if grep -q '#selector(UpdateManager.checkForUpdates(_:))' Sources/AppDelegate.swift \
        && grep -q 'checkForUpdatesMenuItem.target = UpdateManager.shared' Sources/AppDelegate.swift; then
    pass "menu item calls UpdateManager.checkForUpdates with UpdateManager.shared as target"
else
    fail "AppDelegate must wire a menu item with #selector(UpdateManager.checkForUpdates(_:)) targeting UpdateManager.shared"
fi

# 3. This menu disables automatic validation, so the item's availability has
#    to be re-evaluated when the menu opens or it stays in its launch state
#    forever.
if grep -q 'func menuWillOpen' Sources/AppDelegate.swift \
        && grep -q 'checkForUpdatesMenuItem.isEnabled = UpdateManager.shared.canCheckForUpdates' Sources/AppDelegate.swift; then
    pass "menu re-evaluates update availability every time it opens"
else
    fail "AppDelegate must refresh checkForUpdatesMenuItem.isEnabled in menuWillOpen (autoenablesItems is off)"
fi

# 4. The five strings of the update surface exist in both languages with the
#    exact wording, including the {version} placeholder. The parity checker
#    only proves the tables agree, not that either says what was agreed.
while IFS='|' read -r key en zh; do
    [[ -z "$key" ]] && continue
    if grep -q "\.$key: \"$en\"," Sources/Localization.swift \
            && grep -q "\.$key: \"$zh\"," Sources/Localization.swift; then
        pass "localization key $key is localized in both languages"
    else
        fail "localization key $key must exist with en \"$en\" and zh \"$zh\""
    fi
done <<'EOF'
checkForUpdatesEllipsis|Check for Updates…|检查更新…
softwareUpdates|Software Updates|软件更新
updateCurrentVersion|Version {version}|版本 {version}
updateCheckNow|Check Now|立即检查
autoCheckUpdates|Check for updates automatically|自动检查更新
EOF

exit $FAILED

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

# 8. The preferences row is where the automatic-check policy becomes visible.
#    Two silent failures are pinned here: the row falling out of the card's
#    bottom chain (layout breaks only on some window heights), and the
#    checkbox writing Sparkle's flag on load instead of on user toggle — which
#    would silently enable automatic checks for everyone who never touched it.
if grep -q 'updateRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)' Sources/DashboardWindow.swift; then
    pass "updateRow closes the preferences card bottom chain"
else
    fail "updateRow must pin to card.bottomAnchor with constant -8 (tagRow keeps height 54, updateRow closes the card)"
fi
if grep -q 'didClickCheckForUpdates' Sources/DashboardWindow.swift \
        && grep -q 'didToggleAutoUpdates' Sources/DashboardWindow.swift; then
    pass "Software Updates row has check and auto-check actions"
else
    fail "DashboardWindow must define didClickCheckForUpdates and didToggleAutoUpdates"
fi
WRITES="$(grep -c 'UpdateManager\.shared\.automaticallyChecksForUpdates *=' Sources/DashboardWindow.swift || true)"
if [[ "$WRITES" == "1" ]]; then
    pass "automaticallyChecksForUpdates is written from exactly one place (the toggle)"
else
    fail "automaticallyChecksForUpdates must be written exactly once in DashboardWindow (found $WRITES) — never on load"
fi
if grep -q 'autoUpdateCheckbox.state = UpdateManager.shared.automaticallyChecksForUpdates' Sources/DashboardWindow.swift; then
    pass "auto-check checkbox is initialized read-only from Sparkle state"
else
    fail "autoUpdateCheckbox.state must be initialized from UpdateManager.shared.automaticallyChecksForUpdates on load"
fi

# 9. The dashboard size invariants that run-checks.sh greps must survive this
#    row: they are what keeps the panel height derivable from its rows.
INV_DRIFT=""
grep -q 'minSize = NSSize(width: 540, height: Self.naturalContentHeight)' Sources/DashboardWindow.swift || INV_DRIFT="$INV_DRIFT minSize"
grep -q 'private static let naturalContentHeight: CGFloat = 592' Sources/DashboardWindow.swift || INV_DRIFT="$INV_DRIFT naturalContentHeight"
grep -q 'preferencesScroll.documentView = preferencesCard' Sources/DashboardWindow.swift || INV_DRIFT="$INV_DRIFT documentView"
if [[ -z "$INV_DRIFT" ]]; then
    pass "run-checks.sh DashboardWindow size invariants still hold"
else
    fail "DashboardWindow drifted from run-checks.sh invariants:$INV_DRIFT"
fi

# 10. The appcast is the one artifact users' installs consume directly: a
#     missing EdDSA signature or a feed deployed but never regenerated shows up
#     only as "you're up to date" on an old install months later. The checks
#     pin the sign-with-secret-stdin step, the release-asset backup upload and
#     the Pages deploy job — the three links where the feed can silently rot.
WF=".github/workflows/release.yml"
if grep -q -- '--ed-key-file -' "$WF" \
        && grep -q -- '--download-url-prefix' "$WF"; then
    pass "release workflow signs the appcast from the secret key over stdin"
else
    fail "release.yml must run generate_appcast with --ed-key-file - and --download-url-prefix"
fi
if grep -q 'dist/${ZIP_NAME%.zip}.html' "$WF"; then
    pass "release notes are also written as an HTML fragment for the appcast"
else
    fail "release.yml must write dist/\${ZIP_NAME%.zip}.html for generate_appcast --embed-release-notes"
fi
if grep -q 'deploy-appcast:' "$WF" \
        && grep -q 'actions/deploy-pages' "$WF"; then
    pass "appcast deploys to GitHub Pages from its own job"
else
    fail "release.yml needs a deploy-appcast job using actions/deploy-pages"
fi

# 11. generate_appcast's -o option takes a *path*, not a file name: passing a
#     bare `-o appcast.xml` writes the feed relative to the checkout instead of
#     into the archives directory, so the copy afterwards fails with "No such
#     file or directory" — which is exactly how the v1.0.0 release died, after
#     spending the notarization wait. The tool already writes appcast.xml into
#     the archives directory, which is what the workflow copies from.
if grep -qE '(-o|--output) +appcast' "$WF"; then
    fail "generate_appcast -o takes a path, not a name: drop it and copy appcast.xml from the archives dir"
else
    pass "generate_appcast writes the feed into the archives dir (no -o path pitfall)"
fi
if grep -q 'test -f dist/appcast-input/appcast.xml' "$WF"; then
    pass "the appcast step asserts the feed exists before copying it"
else
    fail "the appcast step must assert dist/appcast-input/appcast.xml exists before copying"
fi

exit $FAILED

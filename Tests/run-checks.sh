#!/usr/bin/env bash
# Pre-commit checks for DSH Bar.
#
# Each check targets a mistake that is invisible in review and silent at
# runtime: a missing translation renders as English text with no error, and a
# stale app name leaves a path that no longer resolves.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
FAILED=0

fail() { echo "FAIL  $1"; FAILED=1; }
pass() { echo "ok    $1"; }

APP_NAME="$(sed -n 's/^APP_NAME="\(.*\)"$/\1/p' build.sh)"

# 1. App name must agree between the build script and the bundle, otherwise the
#    installed app and the documented path drift apart.
PLIST_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Info.plist)"
if [[ "$APP_NAME" == "$PLIST_NAME" ]]; then
    pass "build.sh APP_NAME matches Info.plist CFBundleName ($APP_NAME)"
else
    fail "build.sh APP_NAME='$APP_NAME' but Info.plist CFBundleName='$PLIST_NAME'"
fi

# 2. Every .app path in the README must be named after the real app. Comparing
#    against APP_NAME is the point: accepting any `*.app` string (as an earlier
#    version of this script did) meant a stale name sailed through the check it
#    was written to catch.
while IFS= read -r path; do
    if [[ "$path" == *"$APP_NAME.app" ]]; then
        pass "README path: $path"
    else
        fail "README references '$path', but the app is named '$APP_NAME.app'"
    fi
done < <(grep -oE '"[^"]+\.app"' README.md | tr -d '"' | sort -u)

# 3. Translation keys and placeholders must align across languages.
#    A missing key falls back to English silently; a dropped placeholder
#    leaves template variables un-interpolated or drops values at runtime.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$SCRIPT_DIR/localization-check.py"; then
        pass "translation keys and placeholders align across both languages"
    else
        fail "translation keys or placeholders are out of sync (see above)"
    fi
else
    echo "SKIP  translation key and placeholder alignment (python3 not found)"
fi

# 4. The polling gate is the app's whole idle path: one wrong answer shows the
#    menu bar as running when it is not, or vice versa. It is a branch over a
#    syscall, so it gets a real check against real sockets.
if "$SCRIPT_DIR/probe-gate-check.sh" >/dev/null 2>&1; then
    pass "port probe gate answers correctly for closed, listening and dropped ports"
else
    fail "port probe gate check failed — run $SCRIPT_DIR/probe-gate-check.sh to see why"
fi

# 5. An NSEvent monitor that is installed but never removed leaks a closure
#    that holds its owner alive. Each of these three is installed in one place
#    and must be released in another, and the app still runs if a half is
#    deleted — so the pairing is asserted by name rather than by counting.
check_pair() {
    local file="$1" token="$2" install="$3" remove="$4"
    if grep -q "$install" "$file" && grep -q "$remove" "$file"; then
        pass "$file: $token is installed and released"
    else
        fail "$file: $token has an install or a removal but not both"
    fi
}
check_pair Sources/ServiceManager.swift wakeObserver "wakeObserver = NSWorkspace" "removeObserver(observer)"
check_pair Sources/DashboardWindow.swift localEventMonitor "addLocalMonitorForEvents" "removeMonitor(monitor)"
check_pair Sources/DashboardWindow.swift globalEventMonitor "addGlobalMonitorForEvents" "removeMonitor(monitor)"

# 6. The window's floor and the preferences card's height are separate numbers.
#    The floor is chrome + the scroll view's 180pt minimum; the card keeps its
#    own constant because it lives in the scroll view and grows by scrolling,
#    not by resizing. What this check actually protects is the wiring -- that
#    minSize is derived from the named constant rather than a duplicated
#    literal, and that the card really is the scroll view's document view.
#    NOTE: it does NOT verify that the floor covers the card. It did not before
#    the install-channel row either; the card scrolls when it does not.
if grep -q "minSize = NSSize(width: 540, height: Self.naturalContentHeight)" Sources/DashboardWindow.swift \
   && grep -q "private static let naturalContentHeight: CGFloat = 592" Sources/DashboardWindow.swift \
   && grep -q "preferencesScroll.documentView = preferencesCard" Sources/DashboardWindow.swift; then
    pass "panel minimum size is derived from its fixed-height rows"
else
    fail "panel minSize is not tied to naturalContentHeight (rows will clip)"
fi

# 7. The version controller runs npm and probes the registry from its own file,
#    so it needs the same PATH the binary lookup uses. `private` in Swift is
#    file-scoped, so a controller in another file cannot call it at all — the
#    compiler catches that, but a silent copy of the PATH list does not compile
#    differently. Assert the shared definition is the one that exists.
if grep -q "^    static func commandEnvironment() -> \[String: String\] {" Sources/ServiceManager.swift \
   && grep -rq "ServiceManager.commandEnvironment()" Sources/DshVersionController.swift; then
    pass "npm children inherit ServiceManager.commandEnvironment"
else
    fail "DshVersionController must call ServiceManager.commandEnvironment(), not re-derive PATH"
fi

# 8. Tag logic and the row's render decision both change silently when wrong:
#    a refused tag reaches a command the user approved, and an enabled button
#    over an empty dropdown reads as working. Both are checked against the real
#    source, not a copy.
if "$SCRIPT_DIR/tag-probe-check.sh" >/dev/null 2>&1; then
    pass "npm tag command assembly and install-channel row states are correct"
else
    fail "tag probe check failed — run $SCRIPT_DIR/tag-probe-check.sh to see why"
fi

# 9. Exercise actual byte rotation, detached lifetime and log-follow offsets.
if bash "$SCRIPT_DIR/log-rotation-check.sh"; then
    pass "bounded web logger process and rotation behavior"
else
    fail "log rotation check failed — run bash $SCRIPT_DIR/log-rotation-check.sh to see why"
fi

# 10. Preserve owned identity across HTTP outages and keep npm pipes draining.
if python3 "$SCRIPT_DIR/service-identity-check.py"; then
    pass "managed service identity survives inconclusive HTTP probes"
else
    fail "service identity check failed — run python3 $SCRIPT_DIR/service-identity-check.py to see why"
fi
if python3 "$SCRIPT_DIR/install-pipe-check.py"; then
    pass "npm output is drained with bounded diagnostics and install state cleanup"
else
    fail "install pipe check failed — run python3 $SCRIPT_DIR/install-pipe-check.py to see why"
fi

exit $FAILED

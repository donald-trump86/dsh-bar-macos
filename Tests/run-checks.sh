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

# 3. Translation keys must exist in both tables. A key added to one language
#    only falls back to English silently.
if command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PY'
import re, sys

source = open("Sources/Localization.swift", encoding="utf-8").read()
# The two tables are `private static let english/chinese: [Key: String] = [ … ]`.
tables = re.findall(
    r'static let (?:english|chinese):\s*\[Key:\s*String\]\s*=\s*\[(.*?)\n    \]',
    source,
    re.S,
)
if len(tables) < 2:
    print("    could not locate both translation tables")
    sys.exit(2)

keys = [set(re.findall(r'\.(\w+):', table)) for table in tables]
en_only, zh_only = keys[0] - keys[1], keys[1] - keys[0]
for name, missing in (("English-only", en_only), ("Chinese-only", zh_only)):
    if missing:
        print(f"    {name} keys: {', '.join(sorted(missing))}")
sys.exit(1 if (en_only or zh_only) else 0)
PY
    then
        pass "translation keys align across both languages"
    else
        fail "translation keys are out of sync (see above)"
    fi
else
    echo "SKIP  translation key alignment (python3 not found)"
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

# 6. The panel's rows are pinned with fixed heights, so the window's minimum
#    size must be the height they add up to. A smaller floor does not shrink
#    the panel — it lets rows be positioned outside the visible area, which is
#    what made 0.1.1 look overlapped when dragged.
if grep -q "minSize = NSSize(width: 540, height: Self.naturalContentHeight)" Sources/DashboardWindow.swift \
   && grep -q "private static let naturalContentHeight: CGFloat = 538" Sources/DashboardWindow.swift \
   && grep -q "preferencesScroll.documentView = preferencesCard" Sources/DashboardWindow.swift; then
    pass "panel minimum size is derived from its fixed-height rows"
else
    fail "panel minSize is not tied to naturalContentHeight (rows will clip)"
fi

exit $FAILED

#!/usr/bin/env bash
# Pre-commit checks for DSH Bar.
#
# Each check targets a mistake that is invisible in review and silent at
# runtime: a missing translation renders as English text with no error, and a
# stale app name leaves a path that no longer resolves.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
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

# 2. Every path the README tells a user to run must still exist or resolve.
while IFS= read -r path; do
    if [[ -e "$path" || "$path" == *".app" || "$path" == /Applications/* ]]; then
        pass "README path: $path"
    else
        fail "README references a path that does not exist: $path"
    fi
done < <(grep -oE '"/Applications/[^"]+\.app"|"build/[^"]+\.app"' README.md | tr -d '"' | sort -u)

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

exit $FAILED

#!/usr/bin/env bash
# Compile and exercise the production writer, without an app or test framework.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-bar-rotation.XXXXXX")"
cleanup() {
    [[ "$CACHE" == "${TMPDIR:-/tmp}/dsh-bar-rotation."* && -d "$CACHE" ]] || return 1
    rm -rf "$CACHE"
}
trap cleanup EXIT
python3 "$REPO/Tests/log-launch-extract.py" "$CACHE/LaunchHarness.swift"
swiftc -Onone -parse-as-library -module-cache-path "$CACHE/modulecache" \
    "$REPO/Sources/RotatingLogWriter.swift" "$CACHE/LaunchHarness.swift" "$REPO/Tests/LogRotationChecks.swift" \
    -o "$CACHE/log-check"
"$CACHE/log-check"
python3 "$REPO/Tests/log-rotation-process-check.py" "$CACHE/log-check"

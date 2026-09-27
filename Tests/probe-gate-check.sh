#!/usr/bin/env bash
# Truth table for the polling gate in ServiceManager.isPortListening.
#
# The gate decides the menu bar's phase on every 2-second tick, so a wrong
# answer is a wrong status light. The function is extracted from the real
# source rather than copied here, so a change to the implementation is what
# gets tested — a duplicated copy would happily pass while the app was broken.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO/Sources/ServiceManager.swift"

if ! grep -q "private func isPortListening" "$SOURCE"; then
    echo "isPortListening not found in $SOURCE" >&2
    exit 1
fi

CACHE="${TMPDIR:-/tmp}/dsh-bar-probe-gate"
mkdir -p "$CACHE"
trap 'rm -rf "$CACHE"' EXIT

# Take the function verbatim, de-indent it, and drop the `private` that a
# top-level script cannot use.
sed -n '/private func isPortListening/,/^    }/p' "$SOURCE" \
    | sed -e 's/^    //' -e 's/^private func /func /' > "$CACHE/gate.swift"

# The timeout constant lives next to the function; a stale value in the test
# would hide a regression, so take that from the source too.
sed -n 's/^    private static let portProbeTimeoutMilliseconds: Int32 = /let portProbeTimeoutMilliseconds: Int32 = /p' \
    "$SOURCE" | sed 's/^    //' > "$CACHE/timeout.swift"

if [[ ! -s "$CACHE/gate.swift" || ! -s "$CACHE/timeout.swift" ]]; then
    echo "could not extract the gate or its timeout from $SOURCE" >&2
    exit 1
fi

# The function refers to the constant as `Self.…` because it lives on the
# class in the app; a top-level script has no `Self`.
sed -i '' 's/Self\.portProbeTimeoutMilliseconds/portProbeTimeoutMilliseconds/' "$CACHE/gate.swift"

cat > "$CACHE/main.swift" <<'SWIFT'
import Foundation

SWIFT
cat "$CACHE/timeout.swift" >> "$CACHE/main.swift"
cat "$CACHE/gate.swift" >> "$CACHE/main.swift"
cat >> "$CACHE/main.swift" <<'SWIFT'

func listener(_ port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            _ = bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            _ = listen(fd, 1)
        }
    }
    return fd
}

let closedPort = 45711
let livePort = 45712

// Nothing is bound: the gate must report "nothing here" so the stopped state
// costs one syscall and no lsof fork.
assert(!isPortListening(closedPort), "closed port reported as listening")

// A real listener: the gate must let the probe through to the HTTP check.
let server = listener(UInt16(livePort))
assert(isPortListening(livePort), "live listener not detected")

// Closing it again must flip straight back, with no cached result to go stale.
close(server)
assert(!isPortListening(livePort), "closed-after-listen still reported as listening")

// A refused connect on loopback returns immediately rather than consuming the
// whole poll timeout; if this regresses, every stopped tick costs 200ms.
let started = Date()
for _ in 0..<20 { _ = isPortListening(closedPort) }
let perProbe = Date().timeIntervalSince(started) / 20
assert(perProbe < 0.05, "refused probe too slow: \(perProbe)s")

// Known limit: on loopback a connect never stays in EINPROGRESS, so the
// poll/SO_ERROR branch is never exercised here. A bug in that branch (for
// example returning true without reading SO_ERROR) still passes this check.
// Testing it needs a firewall rule to drop SYNs to 127.0.0.1, which is not
// something a test should do to the machine it runs on.
print("PASS")
SWIFT

MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-$CACHE/modulecache}"
mkdir -p "$MODULE_CACHE"
swiftc -O -module-cache-path "$MODULE_CACHE" "$CACHE/main.swift" -o "$CACHE/probe-gate" 2>"$CACHE/build.log" || {
    echo "could not compile the gate check:" >&2
    cat "$CACHE/build.log" >&2
    exit 1
}

"$CACHE/probe-gate"

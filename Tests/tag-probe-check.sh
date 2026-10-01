#!/usr/bin/env bash
# Truth table for DSH tag logic: which tag is "installed", what a probe
# failure looks like, what command a tag produces, and what the install-channel
# row should say and enable in each state.
#
# The functions and types are extracted from Sources/DshVersionController.swift
# and Sources/DashboardWindow.swift rather than copied here, so a change to the
# implementation is what gets tested. Only the *environment* those types reach
# for — the preference, the controller's busy flag, localized strings — is
# stubbed.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO/Sources/DshVersionController.swift"
WINDOW="$REPO/Sources/DashboardWindow.swift"

if ! grep -q "static func installCommand(forTag" "$SOURCE"; then
    echo "installCommand(forTag:) not found in $SOURCE" >&2
    exit 1
fi

if ! grep -q "func tagRowPresentation" "$WINDOW"; then
    echo "tagRowPresentation not found in $WINDOW" >&2
    exit 1
fi

CACHE="${TMPDIR:-/tmp}/dsh-bar-tag-probe"
mkdir -p "$CACHE"
trap 'rm -rf "$CACHE"' EXIT

# `validTag` is what `installCommand` calls to make its decision, so it is
# extracted with it: testing the allowlist through the command is the point.
sed -n '/static func validTag/,/^    }$/p' "$SOURCE" \
    | sed -e 's/^    //' > "$CACHE/valid-tag.swift"
sed -n '/static func installCommand(forTag/,/^    }$/p' "$SOURCE" \
    | sed -e 's/^    //' > "$CACHE/command.swift"

# `static func` is a member, not top-level code: main.swift rejects it. The
# extracted body is wrapped in a namespace that supplies it, and the file-level
# name the assertions call is forwarded to it. The assertions stay verbatim and
# still exercise the real source text.
{
    echo 'enum Extracted {'
    sed -e 's/^/    /' "$CACHE/valid-tag.swift"
    sed -e 's/^/    /' "$CACHE/command.swift"
    echo '}'
    echo 'enum ServiceManager {'
    echo '    static let installCommand = "npm install -g @deepseek-ai/dsh"'
    echo '}'
    echo 'func installCommand(forTag tag: String) -> String? {'
    echo '    Extracted.installCommand(forTag: tag)'
    echo '}'
} > "$CACHE/command.wrapped.swift"
mv "$CACHE/command.wrapped.swift" "$CACHE/command.swift"

# The value types the row renders from, verbatim from the real sources. These
# are what decides the truth table, so they are never re-declared here.
{
    sed -n '/^struct TagOption/,/^}$/p'            "$SOURCE"
    sed -n '/^enum ProbeFailure/,/^}$/p'           "$SOURCE"
    sed -n '/^enum ProbeState/,/^}$/p'             "$SOURCE"
    sed -n '/^struct TagRowPresentation/,/^}$/p'  "$WINDOW"
} > "$CACHE/model.swift"

# `tagRowPresentation` sits at file scope (outside the controller class), so no
# de-indent is needed. Unlike the members extracted above it closes with a `}`
# at column zero, which is what ends the range: the `/^    }$/` form used above
# would cut this one off at the closing brace of its own `switch`.
sed -n '/^func tagRowPresentation/,/^}$/p' "$WINDOW" > "$CACHE/render.swift"

# The seam, not a copy: every value `tagRowPresentation` reads from the app.
# The literals the assertions pin must match the English table exactly —
# `.tagProbeOffline` is compared against "Could not reach the npm registry" —
# and `.tagInstalledSuffix` must keep its {tag}/{version} placeholders, because
# the row substitutes into them rather than formatting a string itself.
cat > "$CACHE/environment.swift" <<'SWIFT'
final class DshVersionController {
    static let shared = DshVersionController()
    var isInstalling = false
}

final class SettingsManager {
    static let shared = SettingsManager()
    var preferredDshTag: String?
}

enum Localization {
    enum Key: String {
        case installChannel, installChannelDesc, tagInstalledSuffix
        case searchingPath, checkingEllipsis, installEllipsis
        case installDoneRestartNotice, portChangedAppliesLater
        case tagProbeOffline, tagProbeTimedOut, tagProbeNotFound, tagProbeBadResponse
    }
}

func L(_ key: Localization.Key, _ variables: [String: String] = [:]) -> String {
    switch key {
    case .tagProbeOffline:     return "Could not reach the npm registry"
    case .tagProbeTimedOut:    return "The npm registry did not answer in time"
    case .tagProbeNotFound:    return "This package is not on the npm registry"
    case .tagProbeBadResponse: return "The npm registry returned an unexpected response"
    case .tagInstalledSuffix:  return "{tag} ({version}, installed)"
    // Also pinned by the assertions above, so a drifted English table is a test
    // failure rather than something only a reader would notice.
    case .installDoneRestartNotice: return "Installed. Restart the service to use it."
    case .installChannel:            return "Install Channel"
    case .portChangedAppliesLater:  return "portChangedAppliesLater"
    case .installChannelDesc:        return "installChannelDesc"
    default:                   return key.rawValue
    }
}
SWIFT

cat > "$CACHE/main.swift" <<'SWIFT'
import Foundation
SWIFT
cat "$CACHE/model.swift"      >> "$CACHE/main.swift"
cat "$CACHE/environment.swift" >> "$CACHE/main.swift"
cat "$CACHE/render.swift"      >> "$CACHE/main.swift"
# command.swift last: it re-declares nothing, but `installCommand(forTag:)`
# must stay the file-level forwarding name the assertions call.
cat "$CACHE/command.swift"     >> "$CACHE/main.swift"

cat >> "$CACHE/main.swift" <<'SWIFT'

// `assert` is compiled out at -O, and this script builds with -O, so the plan's
// asserts would print PASS no matter what the source says. Verified: `assert(1 == 2)`
// exits 0 under -O and traps under -Onone. Same truth table, same messages, but
// always-on.
func expect(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok {
        FileHandle.standardError.write(Data(("FAIL: " + message() + "\n").utf8))
        exit(1)
    }
}
SWIFT

cat >> "$CACHE/main.swift" <<'SWIFT'

// --- Command assembly -----------------------------------------------------

// A tag the registry can legally return must produce the command the user was
// promised: the package name, an @, and the tag itself.
expect(installCommand(forTag: "latest") == "npm install -g @deepseek-ai/dsh@latest",
       "latest produced the wrong command")
expect(installCommand(forTag: "alpha") == "npm install -g @deepseek-ai/dsh@alpha",
       "alpha produced the wrong command")

// A prerelease version pasted into the tag slot, and a scoped-package-looking
// string, are the shapes a user (or a hostile response) actually produces.
expect(installCommand(forTag: "1.0.0") == "npm install -g @deepseek-ai/dsh@1.0.0",
       "a version-shaped tag must still work")
expect(installCommand(forTag: "v1.2.3-rc.1") == "npm install -g @deepseek-ai/dsh@v1.2.3-rc.1",
       "a v-prefixed prerelease tag must still work")

// Anything that could change what the command MEANS is refused outright rather
// than sanitised: empty, whitespace, a semicolon, an @ that would re-scope the
// package, and a space that would split it into two arguments.
for hostile in ["", " ", "  next  ", "next; rm -rf /", "@next", "next next", "$(id)", "a&b", "a|b", "a>b"] {
    expect(installCommand(forTag: hostile) == nil,
           "hostile tag accepted: \(hostile.debugDescription)")
}

// --- Row presentation -----------------------------------------------------
//
// A probe that has not finished must not look like an empty registry: the row
// says it is working and disables both controls.
let loading = tagRowPresentation(
    state: .loading, installedTag: nil, isRunning: false, pendingRestart: false
)
expect(loading.popupEnabled == false, "popup enabled while probing")
expect(loading.installButtonEnabled == false, "install enabled while probing")

// A failed probe explains itself and offers nothing to click. Each reason must
// reach the user: "the dropdown is empty" is not an explanation, and the four
// failures need four different fixes.
let failed = tagRowPresentation(
    state: .failed(.offline), installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(failed.description == "Could not reach the npm registry",
       "probe failure reason is not shown: \(failed.description)")
expect(failed.popupEnabled == false, "popup enabled after a failed probe")
expect(failed.installButtonEnabled == false, "install enabled after a failed probe")
expect(failed.showsRestartNotice == false, "a failed probe is not a pending install")
let spokenReasons: [(ProbeFailure, String)] = [
    (.offline,     "Could not reach the npm registry"),
    (.timedOut,    "The npm registry did not answer in time"),
    (.notFound,    "This package is not on the npm registry"),
    (.badResponse, "The npm registry returned an unexpected response")
]
for (failure, spoken) in spokenReasons {
    let row = tagRowPresentation(
        state: .failed(failure), installedTag: "latest", isRunning: false, pendingRestart: false
    )
    expect(row.description == spoken, "\(failure) says \"\(row.description)\", not \"\(spoken)\"")
}

// Tags that resolve to the same version are both marked installed and both stay
// selectable — they are different channels that merely coincide today.
let twins = ProbeState.loaded(
    tags: ["latest": "0.2.0-rc.2", "next": "0.2.0-rc.2", "alpha": "0.1.7-alpha.2"],
    installedVersion: "0.2.0-rc.2"
)
let twinOptions = twins.options()
let installedCount = twinOptions.filter(\.isInstalled).count
expect(installedCount == 2, "expected latest and next both installed, got \(installedCount)")
let nextTag = twinOptions.first { $0.tag == "next" }
expect(nextTag?.isInstalled == true, "next not marked installed despite matching version")

// Nothing to install when the registry offers no channel other than the one on
// disk: the popup is populated, so the row still renders, but the button is
// dead — reinstalling the version already present is not a repair. `options()`
// sorts installed-first, so index 0 is the installed one and the popup titles it
// with the localized "(installed)" template.
let onlyInstalled = ProbeState.loaded(
    tags: ["latest": "0.2.0-rc.2"], installedVersion: "0.2.0-rc.2"
)
let onInstalled = tagRowPresentation(
    state: onlyInstalled, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(onInstalled.installButtonEnabled == false,
       "install enabled with no other channel to move to")
expect(onInstalled.popupTitle == "latest (0.2.0-rc.2, installed)",
       "installed marker missing or not built from the localized template: \(onInstalled.popupTitle)")

// The stored preference picks the highlighted item, not whichever one happens to
// sort first. Nothing is stored here, so the fallback is index 0 — the installed
// channel, which is what a first run should show.
let defaulted = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(defaulted.popupTitle == "latest (0.2.0-rc.2, installed)",
       "with no stored tag the row should fall back to the installed channel: \(defaulted.popupTitle)")

// A stored tag that names a real channel moves the highlight to it. A stored
// tag the registry no longer offers must fall back rather than leave the popup
// pointing at nothing.
SettingsManager.shared.preferredDshTag = "alpha"
let storedAlpha = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
// A channel that is not installed is titled with its bare tag: which release it
// would install is noise until the user is choosing one.
expect(storedAlpha.popupTitle == "alpha",
       "stored tag did not drive the popup selection: \(storedAlpha.popupTitle)")

SettingsManager.shared.preferredDshTag = "next"
let storedNext = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(storedNext.popupTitle == "next (0.2.0-rc.2, installed)",
       "a stored-but-uninstalled channel lost its installed marker: \(storedNext.popupTitle)")

SettingsManager.shared.preferredDshTag = "no-longer-published"
let staleTag = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(staleTag.popupTitle == "latest (0.2.0-rc.2, installed)",
       "a tag the registry dropped left the popup pointing at nothing: \(staleTag.popupTitle)")
SettingsManager.shared.preferredDshTag = nil

// Another channel exists: enabled. Installing any channel other than the
// current one is a real change, whichever one is highlighted.
let onNext = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(onNext.installButtonEnabled == true, "install disabled when another channel exists")

// Service running does NOT block the install; it only changes the notice.
let whileRunning = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: true, pendingRestart: false
)
expect(whileRunning.installButtonEnabled == onNext.installButtonEnabled,
       "install enablement changed just because the service is running")

// An npm process already running is the one thing that must grey the button out:
// two `npm install -g` runs against the same global prefix corrupt each other.
DshVersionController.shared.isInstalling = true
let busy = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(busy.installButtonEnabled == false, "install enabled while npm is already running")
DshVersionController.shared.isInstalling = false

// After a successful install, the notice tells the user what to do next.
let pending = tagRowPresentation(
    state: twins, installedTag: "next", isRunning: true, pendingRestart: true
)
expect(pending.showsRestartNotice, "restart notice missing after a successful install")
expect(pending.description == "Installed. Restart the service to use it.",
       "pending-restart description is not the restart notice: \(pending.description)")

// A row that is merely running shows the generic "applies later" wording, not
// the install's own restart notice: an install is not always what pending
// means, and claiming otherwise would tell the user to restart for no reason.
expect(whileRunning.description == "portChangedAppliesLater",
       "running-service description is not the applies-later wording: \(whileRunning.description)")
expect(onNext.description == "installChannelDesc",
       "stopped-service description is not the channel description: \(onNext.description)")

// Title and button chrome are pinned to one key each so a typo cannot leave the
// row saying "Install Channel" above an unlabelled control.
expect(onNext.title == "Install Channel", "row title is not the channel title: \(onNext.title)")
expect(onNext.installButtonTitle == "installEllipsis",
       "install button title is not the ellipsis label: \(onNext.installButtonTitle)")
expect(loading.installButtonTitle == "checkingEllipsis",
       "a probing row must say it is working: \(loading.installButtonTitle)")
expect(loading.popupTitle.isEmpty, "a probing row must not claim a selection")
expect(loading.showsRestartNotice == false, "a probing row is not a pending install")
expect(onNext.showsRestartNotice == false, "restart notice shown with nothing installed")

// A state the registry can produce: no tags at all.
let empty = tagRowPresentation(
    state: .loaded(tags: [:], installedVersion: nil), installedTag: nil,
    isRunning: false, pendingRestart: false
)
expect(empty.popupTitle.isEmpty, "empty registry produced a bogus popup title")
expect(empty.installButtonEnabled == false, "install enabled with no tags")

print("PASS")
SWIFT

MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-$CACHE/modulecache}"
mkdir -p "$MODULE_CACHE"
swiftc -O -module-cache-path "$MODULE_CACHE" "$CACHE/main.swift" -o "$CACHE/tag-probe" 2>"$CACHE/build.log" || {
    echo "could not compile the tag check:" >&2
    cat "$CACHE/build.log" >&2
    exit 1
}

"$CACHE/tag-probe"

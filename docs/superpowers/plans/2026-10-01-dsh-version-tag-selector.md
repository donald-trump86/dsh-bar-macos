# DSH Version / npm Tag Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick which npm dist-tag of `@deepseek-ai/dsh` to install, and switch the machine's installed DSH from the preferences panel without opening a terminal.

**Architecture:** One new file, `Sources/DshVersionController.swift`, owns every fact about npm tag semantics — the registry URL, how a tag maps to a command, and which tag the running binary already is. It knows nothing about AppKit. The panel gets a second row under "DSH Command Line" holding a popup plus an Install button; the row re-renders from a small pure function that decides what the popup and button should show, so that decision is testable without a window. A new UserDefaults key stores the chosen tag, and is only ever read — never acted on by itself.

**Tech Stack:** Swift 5 / AppKit, macOS 13+, `Foundation.URLSession`, `Foundation.Process`. No third-party dependencies. No unit-test target: real behavioural tests are standalone `swiftc` scripts under `Tests/` that extract a function verbatim from the real source, following the precedent at `Tests/probe-gate-check.sh`.

**Spec:** `docs/superpowers/specs/2026-10-01-dsh-version-tag-selector-design.md` — read it alongside this plan; this plan implements it and does not re-argue it.

## Global Constraints

These hold in every task. Any task step that contradicts one is wrong.

- **Do not modify the value of `ServiceManager.installCommand`** (`Sources/ServiceManager.swift:44`, `"npm install -g @deepseek-ai/dsh"`). `DshInstallAssistant` reads it at `Sources/DshInstallAssistant.swift:12`, `:19`, `:38` and must keep the untagged command.
- **Never auto-restart the service and never touch `restartPreflight`.** Installing a different version does not restart anything; the user decides when.
- **Never kill, signal, or roll back any process on install failure.** Failure means showing the error.
- **Only one npm process at a time.** A second install request while one is running is dropped, not queued — two `npm install -g` runs against the same global prefix corrupt each other.
- **Never auto-install.** The stored tag (`DSH_DshTag`) is read to seed the popup's selection. No code path reads it in order to install.
- **Store the tag NAME, never a version number.** Tags move; a stored version becomes an invalid menu item tomorrow.
- **Probe only `https://registry.npmjs.org/-/package/@deepseek-ai/dsh/dist-tags`.** Never the full packument (~200KB). Never `npm view` — this machine's npm cache is root-owned and `npm view` fails `EPERM`.
- **Every `npm` / `which` child process must inherit `ServiceManager.commandEnvironment()`** so PATH resolution matches `findNpmBinary()`. It is `private static` today; Task 1 drops just the `private`, leaving bare `static` (which is already `internal` in Swift). Do not write `internal static` — check 7's grep anchors on `^    static func`.
- **The installed-binary comparison is by TAG, not by version number.** `latest` and `next` currently resolve to the same version, so a version-equality check would wrongly report `next` as already installed. Tag identity is what the user's selection means.
- **New user-facing strings go in both `english` and `chinese` tables in `Sources/Localization.swift`, in the same commit.** `Tests/run-checks.sh:42-71` fails otherwise.
- **New source file must be added to `SOURCE_FILES` in `build.sh:37-49`**, or it silently does not compile into the app.
- **Do not change** `CFBundleIdentifier = ai.deepseek.dsh-bar`, the existing UserDefaults keys (`DSH_CustomPort`, `DSH_GlobalHotKey*`, `DSH_Language`, `DSH_AutoRestart`, `DSH_LaunchAtLogin`), or `~/.dsh/dsh-bar-service.json` (`CONTRIBUTING.md:61-71`).
- **Fastest build loop:** `ARCHS=arm64 ./build.sh`. Full gate: `make check`.

## Review Focus

The spec is a vision document; these are the inputs and conditions it implies but no task's tests naturally exercise. Each has a test pinned to the task that owns the code.

1. **Tag names are attacker-shaped strings from the network.** A response of `{"evil; rm -rf /": "1.0.0", ...}` reaches the popup. It is never passed as a shell string (the plan uses `Process.executableURL` + `arguments`, no `sh -c`), but it must not become a popup item label that reads as a command either. — pinned in Task 2.
2. **A tag that would change what the command means** (`""`, `"  "`, `"@next"` — which would re-scope the package, `"next next"` or `"next; rm -rf /"` — which would split or chain it, `"$(id)"`). These are refused before any process spawns. Version-shaped input is *not* refused: `1.0.0` and `v1.2.3-rc.1` are valid npm tags and a user pasting one must get a working command. — pinned in Task 2.
3. **`latest` and `next` pointing at the same version.** Both must show `(installed)` simultaneously, and selecting the other one must stay *enabled* (they are different channels the user may want even though they currently resolve alike). — pinned in Task 3.
4. **The registry returns a non-200, a non-JSON body, or an HTML error page** (proxy captive portal, 404 after a rename). The row must degrade to a readable reason and a disabled button, never an empty dropdown and never a crash. — pinned in Task 2.
5. **The stored tag no longer exists** on the registry (dist-tag deleted upstream, or the user hand-edited the pref). The stored value must not survive as a selectable item or crash the selection. — pinned in Task 3.

---

### Task 1: Widen `commandEnvironment` so the controller can use it

**Files:**
- Modify: `Sources/ServiceManager.swift:320` (access level only)
- Test: `Tests/run-checks.sh` (new check 7)

**Interfaces:**
- Consumes: nothing.
- Produces: `static func commandEnvironment() -> [String: String]` on `ServiceManager`, callable from any file in the DSHBar module. Task 2 depends on this.

A new file cannot reach a `private static` member of another type in the same module — `private` in Swift is file-scoped, not module-scoped. Widen it to `static` (internal) so Task 2 can inherit the exact same PATH the binary lookup already uses.

- [ ] **Step 1: Change the access level**

In `Sources/ServiceManager.swift:320`, change:

```swift
    private static func commandEnvironment() -> [String: String] {
```

to:

```swift
    static func commandEnvironment() -> [String: String] {
```

Nothing else in this task. Do not touch the body.

- [ ] **Step 2: Add a check that pins the widening and forbids the regress**

Append to `Tests/run-checks.sh`, after check 6 and before `exit $FAILED`:

```bash
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
```

This check fails right now, because `Sources/DshVersionController.swift` does not exist yet. That is expected; it is one of the two halves of Task 2.

- [ ] **Step 3: Verify the app still builds with the widened access**

Run: `ARCHS=arm64 ./build.sh`
Expected: build succeeds. `commandEnvironment` has three call sites in `ServiceManager` (`findExecutable`, `readDshVersion`, `launchProcess`); none of them needed changing.

- [ ] **Step 4: Commit**

```bash
git add Sources/ServiceManager.swift Tests/run-checks.sh
git commit -m "refactor: widen commandEnvironment so the version controller can share PATH"
```

---

### Task 2: `DshVersionController` — pure tag logic and the registry probe

**Files:**
- Create: `Sources/DshVersionController.swift`
- Modify: `build.sh:37-49` (`SOURCE_FILES`)

**Interfaces:**
- Consumes: `ServiceManager.commandEnvironment()` from Task 1 (non-private since Task 1).
- Produces, all at **file scope** in `Sources/DshVersionController.swift` (chosen and committed in `3f6b200` — a nested `enum` namespace and a same-named `final class` cannot coexist in Swift, and every downstream reference uses the flat names):
  - `struct TagOption: Equatable { let tag: String; let version: String; let isInstalled: Bool }`
  - `enum ProbeFailure: Equatable, Error { case offline, timedOut, notFound, badResponse }` plus `var message: String`. **`Error` is required**, not optional: `fetchTags` hands this out as a `Result` failure.
  - `enum ProbeState` with the **cases** `idle`, `loading`, `loaded(tags: [String: String], installedVersion: String?)`, `failed(ProbeFailure)` — these are enum cases, not factory functions, and cannot also exist as same-named static funcs. Plus `var tags`, `var installedVersion`, `var failure`, `var isLoading`, `func options() -> [TagOption]`, `var installedTag: String?`.
  - `enum DshVersionControllerError: LocalizedError` with `invalidTag(String)`, `alreadyInstalling`, `npmNotFound`, `installFailed(exitCode: Int32, output: String)`, `installCouldNotStart(String)`.
  - `final class DshVersionController` with `static let shared = DshVersionController()`, `static func validTag(_ tag: String) -> Bool`, `static func installCommand(forTag tag: String) -> String?` (returns `nil` when the tag is empty or contains characters outside `a-zA-Z0-9-._`; delegates to `validTag`), `func fetchTags(completion: @escaping (Result<[String: String], ProbeFailure>) -> Void)`, `func install(tag: String, completion: @escaping (Result<String, Error>) -> Void)`, `private(set) var isInstalling: Bool`.

**Note on the naming decision:** shape (B) — flat file-scope types — was chosen in `3f6b200` and is what the code block below and Tasks 3-4 use. Do not reintroduce the nested-namespace form.

- [ ] **Step 1: Write the failing behavioural test**

Create `Tests/tag-probe-check.sh`, modelled on `Tests/probe-gate-check.sh` — extract the real functions from the real file, never a copy:

```bash
#!/usr/bin/env bash
# Truth table for DSH tag logic: which tag is "installed", what a probe
# failure looks like, and what command a tag produces.
#
# The functions are extracted from Sources/DshVersionController.swift rather
# than copied here, so a change to the implementation is what gets tested.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO/Sources/DshVersionController.swift"

if ! grep -q "static func installCommand(forTag" "$SOURCE"; then
    echo "installCommand(forTag:) not found in $SOURCE" >&2
    exit 1
fi

CACHE="${TMPDIR:-/tmp}/dsh-bar-tag-probe"
mkdir -p "$CACHE"
trap 'rm -rf "$CACHE"' EXIT

sed -n '/static func installCommand(forTag/,/^    }$/p' "$SOURCE" \
    | sed -e 's/^    //' > "$CACHE/command.swift"

cat > "$CACHE/main.swift" <<'SWIFT'
import Foundation

SWIFT
cat "$CACHE/command.swift" >> "$CACHE/main.swift"
cat >> "$CACHE/main.swift" <<'SWIFT'

// A tag the registry can legally return must produce the command the user was
// promised: the package name, an @, and the tag itself.
assert(installCommand(forTag: "latest") == "npm install -g @deepseek-ai/dsh@latest",
       "latest produced the wrong command")
assert(installCommand(forTag: "alpha") == "npm install -g @deepseek-ai/dsh@alpha",
       "alpha produced the wrong command")

// A prerelease version pasted into the tag slot, and a scoped-package-looking
// string, are the shapes a user (or a hostile response) actually produces.
assert(installCommand(forTag: "1.0.0") == "npm install -g @deepseek-ai/dsh@1.0.0",
       "a version-shaped tag must still work")
assert(installCommand(forTag: "v1.2.3-rc.1") == "npm install -g @deepseek-ai/dsh@v1.2.3-rc.1",
       "a v-prefixed prerelease tag must still work")

// Anything that could change what the command MEANS is refused outright rather
// than sanitised: empty, whitespace, a semicolon, an @ that would re-scope the
// package, and a space that would split it into two arguments.
for hostile in ["", " ", "  next  ", "next; rm -rf /", "@next", "next next", "$(id)", "a&b", "a|b", "a>b"] {
    assert(installCommand(forTag: hostile) == nil,
           "hostile tag accepted: \(hostile.debugDescription)")
}

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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash Tests/tag-probe-check.sh`
Expected: FAIL with `installCommand(forTag:) not found in Sources/DshVersionController.swift`.

- [ ] **Step 3: Add the file to the build**

In `build.sh`, insert `Sources/DshVersionController.swift` into `SOURCE_FILES` after `Sources/DshInstallAssistant.swift`.

- [ ] **Step 4: Write the pure tag logic**

Create `Sources/DshVersionController.swift` with `import Foundation`. Define, at file scope:

```swift
struct TagOption: Equatable {
    let tag: String
    let version: String
    let isInstalled: Bool
}

enum ProbeFailure: Equatable {
    case offline, timedOut, notFound, badResponse

    /// Drives the row's description label. The failure reason is what the user
    /// sees instead of a dropdown: an empty list with no explanation reads as a
    /// broken app, not an unreachable network.
    var message: String {
        switch self {
        case .offline:    return L(.tagProbeOffline)
        case .timedOut:   return L(.tagProbeTimedOut)
        case .notFound:   return L(.tagProbeNotFound)
        case .badResponse: return L(.tagProbeBadResponse)
        }
    }
}

enum ProbeState {
    case idle
    case loading
    case loaded(tags: [String: String], installedVersion: String?)
    case failed(ProbeFailure)

    var tags: [String: String] {
        if case .loaded(let tags, _) = self { return tags }
        return [:]
    }

    var installedVersion: String? {
        if case .loaded(_, let version) = self { return version }
        return nil
    }

    var failure: ProbeFailure? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The popup's items, newest channel first.
    ///
    /// Two tags pointing at the same version are both marked installed, and
    /// both stay separately selectable — the user's choice is "follow latest" vs
    /// "follow next", and today those happen to resolve alike. Marking by
    /// version instead would collapse the distinction the moment the tags
    /// diverge.
    func options() -> [TagOption] {
        guard case .loaded(let tags, let installed) = self else { return [] }
        return tags
            .map { TagOption(tag: $0.key, version: $0.value, isInstalled: $0.value == installed) }
            .sorted { lhs, rhs in
                if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
                return lhs.tag < rhs.tag
            }
    }

    /// The installed tag, if any. An install is only worth offering when it
    /// moves a different channel than the one already on disk.
    var installedTag: String? {
        options().first { $0.isInstalled }?.tag
    }
}
```

`installCommand(forTag:)` — note the allowlist. A tag arrives from the network, so it is validated before it reaches a popup label, a stored preference, or (via this function) the confirmation dialog:

```swift
/// The command shown in the confirmation dialog and executed on confirm.
///
/// Returns nil rather than sanitising: a tag we cannot vouch for must never
/// become a command the user is asked to approve, because they approve it
/// without knowing what it was rewritten to.
static func installCommand(forTag tag: String) -> String? {
    guard !tag.isEmpty,
          tag.range(of: "^[a-zA-Z0-9-._]+$", options: .regularExpression) != nil
    else { return nil }
    return "\(ServiceManager.installCommand)@\(tag)"
}
```

Note the build: `ServiceManager.installCommand` is `"npm install -g @deepseek-ai/dsh"`, so appending `@\(tag)` yields `npm install -g @deepseek-ai/dsh@next`. **Do not** write that literal out — reuse the constant so `DshInstallAssistant` and this stay in step. This also satisfies the spec's grep assertion, which requires `installCommand` present and no literal `npm install -g @deepseek-ai/dsh@<letter>`.

- [ ] **Step 5: Write the registry probe**

Add to `final class DshVersionController` in the same file:

```swift
private static let distTagsURL = URL(
    string: "https://registry.npmjs.org/-/package/@deepseek-ai/dsh/dist-tags"
)!
private static let probeTimeout: TimeInterval = 5.0

private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5.0
    config.timeoutIntervalForResource = 5.0
    return URLSession(configuration: config)
}()

private var installInFlight = false

func fetchTags(completion: @escaping (Result<[String: String], ProbeFailure>) -> Void) {
    var request = URLRequest(url: Self.distTagsURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = Self.probeTimeout
    session.dataTask(with: request) { data, response, error in
        if let error = error as? URLError {
            let failure: ProbeFailure = error.code == .timedOut ? .timedOut : .offline
            return DispatchQueue.main.async { completion(.failure(failure)) }
        }
        guard let http = response as? HTTPURLResponse else {
            return DispatchQueue.main.async { completion(.failure(.badResponse)) }
        }
        guard http.statusCode == 200 else {
            let failure: ProbeFailure = http.statusCode == 404 ? .notFound : .badResponse
            return DispatchQueue.main.async { completion(.failure(failure)) }
        }
        guard let data,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !parsed.isEmpty
        else {
            return DispatchQueue.main.async { completion(.failure(.badResponse)) }
        }
        DispatchQueue.main.async { completion(.success(parsed)) }
    }.resume()
}
```

The 5s timeout is deliberately longer than `ServiceManager`'s 1s probe timeout: that one answers "is the local port listening", this one crosses the internet. The row shows `Checking…` while it waits, so a slow network is visible rather than frozen.

- [ ] **Step 6: Write the install path**

```swift
/// Whether an npm process is running right now. The row reads this to grey out
/// its own button; `install` refuses a second run regardless.
private(set) var isInstalling = false

func install(tag: String, completion: @escaping (Result<String, Error>) -> Void) {
    guard let command = Self.installCommand(forTag: tag) else {
        return DispatchQueue.main.async {
            completion(.failure(DshVersionControllerError.invalidTag(tag)))
        }
    }
    guard !installInFlight else {
        return DispatchQueue.main.async {
            completion(.failure(DshVersionControllerError.alreadyInstalling))
        }
    }
    guard let npm = ServiceManager.shared.findNpmBinary() else {
        return DispatchQueue.main.async {
            completion(.failure(DshVersionControllerError.npmNotFound))
        }
    }

    installInFlight = true
    let arguments = command
        .split(separator: " ", omittingEmptySubsequences: true)
        .dropFirst()
        .map(String.init)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: npm)
    process.arguments = arguments
    process.environment = ServiceManager.commandEnvironment()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    DispatchQueue.global(qos: .utility).async {
        var failure: DshVersionControllerError?
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                failure = .installFailed(
                    exitCode: process.terminationStatus,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            failure = .installCouldNotStart(error.localizedDescription)
        }
        DispatchQueue.main.async {
            self.installInFlight = false
            self.isInstalling = false
            switch failure {
            case .some(let error):
                completion(.failure(error))
            case .none:
                completion(.success(""))
            }
        }
    }
}
```

Two decisions pinned here:

- **Splitting the command string.** `installCommand(forTag:)` produces a human-facing string for the dialog; the process runs `npm` directly with the split tail as `arguments`. There is no `sh -c` anywhere, so a tag can never be interpreted as shell syntax. `npm` lives at `/opt/homebrew/bin/npm`, so argv[0] is the real npm — splitting off the first word and letting `executableURL` supply it is safe.
- **`isInstalling` is redundant with `installInFlight`.** It exists so the UI can read the flag without crossing the module's internal state; set it at the same two places `installInFlight` is set. If the compiler warns about it being unused, keep it — Task 4 reads it.

Add the error type:

```swift
enum DshVersionControllerError: LocalizedError {
    case invalidTag(String)
    case alreadyInstalling
    case npmNotFound
    case installFailed(exitCode: Int32, output: String)
    case installCouldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .invalidTag(let tag):
            return L(.installTagInvalid, ["tag": tag])
        case .alreadyInstalling:
            return L(.installAlreadyRunning)
        case .installFailed(let exitCode, let output):
            // npm's own stderr is the useful part — EACCES from a root-owned
            // prefix is the common failure and the app cannot fix it.
            let detail = output.isEmpty ? L(.installNoOutput) : output
            return L(.installFailedBody, ["code": "\(exitCode)", "output": detail])
        case .npmNotFound:
            return L(.installNpmNotFound)
        case .installCouldNotStart(let message):
            return L(.installCouldNotStart, ["reason": message])
        }
    }
}
```

- [ ] **Step 7: Make it compile**

Run: `ARCHS=arm64 ./build.sh`
Expected: FAIL — `DshVersionControllerError`'s cases call `L(.tagProbeOffline)`, `L(.installTagInvalid)` etc., and those keys do not exist yet. Every missing-key error names a key that Task 3 adds. Do not add them here; Task 3 owns `Sources/Localization.swift`, and splitting that file across two commits means an intermediate tree that does not build.

- [ ] **Step 8: Commit**

```bash
git add Sources/DshVersionController.swift build.sh
git commit -m "feat: add DshVersionController with tag logic, registry probe and npm install

The pure tag types (TagOption, ProbeState, DshVersionControllerError) are file
scope; the controller class is the only stateful part."
```

---

### Task 3: The preference, the strings, and the row's rendering logic

**STATUS: complete, landed as `d27237f`.** Every step below ran. Steps 1, 2 and 5 differ from the plan text — read the notes on each step and use the committed source, not the code blocks here. Step 3's truth table was rewritten (5 of the planned 9 assertions survived mutation because two cases passed identical arguments), and Step 6 wired check 8 exactly as written.

**Files:**
- Modify: `Sources/SettingsManager.swift` (new key constant + `preferredDshTag`)
- Modify: `Sources/Localization.swift:72` (enum), `:285` (english), `:492` (chinese)
- Modify: `Sources/DashboardWindow.swift` — new pure function `tagRowPresentation(state:installedTag:isRunning:pendingRestart:)` returning the row's texts and enablement; no view construction here.
- Test: extend `Tests/tag-probe-check.sh` with the render truth table

**Interfaces:**
- Consumes: `TagOption`, `ProbeState`, `ProbeFailure` from Task 2.
- Produces: `var preferredDshTag: String?` on `SettingsManager` (read+write, validated on both), and `func tagRowPresentation(state: ProbeState, installedTag: String?, isRunning: Bool, pendingRestart: Bool) -> TagRowPresentation` where

  ```swift
  struct TagRowPresentation: Equatable {
      var title: String
      var description: String
      var popupTitle: String          // "" while loading; the selected item otherwise
      var popupEnabled: Bool
      var installButtonTitle: String
      var installButtonEnabled: Bool
      var showsRestartNotice: Bool
  }
  ```

  Task 4 calls this and applies the result to the real views.

**Why the preference lives here and not in Task 4:** `tagRowPresentation` below reads `SettingsManager.shared.preferredDshTag` to pick the popup's initial selection. If the property were added in Task 4, this task would not compile. It is one constant and one property, and its own test is the render truth table in this task.

**Why a pure function:** the decision "what does this row say and which button is live" is the part that can be wrong without anything visibly crashing. A dropdown that is enabled with no tag selected, or a button live while a probe failed, are both silent. Extracting it makes the truth table testable with no window and no AppKit — the same move `Tests/probe-gate-check.sh` made for `isPortListening`.

- [ ] **Step 1: Add the preference**

As committed: `SettingsManager` has no `defaults` property, so both accessors use `UserDefaults.standard` directly (the plan's stated fallback). The constant sits with the other keys and the property under a `// MARK: - Install channel` section after the `autoRestartEnabled` block. The validation is `DshVersionController.validTag(_:)` on **both** accessors — an invalid or upstream-deleted tag reads back as `nil`, and writing one removes the key rather than storing it.

In `Sources/SettingsManager.swift`, add the key constant beside the others at `:12`:

```swift
    private let keyPreferredDshTag = "DSH_DshTag"
```

and add after the `autoRestartEnabled` block (after `:96`):

```swift
    // MARK: - DSH Install Channel
    /// The npm dist-tag the user picked in the panel. Read-only in practice: it
    /// seeds the popup's selection and nothing else. No code path installs on
    /// the strength of this value — a tag that was chosen once must not turn
    /// into an install on a later launch.
    ///
    /// The tag NAME is stored, never a version: dist-tags move, so a stored
    /// version would reappear as an item that no longer exists upstream.
    var preferredDshTag: String? {
        get {
            guard let tag = UserDefaults.standard.string(forKey: keyPreferredDshTag),
                  DshVersionController.validTag(tag) else { return nil }
            return tag
        }
        set {
            guard let newValue, DshVersionController.validTag(newValue) else {
                UserDefaults.standard.removeObject(forKey: keyPreferredDshTag)
                return
            }
            UserDefaults.standard.set(newValue, forKey: keyPreferredDshTag)
        }
    }
```

The `validTag` guard on read means a hand-edited or corrupted default reads back as `nil` rather than poisoning the popup — Review Focus #5. This needs `validTag(_:)` from Task 2, which exists by now.

- [ ] **Step 2: Add the localization keys**

In `Sources/Localization.swift`, extend the preferences-rows group at `:72`:

```swift
        case searchingPath, detectingDsh, installedAt, notFoundInstallNpm
        case installChannel, installChannelDesc, tagInstalledSuffix
        case tagProbeOffline, tagProbeTimedOut, tagProbeNotFound, tagProbeBadResponse
        case installConfirmTitle, installConfirmBody, installDoneRestartNotice
        case installFailedTitle, installTagInvalid, installAlreadyRunning
        case installFailedBody, installNoOutput, installNpmNotFound, installCouldNotStart
```

Then add to the **english** table after `:285` (`.notFoundInstallNpm`) and to the **chinese** table after `:492`, keeping the two blocks identical in key order:

```swift
        .installChannel: "Install Channel",
        .installChannelDesc: "Which npm tag to install; latest is the stable one",
        .tagInstalledSuffix: "{tag} ({version}, installed)",
        .tagProbeOffline: "Could not reach the npm registry",
        .tagProbeTimedOut: "The npm registry did not answer in time",
        .tagProbeNotFound: "This package is not on the npm registry",
        .tagProbeBadResponse: "The npm registry returned an unexpected response",
        .installConfirmTitle: "Install DSH from npm?",
        .installConfirmBody: "This will run:\n\n{command}\n\nThe running service is not affected until you restart it.",
        .installDoneRestartNotice: "Installed — restart the service to use it",
        .installFailedTitle: "Could Not Install DSH",
        .installTagInvalid: "\"{tag}\" is not a usable npm tag",
        .installAlreadyRunning: "An install is already running",
        .installFailedBody: "npm exited with code {code}.\n\n{output}",
        .installNoOutput: "(npm produced no output)",
        .installNpmNotFound: "npm was not found on PATH",
        .installCouldNotStart: "npm could not be started: {reason}",
```

```swift
        .installChannel: "安装通道",
        .installChannelDesc: "选择要安装的 npm tag；latest 是稳定版",
        .tagInstalledSuffix: "{tag}（{version}，已安装）",
        .tagProbeOffline: "无法连接 npm registry",
        .tagProbeTimedOut: "npm registry 响应超时",
        .tagProbeNotFound: "npm registry 上找不到这个包",
        .tagProbeBadResponse: "npm registry 返回了无法识别的内容",
        .installConfirmTitle: "用 npm 安装 DSH？",
        .installConfirmBody: "将执行：\n\n{command}\n\n当前运行的服务不受影响，重启后才会生效。",
        .installDoneRestartNotice: "已安装 — 重启服务后生效",
        .installFailedTitle: "无法安装 DSH",
        .installTagInvalid: "“{tag}” 不是可用的 npm tag",
        .installAlreadyRunning: "已有安装正在进行中",
        .installFailedBody: "npm 以代码 {code} 退出。\n\n{output}",
        .installNoOutput: "（npm 没有输出任何内容）",
        .installNpmNotFound: "PATH 中找不到 npm",
        .installCouldNotStart: "无法启动 npm：{reason}",
```

Both tables gain the same 17 keys in the same order. `Tests/run-checks.sh:42-71` verifies the key SETS match; adding to only one table fails it.

- [ ] **Step 3: Extend the behavioural test with the render truth table**

Append to `Tests/tag-probe-check.sh`'s `main.swift` heredoc — extraction, additions:

```bash
# The row's decision (what it says, which button is live) is the part that can
# be silently wrong, so it is a pure function and gets the same treatment as the
# gate. Extract it from DashboardWindow.swift.
if ! grep -q "func tagRowPresentation" "$REPO/Sources/DashboardWindow.swift"; then
    echo "tagRowPresentation not found in $REPO/Sources/DashboardWindow.swift" >&2
    exit 1
fi
sed -n '/^func tagRowPresentation/,/^}$/p' "$REPO/Sources/DashboardWindow.swift" > "$CACHE/render.swift"

# `tagRowPresentation` takes a ProbeState, calls its `options()`, reads the stored
# preference, reads `DshVersionController.shared.isInstalling`, and renders
# localized strings through `L(…)`. None of that exists in a standalone script,
# so the value types are EXTRACTED from the real source and only the environment
# is stubbed. Without this the render truth table cannot compile, and a truth
# table that does not compile is not a test.
{
    sed -n '/^struct TagOption/,/^}$/p'        "$SOURCE"
    sed -n '/^enum ProbeFailure/,/^}$/p'       "$SOURCE"
    sed -n '/^enum ProbeState/,/^}$/p'         "$SOURCE"
    sed -n '/^struct TagRowPresentation/,/^}$/p' "$REPO/Sources/DashboardWindow.swift"
} > "$CACHE/model.swift"

# The environment the pure function reads but must not own. `isInstalling` is a
# plain stored property here: the test only needs it to exist and be false.
cat > "$CACHE/environment.swift" <<'SWIFT'
final class DshVersionController {
    static let shared = DshVersionController()
    var isInstalling = false
}

final class SettingsManager {
    static let shared = SettingsManager()
    var preferredDshTag: String?
}

// `L(…)` returns the key's own name for every string EXCEPT the three the
// assertions below pin literal English text for. A shim that returned something
// else would let those assertions pass against the stub instead of the app.
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
    default:                   return key.rawValue
    }
}
SWIFT
```

Then assemble `main.swift` as `model.swift` + `environment.swift` + `render.swift` + the `expect` helper + the two assertion blocks, in that order, and compile as before.

If `tagRowPresentation` ends up reading anything else from the app, stub that too — a missing symbol is a compile error, and the fix is to stub it honestly, never to edit the implementation to make the test compile.

and before the closing heredoc, after the existing `expect` calls. **Use `expect`, not `assert`** — the script compiles with `swiftc -O`, where `assert` is elided and the whole table would pass unconditionally (see Self-Review 2b):

```swift

// --- Row presentation -----------------------------------------------------
//
// A probe that has not finished must not look like an empty registry: the row
// says it is working and disables both controls.
let loading = tagRowPresentation(
    state: .loading, installedTag: nil, isRunning: false, pendingRestart: false
)
expect(loading.popupEnabled == false, "popup enabled while probing")
expect(loading.installButtonEnabled == false, "install enabled while probing")

// A failed probe explains itself and offers nothing to click.
let failed = tagRowPresentation(
    state: .failed(.offline), installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(failed.description == "Could not reach the npm registry",
       "probe failure reason is not shown: \(failed.description)")
expect(failed.popupEnabled == false, "popup enabled after a failed probe")
expect(failed.installButtonEnabled == false, "install enabled after a failed probe")

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

// Installed tag selected: nothing to do, so the button is dead.
let onInstalled = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(onInstalled.installButtonEnabled == false,
       "install enabled for the tag already on disk")
expect(onInstalled.popupTitle.contains("latest"), "selected tag missing from popup title")

// A different tag selected: enabled, and the command is the one shown.
let onNext = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: false, pendingRestart: false
)
expect(onNext.installButtonEnabled == true, "install disabled for a different tag")

// Service running does NOT block the install; it only changes the notice.
let whileRunning = tagRowPresentation(
    state: twins, installedTag: "latest", isRunning: true, pendingRestart: false
)
expect(whileRunning.installButtonEnabled == onNext.installButtonEnabled,
       "install enablement changed just because the service is running")

// After a successful install, the notice tells the user what to do next.
let pending = tagRowPresentation(
    state: twins, installedTag: "next", isRunning: true, pendingRestart: true
)
expect(pending.showsRestartNotice, "restart notice missing after a successful install")

// A state the registry can produce: no tags at all.
let empty = tagRowPresentation(
    state: .loaded(tags: [:], installedVersion: nil), installedTag: nil,
    isRunning: false, pendingRestart: false
)
expect(empty.popupTitle.isEmpty, "empty registry produced a bogus popup title")
expect(empty.installButtonEnabled == false, "install enabled with no tags")
```

- [ ] **Step 4: Run it and watch it fail**

Run: `bash Tests/tag-probe-check.sh`
Expected: FAIL with `tagRowPresentation not found in Sources/DashboardWindow.swift`.

- [ ] **Step 5: Implement `tagRowPresentation`**

**This step is superseded by what is already committed.** `d27237f` landed a working `tagRowPresentation`, and the truth table in Step 3 was rewritten at the same time. The body below is the ORIGINAL plan, kept only so the diffs are visible. Three of them are deliberate improvements, not regressions:

1. The `switch state` with three early returns became straight-line code ending in one `TagRowPresentation(…)`, because the three arms disagreed with each other — `.failed` and `.loaded` returned different `popupTitle` shapes for the same input, and the `.failed` arm never consulted `pendingRestart`.
2. **The `description` gained `state.failure?.message ?? restingDescription`.** As written below, the `.failed` arm was the only place a reason surfaced, and the plan's own truth table calls `tagRowPresentation` once per state, so the reason was reachable — but the description was assembled in three separate places and could drift. The committed shape computes it once.
3. The button title went from a constant `L(.installEllipsis)` to `state.isLoading ? L(.checkingEllipsis) : L(.installEllipsis)`.

Do not restore this block. Read `Sources/DashboardWindow.swift` for the real body, and note that it lives at **file scope** (a leading `func`, not `    func`) — which is why Step 3's extraction is `/^func tagRowPresentation/,/^}$/p` with no de-indent.

The original, for the record:

```swift
/// What the install-channel row should display. Separated from the views so the
/// decision can be checked without opening a window: an enabled button over an
/// empty dropdown looks like a working app and is not.
struct TagRowPresentation: Equatable {
    var title: String
    var description: String
    var popupTitle: String
    var popupEnabled: Bool
    var installButtonTitle: String
    var installButtonEnabled: Bool
    var showsRestartNotice: Bool
}
```

```swift
func tagRowPresentation(
    state: ProbeState,
    installedTag: String?,
    isRunning: Bool,
    pendingRestart: Bool
) -> TagRowPresentation {
    let title = L(.installChannel)
    let button = L(.installEllipsis)
    let installedSuffix = L(.tagInstalledSuffix)

    switch state {
    case .idle, .loading:
        return TagRowPresentation(
            title: title,
            description: L(.searchingPath),
            popupTitle: L(.checkingEllipsis),
            popupEnabled: false,
            installButtonTitle: button,
            installButtonEnabled: false,
            showsRestartNotice: pendingRestart
        )

    case .failed(let reason):
        return TagRowPresentation(
            title: title,
            description: reason.message,
            popupTitle: "",
            popupEnabled: false,
            installButtonTitle: button,
            installButtonEnabled: false,
            showsRestartNotice: pendingRestart
        )

    case .loaded:
        let options = state.options()
        // The popup shows every channel, each carrying its version so two tags
        // that happen to resolve alike are still distinguishable.
        let titles = options.map { option in
            option.isInstalled
                ? installedSuffix
                    .replacingOccurrences(of: "{tag}", with: option.tag)
                    .replacingOccurrences(of: "{version}", with: option.version)
                : "\(option.tag) — \(option.version)"
        }
        let selected = SettingsManager.shared.preferredDshTag
        let selection = options.firstIndex { $0.tag == selected } ?? 0
        let popupTitle = titles.indices.contains(selection) ? titles[selection] : ""
        // Nothing to install when no channel is known, or the chosen one is
        // already the one on disk. Reinstalling the same version is not a
        // repair, and offering it invites a pointless click.
        let hasOtherChannel = options.contains { $0.tag != installedTag }

        return TagRowPresentation(
            title: title,
            // The running-service wording is deliberately generic: this row also
            // covers an install performed while the service was stopped, and
            // .portChangedRestartToApply ("Restart to Apply") would be a lie
            // there. The full sentence lives in the confirmation dialog.
            description: pendingRestart
                ? L(.installDoneRestartNotice)
                : (isRunning ? L(.portChangedAppliesLater) : L(.installChannelDesc)),
            popupTitle: popupTitle,
            popupEnabled: !options.isEmpty,
            installButtonTitle: button,
            installButtonEnabled: hasOtherChannel && !DshVersionController.shared.isInstalling,
            showsRestartNotice: pendingRestart
        )
    }
}
```

Four things pinned in that body:

- The popup title is built by **substituting into the localized template**, matching `Localization.string` at `Sources/Localization.swift:178-185`, so the `(installed)` marker is translatable rather than a hardcoded `String(format:)`.
- `installButtonEnabled` uses `hasOtherChannel` — a tag exists that is *not* the installed one — **not** "the selected tag differs". Threading the selection in here would need a `selectedTag:` parameter and would put popup state in a function that is supposed to be a pure test of it; Task 4 re-evaluates on every selection change, and when exactly one other channel exists (the common case) the two readings agree. When several exist, the button is enabled for all of them — which is correct, since installing any channel other than the current one is a real change.
- `L(.portChangedAppliesLater)` is reused deliberately rather than adding a near-duplicate key: `Tests/run-checks.sh:42-71` only compares key *sets*, and a second string meaning "applies after a restart" would drift from the first. The version-specific full sentence is `.installConfirmBody`.
- **The description must be `state.failure?.message ?? restingDescription`.** An earlier draft of this body computed the pending-restart / running / idle wording and never consulted `state.failure`, so a failed probe rendered the generic channel blurb and the user was told nothing about the unreachable network — while `ProbeFailure.message`, added in Task 2 specifically to "drive the row's description label", went unused. The plan's own truth table caught it (`FAIL: probe failure reason is not shown: installChannelDesc`). A failure outranks the pending-restart notice, because a failure is what the user has to act on.

Relatedly, the planned three-arm `switch` for the button title was three branches of one decision — `.failed` and `default` both returned `L(.installEllipsis)` — so it collapses to `state.isLoading ? L(.checkingEllipsis) : L(.installEllipsis)`.

- [ ] **Step 6: Wire the check into `make check`**

Append before `exit $FAILED` in `Tests/run-checks.sh`:

```bash
# 8. Tag logic and the row's render decision both change silently when wrong:
#    a refused tag reaches a command the user approved, and an enabled button
#    over an empty dropdown reads as working. Both are checked against the real
#    source, not a copy.
if "$SCRIPT_DIR/tag-probe-check.sh" >/dev/null 2>&1; then
    pass "npm tag command assembly and install-channel row states are correct"
else
    fail "tag probe check failed — run $SCRIPT_DIR/tag-probe-check.sh to see why"
fi
```

Keep check 7 from Task 1 exactly as written. `make check` runs the file top to bottom, so until Task 2 lands, check 7 reports the missing `DshVersionController.swift` before check 8 gets a chance.

- [ ] **Step 7: Run the full gate**

Run: `make check`
Expected: checks 1-6, 7 and 8 pass — that is **11** `ok` lines, not ten: check 2 emits one line per README `.app` path (there are two), check 5 emits one per `check_pair` (there are three), and checks 1, 3, 4, 6, 7, 8 emit one each. Check 6 **still passes** — it asserts `naturalContentHeight: CGFloat = 538` and Task 4 has not run yet. It starts failing only once Task 4 changes the height, which is the spec's deliberate tripwire (`docs/superpowers/specs/2026-10-01-dsh-version-tag-selector-design.md:145`). If check 6 fails *now*, something outside this plan changed the height; find it before continuing.

- [ ] **Step 8: Commit**

```bash
git add Sources/SettingsManager.swift Sources/Localization.swift Sources/DashboardWindow.swift Tests/tag-probe-check.sh Tests/run-checks.sh
git commit -m "feat: add the install-channel preference, strings and render decision

SettingsManager.preferredDshTag lands here rather than in the panel task:
tagRowPresentation below reads it to pick the popup's initial selection, so
Task 4 could not compile without it.

tagRowPresentation is pure so the truth table in tag-probe-check.sh can pin
every state the row can be in, including the latest/next same-version case."
```

---

### Task 4: The panel row and the wire-up

**Files:**
- Modify: `Sources/DashboardWindow.swift:30` (`naturalContentHeight`), `:213` (`cardIsNaturalHeight`), properties near `:55-61`, `makePreferencesCard()` `:556-579` and its constraint block `:691-703`, `updateState(_:)` `:902-915`, `showWindow(_:)` `:159-174`, `rebuildForLanguage()` `:1288-1305`, add `#selector` handlers near `:1007`
- Modify: `CONTRIBUTING.md:61-71`
- Modify: `Tests/run-checks.sh:103` (expected height 538 → 592)

**Interfaces:**
- Consumes: `tagRowPresentation(...) -> TagRowPresentation` and `SettingsManager.preferredDshTag` (Task 3), `TagOption` / `ProbeState` / `ProbeFailure` / `installCommand(forTag:)` / `validTag(_:)` / `fetchTags(completion:)` / `install(tag:completion:)` / `isInstalling` (Task 2).
- Produces: nothing consumed by later tasks. This is the last task.

- [ ] **Step 1: Update the compatibility surface doc**

In `CONTRIBUTING.md:61-71`, change the UserDefaults line to:

```
UserDefaults keys  = DSH_CustomPort, DSH_GlobalHotKey*, DSH_Language,
                     DSH_AutoRestart, DSH_LaunchAtLogin, DSH_DshTag
```

`DSH_DshTag` joins the list because renaming it silently forgets the user's chosen channel — the same reason the others are there.

- [ ] **Step 2: Add the view properties**

In `Sources/DashboardWindow.swift`, beside `dshInfoLabel` / `dshActionButton` at `:55-56`:

```swift
    private let tagPopup = NSPopUpButton()
    private let tagInstallButton = NSButton()
    /// Last probe result; the row re-renders from it whenever anything changes.
    private var tagProbeState: ProbeState = .idle
    /// The channel currently on disk, resolved from the last successful probe.
    private var installedTagName: String?
    /// Set after a successful install, cleared when the service restarts.
    private var pendingTagRestart = false
```

- [ ] **Step 3: Build the row**

In `makePreferencesCard()`, after the `dshRow` block (`:579`) add `separator7` after `dshRow`, then the tag row. Insert `let separator7 = makeSeparator()` + `card.addSubview(separator7)` after `dshRow`'s construction, then:

```swift
        let tagRow = NSView()
        tagRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tagRow)

        let tagText = makeTextStack(
            title: L(.installChannel),
            description: L(.installChannelDesc)
        )
        tagRow.addSubview(tagText)

        tagPopup.removeAllItems()
        tagPopup.target = self
        tagPopup.action = #selector(didChangeTag)
        tagPopup.controlSize = .small
        tagPopup.translatesAutoresizingMaskIntoConstraints = false
        tagRow.addSubview(tagPopup)

        configureActionButton(tagInstallButton, title: L(.installEllipsis), action: #selector(didClickInstallTag))
        tagInstallButton.controlSize = .small
        tagRow.addSubview(tagInstallButton)
```

and add to the constraint block at `:691-703`, replacing the `dshRow.bottomAnchor` constraint there (it becomes the tag row's bottom) with:

```swift
            dshRow.topAnchor.constraint(equalTo: separator6.bottomAnchor),
            dshRow.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            dshRow.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            dshRow.heightAnchor.constraint(equalToConstant: 54),

            separator7.topAnchor.constraint(equalTo: dshRow.bottomAnchor),
            separator7.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            separator7.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            separator7.heightAnchor.constraint(equalToConstant: 1),

            tagRow.topAnchor.constraint(equalTo: separator7.bottomAnchor),
            tagRow.leadingAnchor.constraint(equalTo: portRow.leadingAnchor),
            tagRow.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            tagRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),

            tagText.leadingAnchor.constraint(equalTo: tagRow.leadingAnchor),
            tagText.centerYAnchor.constraint(equalTo: tagRow.centerYAnchor),
            tagText.trailingAnchor.constraint(lessThanOrEqualTo: tagPopup.leadingAnchor, constant: -12),
            tagPopup.trailingAnchor.constraint(equalTo: tagInstallButton.leadingAnchor, constant: -8),
            tagPopup.centerYAnchor.constraint(equalTo: tagRow.centerYAnchor),
            tagPopup.widthAnchor.constraint(equalToConstant: 210),
            tagPopup.heightAnchor.constraint(equalToConstant: 20),

            tagInstallButton.trailingAnchor.constraint(equalTo: tagRow.trailingAnchor),
            tagInstallButton.centerYAnchor.constraint(equalTo: tagRow.centerYAnchor),
            tagInstallButton.widthAnchor.constraint(equalToConstant: 84),
            tagInstallButton.heightAnchor.constraint(equalToConstant: 26)
```

**Two geometry corrections, both measured, not derived.** An earlier draft of this step stacked the Install button BELOW the popup and pinned the popup at 148pt. Both are wrong, and both were caught by driving the real `DashboardWindowController` through a layout harness rather than by reasoning about the constraint algebra.

**1. The stacked layout puts the button outside the card.** With the popup `centerY`-anchored in the 51pt slack row and the button 4pt below the popup, the measured frames are popup `y = 15.5 .. 35.5` and button `y = -12.5 .. 11.5`. The row is unflipped, so a negative y is *below* its bottom edge; in card coordinates the button lands at `y = -4.5 .. 19.5` in a 486pt card whose bottom 8pt is padding — the button hangs 4.5pt past the card's bottom edge. Nothing reports this as a failure: every constraint is satisfied at `.defaultHigh` or lower, so the button is simply drawn outside its container.

**2. A 148pt popup truncates every installed marker.** These are not the short language names `languageRow` carries. Measured `fittingSize.width` of a small `NSPopUpButton` per title:

| title | width |
| :--- | --- |
| `latest` | 74 |
| `alpha` | 73 |
| `0.1.7-alpha.2` | 117 |
| `latest (0.2.0-rc.2, installed)` | **204** |
| `latest（0.2.0-rc.2，已安装）` | 200 |

So the popup needs ~210pt for the widest localized title, not 148. Chinese is *narrower* here (200 vs 204) because full-width parentheses and three CJK glyphs cost less than the English words.

**The corrected layout is side by side**, which is also what every other two-control row in this card does (`portRow`: field + reset; `shortcutRow`: button + reset). Measured with the constraints above on the real card at H=592:

```
tagRow h = 51.0
text   x =   16.0 ..  107.5   (fittingSize.width = 91.5)
popup  x =  141.0 ..  351.0   (w = 210)
button x =  359.0 ..  443.0   (w =  84)
```

Text is clear of the popup with 49.5pt to spare, both controls sit inside the row, and neither overlaps the other. The button is 26pt tall to match `dshActionButton` rather than a small control's natural 20pt, so it reads as the row's primary action beside the picker.

**Why `tagRow` still gets no explicit height:** it is the slack-absorbing bottom row, exactly like `dshRow` was before, and it needs that more than ever — 51pt to hold a 20pt popup with room around it. `dshRow` gains an explicit `54` so the slack does not land on it. Do not add a height to `tagRow`.

- [ ] **Step 4: Update the two height constants and the check that pins them**

Three edits that must land together:

1. `Sources/DashboardWindow.swift:30` → `private static let naturalContentHeight: CGFloat = 592`
2. `Sources/DashboardWindow.swift:213` → `.constraint(equalToConstant: 486)`
3. `Tests/run-checks.sh:103` → `grep -q "private static let naturalContentHeight: CGFloat = 592"`

Also update the two comments that quote the old numbers: `:194` ("fixed 432pt stack" → "fixed 486pt stack") and `:28` ("no longer contributes its full 432pt" → "486pt").

**The arithmetic, measured rather than derived.** An earlier draft of this plan claimed the two constants move together because the card grew by 54. **That is false**, and it was measured to be false rather than argued: a harness driving the real `DashboardWindowController` and forcing `layoutSubtreeIfNeeded()` shows

```
scroll slice = min(windowContentHeight - 358, cardHeight)
card height  = its own constant, independent of the window height
```

Today the card is 432 at every window size from 538 (minimum) upward; the slice is what grows, from 180 to 432 and then stops. `naturalContentHeight = 538` is 358pt of chrome (34 + 72 + 14 + 160 + 14 above, 14 + 32 + 18 below) **plus the scroll view's own 180pt floor** at `Sources/DashboardWindow.swift:232` — it is not the card height, and the comment at `:26-30` already says so ("The preferences card is inside a scroll view and no longer contributes its full 432pt to that sum").

So the two edits are not the same kind of edit:

- **`cardIsNaturalHeight` 432 → 486 is load-bearing.** The fixed parts become 382 + `dshRow` 54 + `separator7` 1 = 437, so leaving the card at 432 underflows by 5pt and the constraint set conflicts. 486 gives `tagRow` 49pt of slack, matching the 50pt slack row it replaces. An exact-fit 437 also resolves, but leaves the bottom row unpadded unlike every other row, so 486 is kept.
- **`naturalContentHeight` 538 → 592 is cosmetic.** It shows 54 more points of rows at the floor (slice 180 → 234). Worth having, but nothing depends on it. Reverting it later would not clip anything — the card scrolls either way.

Measured with both edits applied: at H=592 the card is 486 and the slice 234, with no negative row heights and no dropped constraints. The new row is reachable by scrolling; it is not visible at the window's minimum size, and neither is the existing `dshRow` it replaces.

**Check 6 inherits a wrong premise.** `Tests/run-checks.sh:97-107` says the window's minimum size "must be the height they add up to". That was already untrue before this feature. It greps three literals, so it will still pass after the bump, but it does not verify what its comment claims. Do not propagate the "both move by the same 54" reasoning into the check's comment — update the check's comment instead, or leave it alone and note the gap.

Concretely, in Task 4 Step 4 also replace check 6's comment block with a truthful one, leaving its three greps alone:

```bash
# 6. The window's floor and the preferences card's height are separate numbers.
#    The floor is chrome + the scroll view's 180pt minimum; the card keeps its
#    own constant because it lives in the scroll view and grows by scrolling,
#    not by resizing. What this check actually protects is the wiring -- that
#    minSize is derived from the named constant rather than a duplicated
#    literal, and that the card really is the scroll view's document view.
#    NOTE: it does NOT verify that the floor covers the card. It did not before
#    this feature either; the card scrolls when it does not.
```

- [ ] **Step 5: Write the render application**

Add these methods near `didClickDshAction()` at `:1007`:

```swift
    /// Re-render the install-channel row from the current state.
    ///
    /// Every path that can change the row funnels through here: the probe
    /// finishing, the user picking a tag, an install ending, the service
    /// starting or stopping, the panel opening. One apply point means the row
    /// cannot show a stale version next to a fresh popup.
    private func refreshTagRow() {
        let presentation = tagRowPresentation(
            state: tagProbeState,
            installedTag: installedTagName,
            isRunning: ServiceManager.shared.isRunning,
            pendingRestart: pendingTagRestart
        )

        let options = tagProbeState.options()
        tagPopup.removeAllItems()
        for option in options {
            let title = option.isInstalled
                ? L(.tagInstalledSuffix, ["tag": option.tag, "version": option.version])
                : "\(option.tag) — \(option.version)"
            tagPopup.addItem(withTitle: title)
            tagPopup.lastItem?.representedObject = option.tag
        }
        if let preferred = SettingsManager.shared.preferredDshTag,
           let index = options.firstIndex(where: { $0.tag == preferred }) {
            tagPopup.selectItem(at: index)
        }
        tagPopup.isEnabled = presentation.popupEnabled

        tagInstallButton.title = presentation.installButtonTitle
        tagInstallButton.isEnabled = presentation.installButtonEnabled

        // The whole point of installing while the service runs is that the change
        // does not take effect by itself. Say so, in the row the user is already
        // looking at, rather than only on the channel row below it.
        dshInfoLabel.textColor = pendingTagRestart ? .systemOrange : .secondaryLabelColor

        applyTagDescription(presentation.description)
    }

    /// Point the channel row's description label at the presentation's text.
    ///
    /// The row is built by `makeTextStack(title:description:)`, which returns an
    /// `NSStackView` whose `views` are [title, description] — so the label to
    /// update is the stack's last subview. Re-fetching it each time avoids
    /// holding a second reference to a view `setupUI()` rebuilds on every
    /// language change.
    private func applyTagDescription(_ text: String) {
        guard let row = tagPopup.superview,
              let stack = row.subviews.compactMap({ $0 as? NSStackView }).first,
              let descriptionLabel = stack.views.last as? NSTextField
        else { return }
        descriptionLabel.stringValue = text
    }
```

`presentation.popupTitle` is deliberately not applied here: `refreshTagRow` rebuilds the popup's items from `options` and re-selects the preferred tag itself, which keeps the item list and the selection in one place instead of splitting the two.

Then, replace the dsh row block in `updateState(_:)` (`:902-915`) so the dsh label's colour is left to `refreshTagRow()`:

```swift
        if !ServiceManager.shared.dshDetectionComplete {
            dshInfoLabel.stringValue = L(.searchingPath)
            dshActionButton.title = L(.checkingEllipsis)
            dshActionButton.isEnabled = false
        } else if let path = snapshot.dshPath {
            let version = snapshot.dshVersion.map { " • \($0)" } ?? ""
            dshInfoLabel.stringValue = L(.installedAt, ["path": path, "version": version])
            dshActionButton.title = L(.recheck)
            dshActionButton.isEnabled = true
        } else {
            dshInfoLabel.stringValue = L(.notFoundInstallNpm)
            dshActionButton.title = L(.installEllipsis)
            dshActionButton.isEnabled = true
        }

        refreshTagRow()
```

Note `updateState` is called on every 2-second status tick. `refreshTagRow()` rebuilds the popup each time — cheap (three items) and it is what keeps the row correct when `isInstalling` flips without any other event.

- [ ] **Step 6: Add the handlers**

```swift
    @objc private func didChangeTag() {
        guard let tag = tagPopup.selectedItem?.representedObject as? String,
              DshVersionController.validTag(tag) else { return }
        SettingsManager.shared.preferredDshTag = tag
        refreshTagRow()
    }

    /// Confirm, run, report. Nothing here restarts the service or rolls back on
    /// failure — see the spec's "明确不做的事".
    @objc private func didClickInstallTag() {
        guard let tag = tagPopup.selectedItem?.representedObject as? String,
              DshVersionController.validTag(tag),
              let command = DshVersionController.installCommand(forTag: tag) else { return }
        guard !DshVersionController.shared.isInstalling else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L(.installConfirmTitle)
        // The command is shown verbatim so the user approves the exact thing
        // that will run, global-prefix permissions included.
        alert.informativeText = L(.installConfirmBody, ["command": command])
        alert.alertStyle = .warning
        alert.addButton(withTitle: L(.installEllipsis))
        alert.addButton(withTitle: L(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SettingsManager.shared.preferredDshTag = tag
        tagInstallButton.isEnabled = false
        DshVersionController.shared.install(tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Re-probe rather than assume: npm can exit 0 having changed
                // nothing, and the honest answer is the one the binary reports.
                self.pendingTagRestart = true
                ServiceManager.shared.detectDshInstallation()
                self.refreshTagRow()
            case .failure(let error):
                self.showAlert(
                    title: L(.installFailedTitle),
                    message: error.localizedDescription
                )
                self.refreshTagRow()
            }
        }
    }
```

- [ ] **Step 7: Add the probe kickoff**

In `showWindow(_:)` (`:159-174`), after the existing `ServiceManager.shared.detectDshInstallation()` at `:168`:

```swift
        loadTagOptions()
```

and add the method:

```swift
    /// Fetch the dist-tags and resolve which channel is on disk.
    ///
    /// Runs on every panel open, like the binary check next to it: tags move
    /// between launches and the user's dsh can be upgraded by something else
    /// entirely (nvm, brew, another terminal).
    private func loadTagOptions() {
        // A panel opened twice while a probe is in flight must not stack two
        // requests. Nothing else blocks the retry: after a failure the state is
        // `.failed`, not `.loading`, so the next open probes again.
        guard !tagProbeState.isLoading else { return }
        tagProbeState = .loading
        refreshTagRow()
        DshVersionController.shared.fetchTags { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tags):
                let installed = ServiceManager.shared.snapshot.dshVersion
                self.tagProbeState = .loaded(tags: tags, installedVersion: installed)
                self.installedTagName = self.tagProbeState.installedTag
            case .failure(let reason):
                self.tagProbeState = .failed(reason)
                self.installedTagName = nil
            }
            self.refreshTagRow()
        }
    }
```

The "restart to apply" notice clears when the service actually restarts. Add to `updateState(_:)`'s beginning:

```swift
        if pendingTagRestart, snapshot.phase == .running {
            // A restart puts the newly installed binary in memory; the notice
            // has done its job.
            pendingTagRestart = false
        }
```

Place this **before** `refreshTagRow()` at the end of `updateState`, so the cleared notice is not re-shown on the next tick.

- [ ] **Step 8: Make the language rebuild keep the state**

`rebuildForLanguage()` calls `setupUI()` (`:1295`), which rebuilds the popup with no items. Add after the existing `self.portField.stringValue` line at `:1300`:

```swift
            self.loadTagOptions()
            self.refreshTagRow()
```

`refreshTagRow()` re-fills the popup from `tagProbeState`, so the selection survives a language switch; `loadTagOptions()` is the fresh fetch. Order matters: `loadTagOptions` sets `.loading` and calls `refreshTagRow()` itself.

- [ ] **Step 9: Verify the build and the gate**

Run: `ARCHS=arm64 ./build.sh && make check`
Expected: build succeeds; `make check` reports every check `ok`, including check 6 with the new 592 and check 7 and 8 now both passing.

If check 6 still fails, the sed for `naturalContentHeight` did not land — grep it directly:

```bash
grep -n "naturalContentHeight: CGFloat" Sources/DashboardWindow.swift Tests/run-checks.sh
```

- [ ] **Step 10: Commit**

```bash
git add Sources/DashboardWindow.swift Sources/SettingsManager.swift CONTRIBUTING.md Tests/run-checks.sh
git commit -m "feat: add the install-channel row to the preferences panel

Fixed-height rows grew by one, so naturalContentHeight moves 538 -> 592 and
cardIsNaturalHeight 432 -> 486; run-checks.sh's height assertion moves with
them. The stored tag is read to seed the popup and never acted on."
```

---

## Self-Review

**1. Spec coverage.** Every section of the spec maps to a task:

| Spec section | Task |
| :--- | :--- |
| 目标 / 背景 | Task 4 (the row), Task 2 (the probe) |
| 决策 1-5 (the five locked decisions) | Global Constraints, each with the task that enforces it |
| 明确不做的事 (5 bullets) | Global Constraints — untagged `installCommand`, no restart, no full packument, no semver box, no rollback |
| 数据流 · 探测 | Task 2 Step 5, Task 4 Step 7 |
| 数据流 · 安装 | Task 2 Step 6, Task 4 Step 6 |
| 组件 table (6 rows) | Task 2 (`DshVersionController`), Task 3 Step 1 (`SettingsManager`), Task 4 (`DashboardWindow`), Task 3 Step 2 (`Localization`), Task 4 Step 1 (`CONTRIBUTING.md`), Task 3 Step 6 (`run-checks.sh`) |
| `DshVersionController` two methods | Task 2 Interfaces, Steps 5-6 |
| 并发保护 (one npm at a time) | Global Constraints, Task 2 Step 6 (`installInFlight`), Task 4 Step 6's `isInstalling` guard |
| `preferredDshTag` 语义 | Task 3 Step 1, Global Constraints |
| UI (5 bullets: dropdown, Install button, running service, loading, failure) | Task 3 Step 5, Task 4 Steps 3/5/7, Review Focus #2-#4 |
| 面板高度 (432→486, 538→592) | Task 4 Step 4 |
| 安全与失败约束 (4 bullets) | Global Constraints; PATH via Task 1, timeout in Task 2 Step 5, command shown in Task 4 Step 6 |
| 测试 (key alignment, height tripwire, grep assertion) | Task 3 Steps 2/7, Task 4 Step 4, Tasks 1 and 3 (check 7) |
| 风险 table (4 rows) | Global Constraints (EACCES verbatim via Task 2 Step 6, no rollback), Task 4 Step 6 (`couldNotStartService` path untouched), Task 2 Step 5 + Task 3 Step 5 (probe failure), Review Focus #3 |

No gaps.

**2. Step scan.** Four inconsistencies were found and fixed in place rather than left as contradictions:

- `loadTagOptions()`'s guard was first written as `guard tagProbeState.failure == nil || !tagProbeState.isLoading`, which would block retrying after a failure. It is now `guard !tagProbeState.isLoading else { return }` (Task 4 Step 7), with the reason stated in the code comment.
- Task 3 Step 7's `make check` expectation first said check 6 would fail; it cannot, because Task 4 has not run at that point. It now says check 6 passes now and fails only after Task 4 — which is what makes it a tripwire.
- Task 3 had two `Step 3`s — the test and its "watch it fail" run. Steps 4-8 were renumbered and every cross-reference repointed.
- `tagInfoLabel` appeared as a property in Task 4 Step 2 and as a view in `refreshTagRow()`, but the description text lives in the `NSStackView` that `makeTextStack` builds. The property is gone and `applyTagDescription(_:)` reaches the label through that stack; `refreshTagRow` also no longer applies `presentation.popupTitle`, because it re-selects from `options` directly and two places writing the selection is how they drift.

The "**Note on the naming decision:**" block in Task 2 no longer leaves a choice open: shape (B), flat file-scope types, was chosen and committed in `3f6b200`, so Tasks 3-4 compile against one shape rather than two.

**2b. The test harness was wrong, not just the plan.** Task 2's check was specified with `assert()` compiled at `-O`. On this toolchain `assert(1 == 2)` exits 0 under `-O` and traps under `-Onone` (verified directly). The plan's test therefore **could not fail**: three mutations — loosening the allowlist to `^[^ ]+$`, dropping `@\(tag)` from the command, replacing the allowlist guard with `!tag.isEmpty` — all printed `PASS`. The committed `Tests/tag-probe-check.sh` uses an always-on `expect(_:_:)` helper instead, keeping the plan's assertion expressions and failure strings verbatim; the same three mutations now fail (`FAIL: hostile tag accepted: "@next"`, `FAIL: latest produced the wrong command`) and the restored source passes. **Task 3 must use `expect`, not `assert`,** in the render truth table.

**2c. Two compile defects in Task 2's own code blocks.** `static func` is illegal at top level in `main.swift`, so the extracted members are wrapped in a namespace type and forwarded under their file-scope names; and `validTag` must be extracted alongside `installCommand`, since the latter calls it. Both are handled in the committed script.

**2e. A geometry claim in Task 4 was false, and measurement is what caught it.** The plan asserted that `naturalContentHeight` (538 → 592) and `cardIsNaturalHeight` (432 → 486) must move together because the card grew 54. They were never coupled: driving the real `DashboardWindowController` through a layout harness shows `scroll slice = min(H - 358, cardHeight)`, with the card height independent of the window. 538 is chrome plus the scroll view's own 180pt floor, exactly as the comment at `Sources/DashboardWindow.swift:26-30` says. Only the card constant is load-bearing — at 432 the new row underflows by 5pt. Task 4 Step 4 now carries the measured relationship, says which edit matters, and replaces check 6's comment, whose stated premise ("the window's minimum size must be the height they add up to") was already false before this feature.

**2d. Pre-existing defect found outside this feature's scope.** `Tests/probe-gate-check.sh` — the precedent every check here follows — builds with `swiftc -O` and asserts with `assert()`, so it is currently **vacuous**: its sockets and timing run, but no assertion is ever evaluated. This predates the tag selector and is not touched by Tasks 1-4. It is worth a follow-up, because a passing `probe-gate-check` line in `make check` currently means nothing.

**3. Type consistency.** `tagRowPresentation(state:installedTag:isRunning:pendingRestart:)` is written identically in Task 3 Step 3's test, Task 3 Step 5's implementation, and Task 4 Step 5's call site. `TagOption` / `ProbeState` / `ProbeFailure` / `installCommand(forTag:)` / `validTag(_:)` are defined in Task 2 and used under those names in Tasks 3 and 4. `DshVersionControllerError.installFailed(exitCode:output:)` is constructed with two labels and matched with `let exitCode, let output`.

One ordering bug was found and fixed: Task 3 Step 5's `tagRowPresentation` reads `SettingsManager.shared.preferredDshTag`, but the property was scheduled for Task 4 — Task 3 would not have compiled. `preferredDshTag` (plus its `keyPreferredDshTag` constant) moved to Task 3 Step 1, with a note explaining why it lives with the render logic. Task 3's step list was renumbered after a duplicate Step 3 turned up; Task 4's doc edit was promoted to Step 1; `tagInfoLabel` was removed from its property list in the same pass.

**4. Review Focus.** All five have a pinned test: #1 → Task 2 Step 1's hostile-tag asserts; #2 → same; #3 → Task 3 Step 3's `installedCount == 2` and `nextTag?.isInstalled == true`; #4 → Task 2 Step 5's status/JSON guards plus Task 3 Step 3's `failed` asserts; #5 → Task 3 Step 1's `validTag` guard on the getter.

**5. Proportion.** The spec is 168 lines; the plan is roughly 7× that. The multiplier is mostly data, not transcription: the 17 localized strings × 2 languages, the literal constraint blocks for the new row, and the test bodies for two truth tables. Logic appears as a signature plus a statement of what each guard rejects and why. The two longest code blocks — the `URLSession` probe in Task 2 Step 5 and the `Process` install in Task 2 Step 6 — are the parts where the *order* of operations is the decision (validate before spawn, read the pipe before `waitUntilExit` can deadlock, reset the in-flight flag on the main thread), so those are given as bodies. Everything else the implementer writes.

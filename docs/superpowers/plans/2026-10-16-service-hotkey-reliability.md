# Service Restart and Hotkey Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Fix intermittent managed-service restart refusal and make global shortcut failures visible and recoverable after wake/session activation.

**Architecture:** Keep Swift/AppKit/Carbon and the existing shutdown script. Correct decimal parsing without weakening process identity checks. Preserve desired shortcut configurations separately from live references, propagate handler-installation errors, and retry after wake/session activation.

**Tech Stack:** Swift, AppKit, Carbon, Bash 3.2, Python 3 regression harnesses, macOS 13+.

**Spec:** Small-change description below and the current conversation; the user approved implementation and validation in this session.

## Global Constraints

- macOS 13+; no new dependencies.
- Preserve bundle identifier, UserDefaults keys and `~/.dsh/dsh-bar-service.json` format.
- Keep PID, listening-port and process-start fingerprint checks before sending signals.
- Tests must isolate process signals and filesystem effects; do not stop real user services.
- Preserve user changes to `.github/workflows/release.yml`, `README.md`, and `Tests/sparkle-check.sh`.
- No ServiceManager restructuring or changes to external-service confirmation behavior.
- Update both localization tables if user-facing text changes.

## Review Focus

- Zero-padded 08/09 in seconds, minutes, hours and day-prefixed durations must parse as decimal.
- Missing/malformed elapsed time must refuse termination and preserve the PID file.
- A reused PID or different listener must remain untouched.
- Handler installation failure must remain visible and retryable.
- Repeated recovery must not duplicate handlers/registrations or resurrect explicitly removed shortcuts.

---

## Small-change description for approval

**Confirmed restart cause:** Production `etime_seconds()` fails on `00:08`, `00:09`, and `01:08:09` with `value too great for base`. Bash treats leading zeros as octal. Empty conversion produces `UNVERIFIED-PID`; if the Swift probe recognizes the same managed process, restart displays `Failed to stop the existing service.` Explicit decimal conversion has been verified in memory against zero-padded and multi-day values.

**Confirmed shortcut defect:** `setupEventHandlerIfNeeded()` does not propagate failure. `register` may report success after Carbon key registration even when its event handler was never installed. Return the installation error and retain the desired registration for recovery.

**Proposed recovery:** Re-register desired shortcuts on `NSWorkspace.didWakeNotification` and `NSWorkspace.sessionDidBecomeActiveNotification`. Keep observer setup/cleanup idempotent and avoid repeated modal alerts or polling. This is resilience work; wake/session transition has not been established as the user's actual failure trigger. Preserve the current shortcut action: open Web when running, otherwise start then open Web.

### Task 1: Decimal managed-stop parsing

**Files:** Modify `Sources/ServiceManager.swift` (`stopScript`, currently lines 1442–1517); create `Tests/service-stop-check.py`; modify `Tests/run-checks.sh`.

**Interfaces:** Preserve `private func runStopScript(port: Int) -> StopResult` and Bash `etime_seconds()`. Valid `MM:SS`, `HH:MM:SS`, and `D-HH:MM:SS` produce decimal seconds; invalid input returns empty and preserves refusal behavior.

- [x] **Step 1:** Create a harness extracting the actual script, with mock shell functions for process observations, signals, sleeping and PID-file removal. Assert valid identities with `00:08`, `00:09`, `08:00`, `09:00`, `08:00:00`, `09:00:00`, `8-08:09:08`, and `09-00:00:08` reach `STOPPED` and signal only the fixture PID. Ordinary zero/nonzero controls also pass. Missing/malformed elapsed time and reused PID must never signal or remove identity. A foreign listener must never receive a termination signal; retain the existing stale-PID-file cleanup behavior.
- [x] **Step 2:** Run `python3 Tests/service-stop-check.py`; verify zero-padded cases fail on current code.
- [x] **Step 3:** Validate nonempty numeric components and supported field structure, then use explicit decimal arithmetic (`10#`) for every component. Retain all ownership checks.
- [x] **Step 4:** Rerun the harness; all cases pass. Wire it into `Tests/run-checks.sh` using existing pass/fail conventions.

### Task 2: Truthful shortcut status and recovery

**Files:** Modify `Sources/HotKeyManager.swift`, `Sources/AppDelegate.swift`, and the diagnostics wording in `Sources/ServiceManager.swift` if necessary; create `Tests/hotkey-recovery-check.py`; modify `Tests/run-checks.sh`.

**Interfaces:**
- Preserve `func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping HotKeyAction)` and `func unregister(id: UInt32)`.
- Change `private func setupEventHandlerIfNeeded() -> OSStatus` to propagate installation results.
- Add `func recoverRegistrations()` to retry a snapshot of desired key codes, modifiers and actions.
- Add `func startRecoveryMonitoring()` and `func stopRecoveryMonitoring()` for workspace observer ownership.

- [x] **Step 1:** Extract the actual manager into a Swift test harness with injected Carbon/workspace results. Assert handler failure prevents registration and retains the error; subsequent recovery installs one handler, registers the desired shortcut/action and clears the error. Assert registration conflicts remain retryable; unregister after failure prevents resurrection; repeated recovery leaves one live handler/registration; repeated monitoring start/stop does not leak tokens; both workspace notifications invoke recovery.
- [x] **Step 2:** Run `python3 Tests/hotkey-recovery-check.py`; confirm the current implementation fails expected recovery/status checks.
- [x] **Step 3:** Implement desired-registration storage, the error-returning handler setup and recovery interfaces. Unregister removes desired state even without a live reference. Recovery replaces live references while retaining desired state. Keep state mutation on the main thread and remove observer tokens on stop/deinitialization.
- [x] **Step 4:** Start recovery monitoring after initial shortcut setup in `applicationDidFinishLaunching`; stop monitoring in the final termination reply closure, preserving quit ordering. Use neutral diagnostics wording for errors that are not shortcut conflicts.
- [x] **Step 5:** Run the focused harness; all cases pass. Wire it into `Tests/run-checks.sh`.

### Task 3: Integrated validation and review

- [x] **Step 1:** Run `make check`; investigate failures and distinguish existing failures from regressions.
- [x] **Step 2:** Verify absolute generated-artifact cleanup targets, then run the existing universal build (`make`); arm64 and x86_64 must compile and package.
- [x] **Step 3:** Run `git diff --check`, inspect scoped changes, and have a fresh reviewer check ownership preservation, observer cleanup and registration transitions.
- [x] **Step 4:** Report checks and generated app path. State the limits: controlled notification tests do not prove hours-long live shortcut reliability. Do not install, launch, publish or commit without a separate request.

## Completed validation

- `python3 Tests/service-stop-check.py`: failed before repair (29 failures across nine test methods); passes after repair, including decimal durations, malformed values, ownership drift and verified-only force termination. Process observations and signals are shell-function substitutes.
- `python3 Tests/hotkey-recovery-check.py`: reproduced the hidden handler-installation error before repair; passes afterward, including missing references, retryable conflicts, action delivery and idempotent workspace observers.
- Updated `Tests/service-termination-check.py` to provide the new hotkey dependency and assert cleanup happens once at the final termination reply. Its focused run passes.
- Final `make check`: exit 0. The first full run exposed the missing termination fixture dependency; repaired and reran the complete suite successfully.
- `make`: exit 0; packaged `build/DeepSeek Harness Bar.app`, version 1.0.1, x86_64 and arm64, ad-hoc signed; strict deep signature verification passes. Existing `var lines` never-mutated warning remains.
- Scoped `git diff --check`: passes. The unscoped command reports the existing blank line at EOF in `.github/workflows/release.yml:275`; that user edit was preserved.
- Independent read-only review: no actionable findings.
- No install, launch, commit or publication performed. Controlled tests do not establish the user's precise long-runtime trigger or prove hours-long live shortcut reliability.

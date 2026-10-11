# Sparkle Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the five approved audit findings without changing credentials, domains, the published version or update feed.

**Architecture:** Three independently testable maintenance tasks use existing Bash/Swift/AppKit patterns. Release notes stay conditional on actual signing; the updater uses Sparkle's availability flag. A small main-queue lifecycle-idle gate coordinates ordinary termination and Sparkle relaunch without stopping healthy services.

**Tech Stack:** Swift, AppKit, Foundation, vendored Sparkle 2.10.0, Bash 3.2, Python 3 standard library, existing swiftc build/check scripts.

**Spec:** `docs/superpowers/specs/2026-10-11-sparkle-review-fixes-design.md`

## Global Constraints

- macOS 13.0; arm64 + x86_64; Bash 3.2; no new dependencies or build-system migration.
- Version/build stay 1.0.1. Preserve SUFeedURL, SUPublicEDKey, daily checks and user-confirmed installation.
- Preserve dashboard floor 592 and minimum width 540; preference toggles write only on user action.
- Do not remove the currently accurate unnotarized warning or alter Apple/GitHub credentials.
- Use isolated temporary fixtures, not real services, npm operations, account changes or installation tests.
- Do not push, re-tag or republish as part of these repairs. Local commits only, after green checks.

## Review Focus

1. Existing-release reruns and failed uploads must not leave a false signing assurance (Task 1).
2. A signed local build is not notarized; docs must distinguish both paths and acknowledge Sparkle (Task 1).
3. `canCheckForUpdates == false` rejects checking; true may refocus interactive UI rather than mean no session exists (Task 2).
4. Quit/update during successful or failed launch/restart must wait until identity save/cleanup completes (Task 3).
5. Repeated quit requests, reentrant lifecycle changes and omitted Sparkle delegate callbacks must not duplicate replies or strand waiting actions (Task 3).

---

## File responsibilities

- `.github/workflows/release.yml`: refresh existing-release notes only after successful uploads.
- `README.md`, `CONTRIBUTING.md`: accurate signing/notarization/dependency guidance.
- `Sources/UpdateManager.swift`: shared availability guard and Sparkle postponement delegate.
- `Sources/DashboardWindow.swift`: initial and refreshed Check Now enabled state.
- `Sources/ServiceManager.swift`: main-queue lifecycle-idle action scheduling.
- `Sources/AppDelegate.swift`: one deferred application-termination reply, preserving ordinary versus stop-service intent.
- `Tests/sparkle-check.sh`: real extracted release-step branch probes and documentation checks.
- `Tests/update-availability-check.py`: production action extraction with controlled availability/controller calls.
- `Tests/service-termination-check.py`: production idle-gate and delegate extraction with controlled lifecycle and termination stubs.
- `Tests/run-checks.sh`: register new probes using the existing accumulated-failure convention.

### Task 1: Release notes and truthful documentation

**Files:** Modify `.github/workflows/release.yml:260-280`, `Tests/sparkle-check.sh:232-307`, `README.md:18,39-55,120-148`, `CONTRIBUTING.md:3-4,102`.

**Interfaces:** Consumes existing `Create or update GitHub Release` run block, `TAG`, `ZIP_NAME`, `dist/release-notes.md`. Produces refreshed existing-release body; no new runtime API.

- [ ] Write failing existing-release tests in the real extracted-step stub harness. `release view` succeeds in existing mode; assert upload then edit with `--notes-file dist/release-notes.md`. Failed-upload mode returns nonzero and must record no edit. Keep stable/prerelease creation tests.
- [ ] Add document assertions rejecting unconditional no-Apple-signing and no-third-party-dependencies claims, while retaining conditional unsigned troubleshooting.
- [ ] Run `./Tests/sparkle-check.sh`; verify new assertions fail against the original branch/docs.
- [ ] After successful existing-release upload, run `gh release edit "$TAG" --notes-file dist/release-notes.md`. Keep `set -euo pipefail`, the current unsigned warning and current create branch.
- [ ] Describe native Swift/AppKit with vendored Sparkle; limit xattr guidance to explicitly unsigned/unnotarized releases or local default builds, based on actual release notes. Explain that `SIGNING_IDENTITY` alone performs signing, not notarization/stapling.
- [ ] Run `./Tests/sparkle-check.sh`, `/bin/bash -n Tests/sparkle-check.sh`, `git diff --check`; all pass. Parse workflow YAML using available tooling without adding a dependency to checks.
- [ ] Commit only Task 1 files: `fix: synchronize release notes and signing documentation`.

### Task 2: Update availability

**Files:** Modify `Sources/UpdateManager.swift:30-48`, `Sources/DashboardWindow.swift:753-755,1057-1152`, `Tests/run-checks.sh`; create `Tests/update-availability-check.py`; preserve `Tests/sparkle-api-check.sh` actual framework typecheck.

**Interfaces:** Consumes `var canCheckForUpdates: Bool` and `@objc func checkForUpdates(_ sender: Any?)`; preserves both signatures. Dashboard consumes the same flag, never sessionInProgress.

- [ ] Write a source-extraction Swift harness in the Python probe: extract the real `checkForUpdates` body; stub the controller and availability; unavailable produces zero calls, available produces exactly one call with the original sender. Assert initial and existing `updateState()` refresh set `updateCheckButton.isEnabled` from the same flag, and the single preference-write invariant remains true.
- [ ] Run `python3 Tests/update-availability-check.py`; verify failure before implementation.
- [ ] Guard the shared action with `canCheckForUpdates`; set the Dashboard button's enabled state in row construction and the existing UI refresh path. Do not add another timer or defaults key.
- [ ] Register the Python probe in `Tests/run-checks.sh` using existing pass/fail accumulation.
- [ ] Run `python3 Tests/update-availability-check.py` and `./Tests/sparkle-api-check.sh`; pass the behavioral probe and real Sparkle API typecheck.
- [ ] Commit Task 2 files: `fix: respect Sparkle update availability in preferences`.

### Task 3: Lifecycle-aware quit and update relaunch

**Files:** Modify `Sources/ServiceManager.swift:53-69,190-207,1636-1655`, `Sources/AppDelegate.swift:20-22,80-93`, `Sources/UpdateManager.swift:14-27`, `Tests/run-checks.sh`; create `Tests/service-termination-check.py`.

**Interfaces:** Produce `func performWhenLifecycleIdle(_ action: @escaping () -> Void)` and private `func scheduleLifecycleIdleActions()` in ServiceManager. Consume `snapshot.phase.isBusy`, existing `prepareForTermination()`, `stopServiceForQuit(completion: @escaping (Bool, String?) -> Void)` and the framework delegate hook. Preserve existing launch/stop/restart public APIs.

- [ ] Write source-extracted tests with temporary fixtures and no real processes. Cover immediate idle (asynchronous callback), starting/stopping/restarting delays, saved identity before successful callback, cleanup before failed callback, an operation that becomes busy again before the drain runs, and multiple actions where the first action starts another operation. Each action must run exactly once, FIFO when idle.
- [ ] Test extracted AppDelegate termination behavior with controlled service/NSApplication stubs: ordinary quit and update preserve healthy service; Quit & Stop waits for launch completion then stops once; repeated termination requests produce one pending reply; failure releases termination too. Existing successful process-start/identity-save order must be checked from production source, not invented in a copied implementation.
- [ ] Test the relaunch-postponement callback: idle returns false without invoking installHandler; busy returns true and invokes it once after settling. Verify actual Sparkle delegate method signature via real framework typecheck/build.
- [ ] Run `python3 Tests/service-termination-check.py`; confirm red before implementing the new helper/integration.
- [ ] Implement main-queue pending actions and one scheduled-drain flag. Append in `performWhenLifecycleIdle`; schedule only when idle; dispatched drain rechecks phase, removes an action before invoking it, and stops if that action starts another busy lifecycle. Schedule after existing snapshot observers complete. Keep managed-record save before publishing the running snapshot.
- [ ] In AppDelegate, use one outstanding termination-request guard and `.terminateLater`; schedule existing prepare/stop semantics through the idle helper and reply once on completion. Consume the original `pendingQuitStopsService` intent once; do not stop healthy services on ordinary quit/update.
- [ ] Make UpdateManager conform to `SPUUpdaterDelegate`; use `private(set) lazy var controller: SPUStandardUpdaterController` initialized with `startingUpdater: true`, `updaterDelegate: self`, `userDriverDelegate: nil`. Implement the real imported `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:) -> Bool` hook using the idle helper when phase is busy. Retain AppDelegate as fallback because this hook is not always called.
- [ ] Register the new probe. Run `python3 Tests/service-termination-check.py`, `python3 Tests/service-identity-check.py`, `./Tests/sparkle-api-check.sh`, `./build.sh`, `./Tests/run-checks.sh`; all exit 0, universal 1.0.1 build remains ad-hoc absent configured identity.
- [ ] Commit Task 3 files: `fix: defer termination until service lifecycle settles`.

## Final review and delivery

- [ ] Run `./build.sh`, `./Tests/run-checks.sh`, `git diff --check`; verify bundled version/feed/key unchanged.
- [ ] Obtain a fresh read-only review of the complete repair diff and tests, focusing on callback reentrancy, actor isolation and accurate signing assertions. Fix concrete findings and rerun affected checks.
- [ ] Report local commits, test results and remaining real-install/visual verification limitations. Do not claim Apple notarization or a two-version upgrade test.

## Self-review

All five findings map to Tasks 1–3; all five Review Focus cases have owning regression tests. Helper/action signatures and existing constants are consistent across tasks. No step requires credentials, service operations, publishing or a new dependency. The existing .terminateLater pattern and snapshot update mechanism are reused; the idle helper is the only new lifecycle interface. Execution method remains Native as previously selected; plan review is required before implementation.

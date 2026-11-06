# Environment Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add actionable local environment diagnostics and accurately distinguish installed CLI and running service versions.

**Architecture:** Keep lifecycle ownership in ServiceManager, with an optional version added to its existing persisted record. A small environment inspection value type reuses InstallProcess, and a reusable native diagnostics window renders the existing export plus localized findings.

**Tech Stack:** Swift, AppKit, Foundation, existing Python/Swift check harnesses.

**Spec:** [Approved scope](../specs/2026-11-06-environment-diagnostics-design.md)

**Execution:** Implemented natively in this session under the user's instruction to start, with one delegate limited to the identity test fixture and read-only correctness review. Changes remain available for review without publishing or restarting the user's application. The template's additional execution skills were unavailable; native tools were used.

## Global Constraints

- macOS 13+, arm64 and x86_64; no new dependencies or preferences.
- Use `ServiceManager.commandEnvironment()` for all command checks and service launches.
- Each version command has a 3-second cancellation deadline and a 4096-byte output cap.
- Do not source shell profiles, inspect configuration/credentials, install packages, or restart services during inspection.
- Keep English/Chinese copy aligned, exported URLs redacted, legacy records decodable, and ownership checks unchanged.

## Review Focus

- Installed version changes while the same service is running: preserve the captured running version and restart reminder.
- Legacy or external services: show unknown rather than infer a running version from disk.
- PID reuse or missing fingerprints: never expose an unverified managed version; retain recoverable records through uncertainty.
- A noisy, failing, or hanging executable: bound retained output and completion time without blocking AppKit.
- Repeated inspection or language changes: publish current results, reuse one window, and keep controls readable at minimum width.

---

### Task 1: Preserve the running service version

**Files:** Modify `Sources/ServiceManager.swift`, `Sources/DashboardWindow.swift`, `Sources/AppDelegate.swift`, `Sources/Localization.swift`, `Tests/dashboard-ui-fixture.py`, and `Tests/service-identity-check.py`.

**Interfaces:** Add `ServiceSnapshot.runningDshVersion: String? = nil`, `ServiceSnapshot.needsVersionRestart: Bool`, and optional `ManagedServiceRecord.dshVersion: String? = nil`. Keep installed `dshVersion` semantics and existing initializer compatibility.

- [x] Extend the real-source identity fixture: assert old JSON decodes with nil version; new JSON round-trips; A-running/B-installed requires restart; equal/unknown/external/stopped versions do not; identity mismatch/conflict/exit clears the published running version; a successful inert launch persists its version.
- [x] Run `python3 Tests/service-identity-check.py` and record the result. Pre-implementation failure was not captured: production changes and the delegated fixture were developed in parallel.
- [x] Capture/persist the version on managed launch, publish only on verified probes, and clear it on other states. Replace UI-local restart tracking with the snapshot comparison; render running and installed versions in their respective locations.
- [x] Update the dashboard fixture and run the identity and tag checks; require PASS.

### Task 2: Inspect the environment and show actionable findings

**Files:** Create `Sources/EnvironmentDiagnostics.swift`, `Sources/DiagnosticsWindow.swift`, and `Tests/environment-diagnostics-check.py`; modify `Sources/ServiceManager.swift`, `Sources/DashboardWindow.swift`, `Sources/Localization.swift`, `Tests/dashboard-ui-fixture.py`, and `build.sh`.

**Interfaces:** `EnvironmentDiagnostics.inspect(environment: [String: String]) -> EnvironmentDiagnostics`, `EnvironmentDiagnostics.findExecutable(named: String, environment: [String: String]) -> String?`, `EnvironmentDiagnostics.version(at: String, environment: [String: String]) -> String?`, `EnvironmentDiagnostics.findings(for: ServiceSnapshot) -> [String]`, and `DiagnosticsWindowController.showDiagnostics()`.

- [x] Add isolated checks using temporary executables for PATH order, valid versions, missing/nonzero/hanging/noisy commands, and localized actionable findings. Assert no real service or shell profile is touched.
- [x] Run `python3 Tests/environment-diagnostics-check.py` and record the result. Production types already existed when this fixture was added, so no pre-implementation failure was captured.
- [x] Implement bounded command inspection through InstallProcess. Integrate results with existing CLI detection and diagnostic export; serialize/coalesce rechecks so an older result cannot overwrite an installation-triggered refresh.
- [x] Add a scrollable, reusable native diagnostics window with recheck/copy/logs/permissions actions, localized titles, status/language observation, and no display activation in its offscreen fixture.
- [x] Run environment and dashboard layout checks; require PASS without conflicting layout constraints.

### Task 3: Complete integration and verify the deliverable

**Files:** Modify `Tests/run-checks.sh`, `Tests/settings-layout-check.py`, and `README.md`; update this plan's checkboxes.

**Interfaces:** `make check` includes the environment check; the existing build lists both new source files.

- [x] Document the diagnostics entry point, limits, version provenance, legacy/external unknown behavior, and restart reminder.
- [x] Run `make check` once; investigate any failures and rerun affected checks after fixes.
- [x] Build both architectures using the repository build script after verifying its absolute build deletion targets; do not run its install mode.
- [x] Inspect offscreen native previews and review `git diff --check` plus the final diff for scope and correctness. Record any limits, and leave the user's running app/service untouched.

## Verification recorded

- `PYTHONDONTWRITEBYTECODE=1 make check`: PASS, including the added environment check and all existing checks.
- Identity regression fixture: 15 PASS groups, including legacy records, unknown/external versions, identity uncertainty, concurrent installation during launch, and both restart preflight refusal paths.
- Environment fixture: PASS for command lookup, valid/nonzero/invalid versions, bounded noisy output, timeout cancellation, bilingual findings, and coalesced detection callbacks.
- Native layout fixture: PASS at compact settings widths and the diagnostics window's minimum width, English/Chinese and light/dark; 28 offscreen PNGs produced. Chinese light and English dark diagnostics previews visually inspected.
- Added dashboard regression: a registry reply preceding command detection and a later disk recheck both refresh the installed channel marker and installation availability.
- `SIGNING_IDENTITY=- bash build.sh`: PASS for arm64 and x86_64, universal binary assembled, ad-hoc signature verified. Artifact: `build/DeepSeek Harness Bar.app`; this implementation build preceded the release version bump and was version 1.0.5.
- `git diff --check`: PASS. Validation used isolated fixtures and offscreen AppKit rendering. The built app was not launched or installed, and the user's service was not restarted.

## Release verification recorded — v1.0.6

- Tag `v1.0.6` points to `7618451f0f85527cd44329012b08b45d3e450d2a`. [CI 42146986120](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/42146986120) passed the universal build and full check set on the supported `macos-15` runner. Both CI and Release were moved from the retired `macos-14` runner; the app still targets macOS 13.0.
- The cloud compiler required an explicit `Data.Index` for the existing UTF-8 log-tail boundary expression. The log regression checks passed. The permissions fixture now waits for the asynchronous language rebuild with a 3-second deadline, and the signing fixture captures its keychain search list using a Bash 3.2-compatible loop. Focused local checks and the complete cloud checks passed.
- [Release workflow 42147480907](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/42147480907) succeeded. [DeepSeek Harness Bar v1.0.6](https://github.com/donald-trump86/dsh-bar-macos/releases/tag/v1.0.6) was published as the latest stable release at `2026-11-06T02:01:13Z`, with the universal ZIP, SHA256 file and signed appcast.
- Downloaded public archive: `DSH-Bar-1.0.6-universal.zip`, 3,804,605 bytes. SHA256: `2c21cd69e4bac5b5fc839974a87fd45ad38ec7ecc0b9e66ecf03ce3bf898500a`; it matches both the published checksum file and the GitHub asset digest. ZIP integrity, bundle version/build `1.0.6`, macOS 13.0 minimum and both `arm64`/`x86_64` slices passed inspection.
- `codesign --verify --deep --strict` passed for the downloaded app. The signer is `DSH Bar Self-Signing`; its leaf certificate SHA1 remains `34959d783d07b4e31befa94f5f5c33f8825ba32e`, matching v1.0.4/v1.0.5. The build is self-signed and not notarized by Apple, as stated in the published installation notes.
- The app's embedded Sparkle public key and feed URL are unchanged. Actual Ed25519 verification of the published ZIP passed against the appcast signature and embedded key. Appcast version, minimum system version, download URL, length and embedded notes passed; the live `releases/latest/download/appcast.xml` exactly matched this release's appcast.
- Verification inspected downloaded public assets without installing or launching the released app, replacing the user's current app, or restarting the user's DSH service.

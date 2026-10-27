# Settings and installation controls implementation plan

> Execution: native implementation with a scoped installer worker and final independent review. The user selected the recommended approach and explicitly opted out of further design questions.

**Goal:** Improve native settings and add working installation cancellation, real main-package download speed and bounded task logs.

**Architecture:** Keep AppKit and the compact single window. Use intrinsic stack-driven Service, Versions & Updates and General groups. Download the principal archive from the official public npm registry, verify published SHA-512 integrity, then invoke detected npm on the verified archive. No new dependencies; macOS 13+.

**Spec:** User-approved proposal in this session, 2026-10-27. Main-package download gets truthful bytes, rate, percentage/ETA when known; dependency phase gets npm status/time/logs. Cancel waits for cleanup and never promises rollback.

## Constraints

- Preserve service actions, port handling, hotkeys, notifications, Sparkle, bilingual text and install confirmation. Do not restart DSH or the host.
- Principal download uses registry.npmjs.org (same as existing tag probe), bypassing npm's root cache/custom registry/auth/proxy/CA settings; document this and name public registry in confirmation. npm retains dependency configuration/environment.
- Never derive MB/s from npm log bytes or invent overall installation percentage.
- Single active run; exactly one main-thread completion; busy clears after cleanup. Distinct cancelled outcome.
- Atomically isolated owned npm process group; one graceful termination, bounded cleanup; no process-name matching or stale delayed signals. Drain 64 KiB diagnostic tail while observing exit independently from EOF.
- Verify archive before npm; remove temporary archive on every outcome. System semantic colors, native controls, readable wrapping labels, accessibility preferences. No remote push/release without final-content confirmation.

## Interfaces

`InstallActivity: Equatable` retains `tag: String`, `startedAt: TimeInterval`, `elapsed(at: TimeInterval) -> String`. Adds nested `Phase` cases `resolving`, `downloading`, `verifying`, `installing`, `cancelling`; mutable `phase`, `bytesReceived: Int64`, `totalBytes: Int64?`, `bytesPerSecond: Double`, `outputTail: String`, `version: String?` with defaults.

Controller retains `install(tag:completion:)`, `installActivity`, `isInstalling`, `validTag`, `installCommand`, `fetchTags`. Adds `cancelInstall()`, `private(set) var lastInstallLog: String`. Error adds `cancelled`, localized by `L(.installCancelled)`.

## Review focus

- Cancellation before spawn/between stages prevents mutation; repeated cancellation and stale callbacks cannot affect later runs.
- Child-held pipe after npm exits cannot deadlock or clear exclusion while an owned installation remains active.
- Unknown total/zero speed/phase transition never implies fake progress or dependency download telemetry.
- Invalid integrity, untrusted tarball or HTTP failure prevents npm invocation and cleans temp files.
- English/Chinese and light/dark layouts remain readable at minimum size; language/hide/reopen do not reset the task.

## Task 1: Installer lifecycle

Files: `Sources/DshVersionController.swift`, optional focused `Sources/InstallProcess.swift`, `build.sh`, `Tests/install-pipe-check.py`, optional focused download fixture.

- [x] Implement agreed snapshot API, retained bounded logs and main-thread terminal outcomes.
- [x] Resolve official tag to pinned version, validate HTTPS tarball and SHA-512, download with real delegate byte/rate data.
- [x] Invoke selected npm/environment on verified archive with owned process-group cancellation, bounded drainage and exit handling.
- [x] Fixture checks: silent/noisy output, exclusion, single callback, cancellation before/after spawn and during stage transition, child-held pipe, malformed output, integrity mismatch, HTTP error, unknown length and archive cleanup. Never call real npm or DSH in fixtures.

## Task 2: Grouped settings and task controls

Files: `Sources/DashboardWindow.swift`, `Sources/Localization.swift`, `Tests/install-progress-check.py`.

- [x] Replace fixed card/row heights with intrinsic grouped stacks and wrapping descriptions.
- [x] Add phase, package bytes/rate/ETA, timer, cancel/cancelling and expandable bounded logs; keep final logs available.
- [x] Verify deterministic render snapshots including unknown length, cancellation, phase change, language and hide/reopen.
- [x] Render actual AppKit views offscreen in compact sizes and both appearances for inspection, without launching another live app/service.

## Task 3: Integration

Files: `README.md`; check runner if a new focused test is added.

- [x] Run focused fixtures, localization/probe checks, relevant existing regression suite and universal build.
- [x] Independent review of cancellation/integrity and UI lifecycle; fix substantive findings.
- [x] Inspect native render, document limitations and deliver local build. Do not publish yet.

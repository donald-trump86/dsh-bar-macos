# npm Install Progress Implementation Plan

> Execute in this session using the existing AppKit controller and fixture tests.

**Goal:** Show an animated progress bar, selected tag and elapsed time during npm tag installation, then publish v1.0.3.

**Architecture:** The install worker owns a tag and monotonic start time until completion. The dashboard renders this state with native AppKit controls and a one-second timer. npm supplies no reliable total percentage, so progress is indeterminate. Existing bounded pipe drainage and error handling remain in use.

**Tech Stack:** Swift, AppKit, Foundation, Python fixture checks, GitHub Actions.

**Spec:** User-approved scope in this session: installation progress feedback and release with a new tag.

## Global Constraints

- macOS 13.0+, universal arm64/x86_64, no new dependencies.
- Preserve service ownership and never restart the running DSH service during checks.
- Keep English and Chinese strings and placeholders aligned.
- Reuse the existing self-signing identity; do not access private certificate files.
- User authorized publishing the feature and new tag; use v1.0.3.

## Review Focus

- Silent or noisy npm output: animate and count elapsed time independently; keep the 64 KiB diagnostic limit.
- Failure to spawn or nonzero exit: clear busy state before completion and restore controls before showing errors.
- Reopen and language change: recover the original tag/start time without restarting installation.
- Concurrent click or registry probe completion: never re-enable the popup or install button during installation.
- Empty registry and invalid tag: retain existing validation and reset state on every outcome.

### Task 1: Install activity and presentation

**Files:** Modify `Sources/DshVersionController.swift`, `Sources/DashboardWindow.swift`, `Sources/Localization.swift`, `Tests/install-pipe-check.py`, `Tests/tag-probe-check.sh`.

**Interfaces:** `InstallActivity(tag: String, startedAt: TimeInterval)` with `elapsed(at: TimeInterval) -> String`; `DshVersionController.installActivity: InstallActivity?`; existing `install(tag:completion:)` and `isInstalling` stay callable.

- [x] Extend the real-worker fixture to assert activity creation and cleanup, validation/exclusion, and a silent delayed process; extend the presentation truth table with installation precedence and elapsed formatting.
- [x] Implement activity state, busy presentation and bilingual copy.
- [x] Add a native indeterminate bar and full-width elapsed label below the install row; grow its scrollable card while busy. Run a weak one-second timer only while the panel is visible and installation is active; restore state on reopen/rebuild and stop on close/completion.
- [x] Run `python3 Tests/install-pipe-check.py`, `bash Tests/tag-probe-check.sh`, localization check and an AppKit fixture that exercises real dashboard refresh/timer behavior without npm or live DSH.

### Task 2: Verify and release

**Files:** Modify `Info.plist`, `.github/workflows/release.yml`, and relevant README release example.

**Interfaces:** v1.0.3; existing Release workflow creates universal ZIP, SHA256 and EdDSA-signed appcast.

- [x] Set both version fields to 1.0.3; add actual feature and signing changes to Markdown/HTML release notes, including the first-upgrade permission caveat.
- [x] Run existing checks (avoid local certificate-generation tests where the private-file policy applies; run them in CI) and universal signed build; verify certificate-leaf designated requirement matches the prior local build.
- [x] Review the final diff, commit, push main and a new v1.0.3 tag without force.
- [x] Wait for CI, inspect release notes/assets, download the published ZIP and SHA256, verify universal architectures, nested signatures, same certificate identity and the appcast metadata/signature.

## Verification Results

- Release commit: `2551111612529cef912b7602701af2f065744d3a`; tag `v1.0.3`.
- [CI](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/40301696788): universal build and full consistency checks passed.
- [Release workflow](https://github.com/donald-trump86/dsh-bar-macos/actions/runs/40302008439): certificate import, signed build, packaging, appcast signing and publishing passed. Apple notarization was skipped for the self-signed identity.
- [Published release](https://github.com/donald-trump86/dsh-bar-macos/releases/tag/v1.0.3): stable, public, latest; ZIP, SHA256 and appcast present.
- Downloaded ZIP: 3,695,633 bytes; SHA256 `317821402b5d98992815a228509875811e4b1a6603ba22d536cfcdccbbd7710c` matches the published checksum.
- Downloaded app: version/build 1.0.3; `arm64` and `x86_64`; strict recursive codesign verification passed. Certificate leaf SHA1 `34959d783d07b4e31befa94f5f5c33f8825ba32e` matches the original local identity.
- Appcast: version, download URL, length and feature notes match. Its Ed25519 signature verifies against the app's embedded public key. The update feed and public key are unchanged from v1.0.2.
- This validates the published artifacts and update metadata; an actual user upgrade and macOS permission retention were not exercised.

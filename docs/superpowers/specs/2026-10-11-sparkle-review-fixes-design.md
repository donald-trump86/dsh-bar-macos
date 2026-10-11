# Sparkle review fixes

Approved maintenance scope: repair the five findings from the repository review without changing the update feed, public key, version, certificate configuration, domain or published assets.

## Requirements

1. Re-publishing an existing GitHub Release refreshes its body from the newly generated release notes after uploads succeed. An upload failure must not publish a new signing assurance.
2. Troubleshooting describes quarantine removal only for explicitly ad-hoc/unnotarized builds. Local Developer ID signing is not described as notarization. Native Swift/AppKit wording acknowledges vendored Sparkle.
3. Preferences Check Now follows Sparkle's `canCheckForUpdates`, both initially and on existing UI refreshes. The shared action rejects unavailable checks; interactive Sparkle UI can still be refocused when the flag is true.
4. Ordinary quit, Quit & Stop, and update relaunch wait for an active service launch/stop/restart to settle. Successful launches persist their managed identity before exit. Ordinary quit/update never stop a healthy service; Quit & Stop waits before stopping the owned service.
5. Deferred actions execute once on the main queue, recheck lifecycle state when dispatched, and leave no observer/timer behind. Failures also release waiting termination. Repeated quit requests do not produce duplicate termination replies.

## Design

Use three independently reviewable tasks: release notes/docs, update UI availability, and lifecycle-aware termination. Keep existing files and service lifecycle implementations; do not refactor the manager or invent another process owner.

ServiceManager gains `func performWhenLifecycleIdle(_ action: @escaping () -> Void)`. A small main-queue pending-action list drains only while `snapshot.phase.isBusy == false`; it is scheduled from the helper and after snapshot updates. Each queued action is removed before invocation. A dispatched drain rechecks phase, so a newly started operation cannot race a previously scheduled action. Saving the launch record remains before publishing the terminal running snapshot.

AppDelegate uses `.terminateLater` and one outstanding-reply guard, then invokes the existing prepare/stop behavior through the idle helper. UpdateManager conforms to Sparkle's relaunch-postponement delegate and uses the same helper; AppDelegate remains the fallback because Sparkle documents that the delegate hook is not always called. Construct the controller lazily with `updaterDelegate: self`, avoiding use of self before initialization.

## Constraints and proof

- macOS 13.0; arm64 + x86_64; Bash 3.2; no new dependencies or build-system migration.
- Version/build stay 1.0.1. Preserve SUFeedURL, SUPublicEDKey, daily checks and user-confirmed installation.
- Preserve dashboard floor 592 and minimum width 540; preference toggles write only on user action.
- Do not remove the currently accurate unnotarized warning or alter Apple/GitHub credentials.
- Use actual extracted production methods/steps with isolated stubs and temporary files. No real service, npm install, account changes or upgrade installation in tests.
- Prove existing/new release and upload-failure paths; availability true/false; delayed successful/failed lifecycle, restart and stop boundaries; repeated termination and update callbacks.
- Local build, complete checks and an independent final review are required. Real two-version update installation remains a separate manual verification, not a claimed result.

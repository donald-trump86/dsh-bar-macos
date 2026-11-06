# Environment diagnostics and service versions

The user approved implementing the two improvements proposed during brainstorming: actionable local environment diagnostics and separate installed/running DSH versions.

## Behavior

- Preferences opens a reusable native Environment Diagnostics window. It shows findings and the existing diagnostic report, with Recheck, Copy Diagnostics, View Live Logs, and Permissions Guide actions.
- Inspect `dsh`, `node`, and `npm` using exactly `ServiceManager.commandEnvironment()`. Show the resolved paths, validated versions, and search PATH. Do not source shell profiles, inspect configuration/credentials, install packages, or restart services as part of inspection.
- Run each `--version` command off the main thread, with a 3-second cancellation deadline and at most 4096 retained output bytes. Reuse the existing process-group runner. Nonzero exits, timeout, or unrecognized version output mean the command could not be verified.
- Findings distinguish missing commands from commands that cannot run; explain PATH differences from interactive terminals; report occupied ports and known version changes with the appropriate next step. Permission state is not inferred.
- `ServiceSnapshot.dshVersion` remains the installed CLI version. Add optional `runningDshVersion`, recorded at successful managed launch and persisted as optional `ManagedServiceRecord.dshVersion`. Legacy records remain decodable.
- Publish the running version only after the existing PID/port/start-time identity check succeeds. Unknown/external services stay unknown; stopped/conflicting services do not show a running version. Retain the existing first-miss debounce and ownership recovery rules.
- `needsVersionRestart` is true only for a running, verified managed service with two known, different versions. Menu/service details show the running version; the CLI row shows the installed version. A restart reminder follows this comparison, including upgrades outside the app and app relaunches.
- Keep all user-facing copy in the existing English/Chinese localization tables. Keep diagnostic export redaction and the existing install/restart confirmations.

## Constraints and validation

Swift/AppKit, macOS 13+, arm64 and x86_64; no new dependencies, preferences, network requests, automatic installation, or automatic service restarts. Validate actual production decisions with isolated command/identity fixtures and native offscreen layout tests; compile both architectures. Do not install the build over the user's app or restart their running services.

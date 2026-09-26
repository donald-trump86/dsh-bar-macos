# Contributing to DeepSeek Harness Bar

A native macOS menu bar companion for DeepSeek Harness. Pure Swift, no third-party
dependencies, macOS 13+.

## Build and run

```bash
make            # build/DeepSeek Harness Bar.app (universal)
make install    # same, copied to /Applications
make run        # install and open
make check      # consistency checks — run this before every commit
```

`make` compiles the sources twice (arm64 + x86_64) and lipo's the result, so a
full build takes a minute. To iterate faster, build one architecture:

```bash
ARCHS=arm64 ./build.sh
```

## What `make check` verifies

Three failure modes that review does not catch and the compiler does not either:

| Check | Catches |
| :--- | :--- |
| Translation key alignment | A `Key` added to one language table but not the other. The UI silently falls back to English — no error, no warning. |
| `APP_NAME` vs `CFBundleName` | Renaming the app in one file only. The built bundle and the documented path drift apart. |
| README `.app` paths | A path in the docs that no longer resolves after a rename. |

CI runs the same script on every push and pull request, plus a full build.

## Changing user-facing text

Every string lives in `Sources/Localization.swift`, in two tables — `english`
and `chinese`. A change means editing **both**, in the same commit:

```swift
private static let english: [Key: String] = [
    .someKey: "English text",
    …
]

private static let chinese: [Key: String] = [
    .someKey: "中文文本",
    …
]
```

`make check` fails if the two key sets differ. It does not check the
placeholders, so a `"{port}"` dropped from one side still ships.

## Naming

- **Full name** `DeepSeek Harness Bar` — the app bundle, `Info.plist`, README
  headings, release notes. Anything a user sees in Finder or a download.
- **Short name** `DSH Bar` — all in-app UI strings. The menu bar has room for
  `🐳 ●` and little else, so a 23-character name does not fit.

## Do not change these

They are compatibility surface, not implementation detail. Changing any of them
silently drops the user's existing configuration:

```
CFBundleIdentifier = ai.deepseek.dsh-bar
UserDefaults keys  = DSH_CustomPort, DSH_GlobalHotKey*, DSH_Language,
                     DSH_AutoRestart, DSH_LaunchAtLogin
State file         = ~/.dsh/dsh-bar-service.json
```

## Two things that are easy to get wrong

**Global hot keys conflict system-wide.** `RegisterEventHotKey` returns
`eventHotKeyExistsErr` when another app already owns the combination. That used
to be logged and swallowed, leaving a shortcut in the preferences that could
never fire. Recording now probes for availability *before* persisting, and the
probe happens with this app's own hot key unregistered — otherwise the app would
collide with itself and reject the combination the user already had. See
`HotKeyManager.isAvailable` and its two call sites in `DashboardWindow`.

The same conflict is why the default `⇧⌘D` may fail on a machine that has other
tools installed. There is no "correct" default — any fixed combination can be
taken — so the app reports the conflict and asks for a different one rather than
guessing.

**`probe()` gates on a TCP connect before forking.** `isPortListening` answers
"is anything on this port?" with one syscall, so the common stopped state costs
no `lsof` process at all. If you add work to `probe()`, put it *after* that gate,
or you put a fork back into every 2-second tick.

## Known deliberate simplifications

- `ServiceManager.swift` is ~1,700 lines and mixes polling, process identity
  checks, lifecycle, and the embedded shell scripts. It is not split because
  there are no unit tests to catch a bad move, and the concurrent parts are
  exactly the code that must not lose a running service. Split it when a test
  target exists.
- No unit test target. `make check` is the entire safety net, and it only covers
  the failures that are silent.
- Ad-hoc signed, not notarized. See the README troubleshooting section.

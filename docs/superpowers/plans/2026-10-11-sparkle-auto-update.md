# Sparkle 2 auto-update integration

## Goal

Give DeepSeek Harness Bar a real auto-update channel: users get a standard macOS
update prompt (release notes, "Install and Relaunch") driven by Sparkle 2, with
daily background checks by default. Releases become self-service — a pushed
`v*` tag builds, signs, notarizes, publishes the zip on GitHub Releases, and
publishes a signed appcast that installed apps poll.

## Architecture

- **Vendored framework.** `Vendor/Sparkle.framework` (Sparkle 2.10.0 universal
  binary, committed to the repo) plus `Vendor/Sparkle/bin/` tools
  (`generate_appcast`, `sign_update`, `generate_keys`, `BinaryDelta`) for CI
  signing. No SwiftPM/Xcode migration — `build.sh` keeps driving `xcrun swiftc`
  per-arch + `lipo`, gaining `-F Vendor -framework Sparkle` and
  `-Wl,-rpath,@loader_path/../Frameworks`.
- **One wrapper.** New `Sources/UpdateManager.swift` owns
  `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
  userDriverDelegate: nil)` and is the only file that imports Sparkle. AppDelegate
  and DashboardWindow talk to `UpdateManager.shared` only.
- **Feed.** `SUFeedURL` = `https://donald-trump86.github.io/dsh-bar-macos/appcast.xml`
  (GitHub Pages, deployed by the release workflow). Update zips stay on GitHub
  Releases; `generate_appcast --download-url-prefix` rewrites enclosure URLs to
  `https://github.com/donald-trump86/dsh-bar-macos/releases/download/<tag>/…`.
- **Signing.** EdDSA: private key as repo secret `SPARKLE_PRIVATE_ED_KEY`,
  fed to `generate_appcast` via `--ed-key-file -`; public key baked into
  `Info.plist` as `SUPublicEDKey`. The appcast is regenerated single-item per
  release (any older installed version upgrades to the latest item).
- **Code signing order.** `build.sh` signs Sparkle inside-out before the app
  bundle (Installer.xpc → Downloader.xpc → Autoupdate → Updater.app →
  Sparkle.framework → app), never `--deep`. CI keeps doing Developer ID +
  notarization; local falls back to ad-hoc.

## Tech Stack

- Sparkle 2.10.0 prebuilt (`Sparkle-2.10.0.tar.xz`, already extracted at
  `.sparkle-research/extracted/`), macOS 13.0+, universal arm64+x86_64.
- Bash (`build.sh`, `Tests/run-checks.sh`, new `Tests/sparkle-check.sh`,
  `Tests/sparkle-api-check.sh`), Swift (AppDelegate/DashboardWindow changes),
  GitHub Actions (`release.yml`: build → notarize → appcast → Pages deploy).
- Verified API surface (from vendored headers):
  `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`,
  `- (IBAction)checkForUpdates:(nullable id)sender`,
  `SPUUpdater.canCheckForUpdates` (readonly Bool), `automaticallyChecksForUpdates`
  (Bool), `updateCheckInterval` (NSTimeInterval), `automaticallyDownloadsUpdates`
  (Bool).

## Spec

Approved decisions (grilling round, all "recommended" answers accepted):

1. Vendor prebuilt framework; no package-manager migration.
2. Appcast on GitHub Pages; zips on GitHub Releases.
3. EdDSA signing + appcast generation fully automated in `release.yml` via
   secrets; public key in `Info.plist`.
4. UI: "Check for Updates…" NSMenu item + a Software Updates row in the
   Dashboard preferences card (version line, check button, auto-check toggle).
   Standard Sparkle UI; daily background check; never silent install
   (`SUAutomaticallyUpdate=false`).
5. Explicit inside-out codesign of Sparkle nested components in `build.sh`
   (doc-sanctioned order, no `--deep`); CI Developer ID + notarize; local ad-hoc.

Runtime behavior:

- `SUEnableAutomaticChecks=true` + `SUScheduledCheckInterval=86400` → daily
  background check by default. `SUAutomaticallyUpdate=false` → Sparkle prompts
  (download+install only on user approval). `SUShowReleaseNotes=true`.
- The prefs toggle reads/writes `updater.automaticallyChecksForUpdates` **only
  on user toggle** (Sparkle docs: never set it otherwise; it is NSUserDefaults-
  backed and must not be backed by additional defaults).
- Menu item target is the controller (`checkForUpdates(_:)`); validation via
  `canCheckForUpdates`.

## Global Constraints

- `Tests/run-checks.sh` invariants at run-checks.sh:86-88 grep these exact
  lines in DashboardWindow.swift — they must survive unchanged:
  `minSize = NSSize(width: 540, height: Self.naturalContentHeight)`,
  `private static let naturalContentHeight: CGFloat = 592`,
  `preferencesScroll.documentView = preferencesCard`. New prefs rows go inside
  the scrollable card; do not touch those lines.
- Every new Localization.Key must be added to **both** `english` and `chinese`
  tables (`Tests/localization-check.py` enforces key + placeholder parity).
- Test style: repo checks are real-implementation probes — extract/compile real
  Swift with `xcrun swiftc` in `/tmp`, or grep invariants against real files.
  Follow it.
- `build.sh` stays the single build entry (Makefile wraps it); no Xcode project.
- Packaging must preserve Sparkle's symlinks/permissions: embed with `ditto`,
  never plain `cp` of the framework.
- Do not use `--deep` when signing (verify with `--deep --strict` is fine).

## Review Focus

- The five nested `codesign` commands match the Sparkle-documented order and
  run **before** the app-bundle sign.
- The toggle never writes `automaticallyChecksForUpdates` except in its action.
- `SUPublicEDKey` (Info.plist) and `SPARKLE_PRIVATE_ED_KEY` (secret) are the
  matched EdDSA pair; appcast generation fails closed if the secret is missing.
- Nothing in the three DashboardWindow invariant lines changes.

---

## Task 0: EdDSA key bootstrap (user-assisted, do first)

**Why first:** Task 3 bakes the public key into Info.plist; Task 6 needs the
private key as a secret. One key pair serves the app forever.

**Files:** `Vendor/Sparkle/bin/generate_keys` (after Task 1), GitHub repo
secrets, `Info.plist` (consumed in Task 3).

**Steps:**

1. After Task 1 lands the tools, run:
   `./Vendor/Sparkle/bin/generate_keys` (Keychain may pop an approval dialog —
   the user clicks Allow; note the printed public key),
   then `./Vendor/Sparkle/bin/generate_keys -x /tmp/dshbar_eddsa_key` to export
   the private key file.
2. User creates repo secret `SPARKLE_PRIVATE_ED_KEY` containing the exact text
   of `/tmp/dshbar_eddsa_key` (`gh secret set SPARKLE_PRIVATE_ED_KEY <
   /tmp/dshbar_eddsa_key`), then shred the export.
3. Public key value goes to Task 3. If the user defers this task, leave
   `SUPublicEDKey` as `REPLACE_WITH_EDDSA_PUBLIC_KEY` and the release workflow
   will fail closed until the pair is configured.

---

## Task 1: Vendor Sparkle 2.10.0 + layout test

**Files:** `Vendor/Sparkle.framework` (new), `Vendor/Sparkle/bin/` (new),
`Vendor/SPARKLE_VERSION` (new), `Tests/sparkle-check.sh` (new),
`Tests/run-checks.sh` (register), `.gitignore`.

**Interfaces:**

- `Vendor/Sparkle.framework/Versions/B/{Sparkle,Autoupdate,Updater.app,XPCServices/Installer.xpc,XPCServices/Downloader.xpc,Modules/module.modulemap}`.
- `Vendor/SPARKLE_VERSION`: one line — `2.10.0
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz`.
- `Tests/sparkle-check.sh`: `pass()/fail()` style like existing checks.

**Steps:**

1. **Failing test first.** Write `Tests/sparkle-check.sh` asserting: framework
   layout paths above exist; `lipo -archs Vendor/Sparkle.framework/Versions/B/Sparkle`
   reports both `arm64` and `x86_64`; `Vendor/Sparkle/bin/generate_appcast`,
   `sign_update`, `generate_keys` exist and are executable. Run it → fails
   (no `Vendor/`).
2. Copy from the already-extracted research material:
   `mkdir -p Vendor/Sparkle/bin`,
   `ditto .sparkle-research/extracted/Sparkle.framework Vendor/Sparkle.framework`,
   `cp .sparkle-research/extracted/bin/{generate_appcast,sign_update,generate_keys,BinaryDelta} Vendor/Sparkle/bin/`.
   Write `Vendor/SPARKLE_VERSION`.
3. Add `.sparkle-research/` to `.gitignore` (research material stays local).
4. Register `Tests/sparkle-check.sh` in `Tests/run-checks.sh`.
5. Verify: `Tests/sparkle-check.sh` passes; `Tests/run-checks.sh` green.
6. Commit: `Vendor Sparkle 2.10.0 framework and tools`.

---

## Task 2: build.sh — link, embed, inside-out codesign

**Files:** `build.sh`, `Tests/sparkle-check.sh` (extend).

**Interfaces (exact additions):**

- `SOURCE_FILES` gains `Sources/UpdateManager.swift` (lands in Task 4; add the
  line here so the build stays green end-to-end — create a stub file in Task 4
  if tasks run out of order).
- `COMMON_SWIFT_FLAGS` gains: `-F "$SCRIPT_DIR/Vendor"`, `-framework Sparkle`.
- Per-arch link line gains:
  `-Xlinker -rpath -Xlinker @loader_path/../Frameworks`.
- After assembling `Contents/` (before `xattr -cr`):
  `ditto "Vendor/Sparkle.framework" "$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"`.
- Nested signing block (inside-out, docs order — note `--preserve-metadata=entitlements`
  on Downloader.xpc for Sparkle ≥ 2.6; `--timestamp` only with a real identity):

  ```bash
  SPARKLE_FW="$BUNDLE_DIR/Contents/Frameworks/Sparkle.framework"
  sign_nested() { # $1..$n = paths; uses $SIGN_STYLE args
      local p; for p in "$@"; do
          codesign --force ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$SIGN_ID" "$p"
      done
  }
  # Developer ID: SIGN_ID=$SIGNING_IDENTITY SIGN_ARGS=(--options runtime --timestamp)
  # Ad-hoc:       SIGN_ID=-          SIGN_ARGS=()
  sign_nested \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \  # add --preserve-metadata=entitlements for this one
      "$SPARKLE_FW/Versions/B/Autoupdate" \
      "$SPARKLE_FW/Versions/B/Updater.app" \
      "$SPARKLE_FW"
  ```

  Then sign the app bundle as today. Never `--deep` in signing.

**Steps:**

1. **Failing test first.** Extend `Tests/sparkle-check.sh` with greps on
   build.sh: embed uses `ditto … Vendor/Sparkle.framework … Contents/Frameworks`;
   `-framework Sparkle`; `@loader_path/../Frameworks`; the five nested sign
   targets appear in documented order (Installer.xpc → Downloader.xpc →
   Autoupdate → Updater.app → Sparkle.framework) and the sign block contains
   `--preserve-metadata=entitlements`; no `--deep` on any `codesign … --sign`
   line. Run → fails.
2. Implement the build.sh additions.
3. Verify: `./build.sh` succeeds;
   `otool -L "build/DeepSeek Harness Bar.app/Contents/MacOS/dsh-bar" | grep Sparkle`
   shows `@rpath/Sparkle.framework/...`;
   `test -d "build/DeepSeek Harness Bar.app/Contents/Frameworks/Sparkle.framework"`;
   `codesign --verify --deep --strict` passes (already run by build.sh);
   `Tests/sparkle-check.sh` passes.
4. Commit: `Embed and sign Sparkle in build.sh`.

---

## Task 3: Info.plist Sparkle keys

**Files:** `Info.plist`, `Tests/sparkle-check.sh` (extend).

**Interfaces (exact keys):**

```xml
<key>SUFeedURL</key>
<string>https://donald-trump86.github.io/dsh-bar-macos/appcast.xml</string>
<key>SUPublicEDKey</key>
<string><!-- public key from Task 0, or REPLACE_WITH_EDDSA_PUBLIC_KEY --></string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
<key>SUAutomaticallyUpdate</key>
<false/>
<key>SUShowReleaseNotes</key>
<true/>
```

**Steps:**

1. **Failing test first.** Extend `Tests/sparkle-check.sh`: `plutil` assertions —
   SUFeedURL equals the URL above; SUScheduledCheckInterval == 86400;
   SUEnableAutomaticChecks == true; SUAutomaticallyUpdate == false;
   SUPublicEDKey present and != `REPLACE_WITH_EDDSA_PUBLIC_KEY` (warn-only until
   Task 0 lands, then hard). Run → fails.
2. Add the keys to Info.plist.
3. Verify: `./build.sh` still green (plist is copied and version-stamped);
   `Tests/sparkle-check.sh` passes.
4. Commit: `Declare Sparkle feed and update policy in Info.plist`.

---

## Task 4: UpdateManager + menu item

**Files:** `Sources/UpdateManager.swift` (new), `Sources/AppDelegate.swift`,
`Sources/Localization.swift`, `Tests/sparkle-api-check.sh` (new),
`Tests/run-checks.sh` (register).

**Interfaces:**

```swift
import Foundation
import Sparkle   // only this file imports Sparkle

@MainActor
final class UpdateManager: NSObject {
    static let shared = UpdateManager()
    let controller: SPUStandardUpdaterController
    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? canCheckForUpdates : true
    }
}
```

- AppDelegate: new property `updateMenuItem: NSMenuItem`; in `setupMenu()`
  insert after `logsMenuItem`, before the quit separator:

  ```swift
  updateMenuItem = NSMenuItem(
      title: L(.checkForUpdatesEllipsis),
      action: #selector(UpdateManager.checkForUpdates(_:)),
      keyEquivalent: "")
  updateMenuItem.target = UpdateManager.shared
  menu.addItem(updateMenuItem)
  ```

- New Localization keys (both tables):
  `checkForUpdatesEllipsis` en "Check for Updates…" / zh "检查更新…";
  `softwareUpdates` en "Software Updates" / zh "软件更新";
  `updateCurrentVersion` en "Version {version}" / zh "版本 {version}";
  `updateCheckNow` en "Check Now" / zh "立即检查";
  `autoCheckUpdates` en "Check for updates automatically" / zh "自动检查更新".

**Steps:**

1. **Failing test first.** Write `Tests/sparkle-api-check.sh`:
   `xcrun swiftc -typecheck -parse-as-library -module-name SparkleAPICheck
   -F Vendor -sdk "$(xcrun --sdk macosx --show-sdk-path)" Sources/UpdateManager.swift`
   (real API surface of the vendored headers must compile) plus greps:
   AppDelegate wires `#selector(UpdateManager.checkForUpdates` with
   `target = UpdateManager.shared`. Run → fails (file absent).
2. Implement `Sources/UpdateManager.swift`, AppDelegate menu wiring,
   Localization keys (both tables).
3. Verify: `Tests/sparkle-api-check.sh` passes; `python3 Tests/localization-check.py`
   passes; `./build.sh` green (SOURCE_FILES line added in Task 2);
   `Tests/run-checks.sh` green.
4. Commit: `Wire Sparkle updater behind UpdateManager`.

---

## Task 5: Dashboard Software Updates row

**Files:** `Sources/DashboardWindow.swift`, `Tests/sparkle-check.sh` (extend).

**Interfaces (follow the existing row pattern):**

- New controls on `DashboardWindowController`:
  `updateInfoLabel` (dynamic description, substituted into the text stack the
  way `tagInfoLabel` is at DashboardWindow.swift:698-711),
  `updateCheckButton` (`configureActionButton(..., title: L(.updateCheckNow),
  action: #selector(didClickCheckForUpdates))`),
  `autoUpdateCheckbox` (`NSButton(checkboxWithTitle: L(.autoCheckUpdates), …)`).
- New `updateRow` **below** `tagRow`: `separator8` after tagRow;
  `tagRow` gets `heightAnchor == 54` (replacing its current `bottom ==
  card.bottom - 8` pin at DashboardWindow.swift:~820); `updateRow.top ==
  separator8.bottom`; `updateRow.bottom == card.bottom, constant: -8`.
  Layout mirrors the checkbox rows (`loginRow` pattern).
- `updateText = makeTextStack(title: L(.softwareUpdates),
  description: L(.updateCurrentVersion, ["version": UpdateManager.shared.currentVersion]))`
  with `updateInfoLabel` substituted for the dynamic line (survives language-
  change rebuilds).
- Actions:

  ```swift
  @objc private func didClickCheckForUpdates() {
      UpdateManager.shared.checkForUpdates(self)
  }
  @objc private func didToggleAutoUpdates() {
      UpdateManager.shared.automaticallyChecksForUpdates =
          (autoUpdateCheckbox.state == .on)   // ONLY write on user toggle
  }
  ```

- `setupUI()`: `autoUpdateCheckbox.state = UpdateManager.shared.automaticallyChecksForUpdates
  ? .on : .off` (read-only initialization).

**Steps:**

1. **Failing test first.** Extend `Tests/sparkle-check.sh`: greps for
   `updateRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)`,
   `didToggleAutoUpdates`, and the three run-checks invariant lines (double
   check no drift). Run → fails.
2. Implement the row + actions.
3. Verify: `./build.sh` green; `Tests/run-checks.sh` green (its DashboardWindow
   size invariants at run-checks.sh:86-88 unchanged); `Tests/sparkle-check.sh`
   passes. Manual: open Dashboard → Preferences → Software Updates row shows
   version, Check Now button, auto-check toggle reflecting Sparkle state.
4. Commit: `Add Software Updates row to preferences`.

---

## Task 6: CI appcast signing + Pages deploy

**Files:** `.github/workflows/release.yml`, `Tests/sparkle-check.sh` (extend).

**Interfaces:**

- In "Verify and package" (or a new step after "Notarize and staple" — must run
  **after** stapling so the shipped zip is final): write release notes as
  **both** `dist/release-notes.md` (GitHub release body, as today) and
  `dist/${ZIP_NAME%.zip}.html` (HTML fragment for the appcast: `<h3>…</h3><ol>…`
  of the same installation steps; no DOCTYPE/body so `generate_appcast` embeds
  it as CDATA).
- New step "Generate EdDSA-signed appcast":

  ```bash
  test -n "${SPARKLE_PRIVATE_ED_KEY:-}" || { echo "SPARKLE_PRIVATE_ED_KEY missing" >&2; exit 1; }
  mkdir -p dist/appcast-input
  cp "dist/$ZIP_NAME" dist/appcast-input/
  cp "dist/${ZIP_NAME%.zip}.html" dist/appcast-input/
  echo "$SPARKLE_PRIVATE_ED_KEY" | ./Vendor/Sparkle/bin/generate_appcast \
      --ed-key-file - \
      --embed-release-notes \
      --download-url-prefix "https://github.com/${GH_REPO}/releases/download/${TAG}/" \
      -o appcast.xml dist/appcast-input
  cp dist/appcast-input/appcast.xml dist/appcast.xml
  ```

- Upload `dist/appcast.xml` to the GitHub Release (backup asset) and as a
  separate workflow artifact `appcast`.
- New job `deploy-appcast` (`needs: release`, `runs-on: ubuntu-latest`,
  `permissions: {pages: write, id-token: write}`, `environment: github-pages`):
  download artifact `appcast` → `actions/upload-pages-artifact` (site dir
  containing `appcast.xml`) → `actions/deploy-pages@v4`.
- One-time user setup (documented in README task): repo Settings → Pages →
  Source = **GitHub Actions**; secret `SPARKLE_PRIVATE_ED_KEY` (Task 0).

**Steps:**

1. **Failing test first.** Extend `Tests/sparkle-check.sh` with greps:
   `generate_appcast` with `--ed-key-file -` and `--download-url-prefix`;
   `appcast.xml` in upload paths; `deploy-appcast` job with `deploy-pages`.
   Run → fails.
2. Implement the workflow changes.
3. Verify: `Tests/sparkle-check.sh` passes; YAML parses
   (`python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))"`);
   `Tests/run-checks.sh` green. Full end-to-end verification happens on the
   first real `v*` tag (listed in handoff).
4. Commit: `Generate signed appcast and deploy it to GitHub Pages`.

---

## Task 7: README + full check pass

**Files:** `README.md`.

**Steps:**

1. Extend the release section (README.md around lines 113-125): mention the
   auto-update channel (daily check, prompt install), the required secrets
   table (add `SPARKLE_PRIVATE_ED_KEY`), and Pages prerequisite. Update the
   project-structure blurb (README.md:187) with `Vendor/` and
   `Sources/UpdateManager.swift`.
2. Verify: `make check` (i.e. `Tests/run-checks.sh`) fully green;
   `./build.sh` green.
3. Commit: `Document Sparkle auto-update setup`.

---

## Self-review (writing-plans checklist)

- [x] Every task has failing test → implement → verify → commit.
- [x] Exact paths, signatures, key names, commands spelled out; no "TBD" in
      code-level detail (only the user-side key bootstrap is deferred to Task 0).
- [x] Global constraints honored: run-checks.sh:86-88 invariant lines untouched;
      localization parity in both tables; ditto for symlinks; no `--deep` signing.
- [x] Sequencing: Task 0 (keys) → 1 (vendor) → 2 (build) → 3 (plist) → 4
      (updater+menu) → 5 (row) → 6 (CI) → 7 (docs); each builds on the previous.
- [x] Verified against the real Sparkle 2.10.0 headers/tools (init signature,
      `checkForUpdates:` IBAction, `canCheckForUpdates`, NSTimeInterval
      `updateCheckInterval`, `generate_appcast --ed-key-file -` stdin secret
      support, documented codesign order incl. `--preserve-metadata=entitlements`).

## Execution handoff

Open questions for execution mode (user picks):

1. **Execution style:** subagent-driven (fresh subagent per task, reviewed
   between) or native (this session executes task by task)?
2. **Task 0 timing:** run key generation now (needs one Keychain approval click
   + `gh secret set`) or ship with placeholder and configure before first
   release? (Release workflow fails closed until the pair exists.)
3. **Pages fallback:** if the repo can't use GitHub Pages (private repo without
   Pages), switch SUFeedURL to a `gh-pages`-branch raw URL — confirm repo
   visibility during execution.

End-to-end proof on the first `v*` tag after merge: release builds → zip
notarized → appcast signed+published at the SUFeedURL → an installed older
build shows the standard update prompt within 24h (or via "Check Now").

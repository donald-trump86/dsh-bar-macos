# Stable Self-Signed Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep macOS TCC permissions (辅助功能/自动化/屏幕录制) across app updates by signing every build — local and GitHub Release — with one long-lived self-signed code-signing certificate, without paying for the Apple Developer Program.

**Architecture:** macOS identifies an app to its privacy system (TCC) by the code signature's designated requirement. An ad-hoc signature (today's default) is unique per build, so every Sparkle update looks like a brand-new app and re-prompts for permission. One self-signed certificate used for every build produces an identical designated requirement each time, so granted permissions survive updates. This is Layer 1 only: packaging/build/release/docs/tests. No Swift sources, no entitlements, no sandbox changes.

**Tech Stack:** system bash 3.2, `security(1)`, `codesign(1)`, LibreSSL `openssl` (system), GitHub Actions.

**Spec:** Design approved in chat 2026-10-16 (m00024–m00025). Binding points: no paid Apple account; self-signed cert CN `DSH Bar Self-Signing`; GitHub Releases also switch to the self-signed cert (user-approved); the existing Developer ID path (when those secrets are set) keeps working byte-for-byte in behavior; notarization only ever runs for Developer ID; Sparkle's EdDSA update channel (`SUPublicEDKey` / `SPARKLE_PRIVATE_ED_KEY`) is untouched. Layer 2 (in-app permission center) is a separate future plan.

## Global Constraints

- Identity name (CN) is exactly `DSH Bar Self-Signing`.
- p12 artifact is `dsh-bar-self-signing.p12` (repo root when default) and must be covered by `.gitignore`; private key material is never committed.
- Self-signed signing uses plain `codesign --force --sign <identity>` — never `--options runtime`, never `--timestamp` (both are Developer-ID-only).
- Identities matching `Developer ID Application:`* keep today's flags (`--options runtime --timestamp` + entitlements). That path is unchanged.
- GitHub secrets keep their existing names: `APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_KEYCHAIN_PASSWORD`; notarization secrets (`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) unchanged and used only for Developer ID.
- All shell scripts run on system bash 3.2 (no bash-4 features); `bash -n` must pass on every touched script.
- No new dependencies — only system tools (`security`, `codesign`, `openssl`, `clang`, `python3`).
- `Tests/run-checks.sh` stays green; new checks are appended following its numbered-comment style.
- README edits keep the bilingual zh/en style and must not break run-checks check #2 (every quoted `*.app` path must be `DeepSeek Harness Bar.app`).
- Tests use scratch keychains only; they never write to `login.keychain-db`, and if they prepend to the keychain search list they restore it exactly (trap-based).
- Commits use the repo's prefix style: `feat:`, `test:`, `docs:`.

## Review Focus

1. Fresh clone, no cert anywhere: `./build.sh` must still succeed ad-hoc and must not hang on a keychain prompt. → Task 2 structural check (auto-detect block is conditional, ad-hoc fallback prints a hint) and CI's existing build step exercises this path.
2. CI with self-signed P12 but no notarization secrets: the release must skip notarization, not fail. → Task 3 check asserts the notarize step's `if:` gates on `developer_id`, not on `configured`.
3. The TCC-stability property itself: two builds signed with the same identity must produce identical designated requirements. → Task 2 behavioral check signs a real binary twice with a scratch identity and compares `codesign -drr` output.
4. Re-running the creation script must not silently mint a second cert (would reset permissions). → Task 1 idempotency test: second run without `--force` exits non-zero.
5. Private key leakage: p12/intermediate key files written into the repo tree must be ignored. → Task 1 check asserts `git check-ignore` matches `dsh-bar-self-signing.p12`.

---

### Task 1: Self-signed identity creation script + signing checks skeleton

**Files:**
- Create: `Packaging/create-signing-identity.sh`
- Create: `Tests/signing-check.sh`
- Modify: `.gitignore`
- Modify: `Tests/run-checks.sh` (append check #17)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `create-signing-identity.sh [--keychain PATH] [--keychain-password PW] [--p12-out PATH] [--password PW] [--skip-trust] [--force]`. Defaults: `--keychain login.keychain-db`, `--p12-out ./dsh-bar-self-signing.p12`. On success: identity `DSH Bar Self-Signing` exists in the target keychain as a valid codesigning identity, and the p12 (encrypted with `--password`) exists at `--p12-out`. Task 2's tests invoke this script to mint scratch identities.

- [ ] **Step 1: Write failing checks in `Tests/signing-check.sh` (header comment + section 1)**

Header follows `Tests/sparkle-check.sh` style (`set -uo pipefail`, `fail()`/`pass()`, `cd` to repo root). Section 1 checks:
  1. `bash -n Packaging/create-signing-identity.sh` passes.
  2. Scratch-keychain end-to-end: `TMP=$(mktemp -d)`; `security create-keychain -p testpw "$TMP/scratch.keychain-db"`; `security set-keychain-settings -lut 300 "$TMP/scratch.keychain-db"`; `security unlock-keychain -p testpw "$TMP/scratch.keychain-db"`; run `Packaging/create-signing-identity.sh --keychain "$TMP/scratch.keychain-db" --keychain-password testpw --p12-out "$TMP/test.p12" --password testpw --skip-trust`; then assert `security find-identity -v -p codesigning "$TMP/scratch.keychain-db"` lists `DSH Bar Self-Signing`; assert `openssl pkcs12 -in "$TMP/test.p12" -passin pass:testpw -noout` parses.
  3. Idempotency: a second run against the same keychain without `--force` exits non-zero.
  4. `.gitignore` covers the artifact: `git check-ignore -q dsh-bar-self-signing.p12`.
  Cleanup: `security delete-keychain` on the scratch keychain in a trap.

- [ ] **Step 2: Run to verify failure**

Run: `bash Tests/signing-check.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `Packaging/create-signing-identity.sh`**

Algorithm (signature and flags are fixed above; this is the body outline):
  - `set -euo pipefail`; usage/`--help` text; parse flags. Refuse if `--password` missing.
  - If target keychain lacks `security list-keychains -d user` membership that is fine — `security import -k` accepts a path.
  - Idempotency first: if `security find-identity -v -p codesigning "$KEYCHAIN"` already lists `"DSH Bar Self-Signing"` and `--force` not given → exit 1 with a message explaining a new cert resets TCC permissions.
  - Intermediates in `mktemp -d` (trap-cleanup): write an openssl config heredoc with `[codesign] extendedKeyUsage = codeSigning` (LibreSSL has no `-addext`); `openssl req -x509 -new -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -subj /CN=DSH Bar Self-Signing -config cnf -extensions codesign`; `openssl pkcs12 -export -out "$P12_OUT" -inkey key.pem -in cert.pem -password pass:"$PASSWORD"`.
  - Import: `security import "$P12_OUT" -P "$PASSWORD" -T /usr/bin/codesign -k "$KEYCHAIN"`.
  - If `--keychain-password` given: `security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"` (lets codesign sign non-interactively; mirrors what CI does).
  - Unless `--skip-trust`: `security add-trusted-cert -p codeSigning -k "$KEYCHAIN" cert.pem`; print that macOS will show one authorization dialog when targeting the login keychain.
  - Print next steps: `base64 -i <p12> | pbcopy` → secret `APPLE_CERT_P12_BASE64`; the p12 password → `APPLE_CERT_PASSWORD`; any keychain password → `APPLE_KEYCHAIN_PASSWORD`; note that regenerating the cert later costs one more round of permission prompts.

- [ ] **Step 4: Add `dsh-bar-self-signing.p12` to `.gitignore`; wire `Tests/signing-check.sh` into `Tests/run-checks.sh` as numbered check #17** (same `if bash … then pass … else fail` shape as check #11).

- [ ] **Step 5: Run checks; commit**

Run: `bash Tests/signing-check.sh && ./Tests/run-checks.sh` — both green.
Commit: `feat: add self-signed identity creation script and signing checks` (script + tests + .gitignore + run-checks).

### Task 2: build.sh two-path signing + keychain auto-detect

**Files:**
- Modify: `build.sh:120-173` (signing section)
- Modify: `Tests/signing-check.sh` (append section 2)

**Interfaces:**
- Consumes: `Packaging/create-signing-identity.sh` (test minting), identity CN from Global Constraints.
- Produces: build behavior later tasks rely on — release.yml passes `SIGNING_IDENTITY` env unchanged; the self-signed path signs nested Sparkle components with the same identity but no runtime/timestamp flags.

- [ ] **Step 1: Append failing checks (section 2) to `Tests/signing-check.sh`**

Structural:
  1. `grep -q 'if \[\[ "$SIGNING_IDENTITY" == "Developer ID Application:"\* \]\]' build.sh` (the Developer-ID-only flag branch exists).
  2. build.sh contains a `security find-identity` auto-detect block and its ad-hoc fallback hint mentions `create-signing-identity.sh`.

Behavioral (the TCC-stability proof): save current search list (`security list-keychain -d user`), create scratch keychain + identity exactly as in section 1, prepend scratch keychain to the search list, trap-restore the list and `security delete-keychain`. Then:
  - Compile `int main(){return 0;}` with `clang` to `$TMP/bin1` and `$TMP/bin2`.
  - `codesign --force --sign "DSH Bar Self-Signing"` both.
  - Extract `codesign -drr` designated-requirement text from each, normalize whitespace, assert identical.
  - Assert the DR contains `anchor` (cert-anchored, not hash-anchored): this is what makes TCC see "the same app" across builds.
  - Ad-hoc-sign `$TMP/bin3` (`codesign --force --sign -`) and assert its DR differs from the certified one.

- [ ] **Step 2: Run to verify failure**

Run: `bash Tests/signing-check.sh`
Expected: FAIL — the identity minting works (section 1), but the build.sh structural greps find no Developer-ID branch and no auto-detect block.

- [ ] **Step 3: Modify `build.sh`**

  - Auto-detect before the existing `SIGN_ARGS` block: when `SIGNING_IDENTITY` is empty, try `security find-identity -v -p codesigning` for an identity named exactly `DSH Bar Self-Signing`; if found, use it and log `==> Using self-signed identity from keychain: …`.
  - Flag selection (replaces the current `if [[ -n "$SIGNING_IDENTITY" ]]` at build.sh:126): `SIGN_ARGS=(--options runtime --timestamp)` only when the identity matches `Developer ID Application:`*; otherwise `SIGN_ARGS=()`. The nested Sparkle re-sign block keeps using the existing `${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}` expansion, so it picks up the distinction automatically.
  - Final bundle signing: three cases — empty → today's ad-hoc path plus a one-line hint pointing at `Packaging/create-signing-identity.sh`; `Developer ID Application:`* → today's `--options runtime --timestamp --entitlements` command unchanged; anything else → `codesign --force --entitlements "Packaging/DSHBar.entitlements" --sign "$SIGNING_IDENTITY"` (entitlements file is an empty dict; keep for parity, drop runtime/timestamp).
  - Keep the summary line at build.sh:173 printing `$SIGNING_IDENTITY:-ad-hoc}` — still correct in all three cases.

- [ ] **Step 4: Implementer end-to-end verification (not part of run-checks)**

With the scratch identity's keychain in the search list and `SIGNING_IDENTITY` unset: `ARCHS=arm64 CLANG_MODULE_CACHE_PATH=$PWD/build/.modulecache ./build.sh` → build log shows the detected identity; `codesign -dv "build/DeepSeek Harness Bar.app"` reports `Authority=DSH Bar Self-Signing`; `codesign --verify --deep --strict` passes. Then restore the search list. If codesign prompts for key access, the script's `set-key-partition-list` (run with `--keychain-password`) is what avoids it — verify it was run.

- [ ] **Step 5: Run checks; commit**

Run: `bash Tests/signing-check.sh && ./Tests/run-checks.sh` — green.
Commit: `feat: sign builds with stable self-signed identity`.

### Task 3: release.yml — any-identity import, `signing_mode`, gated notarization, three-state notes

**Files:**
- Modify: `.github/workflows/release.yml` (import step, build step env, notarize step, notes step)
- Modify: `Tests/signing-check.sh` (append section 3)

**Interfaces:**
- Consumes: `SIGNING_IDENTITY` env contract from Task 2 (Developer ID → runtime/timestamp; self-signed → plain).
- Produces: workflow outputs from the import step — `configured` (unchanged), `identity`, `developer_id` (`true|false`), `signing_mode` (`developer-id|self-signed|ad-hoc`).

- [ ] **Step 1: Append failing checks (section 3)**

  1. Import step: identity selection must accept any codesigning identity, preferring `Developer ID Application` when both exist (assert the awk/grep no longer matches only `Developer ID Application`).
  2. Import step emits `developer_id=` and `signing_mode=` outputs.
  3. Notarize step's `if:` is `steps.signing.outputs.developer_id == 'true'` (not `configured`).
  4. Notes step branches on `signing_mode` with three distinct texts; the `self-signed` branch mentions that macOS permissions survive updates and still includes the `xattr -cr` quarantine instructions; the `developer-id` branch text is unchanged from today.

- [ ] **Step 2: Run to verify failure** — `bash Tests/signing-check.sh` FAIL on section 3.

- [ ] **Step 3: Modify `.github/workflows/release.yml`**

  - Import step: after import, list identities in `$KEYCHAIN_PATH`; if none → hard fail (unchanged). Prefer a `Developer ID Application` identity if present, else the first codesigning identity. Emit `identity`, plus `developer_id=true|false` by prefix test, plus `signing_mode` (`developer-id` / `self-signed` / `ad-hoc` when secrets were absent and the step early-exited with `configured=false`).
  - Notarize step: change only its `if:` to `developer_id == 'true'` (self-signed certs cannot be notarized; with a self-signed P12 configured, notarization credentials are intentionally not required).
  - Notes step: switch `SIGNED` env to `SIGNING_MODE="${{ steps.signing.outputs.signing_mode }}"` and render three states in both the markdown and HTML fragments (keep fragments content-identical): `developer-id` → today's sentence; `self-signed` → "Signed with the project's self-signing certificate, so macOS permissions (Accessibility/Automation/Screen Recording) survive updates. Not notarized by Apple — clear the quarantine attribute after download:" + existing `xattr -cr` block; `ad-hoc` → today's not-notarized block.

- [ ] **Step 4: Run checks; commit**

Run: `bash Tests/signing-check.sh && ./Tests/run-checks.sh` — green.
Commit: `feat: release builds signed with self-signed identity`.

### Task 4: README owner setup documentation

**Files:**
- Modify: `README.md`
- Modify: `Tests/signing-check.sh` (append section 4)
- Modify: `CONTRIBUTING.md` only if it currently mentions signing/release behavior (grep first; if silent, leave untouched)

**Interfaces:**
- Consumes: script CLI from Task 1, secret names from Global Constraints, the one-time re-auth caveat from the spec.

- [ ] **Step 1: Append failing checks (section 4)**

  1. README contains a signing/permissions section mentioning: `Packaging/create-signing-identity.sh`, the three secret names (`APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_KEYCHAIN_PASSWORD`), and that switching from an old build to a self-signed one triggers one final permission prompt (之后不再重复).
  2. Run-checks README path check (#2) still passes — any new quoted `*.app` path must be `DeepSeek Harness Bar.app`.

- [ ] **Step 2: Run to verify failure** — FAIL on section 4.

- [ ] **Step 3: Write the README section** (bilingual, following the existing 为什么用它/Why style): why permissions reset today (ad-hoc signature = new app identity per build), the one-time owner setup (run the script → p12 → base64 → three secrets), what CI does from the next tag on, the 10-year cert expiry note (regeneration costs one re-prompt round), and that contributors without the cert are unaffected (ad-hoc fallback).

- [ ] **Step 4: Run full checks; commit**

Run: `./Tests/run-checks.sh` — green.
Commit: `docs: self-signed signing setup for stable permissions`.

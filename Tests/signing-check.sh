#!/usr/bin/env bash
# Self-signed code-signing identity checks.
#
# Each block targets a failure that is silent until an update ships: a script
# that happily mints a fresh identity on every run resets the TCC privacy
# permissions every installed copy granted the app, a p12 that no parser
# accepts only surfaces as a CI import failure after the release is tagged,
# and a private key committed to the repository is a leak no later check can
# undo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
FAILED=0

fail() { echo "FAIL  $1"; FAILED=1; }
pass() { echo "ok    $1"; }

IDENTITY="DSH Bar Self-Signing"
SCRIPT="Packaging/create-signing-identity.sh"

# Scratch keychain lifetime: created for check 2, reused by check 3, deleted
# on exit. The login keychain is never touched by these checks.
SCRATCH_DIR=""
SCRATCH_KEYCHAIN=""
cleanup() {
    if [[ -n "$SCRATCH_KEYCHAIN" && -e "$SCRATCH_KEYCHAIN" ]]; then
        security delete-keychain "$SCRATCH_KEYCHAIN" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SCRATCH_DIR" && -d "$SCRATCH_DIR" ]]; then
        RESOLVED="$(cd "$SCRATCH_DIR" && pwd -P)"
        TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
        if [[ "$RESOLVED" == "$TMP_BASE"/dshbar-signing.* ]]; then
            rm -rf -- "$RESOLVED"
        fi
    fi
}
trap cleanup EXIT

# 1. The script must parse under the system bash 3.2 that runs these checks;
#    a bash 4-ism passes on a contributor's newer shell and dies in CI.
if bash -n "$SCRIPT" 2>/dev/null; then
    pass "create-signing-identity.sh parses under bash -n"
else
    fail "$SCRIPT does not exist or fails bash -n (system bash is 3.2)"
fi

# 2. End-to-end against a scratch keychain: the identity must land in the
#    target keychain under the codesigning policy and the p12 must parse —
#    the two things CI later does with the artifact. --skip-trust keeps the
#    run hermetic (add-trusted-cert writes per-user trust settings), which is
#    also why find-identity runs without -v here: -v lists *valid* identities
#    only, and an untrusted scratch identity (CSSMERR_TP_NOT_TRUSTED) never
#    appears in it. The parse pins /usr/bin/openssl for the same reason the
#    script's export does: a Homebrew OpenSSL 3/4 in PATH cannot read the
#    Apple-compatible legacy p12 without its legacy provider.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dshbar-signing.XXXXXX")"
SCRATCH_DIR="$TMP"
KEYCHAIN="$TMP/scratch.keychain-db"
SCRATCH_KEYCHAIN="$KEYCHAIN"
MINT_OK=1
security create-keychain -p testpw "$KEYCHAIN" >/dev/null 2>&1 || MINT_OK=0
security set-keychain-settings -lut 300 "$KEYCHAIN" >/dev/null 2>&1 || MINT_OK=0
security unlock-keychain -p testpw "$KEYCHAIN" >/dev/null 2>&1 || MINT_OK=0
bash "$SCRIPT" --keychain "$KEYCHAIN" --keychain-password testpw \
    --p12-out "$TMP/test.p12" --password testpw --skip-trust >/dev/null 2>&1 || MINT_OK=0
IDS="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
[[ "$IDS" == *"$IDENTITY"* ]] || MINT_OK=0
/usr/bin/openssl pkcs12 -in "$TMP/test.p12" -passin pass:testpw -noout >/dev/null 2>&1 || MINT_OK=0
if [[ "$MINT_OK" -eq 1 ]]; then
    pass "identity script mints a codesigning identity and a parseable p12 into a scratch keychain"
else
    fail "identity script must mint '$IDENTITY' into a scratch keychain and a p12 openssl can parse"
fi

# 3. Idempotency is the TCC contract: re-running against a keychain that
#    already holds the identity must refuse unless --force is passed, or a
#    careless re-run silently invalidates every granted permission.
if [[ "$IDS" == *"$IDENTITY"* ]]; then
    if bash "$SCRIPT" --keychain "$KEYCHAIN" --p12-out "$TMP/test2.p12" \
            --password testpw --skip-trust >/dev/null 2>&1; then
        fail "second run without --force must refuse to mint a new identity"
    else
        pass "second run without --force refuses to replace the existing identity"
    fi
else
    fail "idempotency not checkable: '$IDENTITY' never landed in the scratch keychain"
fi

# 4. The p12 is private key material; .gitignore is the only thing standing
#    between a local run and a committed key.
if git check-ignore -q dsh-bar-self-signing.p12; then
    pass ".gitignore covers dsh-bar-self-signing.p12"
else
    fail ".gitignore must cover dsh-bar-self-signing.p12 (private key material)"
fi

exit $FAILED

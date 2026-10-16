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

# 5. build.sh must gate --options runtime/--timestamp (notarization flags, and
#    a hard requirement on an Apple timestamp server) on a Developer ID
#    identity only. A self-signed identity carrying those flags fails at
#    signing time on every machine without notarization credentials — the
#    exact failure this plan exists to prevent.
if grep -q 'if \[\[ "$SIGNING_IDENTITY" == "Developer ID Application:"\* \]\]' build.sh; then
    pass "build.sh gates runtime/timestamp flags on Developer ID identities"
else
    fail "build.sh must gate runtime/timestamp on 'Developer ID Application:'* identities"
fi

# 6. With SIGNING_IDENTITY unset, build.sh must look up the long-lived
#    self-signed identity in the keychain instead of silently ad-hoc
#    signing — and must tell the user how to create it when absent.
if grep -q 'security find-identity' build.sh \
        && grep -q 'create-signing-identity.sh' build.sh; then
    pass "build.sh auto-detects the self-signed identity and hints at the creation script"
else
    fail "build.sh must auto-detect 'DSH Bar Self-Signing' and hint at Packaging/create-signing-identity.sh"
fi

# 7. Behavioral proof of the whole plan: two binaries signed by the same
#    self-signed identity must yield an IDENTICAL designated requirement
#    (what TCC matches on — this is why permissions survive updates), while
#    an ad-hoc binary's DR is cdhash-based and unique per build. Empirical
#    notes recorded in the SDD report: DR text comes from `codesign -d -r-`
#    (-drr prints nothing on this OS), it embeds the binary's identifier so
#    both copies are signed with a fixed -i to keep the comparison honest,
#    and a self-signed cert anchors as `certificate leaf = H"…"` rather than
#    the Apple-CA `anchor` form — the leaf hash is the TCC-stability property.
#    Signing goes through `codesign --keychain` because the scratch keychain
#    is deliberately not in the user's keychain search list.
DR_OK=1
if [[ "$MINT_OK" -eq 1 ]]; then
    DR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dshbar-signing.XXXXXX")"
    printf 'int main(){return 0;}\n' > "$DR_TMP/m.c"
    clang -o "$DR_TMP/bin1" "$DR_TMP/m.c" >/dev/null 2>&1 || DR_OK=0
    clang -o "$DR_TMP/bin2" "$DR_TMP/m.c" >/dev/null 2>&1 || DR_OK=0
    clang -o "$DR_TMP/bin3" "$DR_TMP/m.c" >/dev/null 2>&1 || DR_OK=0
    codesign --force --keychain "$KEYCHAIN" -i dshbar-dr-check \
        --sign "$IDENTITY" "$DR_TMP/bin1" >/dev/null 2>&1 || DR_OK=0
    codesign --force --keychain "$KEYCHAIN" -i dshbar-dr-check \
        --sign "$IDENTITY" "$DR_TMP/bin2" >/dev/null 2>&1 || DR_OK=0
    codesign --force --sign - "$DR_TMP/bin3" >/dev/null 2>&1 || DR_OK=0
    DR1="$(codesign -d -r- "$DR_TMP/bin1" 2>/dev/null | tr -s '[:space:]' ' ')"
    DR2="$(codesign -d -r- "$DR_TMP/bin2" 2>/dev/null | tr -s '[:space:]' ' ')"
    DR3="$(codesign -d -r- "$DR_TMP/bin3" 2>/dev/null | tr -s '[:space:]' ' ')"
    DR_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    [[ -n "$DR1" && "$DR1" == "$DR2" ]] || DR_OK=0
    [[ "$DR1" == *certificate\ leaf* ]] || DR_OK=0
    [[ "$DR3" == *cdhash* && "$DR1" != "$DR3" ]] || DR_OK=0
    if [[ -n "$DR_TMP" && -d "$DR_TMP" ]]; then
        RESOLVED="$(cd "$DR_TMP" && pwd -P)"
        if [[ "$RESOLVED" == "$DR_BASE"/dshbar-signing.* ]]; then
            rm -rf -- "$RESOLVED"
        fi
    fi
    if [[ "$DR_OK" -eq 1 ]]; then
        pass "same-identity binaries share an identical certificate-leaf DR; ad-hoc DR is cdhash"
    else
        fail "two self-signed binaries must share one certificate-leaf DR, and ad-hoc must differ"
    fi
else
    fail "DR stability not checkable: identity never minted in check 2"
fi

# 8. CI must import whichever identity the P12 carries — Developer ID when
#    present, else the project's self-signed cert — instead of hard-failing on
#    anything that is not Developer ID. The generic selector must pick the
#    first codesigning identity of ANY kind, and only the total absence of an
#    identity may fail the step; the Developer ID lookup is a preference
#    applied after that selection, so it may itself be an awk with exit.
if grep -q 'NR>1 && \$2 != ""' .github/workflows/release.yml \
        && grep -q 'No codesigning identity found' .github/workflows/release.yml \
        && ! grep -q 'No Developer ID Application identity found' .github/workflows/release.yml; then
    pass "release.yml selects any codesigning identity, preferring Developer ID"
else
    fail "release.yml identity selection must accept any identity (prefer Developer ID)"
fi

# 9. The import step must classify what it found so later steps can branch:
#    developer_id gates notarization (self-signed certs cannot be notarized),
#    signing_mode picks the release-note text.
if grep -q 'developer_id=' .github/workflows/release.yml \
        && grep -q 'signing_mode=' .github/workflows/release.yml; then
    pass "release.yml emits developer_id and signing_mode outputs"
else
    fail "release.yml import step must emit developer_id= and signing_mode= outputs"
fi

# 10. Notarization is only possible for Developer ID identities; running it
#     for a self-signed release wastes a release and fails at submit. The
#     gate must be developer_id, not the old configured flag.
if grep -q "if: steps.signing.outputs.developer_id == 'true'" .github/workflows/release.yml \
        && ! grep -q "if: steps.signing.outputs.configured == 'true'" .github/workflows/release.yml; then
    pass "notarize step gated on developer_id"
else
    fail "notarize step if: must be steps.signing.outputs.developer_id == 'true'"
fi

# 11. Release notes must explain three states in BOTH the markdown and the
#     HTML fragment. The self-signed branch is the one users actually read:
#     it must say permissions survive updates AND still carry the xattr -cr
#     quarantine instructions (un-notarized build). Three states × two
#     formats, with quarantine text in the self-signed and ad-hoc branches
#     of each, means exactly four xattr -cr lines.
if grep -q 'SIGNING_MODE: ${{ steps.signing.outputs.signing_mode }}' .github/workflows/release.yml \
        && grep -q 'permissions' .github/workflows/release.yml \
        && grep -q 'self-signed' .github/workflows/release.yml \
        && grep -c 'xattr -cr' .github/workflows/release.yml | grep -q '^4$'; then
    pass "notes step renders three signing states incl. xattr for self-signed"
else
    fail "notes step must branch on signing_mode with three distinct texts"
fi

exit $FAILED

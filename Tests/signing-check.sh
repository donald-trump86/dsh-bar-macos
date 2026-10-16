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
#    The selector must NOT use find-identity -v (which hides untrusted
#    identities — a fresh self-signed import is untrusted) and must NOT
#    skip line 1 (identity lines come first in find-identity output, so
#    NR>1 would drop the only identity).
if grep -q '$2 != ""' .github/workflows/release.yml \
        && ! grep -q 'NR>1' .github/workflows/release.yml \
        && ! grep -q 'find-identity -v' .github/workflows/release.yml \
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
#     of each, means exactly four xattr -cr lines. The greps are scoped to
#     the notes step (from the SIGNING_MODE env line to the appcast step) so
#     the 'permissions'/'self-signed' clauses can't be satisfied by the
#     workflow's permissions block or signing_mode output emissions.
NOTES_REGION="$(sed -n '/SIGNING_MODE: ${{ steps.signing.outputs.signing_mode }}/,/Generate EdDSA-signed appcast/p' .github/workflows/release.yml)"
if grep -q 'SIGNING_MODE: ${{ steps.signing.outputs.signing_mode }}' .github/workflows/release.yml \
        && grep -q 'permissions' <<<"$NOTES_REGION" \
        && grep -q 'self-signed' <<<"$NOTES_REGION" \
        && grep -q 'survive updates' <<<"$NOTES_REGION" \
        && grep -c 'xattr -cr' <<<"$NOTES_REGION" | grep -q '^4$'; then
    pass "notes step renders three signing states incl. xattr for self-signed"
else
    fail "notes step must branch on signing_mode with three distinct texts"
fi

# 12. The README is where users discover the self-signed option, so it must
#     document the whole setup: the identity script, the three secrets the
#     release workflow imports (the secret names are the CI contract — a
#     renamed secret only fails the build after the release is tagged), and
#     the one-time re-auth caveat: upgrading an installed build to the
#     self-signed cert prompts for permissions one final time, and a user
#     not warned about that prompt assumes a TCC reset. The greps pin the
#     stable identifiers (script name, secret names) and never the
#     bilingual heading text, which is free to be reworded.
if grep -q 'create-signing-identity.sh' README.md \
        && grep -q 'APPLE_CERT_P12_BASE64' README.md \
        && grep -q 'APPLE_CERT_PASSWORD' README.md \
        && grep -q 'APPLE_KEYCHAIN_PASSWORD' README.md \
        && grep -Eqi '不再重复|不会再|one final|prompt(s|ed)? once' README.md; then
    pass "README documents the self-signed setup: creation script, three CI secrets, one-time re-auth"
else
    fail "README must document the self-signed setup (create-signing-identity.sh, APPLE_CERT_P12_BASE64, APPLE_CERT_PASSWORD, APPLE_KEYCHAIN_PASSWORD, one-time re-auth caveat)"
fi

# 13. The README release-signing table must cover all three modes, not the
#     old Developer-ID/ad-hoc dichotomy: a self-signed release differs from
#     ad-hoc where users care (permissions stay stable) and from Developer
#     ID where Gatekeeper cares (un-notarized, so the xattr -cr workaround
#     applies to it too). 'Developer ID', 'ad-hoc' and 'xattr' all appear
#     elsewhere in the README, so the greps run on the table region only —
#     everything from the 发布包的签名和公证取决于仓库配置 intro down to the next
#     #### heading, filtered to table rows — and the self-signed
#     requirement is row-level: the 自签名 row itself must carry the
#     un-notarized caveat (未公证 or xattr), not merely exist in the file.
SIGNING_TABLE="$(awk '/发布包的签名和公证取决于仓库配置/{f=1;next} /^#### /{f=0} f' README.md 2>/dev/null)"
TABLE_ROWS="$(grep '^[[:space:]]*|' <<<"$SIGNING_TABLE")"
DEV_ID_ROW="$(grep 'Developer ID' <<<"$TABLE_ROWS" | grep -E '公证|notarized')"
SELF_SIGNED_ROW="$(grep -E '自签名|self-signed' <<<"$TABLE_ROWS" | grep -E 'xattr|未公证|not notarized')"
ADHOC_ROW="$(grep 'ad-hoc' <<<"$TABLE_ROWS")"
if [[ -n "$TABLE_ROWS" && -n "$DEV_ID_ROW" && -n "$SELF_SIGNED_ROW" && -n "$ADHOC_ROW" ]]; then
    pass "README signing table covers Developer ID, self-signed and ad-hoc modes"
else
    fail "README signing table must cover three modes: Developer ID (公证), 自签名 (未公证 + xattr), ad-hoc"
fi

# 14. CONTRIBUTING.md's signing note is the only signing guidance many
#     contributors read, so it must name the self-signed mode (releases are
#     Developer ID, self-signed or ad-hoc depending on configuration)
#     instead of the old two-way story. A missing file, or a note with no
#     signing mention at all, fails: the note exists today and this plan
#     only extends it.
if [[ -f CONTRIBUTING.md ]] && grep -qi 'signing' CONTRIBUTING.md \
        && grep -Eqi '自签名|self-signed' CONTRIBUTING.md; then
    pass "CONTRIBUTING.md signing note covers the self-signed mode"
else
    fail "CONTRIBUTING.md must exist and its signing note must mention the self-signed option (自签名/self-signed)"
fi

# 15. BEHAVIORAL: the release.yml identity selector must actually resolve
#     identities at runtime, not just match greps. Structural checks 8-10
#     missed a real defect (find-identity -v hides untrusted identities and
#     NR>1 skipped the only identity line) because greps can't execute the
#     selector. This check runs the exact CI import + selection flow against
#     three scratch-keychain scenarios: the project's self-signed P12
#     (untrusted — the -v pitfall), a Developer-ID-named P12, and an empty
#     keychain (must hard-fail with the exact message). Scratch keychains
#     only; login.keychain-db is never touched (the helper script owns the
#     trap-based cleanup).
if [[ -x Tests/selector-behavior.sh ]] && bash Tests/selector-behavior.sh >/dev/null 2>&1; then
    pass "identity selector resolves self-signed and Developer ID P12s at runtime"
else
    fail "identity selector must resolve the self-signed P12 at runtime (run Tests/selector-behavior.sh for details)"
fi

exit $FAILED

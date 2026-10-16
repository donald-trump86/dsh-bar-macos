#!/usr/bin/env bash
# Create the project's long-lived self-signed code-signing identity.
#
# macOS keys an app's TCC privacy permissions (screen recording,
# accessibility, ...) to its code-signing identity, so every build must be
# signed by the SAME identity or each Sparkle update arrives as a stranger
# and re-prompts for everything. Ad-hoc signing derives a new identity per
# build; this script mints the one certificate that must then live as long
# as the project does.

set -euo pipefail

IDENTITY_NAME="DSH Bar Self-Signing"
KEYCHAIN="login.keychain-db"
KEYCHAIN_PASSWORD=""
P12_OUT="./dsh-bar-self-signing.p12"
PASSWORD=""
SKIP_TRUST=0
FORCE=0

# securityd cannot parse the PKCS#12 that OpenSSL 3+/4 writes by default
# (the import dies with "MAC verification failed during PKCS12 import"), so
# the bundle must come from the system LibreSSL — never from PATH, where a
# Homebrew openssl may shadow it.
OPENSSL_BIN="/usr/bin/openssl"

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Create the "$IDENTITY_NAME" codesigning identity in an existing keychain and
export it as an encrypted p12 for CI.

Options:
  --keychain PATH         Existing keychain to hold the identity
                          (default: login.keychain-db). Never created here.
  --keychain-password PW  Password of the target keychain. When given, runs
                          security set-key-partition-list so codesign can
                          sign non-interactively later; skipped when absent.
  --p12-out PATH          Where to write the encrypted bundle
                          (default: ./dsh-bar-self-signing.p12).
  --password PW           Password encrypting the p12 (required).
  --skip-trust            Skip security add-trusted-cert; used by tests that
                          must not touch per-user trust settings.
  --force                 Proceed even if the identity already exists.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keychain)
            [[ $# -ge 2 ]] || { echo "error: --keychain requires a value" >&2; exit 2; }
            KEYCHAIN="$2"; shift 2 ;;
        --keychain-password)
            [[ $# -ge 2 ]] || { echo "error: --keychain-password requires a value" >&2; exit 2; }
            KEYCHAIN_PASSWORD="$2"; shift 2 ;;
        --p12-out)
            [[ $# -ge 2 ]] || { echo "error: --p12-out requires a value" >&2; exit 2; }
            P12_OUT="$2"; shift 2 ;;
        --password)
            [[ $# -ge 2 ]] || { echo "error: --password requires a value" >&2; exit 2; }
            PASSWORD="$2"; shift 2 ;;
        --skip-trust) SKIP_TRUST=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$PASSWORD" ]]; then
    echo "error: --password is required (it encrypts the exported p12)" >&2
    exit 1
fi

if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: keychain '$KEYCHAIN' does not exist — this script never creates keychains" >&2
    exit 1
fi

# Refuse to replace an existing identity: a different certificate makes macOS
# treat the next update as a new app and re-prompts every TCC permission on
# every installed copy. `find-identity -v` hides identities whose trust has
# not been confirmed, so the plain form is checked too — an identity imported
# with --skip-trust only shows up there.
if [[ "$FORCE" -eq 0 ]]; then
    VALID="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
    ALL="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
    if [[ "$VALID" == *"\"$IDENTITY_NAME\""* || "$ALL" == *"\"$IDENTITY_NAME\""* ]]; then
        echo "error: identity \"$IDENTITY_NAME\" already exists in $KEYCHAIN" >&2
        echo "       A new certificate resets the TCC privacy permissions every installed copy" >&2
        echo "       has granted the app. To mint a new one anyway, re-run with --force" >&2
        echo "       (the old certificate stays in the keychain until you remove it)." >&2
        exit 1
    fi
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dshbar-identity.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# LibreSSL has no `req -addext`, so the codeSigning extension rides in a
# config file. keyUsage is needed as well: without it the identity is listed
# "(Invalid Key Usage for policy)" even after being trusted.
cat > "$WORK/codesign.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $IDENTITY_NAME
[codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

"$OPENSSL_BIN" req -x509 -new -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY_NAME" -config "$WORK/codesign.cnf" -extensions codesign

"$OPENSSL_BIN" pkcs12 -export -out "$P12_OUT" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -password pass:"$PASSWORD"

security import "$P12_OUT" -P "$PASSWORD" -T /usr/bin/codesign -k "$KEYCHAIN"

if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
    # Without the partition list, every codesign run prompts to unlock the key.
    security set-key-partition-list -S apple-tool:,apple: \
        -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi

if [[ "$SKIP_TRUST" -eq 0 ]]; then
    security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    echo "note: when the target is the login keychain, macOS asks once to authorize trusting this certificate."
fi

echo "Identity \"$IDENTITY_NAME\" created in $KEYCHAIN; encrypted bundle written to $P12_OUT."
echo
echo "Next steps (CI secrets):"
echo "  base64 -i '$P12_OUT' | pbcopy → APPLE_CERT_P12_BASE64"
echo "  the --password value → APPLE_CERT_PASSWORD"
if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
    echo "  the --keychain-password value → APPLE_KEYCHAIN_PASSWORD"
fi
echo
echo "Keep this certificate for the project's lifetime: regenerating it later costs"
echo "every installed copy another round of TCC permission prompts."

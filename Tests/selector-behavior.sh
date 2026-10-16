#!/bin/bash
# Behavioral verification of the FIXED release.yml identity selector.
# Reproduces the CI import flow against scratch keychains:
#   scenario 1: self-signed P12 (untrusted) — must resolve, mode=self-signed
#   scenario 2: Developer-ID-named P12 (codeSigning EKU) — must resolve, mode=developer-id
#   scenario 3: empty keychain — must hard-fail with the exact error message
# Never touches login.keychain-db. Scratch keychains created under mktemp dirs.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'for kc in "$TMP"/*.keychain-db; do [ -e "$kc" ] && security delete-keychain "$kc" >/dev/null 2>&1; done; rm -rf "$TMP"' EXIT

run_selector() {
    # $1 = keychain path; emits the same outputs the CI step writes
    local KC="$1" OUT=""
    IDENTITY="$(security find-identity -p codesigning "$KC" \
        | awk -F'"' '$2 != "" {print $2; exit}')"
    DEVELOPER_IDENTITY="$(security find-identity -p codesigning "$KC" \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
    if [[ -z "$IDENTITY" ]]; then
        echo "HARD-FAIL: No codesigning identity found in the imported certificate."
        return 1
    fi
    if [[ -n "$DEVELOPER_IDENTITY" ]]; then
        IDENTITY="$DEVELOPER_IDENTITY"
        echo "developer_id=true"
        echo "signing_mode=developer-id"
    else
        echo "developer_id=false"
        echo "signing_mode=self-signed"
    fi
    echo "identity=$IDENTITY"
    return 0
}

FAILED=0

# --- Scenario 1: project self-signed P12 -----------------------------------
KC1="$TMP/s1.keychain-db"
security create-keychain -p testpass "$KC1" >/dev/null
bash "$REPO_ROOT/Packaging/create-signing-identity.sh" \
    --keychain "$KC1" --p12-out "$TMP/s1.p12" --password testpass --skip-trust >/dev/null 2>&1
[[ -f "$TMP/s1.p12" ]] || { echo "S1 setup failed: script did not mint p12"; exit 1; }
security import "$TMP/s1.p12" -P testpass -A -t cert -f pkcs12 -k "$KC1" >/dev/null 2>&1
OUT1="$(run_selector "$KC1")"
if [[ "$OUT1" == *"signing_mode=self-signed"* && "$OUT1" == *"DSH Bar Self-Signing"* ]]; then
    echo "S1 self-signed P12: OK -> $OUT1" | tr '\n' ' '; echo
else
    echo "S1 self-signed P12: FAILED -> $OUT1"; FAILED=1
fi

# --- Scenario 2: Developer-ID-named P12 -----------------------------------
KC2="$TMP/s2.keychain-db"
security create-keychain -p testpass "$KC2" >/dev/null
cat > "$TMP/openssl.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Developer ID Application: Test (TEAMID)
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k2.pem" -out "$TMP/c2.pem" \
    -days 2 -nodes -config "$TMP/openssl.cnf" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -out "$TMP/s2.p12" -inkey "$TMP/k2.pem" -in "$TMP/c2.pem" \
    -name "Developer ID Application: Test (TEAMID)" -passout pass:testpass >/dev/null 2>&1
security import "$TMP/s2.p12" -P testpass -A -t cert -f pkcs12 -k "$KC2" >/dev/null 2>&1
OUT2="$(run_selector "$KC2")"
if [[ "$OUT2" == *"signing_mode=developer-id"* && "$OUT2" == *"Developer ID Application"* ]]; then
    echo "S2 Developer ID P12: OK -> $OUT2" | tr '\n' ' '; echo
else
    echo "S2 Developer ID P12: FAILED -> $OUT2"; FAILED=1
fi

# --- Scenario 3: empty keychain → hard fail -------------------------------
KC3="$TMP/s3.keychain-db"
security create-keychain -p testpass "$KC3" >/dev/null
OUT3="$(run_selector "$KC3")"
RC3=$?
if [[ $RC3 -ne 0 && "$OUT3" == *"No codesigning identity found"* ]]; then
    echo "S3 empty keychain: OK (hard-fail with exact message)"
else
    echo "S3 empty keychain: FAILED rc=$RC3 -> $OUT3"; FAILED=1
fi

exit $FAILED

#!/bin/bash
# Create a stable, self-signed "FloatNote Dev" code-signing identity.
#
# WHY: macOS ties TCC permissions (Screen Recording, Microphone, …) to an app's
# code-signing *designated requirement*. An ad-hoc signature pins the exact cdhash,
# so every `./build.sh` rebuild changes the cdhash and macOS re-prompts for
# permission. Signing with a *stable* identity instead makes the DR
# `identifier "com.floatnote.app" and certificate leaf = H"<cert>"`, which stays
# constant across rebuilds — so you grant Screen Recording ONCE and it sticks.
#
# The cert is self-signed and therefore UNtrusted by the OS (CSSMERR_TP_NOT_TRUSTED).
# That is fine and expected: OS trust (Gatekeeper) is a separate check from the TCC
# DR match. `build.sh` matches it with `find-identity` WITHOUT `-v` for this reason.
#
# Run once per machine. Idempotent: re-running rebuilds the keychain from scratch.
set -euo pipefail

KC="$HOME/Library/Keychains/floatnote-dev.keychain-db"
KC_PW="floatnote-dev"        # password for the dedicated keychain (local dev only)
P12_PW="floatnote-dev"       # transient p12 export password
NAME="FloatNote Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Self-signed cert + private key with the codeSigning extended key usage.
cat > "$TMP/cert.cnf" <<'CNF'
[ req ]
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no
[ req_dn ]
CN = FloatNote Dev
[ codesign_ext ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"

# 2. Bundle into a PKCS#12. `-legacy` + SHA1 algs are REQUIRED — OpenSSL 3.x's
#    default PKCS12 MAC is rejected by Apple's `security import` ("MAC verification
#    failed"). A non-empty password is also required for the same reason.
openssl pkcs12 -export -legacy \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$NAME" -passout pass:"$P12_PW"

# 3. Dedicated keychain (keeps this out of the login keychain) with a known password,
#    so codesign never has to GUI-prompt for key access.
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings "$KC"                 # no auto-lock / timeout
security unlock-keychain -p "$KC_PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12_PW" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null

# 4. Add to the user keychain search list (preserving the existing entries) so
#    `codesign --sign "FloatNote Dev"` and `find-identity` can see it.
OLD=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
security list-keychains -d user -s "$KC" $OLD

echo "✅ '$NAME' code-signing identity ready:"
security find-identity -p codesigning "$KC" | grep "$NAME" || true
echo "Now run ./build.sh — the app will be signed with this identity."

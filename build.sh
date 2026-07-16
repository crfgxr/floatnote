#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/FloatNote"
pkill -f "FloatNote.app" 2>/dev/null || true

# Abort if the build fails — otherwise we'd silently deploy a stale binary.
if ! swift build -c release; then
    echo "❌ Build FAILED — /Applications/FloatNote.app NOT updated." >&2
    exit 1
fi

cp .build/release/FloatNote "/Applications/FloatNote.app/Contents/MacOS/FloatNote"
# Copy SPM resource bundle(s) (e.g. the vendored Excalidraw assets) so Bundle.module
# resolves them at runtime — without this the board's web assets would be missing.
for b in .build/release/*.bundle; do
    [ -e "$b" ] || continue
    rm -rf "/Applications/FloatNote.app/Contents/Resources/$(basename "$b")"
    cp -R "$b" "/Applications/FloatNote.app/Contents/Resources/"
done
cp Info.plist "/Applications/FloatNote.app/Contents/Info.plist"
cp AppIcon.icns "/Applications/FloatNote.app/Contents/Resources/AppIcon.icns"
touch "/Applications/FloatNote.app"
# Sign with the "FloatNote Dev" identity when present; otherwise ad-hoc.
# NOTE: "FloatNote Dev" is a self-signed dev cert, so it is UNtrusted by the OS
# (CSSMERR_TP_NOT_TRUSTED). We therefore match with `find-identity` WITHOUT `-v`
# (the `-v` "valid only" filter drops untrusted certs — do NOT add it back). OS trust
# is irrelevant here: what matters is that the signing identity is *stable* across
# rebuilds, so the app's designated requirement (bundle id + leaf cert) stays constant
# and macOS keeps TCC grants (Screen Recording, Mic, …) instead of re-prompting on
# every rebuild — which is exactly what ad-hoc signing (cdhash-pinned DR) could not do.
# Create the cert with: docs/dev-signing-cert.sh (self-signed, codeSigning EKU).
if security find-identity -p codesigning 2>/dev/null | grep -q "FloatNote Dev"; then
    # The dedicated floatnote-dev keychain re-locks (reboot/logout), and codesign
    # can't reach the private key when it's locked — it fails with
    # errSecInternalComponent and we'd silently regress to ad-hoc (the very cdhash
    # churn this identity exists to prevent). Unlock it first with the known dev
    # password (set by docs/dev-signing-cert.sh). Non-fatal if the keychain is
    # missing — the sign below will surface any real problem.
    security unlock-keychain -p "floatnote-dev" \
        "$HOME/Library/Keychains/floatnote-dev.keychain-db" 2>/dev/null || true
    # NO --options runtime: the app was never built for the hardened runtime (no
    # entitlements), and it isn't needed for TCC persistence — only a *stable* signing
    # identity is. Hardened runtime + a self-signed cert only adds AMFI strictness.
    codesign --force --deep --sign "FloatNote Dev" /Applications/FloatNote.app
else
    codesign --force --deep --sign - /Applications/FloatNote.app
fi
open /Applications/FloatNote.app
echo "Done — app updated and launched."

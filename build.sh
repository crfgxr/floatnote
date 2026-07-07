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
# Sign with the "FloatNote Dev" identity when present; otherwise ad-hoc —
# which is how the app has actually been running (no identity in the keychain,
# and the old script ignored the codesign failure silently).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "FloatNote Dev"; then
    codesign --force --deep --sign "FloatNote Dev" --options runtime /Applications/FloatNote.app
else
    codesign --force --deep --sign - /Applications/FloatNote.app
fi
open /Applications/FloatNote.app
echo "Done — app updated and launched."

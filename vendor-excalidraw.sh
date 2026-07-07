#!/bin/bash
# One-time (and on-upgrade) vendoring of Excalidraw into a self-contained, offline
# bundle under FloatNote/FloatNote/Resources/excalidraw. The normal ./build.sh does
# NOT run this — it only copies the already-vendored static assets. Re-run this when
# bumping the Excalidraw version in vendor/excalidraw/package.json.
set -euo pipefail
cd "$(dirname "$0")/vendor/excalidraw"
npm install
npm run build
echo "Excalidraw vendored into FloatNote/FloatNote/Resources/excalidraw"

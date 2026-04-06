#!/bin/bash
cd "$(dirname "$0")/FloatNote"
pkill -f "FloatNote.app" 2>/dev/null
swift build -c release 2>&1
cp .build/release/FloatNote "/Applications/FloatNote.app/Contents/MacOS/FloatNote"
codesign --force --sign - /Applications/FloatNote.app
open /Applications/FloatNote.app
echo "Done — app updated and launched."

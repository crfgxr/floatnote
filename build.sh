#!/bin/bash
cd "$(dirname "$0")/MyEvernote"
pkill -f "MyEvernote.app" 2>/dev/null
swift build -c release 2>&1
cp .build/release/MyEvernote "/Applications/MyEvernote.app/Contents/MacOS/MyEvernote"
open /Applications/MyEvernote.app
echo "Done — app updated and launched."

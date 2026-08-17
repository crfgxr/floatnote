#!/bin/bash
# Vendors SwiftTerm and applies FloatNote's patch.
#
# Why a fork: SwiftTerm's terminal snaps the viewport to the bottom on every
# byte of output. Its own `Terminal.scroll()` already honors a
# `Terminal.userScrolling` flag, but nothing upstream ever sets it — the
# terminal *view* has a separate, identically-named property — and the flag is
# `internal`, so it can't be set from FloatNote. The patch sets it in
# `scrollTo()` (every scroll path funnels through there) and adds
# `linesBelowViewport` / `scrollToBottom()` for the scroll-back pill.
#
# Run once per machine, and again after changing SWIFTTERM_VERSION. build.sh
# does NOT run this — it just builds whatever is already in vendor/.
set -euo pipefail

SWIFTTERM_VERSION="v1.13.0"
REPO="https://github.com/migueldeicaza/SwiftTerm.git"
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$ROOT/vendor/SwiftTerm"
PATCH="$ROOT/vendor/swiftterm-sticky-scroll.patch"

if [ -d "$DEST" ]; then
    echo "→ removing existing $DEST"
    rm -rf "$DEST"
fi

echo "→ cloning SwiftTerm $SWIFTTERM_VERSION"
git clone -q --depth 1 --branch "$SWIFTTERM_VERSION" "$REPO" "$DEST"

echo "→ applying $(basename "$PATCH")"
git -C "$DEST" apply --3way "$PATCH"

echo "✓ vendor/SwiftTerm ready ($SWIFTTERM_VERSION + FloatNote patch)"
echo "  FloatNote/Package.swift points at ../vendor/SwiftTerm"

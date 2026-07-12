#!/bin/sh
# Build GotBoxFinder.appex -- the macOS Finder Sync extension (status badges) --
# with FPC, and ad-hoc code-sign it. macOS only (needs the Cocoa/FinderSync
# frameworks + codesign).
#
#   packaging/macos/build-appex.sh [OUTDIR]
#
# The .appex is written to $OUTDIR/GotBoxFinder.appex (OUTDIR defaults to the
# repo root). Override the compiler with FPC=... and the version string embedded
# in Info.plist with VERSION=... (defaults to 0.5.0). CI copies the result into
# GotBox.app/Contents/PlugIns/ before building the .dmg.
#
# NOTE: ad-hoc signing (codesign -s -) only lets the extension load on the
# machine that built it (or after a manual Gatekeeper override). Distributing it
# to downloaded-.dmg users needs a Developer ID cert + notarization (future).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
outdir=${1:-$root}
ver=${VERSION:-0.5.0}
fpc=${FPC:-fpc}

appex="$outdir/GotBoxFinder.appex"
macos="$appex/Contents/MacOS"
res="$appex/Contents/Resources"

rm -rf "$appex"
mkdir -p "$macos" "$res"

# Info.plist (with the version substituted in, like the app bundle)
sed "s/__VERSION__/$ver/g" "$here/GotBoxFinder-Info.plist" \
    > "$appex/Contents/Info.plist"

# badge images loaded by the extension at runtime
cp "$root/assets/overlay-synced.png" \
   "$root/assets/overlay-modified.png" \
   "$root/assets/overlay-conflict.png" "$res/"

# build the extension executable straight into the bundle
mkdir -p "$root/lib/finderext"
"$fpc" -O2 -Fu"$root/src/core" -Fu"$root/src/mac" -FU"$root/lib/finderext" \
       -o"$macos/GotBoxFinder" "$root/gboxfinderext.lpr"

# ad-hoc sign the bundle (dev/self-built; see the note above)
codesign -s - --force --deep "$appex"

echo "built $appex"

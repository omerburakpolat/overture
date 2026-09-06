#!/bin/bash
# Packages an .app into a compressed DMG with an /Applications symlink.
# Usage: scripts/make-dmg.sh <path/to/Overture.app> <out.dmg>
set -euo pipefail
APP="${1:?app path required}"
OUT="${2:?output dmg path required}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# Sparkle vendors BSD-2 components whose clause 2 binds redistribution in
# binary form. The notices also ship inside the bundle (App/ is a
# synchronized group, so App/THIRD-PARTY-NOTICES.md lands in Resources);
# this copy makes them visible on the mounted volume too.
cp "$(dirname "$0")/../THIRD-PARTY-NOTICES.md" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname Overture -srcfolder "$STAGE" -fs APFS \
  -format UDZO -quiet "$OUT"

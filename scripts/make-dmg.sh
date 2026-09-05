#!/bin/bash
# Packages an .app into a compressed DMG with an /Applications symlink.
# Usage: scripts/make-dmg.sh <path/to/Overture.app> <out.dmg>
set -euo pipefail
APP="${1:?app path required}"
OUT="${2:?output dmg path required}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname Overture -srcfolder "$STAGE" -fs APFS \
  -format UDZO -quiet "$OUT"

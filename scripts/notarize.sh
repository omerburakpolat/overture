#!/bin/bash
# Notarizes and staples a DMG. One-time setup (docs/RELEASING.md):
#   xcrun notarytool store-credentials overture-notary \
#     --apple-id <id> --team-id B2DYXY7U9Y --password <app-specific-password>
set -euo pipefail
DMG="${1:?dmg path required}"
PROFILE="${OVERTURE_NOTARY_PROFILE:-overture-notary}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "Notarized and stapled: $DMG"

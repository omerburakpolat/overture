#!/bin/bash
# Notarizes and staples a DMG. Fails loudly on rejection (notarytool's
# --wait exits 0 even for Invalid) and prints Apple's issue log.
# One-time setup (docs/RELEASING.md):
#   xcrun notarytool store-credentials overture-notary \
#     --apple-id <id> --team-id B2DYXY7U9Y --password <app-specific-password>
set -euo pipefail
DMG="${1:?dmg path required}"
PROFILE="${OVERTURE_NOTARY_PROFILE:-overture-notary}"

RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" \
  --wait --output-format json)"
SUBMISSION_ID="$(echo "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
STATUS="$(echo "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
echo "Submission $SUBMISSION_ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "Notarized and stapled: $DMG"

#!/bin/bash
# Notarizes and staples a DMG. Fails loudly on rejection (notarytool's
# --wait exits 0 even for Invalid) and prints Apple's issue log.
#
# Two ways to authenticate, picked automatically:
#
#   App Store Connect API key (CI) — set all three:
#     NOTARY_KEY_PATH   path to the AuthKey_<KEYID>.p8
#     NOTARY_KEY_ID     the <KEYID> from that filename
#     NOTARY_ISSUER_ID  issuer UUID from App Store Connect → Integrations
#
#   Keychain profile (local, default) — one-time setup:
#     xcrun notarytool store-credentials overture-notary \
#       --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#       --key-id <KEYID> --issuer <ISSUER_ID>
#
# An API key is preferred over an Apple ID + app-specific password: it is not
# invalidated when the Apple ID password changes, needs no 2FA, and can be
# revoked on its own. See docs/RELEASING.md.
set -euo pipefail
DMG="${1:?dmg path required}"
PROFILE="${OVERTURE_NOTARY_PROFILE:-overture-notary}"

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_PATH set but NOTARY_KEY_ID is not}"
  : "${NOTARY_ISSUER_ID:?NOTARY_KEY_PATH set but NOTARY_ISSUER_ID is not}"
  [ -r "$NOTARY_KEY_PATH" ] || { echo "Cannot read key: $NOTARY_KEY_PATH" >&2; exit 1; }
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID"
        --issuer "$NOTARY_ISSUER_ID")
  echo "Authenticating with App Store Connect API key $NOTARY_KEY_ID"
else
  AUTH=(--keychain-profile "$PROFILE")
  echo "Authenticating with keychain profile $PROFILE"
fi

RESULT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" \
  --wait --output-format json)"
# plutil parses JSON and ships with macOS; python3 is not guaranteed on a
# clean runner, and a release must not die on a missing interpreter.
SUBMISSION_ID="$(printf '%s' "$RESULT" | plutil -extract id raw -o - -)"
STATUS="$(printf '%s' "$RESULT" | plutil -extract status raw -o - -)"
echo "Submission $SUBMISSION_ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" || true
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "Notarized and stapled: $DMG"

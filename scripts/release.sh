#!/bin/bash
# Builds, signs, and packages a release DMG.
# Usage: scripts/release.sh <version> [signing-identity]
#   e.g. scripts/release.sh 0.1.0
#        scripts/release.sh 0.1.0-dev "Apple Development"   (local smoke test)
# SYMROOT is forced local so machine-global Xcode build-location settings
# can't redirect the products.
set -euo pipefail
VERSION="${1:?version required (e.g. 0.1.0)}"
IDENTITY="${2:-Developer ID Application}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
TEAM="${OVERTURE_TEAM_ID:-B2DYXY7U9Y}"

# App/THIRD-PARTY-NOTICES.md is the copy that gets bundled (App/ is a
# synchronized group); the root one is what people read on GitHub. They
# must not drift — a stale bundled copy is an attribution failure that
# nothing else would catch.
if ! cmp -s "$ROOT/THIRD-PARTY-NOTICES.md" "$ROOT/App/THIRD-PARTY-NOTICES.md"; then
  echo "ERROR: THIRD-PARTY-NOTICES.md differs from App/THIRD-PARTY-NOTICES.md" >&2
  echo "Run: cp THIRD-PARTY-NOTICES.md App/THIRD-PARTY-NOTICES.md" >&2
  exit 1
fi

rm -rf "$BUILD"
xcodebuild -project "$ROOT/Overture.xcodeproj" -scheme Overture \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD/DerivedData" \
  SYMROOT="$BUILD/Products" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | tail -3

APP="$BUILD/Products/Release/Overture.app"

# Sparkle ships pre-signed by its own project; notarization requires OUR
# Developer ID + secure timestamp on every nested executable. Re-sign
# inside-out (per Sparkle's own signing guidance), then reseal the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for XPC in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
    codesign -f -o runtime --timestamp --preserve-metadata=entitlements \
      -s "$IDENTITY" "$XPC"
  done
  codesign -f -o runtime --timestamp -s "$IDENTITY" \
    "$SPARKLE/Versions/B/Autoupdate"
  codesign -f -o runtime --timestamp -s "$IDENTITY" \
    "$SPARKLE/Versions/B/Updater.app"
  codesign -f -o runtime --timestamp -s "$IDENTITY" "$SPARKLE"
fi
codesign -f -o runtime --timestamp \
  --entitlements "$ROOT/App/Overture.entitlements" \
  -s "$IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"
# get-task-allow must NOT appear in a distribution build.
if codesign --display --entitlements - "$APP" 2>/dev/null \
    | grep -q get-task-allow; then
  echo "ERROR: get-task-allow entitlement present" >&2
  exit 1
fi
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Authority|flags' | head -3
"$ROOT/scripts/make-dmg.sh" "$APP" "$ROOT/build/Overture-$VERSION.dmg"
# Sign the disk image itself, not just the app inside it. Without this the
# DMG carries only a stapled notarization ticket, and `spctl --context
# context:primary-signature` reports "rejected: no usable signature" on a
# perfectly good build — which reads as a compromised download to anyone
# who checks. Must happen before notarization so the staple covers it.
codesign -f --timestamp -s "$IDENTITY" "$ROOT/build/Overture-$VERSION.dmg"
codesign --verify --strict "$ROOT/build/Overture-$VERSION.dmg"
echo "DMG: $ROOT/build/Overture-$VERSION.dmg"
echo "Next (distribution builds): scripts/notarize.sh build/Overture-$VERSION.dmg"

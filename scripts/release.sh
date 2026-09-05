#!/bin/bash
# Builds, signs, and packages a release DMG.
# Usage: scripts/release.sh <version> [signing-identity]
#   e.g. scripts/release.sh 0.1.0
#        scripts/release.sh 0.1.0-dev "Apple Development"   (local smoke test)
# Default identity requires a Developer ID Application certificate
# (docs/RELEASING.md). SYMROOT is forced local so machine-global Xcode
# build-location settings can't redirect the products.
set -euo pipefail
VERSION="${1:?version required (e.g. 0.1.0)}"
IDENTITY="${2:-Developer ID Application}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
TEAM="${OVERTURE_TEAM_ID:-B2DYXY7U9Y}"

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
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | tail -3

APP="$BUILD/Products/Release/Overture.app"
codesign --verify --deep --strict "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Authority|flags' | head -4
"$ROOT/scripts/make-dmg.sh" "$APP" "$ROOT/build/Overture-$VERSION.dmg"
echo "DMG: $ROOT/build/Overture-$VERSION.dmg"
echo "Next (distribution builds): scripts/notarize.sh build/Overture-$VERSION.dmg"

#!/bin/bash
# Build the current working tree and run it, replacing whatever is already
# running. This is the "let me try my change" loop — not a release.
#
#   scripts/run-local.sh              # Debug, fastest
#   scripts/run-local.sh Release      # Release, what users get
#
# Why this exists: several copies of Overture.app can sit on disk at once (a
# brew-installed release, an Xcode Debug build, a Release build, an old rc).
# They all share the bundle id dev.overture.Overture, so `open` and the Dock
# hand focus to whichever LaunchServices saw last — you end up looking at a
# stale build and believing it is your change. This always runs the one it
# just built, and says so.
#
# SYMROOT is forced local because machine-global Xcode build-location settings
# otherwise redirect the products somewhere unrelated.
set -euo pipefail
CONFIG="${1:-Debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/local"
APP="$BUILD/Products/$CONFIG/Overture.app"

echo "Building $CONFIG…"
xcodebuild -project "$ROOT/Overture.xcodeproj" -scheme Overture \
  -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD/DerivedData" SYMROOT="$BUILD/Products" \
  build | tail -2

[ -d "$APP" ] || { echo "Expected app at $APP" >&2; exit 1; }

# Quit any running copy — including one from a different path. Without this,
# `open` just focuses the old process and nothing appears to change.
if pgrep -x Overture > /dev/null; then
  RUNNING="$(ps -p "$(pgrep -x Overture | head -1)" -o comm= | sed 's|/Contents/MacOS/Overture||')"
  echo "Quitting running copy: $RUNNING"
  osascript -e 'quit app "Overture"' 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x Overture > /dev/null || break; sleep 0.25; done
  pgrep -x Overture > /dev/null && { echo "Overture would not quit — quit it manually" >&2; exit 1; }
fi

echo "Launching $APP"
open -a "$APP"

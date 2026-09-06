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

# Quit EVERY running copy, not just one — including copies from other paths.
# Without this, `open` just focuses an old process and nothing appears to
# change. All copies share the bundle id, so a single survivor is enough to
# steal the launch: quitting only the lowest pid left this script failing in
# exactly the multi-copy case it exists for.
PIDS="$(pgrep -x Overture 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  for pid in $PIDS; do
    RUNNING="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's|/Contents/MacOS/Overture||' || true)"
    [ -n "$RUNNING" ] && echo "Quitting running copy: $RUNNING (pid $pid)"
  done

  # Ask nicely first so the app can save state.
  osascript -e 'quit app "Overture"' 2>/dev/null || true
  for _ in $(seq 1 20); do
    still=""
    for pid in $PIDS; do kill -0 "$pid" 2>/dev/null && still="$still $pid"; done
    [ -z "$still" ] && break
    sleep 0.25
  done

  # `quit app` addresses one process by name; anything else still up gets a
  # TERM, which is still a graceful AppKit shutdown.
  if [ -n "$still" ]; then
    for pid in $still; do kill -TERM "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 20); do
      still=""
      for pid in $PIDS; do kill -0 "$pid" 2>/dev/null && still="$still $pid"; done
      [ -z "$still" ] && break
      sleep 0.25
    done
  fi

  if [ -n "$still" ]; then
    echo "These copies would not quit — quit them manually:" >&2
    for pid in $still; do
      echo "  pid $pid  $(ps -p "$pid" -o comm= 2>/dev/null || echo '<gone>')" >&2
    done
    exit 1
  fi
fi

echo "Launching $APP"
open -a "$APP"

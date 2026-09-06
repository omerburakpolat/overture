#!/bin/bash
# Remove build artifacts. Everything deleted here is gitignored and
# regenerable — no source, no signing material, no release asset that is not
# already published on GitHub.
#
#   scripts/clean.sh --dry-run   # show what would go, delete nothing
#   scripts/clean.sh             # delete
#
# Refuses to run while Overture is running from inside the repo: scripts/
# run-local.sh launches out of build/, and deleting a running app bundle
# leaves the process alive with its resources yanked out from under it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# rm -rf below is derived from $0. Invoked through a symlink, or copied
# elsewhere, that could point somewhere entirely unrelated — so prove this
# is actually the repo before deleting anything.
[ -e "$ROOT/Overture.xcodeproj" ] || {
  echo "refusing to clean: $ROOT is not the Overture repo" >&2
  exit 1
}

# Every running copy, not just the lowest pid: a brew-installed Overture in
# /Applications routinely outlives the one built here, and if it happened to
# hold the lower pid the in-repo copy went unnoticed and got deleted anyway.
for pid in $(pgrep -x Overture 2>/dev/null || true); do
  RUNNING="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  case "$RUNNING" in
    "$ROOT"/*)
      echo "Overture is running from inside the repo:" >&2
      echo "  ${RUNNING%/Contents/MacOS/Overture} (pid $pid)" >&2
      echo "Quit it first:  osascript -e 'quit app \"Overture\"'" >&2
      exit 1
      ;;
  esac
done

# .build*  SwiftPM caches, including the per-agent scratch dirs
# build/    xcodebuild products, DerivedData, and locally built DMGs
# dist/     release staging for generate_appcast
TARGETS=(.build .build-app .build-main build dist)

TOTAL=0
for t in "${TARGETS[@]}"; do
  path="$ROOT/$t"
  [ -e "$path" ] || continue
  size="$(du -sk "$path" 2>/dev/null | cut -f1)"
  TOTAL=$((TOTAL + size))
  printf '  %-14s %s\n' "$t" "$(du -sh "$path" 2>/dev/null | cut -f1)"
  [ "$DRY" -eq 1 ] || rm -rf "$path"
done

HUMAN="$(echo "$TOTAL" | awk '{printf "%.1fG", $1/1048576}')"
if [ "$DRY" -eq 1 ]; then
  echo "Would reclaim $HUMAN. Nothing deleted (--dry-run)."
else
  echo "Reclaimed $HUMAN."
  echo "Next build refetches SwiftPM dependencies and recompiles from scratch."
fi

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
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if pgrep -x Overture > /dev/null; then
  RUNNING="$(ps -p "$(pgrep -x Overture | head -1)" -o comm= 2>/dev/null || true)"
  case "$RUNNING" in
    "$ROOT"/*)
      echo "Overture is running from inside the repo:" >&2
      echo "  ${RUNNING%/Contents/MacOS/Overture}" >&2
      echo "Quit it first:  osascript -e 'quit app \"Overture\"'" >&2
      exit 1
      ;;
  esac
fi

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

#!/bin/bash
# Reserve the build number before Xcode reads build settings; never change MARKETING_VERSION.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios) DESTINATION='generic/platform=iOS' ;;
  macos) DESTINATION='generic/platform=macOS' ;;
  *) echo 'usage: scripts/archive_app_store.sh [ios|macos] [archive-path]' >&2; exit 2 ;;
esac
ARCHIVE="${2:-${TMPDIR:-/tmp}/RideIntercom-${PLATFORM}-$(date +%Y%m%d-%H%M%S).xcarchive}"
case "$ARCHIVE" in /*) ;; *) ARCHIVE="$PWD/$ARCHIVE" ;; esac
if [ -e "$ARCHIVE" ]; then echo "Archive already exists: $ARCHIVE" >&2; exit 2; fi
cd "$ROOT"
# agvtool updates the project on disk. Xcode must not save a stale in-memory copy over it.
if pgrep -x Xcode >/dev/null; then
  echo 'Close Xcode before reserving the distribution build number, then run this command again.' >&2
  exit 2
fi
# Serialize this entrypoint for the same checkout. A failed Archive still consumes its number.
LOCK="$ROOT/.archive-app-store.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another distribution build is running (or its lock remains): $LOCK" >&2
  exit 2
fi
trap 'rmdir "$LOCK"' EXIT
xcrun agvtool -noscm next-version
xcodebuild archive -project RideIntercom.xcodeproj -scheme RideIntercom \
  -configuration Release -destination "$DESTINATION" -archivePath "$ARCHIVE" \
  -derivedDataPath "${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/RideIntercom-DistributionDerivedData}"
printf 'Archive created: %s\nExport without renumbering: xcodebuild -exportArchive -archivePath "%s" -exportOptionsPlist "%s/scripts/ExportOptions.plist" -exportPath <output-directory>\n' "$ARCHIVE" "$ARCHIVE" "$ROOT"

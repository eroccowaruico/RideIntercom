#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/RideIntercom-RunDerivedData}"
mkdir -p "$DERIVED"
DERIVED="$(cd "$DERIVED" && pwd -P)"
case "$DERIVED/" in "$ROOT/"*) echo 'DERIVED_DATA_PATH must be outside the synchronized repository' >&2; exit 2;; esac
APP="$DERIVED/Build/Products/Debug/RideIntercom.app"
BINARY="$APP/Contents/MacOS/RideIntercom"
MODE="${1:---verify}"
case "$MODE" in run|--verify|--logs|--debug) ;; *) echo 'usage: scripts/build_and_run.sh [run|--verify|--logs|--debug]' >&2; exit 2;; esac
# Stop only the executable built by this entry point, not other checkouts or tests.
while read -r pid; do
  [ -z "$pid" ] || kill -TERM "$pid"
done < <(ps -axo pid=,comm= | awk -v target="$BINARY" '{pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == target) print pid}')
xcodebuild build -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" > "$DERIVED/build.log" 2>&1 || { tail -n 40 "$DERIVED/build.log"; exit 1; }
if [ "$MODE" = --debug ]; then exec lldb -- "$BINARY"; fi
open -n "$APP"
if [ "$MODE" = --logs ]; then exec /usr/bin/log stream --info --style compact --predicate 'process == "RideIntercom"'; fi
if [ "$MODE" = --verify ]; then
  sleep 2
  ps -axo comm= | awk -v target="$BINARY" '$0 == target {found=1} END {exit !found}'
  printf 'Build and launch verified: %s\n' "$APP"
fi

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:---verify}"
case "$MODE" in run|--verify|--logs|--debug) ;; *) echo 'usage: scripts/build_and_run.sh [run|--verify|--logs|--debug]' >&2; exit 2;; esac
SETTINGS="$(python3 "$ROOT/scripts/xcode_paths.py" --scheme RideIntercom --destination 'platform=macOS,arch=arm64' --action LaunchAction)"
IFS=$'\t' read -r CONFIGURATION APP <<< "$SETTINGS"
BINARY="$APP/Contents/MacOS/RideIntercom"
mkdir -p "$ROOT/.validation"
LOG="$ROOT/.validation/build-and-run.log"
xcodebuild build -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -configuration "$CONFIGURATION" > "$LOG" 2>&1 || { tail -n 40 "$LOG"; exit 1; }
if [ "$MODE" = --debug ]; then exec lldb -- "$BINARY"; fi
open "$APP"
if [ "$MODE" = --logs ]; then exec /usr/bin/log stream --info --style compact --predicate 'process == "RideIntercom"'; fi
if [ "$MODE" = --verify ]; then
  sleep 2
  ps -axo comm= | awk -v target="$BINARY" '$0 == target {found=1} END {exit !found}'
  printf 'Build and launch verified: %s\n' "$APP"
fi

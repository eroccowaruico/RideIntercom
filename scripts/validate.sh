#!/bin/bash
# One reproducible validation entry point. No deployment and no user-data reset.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="${VALIDATION_DIR:-$ROOT/.validation/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STATUS=0
printf 'stage\texit_code\n' > "$OUT/results.tsv"
run() {
  local name="$1"; shift
  printf 'Running %s\n' "$name"
  "$@" > "$OUT/$name.log" 2>&1
  local code=$?
  printf '%s\t%s\n' "$name" "$code" >> "$OUT/results.tsv"
  if [ "$code" -ne 0 ]; then tail -n 25 "$OUT/$name.log"; STATUS=1; fi
}
{
  git rev-parse HEAD
  git status --short
  sw_vers
  xcodebuild -version
  swift --version
  node --version
  npm --version
  cat RideIntercom.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  cat RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.metadata
} > "$OUT/environment.txt" 2>&1
MODE="${1:-all}"
case "$MODE" in all|packages|worker|macos|ios|scripts) ;; *) echo 'usage: scripts/validate.sh [all|packages|worker|macos|ios|scripts]' >&2; exit 2;; esac
if [ "$MODE" = all ] || [ "$MODE" = packages ]; then
  for package in AudioCore AudioMixer Codec SessionManager; do
    run "package-$package" swift test --package-path "RideIntercom/packages/Audio/$package"
  done
  for package in DynamicsProcessor PeakLimiter SoundIsolation VADGate; do
    run "package-$package" swift test --package-path "RideIntercom/packages/Audio/Effectors/$package"
  done
  run package-RTC swift test --package-path RideIntercom/packages/RTC
  run native-WebRTC swift build --package-path RideIntercom/packages/RTC --target RTCNativeWebRTC
fi
if [ "$MODE" = all ] || [ "$MODE" = worker ]; then
  run worker-install npm --prefix server ci
  run worker-types npm --prefix server run type-check
  run worker-test npm --prefix server test
fi
if [ "$MODE" = all ] || [ "$MODE" = scripts ]; then
  run webrtc-scripts python3 -m unittest discover -s scripts/tests
fi
if [ "$MODE" = all ] || [ "$MODE" = macos ]; then
  run macos-tests xcodebuild test -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests -derivedDataPath "$OUT/DerivedData-macOS" -resultBundlePath "$OUT/macos-tests.xcresult"
fi
if [ "$MODE" = all ] || [ "$MODE" = ios ]; then
  # Always a new dedicated simulator. Never erase or uninstall on a user's device.
  RUNTIME="${SIMULATOR_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["isAvailable"] and x["name"].startswith("iOS")]; print(sorted(r,key=lambda x: tuple(map(int,x["version"].split("."))))[-1]["identifier"])')}"
  DEVICE="${SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
  SIM=$(xcrun simctl create "RideIntercom Validation $(date +%Y%m%d-%H%M%S)" "$DEVICE" "$RUNTIME") || exit 1
  printf '%s\n' "$SIM" > "$OUT/simulator-id.txt"
  trap 'xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true' EXIT
  run simulator-boot xcrun simctl boot "$SIM"
  run simulator-ready xcrun simctl bootstatus "$SIM" -b
  run ios-tests xcodebuild test -project RideIntercom.xcodeproj -scheme RideIntercom -destination "platform=iOS Simulator,id=$SIM" -parallel-testing-enabled NO -derivedDataPath "$OUT/DerivedData-iOS" -resultBundlePath "$OUT/ios-tests.xcresult"
fi
printf 'Results: %s\n' "$OUT/results.tsv"
cat "$OUT/results.tsv"
exit "$STATUS"

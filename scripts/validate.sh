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
if [ -e "$OUT/results.tsv" ]; then
  echo "Validation output already exists; use a new VALIDATION_DIR: $OUT" >&2
  exit 2
fi
STATUS=0
printf 'stage\texit_code\n' > "$OUT/results.tsv"
run() {
  local name="$1"; shift
  printf 'Running %s\n' "$name"
  "$@" > "$OUT/$name.log" 2>&1
  local code=$?
  if [[ "$name" == *-tests ]] && [ -d "$OUT/$name.xcresult" ]; then
    xcrun xcresulttool get test-results summary --path "$OUT/$name.xcresult" > "$OUT/$name-summary.json" 2> "$OUT/$name-summary.log"
    if ! python3 - "$OUT/$name-summary.json" <<'CHECK'
import json,sys
s=json.load(open(sys.argv[1]))
assert s.get('totalTestCount', 0) > 0, 'No tests executed'
assert s.get('failedTests', 0) == 0 and s.get('passedTests', 0) > 0, 'Tests did not pass'
CHECK
    then code=1; fi
  fi
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
case "$MODE" in all|headless|packages|worker|pair|macos|ios|ios-ui|scripts) ;; *) echo 'usage: scripts/validate.sh [all|headless|packages|worker|pair|macos|ios|ios-ui|scripts]' >&2; exit 2;; esac
run development-setup python3 scripts/check_development_setup.py
if [ "$STATUS" -ne 0 ]; then exit "$STATUS"; fi
if [ "$MODE" = all ] || [ "$MODE" = headless ] || [ "$MODE" = packages ]; then
  for package in AudioCore AudioMixer Codec SessionManager; do
    run "package-$package" swift test --package-path "RideIntercom/packages/Audio/$package"
  done
  for package in DynamicsProcessor PeakLimiter SoundIsolation VADGate; do
    run "package-$package" swift test --package-path "RideIntercom/packages/Audio/Effectors/$package"
  done
  run package-RTC swift test --package-path RideIntercom/packages/RTC
  run native-WebRTC swift build --package-path RideIntercom/packages/RTC --target RTCNativeWebRTC
fi
if [ "$MODE" = all ] || [ "$MODE" = headless ] || [ "$MODE" = worker ] || [ "$MODE" = pair ]; then
  run worker-install npm --prefix server ci
  run worker-types npm --prefix server run type-check
  run worker-test npm --prefix server test
fi
if [ "$MODE" = all ] || [ "$MODE" = headless ] || [ "$MODE" = pair ]; then
  run swift-worker-pair npm --prefix server run test:pair
fi
if [ "$MODE" = all ] || [ "$MODE" = headless ] || [ "$MODE" = scripts ]; then
  run development-setup-tests python3 -m unittest discover -s scripts/tests -p test_development_setup.py
  run webrtc-scripts python3 -m unittest discover -s scripts/tests -p test_webrtc_scripts.py
  run cloudflare-scripts node --test scripts/Cloudflare/estimate-cost.test.mjs scripts/Cloudflare/issue-device.test.mjs
fi
if [ "$MODE" = all ] || [ "$MODE" = macos ]; then
  run macos-tests xcodebuild test -project RideIntercom.xcodeproj -scheme RideIntercom -destination 'platform=macOS,arch=arm64' -only-testing:RideIntercomTests -derivedDataPath "${VALIDATION_DERIVED_DATA:-$OUT}/DerivedData-macOS" -resultBundlePath "$OUT/macos-tests.xcresult"
fi
if [ "$MODE" = all ] || [ "$MODE" = ios ] || [ "$MODE" = ios-ui ]; then
  # Always a new dedicated simulator. Never erase or uninstall on a user's device.
  RUNTIME="${SIMULATOR_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["isAvailable"] and x["name"].startswith("iOS")]; print(sorted(r,key=lambda x: tuple(map(int,x["version"].split("."))))[-1]["identifier"])')}"
  DEVICE="${SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
  SIM=$(xcrun simctl create "RideIntercom Validation $(date +%Y%m%d-%H%M%S)" "$DEVICE" "$RUNTIME") || exit 1
  printf '%s\n' "$SIM" > "$OUT/simulator-id.txt"
  trap 'xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true' EXIT
  run simulator-boot xcrun simctl boot "$SIM"
  run simulator-ready xcrun simctl bootstatus "$SIM" -b
  run simulator-appearance xcrun simctl ui "$SIM" appearance "${SIMULATOR_APPEARANCE:-dark}"
  TEST_COMMAND=(xcodebuild test)
  if [ "$MODE" = ios-ui ]; then TEST_COMMAND+=(-only-testing:RideIntercomUITests); fi
  run ios-tests "${TEST_COMMAND[@]}" -project RideIntercom.xcodeproj -scheme RideIntercom -destination "platform=iOS Simulator,id=$SIM" -parallel-testing-enabled NO -derivedDataPath "${VALIDATION_DERIVED_DATA:-$OUT}/DerivedData-iOS" -resultBundlePath "$OUT/ios-tests.xcresult"
fi
printf 'Results: %s\n' "$OUT/results.tsv"
cat "$OUT/results.tsv"
exit "$STATUS"

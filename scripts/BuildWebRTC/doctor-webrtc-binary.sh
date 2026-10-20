#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_PARENT="$(cd "${REPOSITORY_ROOT}/.." && pwd)"

default_developer_dir() {
  local selected=""
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "${selected}" && "${selected}" != *CommandLineTools* ]]; then
    echo "${selected}"
    return
  fi

  local xcode_app=""
  xcode_app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1 || true)"
  if [[ -n "${xcode_app}" && -d "${xcode_app}/Contents/Developer" ]]; then
    echo "${xcode_app}/Contents/Developer"
    return
  fi

  echo "${selected}"
}

RTC_PACKAGE_DIR="${RTC_PACKAGE_DIR:-${REPOSITORY_ROOT}/RideIntercom/packages/RTC}"
WEBRTC_BUILD_ROOT="${WEBRTC_BUILD_ROOT:-${REPOSITORY_PARENT}/webrtc-build}"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-${REPOSITORY_PARENT}/depot_tools}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(default_developer_dir)}"
RUN_SWIFTPM_CHECK="${RUN_SWIFTPM_CHECK:-true}"

status=0

ok() { echo "OK: $1"; }
warn() { echo "WARN: $1"; }
fail() { echo "FAIL: $1"; status=1; }

next_action() {
  echo "NEXT: $1"
}

check_path() {
  local path="$1"
  local label="$2"
  local action="$3"
  if [[ -e "${path}" ]]; then
    ok "${label}: ${path}"
  else
    fail "${label} not found: ${path}"
    next_action "${action}"
  fi
}

echo "WebRTC binary doctor"
echo "Repository: ${REPOSITORY_ROOT}"
echo "RTC package: ${RTC_PACKAGE_DIR}"
echo "Build root: ${WEBRTC_BUILD_ROOT}"
echo

check_path "${DEVELOPER_DIR}/usr/bin/xcodebuild" "Xcode Developer directory" "Set DEVELOPER_DIR to an installed Xcode Developer directory, or switch xcode-select to Xcode."
check_path "${DEPOT_TOOLS_DIR}/gclient" "depot_tools gclient" "DEPOT_TOOLS_DIR=/path/to/depot_tools scripts/BuildWebRTC/update-webrtc-binary.sh"
check_path "${DEPOT_TOOLS_DIR}/fetch" "depot_tools fetch" "DEPOT_TOOLS_DIR=/path/to/depot_tools scripts/BuildWebRTC/update-webrtc-binary.sh"

echo
if branch="$(${SCRIPT_DIR}/resolve-webrtc-branch.sh 2>/dev/null)"; then
  ok "Current stable WebRTC branch resolves to ${branch}"
else
  warn "Could not resolve current WebRTC branch from Chromium Dashboard"
  next_action "Run with WEBRTC_BRANCH=branch-heads/<number> scripts/BuildWebRTC/update-webrtc-binary.sh"
fi

echo
if [[ -d "${WEBRTC_BUILD_ROOT}/src" ]]; then
  ok "WebRTC source checkout exists"
else
  warn "WebRTC source checkout does not exist"
  next_action "scripts/BuildWebRTC/update-webrtc-binary.sh will fetch it automatically"
fi

base_outputs=(
  "ios-arm64-device/WebRTC.framework"
  "ios-x64-simulator/WebRTC.framework"
  "ios-arm64-simulator/WebRTC.framework"
  "macos-x64/WebRTC.framework"
  "macos-arm64/WebRTC.framework"
)

missing_base=0
for output in "${base_outputs[@]}"; do
  if [[ -d "${WEBRTC_BUILD_ROOT}/src/out/${output}" ]]; then
    ok "Build output exists: ${output}"
  else
    warn "Build output missing: ${output}"
    missing_base=1
  fi
done
if [[ "${missing_base}" -ne 0 ]]; then
  next_action "Run scripts/BuildWebRTC/update-webrtc-binary.sh to build missing outputs"
fi

echo
if [[ -d "${WEBRTC_BUILD_ROOT}/src/out/WebRTC.xcframework" ]]; then
  if "${SCRIPT_DIR}/verify-webrtc-xcframework.sh" "${WEBRTC_BUILD_ROOT}/src/out/WebRTC.xcframework" >/dev/null; then
    ok "Generated WebRTC.xcframework header verification passed"
  else
    fail "Generated WebRTC.xcframework header verification failed"
    next_action "ASSEMBLE_ONLY=true IOS=true MACOS=true scripts/BuildWebRTC/build-webrtc-xcframework.sh"
  fi
else
  warn "Generated WebRTC.xcframework does not exist"
  next_action "scripts/BuildWebRTC/update-webrtc-binary.sh"
fi

zip_path="$(find "${WEBRTC_BUILD_ROOT}/src/out" -maxdepth 1 -type f -name 'WebRTC-*.xcframework.zip' -print 2>/dev/null | sort | tail -1 || true)"
if [[ -n "${zip_path}" ]]; then
  ok "Generated zip exists: ${zip_path}"
  shasum -a 256 "${zip_path}"
else
  warn "Generated WebRTC zip does not exist"
  next_action "scripts/BuildWebRTC/update-webrtc-binary.sh"
fi

echo
imported_zip="${RTC_PACKAGE_DIR}/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip"
metadata="${RTC_PACKAGE_DIR}/BinaryArtifacts/WebRTC/WebRTC.xcframework.metadata"
if [[ -f "${imported_zip}" ]]; then
  ok "Imported binary target zip exists"
  shasum -a 256 "${imported_zip}"
else
  fail "Imported binary target zip does not exist"
  next_action "scripts/BuildWebRTC/import-webrtc-xcframework.sh"
fi

if [[ -f "${metadata}" ]]; then
  ok "Imported metadata exists"
  cat "${metadata}"
else
  warn "Imported metadata does not exist"
  next_action "scripts/BuildWebRTC/import-webrtc-xcframework.sh"
fi

echo
if [[ "${RUN_SWIFTPM_CHECK}" == "true" ]]; then
  if (cd "${RTC_PACKAGE_DIR}" && "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" build --target RTCNativeWebRTC >/dev/null); then
    ok "RTCNativeWebRTC builds with imported WebRTC binary target"
  else
    fail "RTCNativeWebRTC build failed"
    next_action "CLEAN_MODE=swiftpm DRY_RUN=false scripts/BuildWebRTC/clean-webrtc-build-resources.sh && scripts/BuildWebRTC/update-webrtc-binary.sh"
  fi
else
  warn "SwiftPM build check skipped because RUN_SWIFTPM_CHECK=false"
fi

echo
if [[ "${status}" -eq 0 ]]; then
  echo "Doctor result: OK"
else
  echo "Doctor result: action required"
fi
exit "${status}"

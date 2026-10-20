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
WEBRTC_BRANCH="${WEBRTC_BRANCH:-}"
IOS="${IOS:-true}"
MACOS="${MACOS:-true}"
RUN_SWIFTPM_VALIDATION="${RUN_SWIFTPM_VALIDATION:-true}"
RUN_TESTS="${RUN_TESTS:-true}"

export WEBRTC_BUILD_ROOT DEPOT_TOOLS_DIR DEVELOPER_DIR IOS MACOS

usage() {
  cat <<USAGE
Usage:
  $0

This is the normal one-command workflow. It resolves the WebRTC branch,
builds WebRTC.xcframework, verifies platform slices and headers, validates
the candidate in an isolated RTC package, and only then imports the zip.

Common overrides:
  WEBRTC_BRANCH=branch-heads/7727   Build a fixed WebRTC branch.
  IOS=true|false                    Include iOS device/simulator slices. Default: ${IOS}
  MACOS=true|false                  Include macOS universal slice. Default: ${MACOS}
  RUN_TESTS=false                   Skip isolated RTC package tests.
  RUN_SWIFTPM_VALIDATION=false      Skip RTCNativeWebRTC build validation.
USAGE
}

log_step() {
  echo
  echo "==> $1"
}

die_with_doctor_hint() {
  echo >&2
  echo "WebRTC binary update failed." >&2
  echo "Run this diagnostic command for the next concrete action:" >&2
  echo "  cd ${REPOSITORY_ROOT}" >&2
  echo "  scripts/BuildWebRTC/doctor-webrtc-binary.sh" >&2
  exit 1
}

require_file() {
  local path="$1"
  local message="$2"
  if [[ ! -e "${path}" ]]; then
    echo "Missing: ${path}" >&2
    echo "${message}" >&2
    exit 1
  fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

trap die_with_doctor_hint ERR

log_step "Checking prerequisites"
require_file "${DEVELOPER_DIR}/usr/bin/xcodebuild" "Set DEVELOPER_DIR to an installed Xcode Developer directory."
require_file "${DEPOT_TOOLS_DIR}/gclient" "Set DEPOT_TOOLS_DIR to the directory containing depot_tools."
require_file "${DEPOT_TOOLS_DIR}/fetch" "Set DEPOT_TOOLS_DIR to the directory containing depot_tools."

if [[ -z "${WEBRTC_BRANCH}" ]]; then
  log_step "Resolving current WebRTC branch"
  WEBRTC_BRANCH="$(${SCRIPT_DIR}/resolve-webrtc-branch.sh)"
fi
export WEBRTC_BRANCH
echo "WEBRTC_BRANCH=${WEBRTC_BRANCH}"

log_step "Building WebRTC.xcframework"
"${SCRIPT_DIR}/build-webrtc-xcframework.sh"

log_step "Validating the candidate in an isolated RTC package"
STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT
STAGED_PACKAGE="${STAGING_ROOT}/RTC"
mkdir -p "${STAGED_PACKAGE}"
rsync -a --exclude=.build --exclude=.swiftpm --exclude=.git "${RTC_PACKAGE_DIR}/" "${STAGED_PACKAGE}/"
CANDIDATE_ZIP="${WEBRTC_BUILD_ROOT}/src/out/WebRTC-${WEBRTC_BRANCH//\//-}.xcframework.zip"
RTC_PACKAGE_DIR="${STAGED_PACKAGE}" \
WEBRTC_ARTIFACT_DIR="${STAGED_PACKAGE}/BinaryArtifacts/WebRTC" \
WEBRTC_XCFRAMEWORK_ZIP="${CANDIDATE_ZIP}" \
  "${SCRIPT_DIR}/import-webrtc-xcframework.sh"

if [[ "${RUN_SWIFTPM_VALIDATION}" == "true" ]]; then
  log_step "Building RTCNativeWebRTC against the candidate"
  "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" build --package-path "${STAGED_PACKAGE}" --target RTCNativeWebRTC
fi

if [[ "${RUN_TESTS}" == "true" ]]; then
  log_step "Running RTC tests against the candidate"
  "${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" test --package-path "${STAGED_PACKAGE}"
fi

log_step "Installing the validated candidate"
RTC_PACKAGE_DIR="${RTC_PACKAGE_DIR}" WEBRTC_XCFRAMEWORK_ZIP="${CANDIDATE_ZIP}" \
  "${SCRIPT_DIR}/import-webrtc-xcframework.sh"

log_step "WebRTC binary update completed"
cat <<SUMMARY
Imported artifact:
  ${RTC_PACKAGE_DIR}/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip

Metadata:
  ${RTC_PACKAGE_DIR}/BinaryArtifacts/WebRTC/WebRTC.xcframework.metadata

Optional cleanup after you confirm the app builds:
  CLEAN_MODE=build-output DRY_RUN=false scripts/BuildWebRTC/clean-webrtc-build-resources.sh

Keep the source checkout when you expect to rebuild soon:
  ${WEBRTC_BUILD_ROOT}
SUMMARY

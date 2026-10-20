#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_PARENT="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
WEBRTC_BUILD_ROOT="${WEBRTC_BUILD_ROOT:-${REPOSITORY_PARENT}/webrtc-build}"
RTC_PACKAGE_DIR="${RTC_PACKAGE_DIR:-${REPOSITORY_ROOT}/RideIntercom/packages/RTC}"
CLEAN_MODE="${CLEAN_MODE:-build-output}"
DRY_RUN="${DRY_RUN:-true}"

usage() {
  cat <<USAGE
Usage:
  CLEAN_MODE=<mode> DRY_RUN=false $0

Modes:
  build-output  Remove WebRTC generated build output under WEBRTC_BUILD_ROOT/src/out.
  swiftpm       Remove SwiftPM WebRTC checkout/artifacts under RideIntercom/packages/RTC/.build.
  source        Remove the whole WEBRTC_BUILD_ROOT checkout.
  all           Remove build-output, swiftpm, and source resources.

Environment:
  WEBRTC_BUILD_ROOT=${WEBRTC_BUILD_ROOT}
  RTC_PACKAGE_DIR=${RTC_PACKAGE_DIR}
  DRY_RUN=${DRY_RUN}

DRY_RUN defaults to true. Set DRY_RUN=false to delete files.
USAGE
}

remove_path() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo "skip missing: ${path}"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "would remove: ${path}"
  else
    echo "removing: ${path}"
    rm -rf "${path}"
  fi
}

remove_glob() {
  local pattern="$1"
  local matched=false
  while IFS= read -r path; do
    matched=true
    remove_path "${path}"
  done < <(compgen -G "${pattern}" || true)
  if [[ "${matched}" == "false" ]]; then
    echo "skip missing: ${pattern}"
  fi
}

clean_build_output() {
  remove_path "${WEBRTC_BUILD_ROOT}/src/out"
}

clean_swiftpm() {
  remove_path "${RTC_PACKAGE_DIR}/.build/workspace-state.json"
  remove_path "${RTC_PACKAGE_DIR}/.build/debug.yaml"
  remove_path "${RTC_PACKAGE_DIR}/.build/plugin-tools.yaml"
  remove_path "${RTC_PACKAGE_DIR}/.build/artifacts/rtc/WebRTC"
  remove_path "${RTC_PACKAGE_DIR}/.build/artifacts/extract/rtc"
  remove_path "${RTC_PACKAGE_DIR}/.build/artifacts/extract/webrtc"
  remove_path "${RTC_PACKAGE_DIR}/.build/arm64-apple-macosx/debug/WebRTC.framework"
  remove_glob "${RTC_PACKAGE_DIR}/.build/arm64-apple-macosx/debug/RTC*WebRTC*"
  remove_path "${RTC_PACKAGE_DIR}/.build/artifacts/webrtc"
  remove_path "${RTC_PACKAGE_DIR}/.build/checkouts/WebRTC"
  remove_path "${RTC_PACKAGE_DIR}/.build/checkouts/webrtc"
  remove_glob "${RTC_PACKAGE_DIR}/.build/checkouts/*webrtc*"
  remove_glob "${RTC_PACKAGE_DIR}/.build/repositories/WebRTC-*"
  remove_glob "${RTC_PACKAGE_DIR}/.build/repositories/webrtc-*"
  remove_glob "${RTC_PACKAGE_DIR}/.build/repositories/*webrtc*"
}

clean_source() {
  remove_path "${WEBRTC_BUILD_ROOT}"
}

case "${CLEAN_MODE}" in
  build-output)
    clean_build_output
    ;;
  swiftpm)
    clean_swiftpm
    ;;
  source)
    clean_source
    ;;
  all)
    clean_build_output
    clean_swiftpm
    clean_source
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown CLEAN_MODE: ${CLEAN_MODE}" >&2
    usage >&2
    exit 2
    ;;
esac

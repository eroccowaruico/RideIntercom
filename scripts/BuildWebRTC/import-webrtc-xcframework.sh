#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_PARENT="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
WEBRTC_BUILD_ROOT="${WEBRTC_BUILD_ROOT:-${REPOSITORY_PARENT}/webrtc-build}"
DEFAULT_OUTPUT_DIR="${WEBRTC_BUILD_ROOT}/src/out"
OUTPUT_DIR="${WEBRTC_OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"
RTC_PACKAGE_DIR="${RTC_PACKAGE_DIR:-${REPOSITORY_ROOT}/RideIntercom/packages/RTC}"
ARTIFACT_DIR="${WEBRTC_ARTIFACT_DIR:-${RTC_PACKAGE_DIR}/BinaryArtifacts/WebRTC}"
SOURCE_ZIP="${WEBRTC_XCFRAMEWORK_ZIP:-}"

if [[ -z "${SOURCE_ZIP}" ]]; then
  SOURCE_ZIP="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'WebRTC-*.xcframework.zip' -print 2>/dev/null | sort | tail -1)"
fi

if [[ -z "${SOURCE_ZIP}" || ! -f "${SOURCE_ZIP}" ]]; then
  echo "WebRTC xcframework zip was not found." >&2
  echo "Set WEBRTC_XCFRAMEWORK_ZIP or build it under: ${OUTPUT_DIR}" >&2
  exit 1
fi

# Stage and validate the pair before one atomic directory publication.
exec python3 "${SCRIPT_DIR}/import_webrtc_artifact.py" "${SOURCE_ZIP}" "${ARTIFACT_DIR}" \
  "${SCRIPT_DIR}/verify-webrtc-xcframework.sh"

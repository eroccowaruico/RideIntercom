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
DESTINATION_ZIP="${ARTIFACT_DIR}/WebRTC.xcframework.zip"
METADATA_FILE="${ARTIFACT_DIR}/WebRTC.xcframework.metadata"

if [[ -z "${SOURCE_ZIP}" ]]; then
  SOURCE_ZIP="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'WebRTC-*.xcframework.zip' -print 2>/dev/null | sort | tail -1)"
fi

if [[ -z "${SOURCE_ZIP}" || ! -f "${SOURCE_ZIP}" ]]; then
  echo "WebRTC xcframework zip was not found." >&2
  echo "Set WEBRTC_XCFRAMEWORK_ZIP or build it under: ${OUTPUT_DIR}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

unzip -q "${SOURCE_ZIP}" -d "${TMP_DIR}"

if [[ ! -d "${TMP_DIR}/WebRTC.xcframework" ]]; then
  echo "Archive does not contain WebRTC.xcframework at its root: ${SOURCE_ZIP}" >&2
  exit 1
fi

"${SCRIPT_DIR}/verify-webrtc-xcframework.sh" "${TMP_DIR}/WebRTC.xcframework"

mkdir -p "${ARTIFACT_DIR}"
cp "${SOURCE_ZIP}" "${DESTINATION_ZIP}"

checksum="$(shasum -a 256 "${DESTINATION_ZIP}" | awk '{print $1}')"
cat > "${METADATA_FILE}" <<EOF
source_zip=$(basename "${SOURCE_ZIP}")
checksum=${checksum}
imported_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

echo "Imported: ${DESTINATION_ZIP}"
echo "Checksum: ${checksum}"

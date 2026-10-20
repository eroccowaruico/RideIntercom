#!/usr/bin/env bash
set -euo pipefail

XCFRAMEWORK_PATH="${1:-}"

if [[ -z "${XCFRAMEWORK_PATH}" ]]; then
  echo "Usage: $0 path/to/WebRTC.xcframework" >&2
  exit 2
fi

if [[ ! -d "${XCFRAMEWORK_PATH}" ]]; then
  echo "WebRTC.xcframework was not found: ${XCFRAMEWORK_PATH}" >&2
  exit 1
fi

# Validate the manifest and the actual binaries, not just any folders found.
python3 - "${XCFRAMEWORK_PATH}" <<'PYTHON'
import pathlib, plistlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
try:
    with (root / 'Info.plist').open('rb') as source:
        libraries = plistlib.load(source)['AvailableLibraries']
    expected = {('ios', ''): {'arm64'}, ('ios', 'simulator'): {'arm64', 'x86_64'},
                ('macos', ''): {'arm64', 'x86_64'}}
    found = {}
    for library in libraries:
        platform = (library['SupportedPlatform'], library.get('SupportedPlatformVariant', ''))
        framework = root / library['LibraryIdentifier'] / library['LibraryPath']
        binary = framework / 'WebRTC'
        actual = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
        declared = set(library['SupportedArchitectures'])
        if actual != declared:
            raise ValueError(f'{binary}: declared {declared}, actual {actual}')
        found.setdefault(platform, set()).update(actual)
    for platform, architectures in expected.items():
        if not architectures <= found.get(platform, set()):
            raise ValueError(f'Missing slice or architectures: {platform} {architectures}')
except Exception as error:
    print(f'Invalid WebRTC.xcframework: {error}', file=sys.stderr)
    sys.exit(1)
PYTHON

required_headers=(
  WebRTC.h
  RTCAudioSource.h
  RTCAudioTrack.h
  RTCConfiguration.h
  RTCDataChannel.h
  RTCDataChannelConfiguration.h
  RTCIceCandidate.h
  RTCIceServer.h
  RTCMediaConstraints.h
  RTCPeerConnection.h
  RTCPeerConnectionFactory.h
  RTCSessionDescription.h
)

missing_count=0

while IFS= read -r framework_dir; do
  headers_dir="${framework_dir}/Headers"
  if [[ ! -d "${headers_dir}" && -d "${framework_dir}/Versions/A/Headers" ]]; then
    headers_dir="${framework_dir}/Versions/A/Headers"
  fi

  if [[ ! -d "${headers_dir}" ]]; then
    echo "Missing Headers directory: ${framework_dir}" >&2
    missing_count=$((missing_count + 1))
    continue
  fi

  for header in "${required_headers[@]}"; do
    if [[ ! -f "${headers_dir}/${header}" ]]; then
      echo "Missing ${header} in ${headers_dir}" >&2
      missing_count=$((missing_count + 1))
    fi
  done

  if [[ -f "${headers_dir}/WebRTC.h" ]]; then
    while IFS= read -r imported_header; do
      if [[ ! -f "${headers_dir}/${imported_header}" ]]; then
        echo "Missing ${imported_header} imported by WebRTC.h in ${headers_dir}" >&2
        missing_count=$((missing_count + 1))
      fi
    done < <(sed -n 's/^#import <WebRTC\/\([^>]*\.h\)>.*/\1/p' "${headers_dir}/WebRTC.h" | sort -u)
  fi
done < <(find "${XCFRAMEWORK_PATH}" -path '*/WebRTC.framework' -type d | sort)

if [[ "${missing_count}" -ne 0 ]]; then
  echo "WebRTC.xcframework header verification failed: ${missing_count} missing item(s)." >&2
  exit 1
fi

echo "WebRTC.xcframework header verification passed: ${XCFRAMEWORK_PATH}"

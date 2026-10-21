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
import pathlib, plistlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])

def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    values = set(re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output))
    if not values:
        raise ValueError(f'Missing UUID: {path}')
    return values

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
        symbols_path = library.get('DebugSymbolsPath')
        # iOS device symbols are required for App Store distribution.
        if not symbols_path and platform == ('ios', ''):
            raise ValueError(f'Missing dSYM declaration: {binary}')
        if symbols_path:
            dwarf = (framework.parent / symbols_path / 'WebRTC.framework.dSYM'
                     / 'Contents/Resources/DWARF/WebRTC')
            if not dwarf.is_file():
                raise ValueError(f'Missing dSYM: {dwarf}')
            if uuids(binary) != uuids(dwarf):
                raise ValueError(f'dSYM UUID mismatch: {binary} and {dwarf}')
        found.setdefault(platform, set()).update(actual)
        symbols = subprocess.check_output(['nm', '-g', str(binary)], text=True)
        if re.search(r'AVCapture|RTCCamera', symbols):
            raise ValueError(f'Camera capture API found: {binary}')
        headers = framework / 'Headers'
        for header in headers.glob('*.h'):
            if re.search(r'AVCapture|RTCCamera', header.name):
                raise ValueError(f'Camera capture header found: {header}')
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

echo "WebRTC.xcframework slice, dSYM UUID, camera exclusion, and header verification passed: ${XCFRAMEWORK_PATH}"

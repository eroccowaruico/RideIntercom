#!/usr/bin/env python3
"""Validate SDK privacy resources; optionally repair only the known GN Mac layout."""
import argparse
from pathlib import Path
import plistlib
import sys


def child(root, value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError(f'Unsafe artifact path: {value}')
    result = root / path
    result.resolve(strict=True).relative_to(root.resolve(strict=True))
    return result


def check_plist(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Missing regular privacy manifest: {path}')
    with path.open('rb') as source:
        document = plistlib.load(source)
    if not isinstance(document, dict):
        raise ValueError(f'Privacy manifest must be a dictionary: {path}')
    # Check the resource format, not Apple's changing reason-code policy.
    types = {'NSPrivacyTracking': bool, 'NSPrivacyTrackingDomains': list,
             'NSPrivacyCollectedDataTypes': list, 'NSPrivacyAccessedAPITypes': list}
    for key, expected in types.items():
        if key in document and type(document[key]) is not expected:
            raise ValueError(f'Invalid {key} type in privacy manifest: {path}')


def check_framework(framework, platform, repair):
    resolved = framework.resolve(strict=True)
    # Check before following resource links or passing any framework path to tools.
    for path in framework.rglob('*'):
        if path.is_symlink():
            path.resolve(strict=True).relative_to(resolved)
    if platform == 'macos':
        target = framework / 'Versions/A/Resources/PrivacyInfo.xcprivacy'
        if (framework / 'Resources').resolve(strict=True) != target.parent.resolve(strict=True):
            raise ValueError(f'Nonstandard macOS Resources link: {framework}')
    else:
        target = framework / 'PrivacyInfo.xcprivacy'
    manifests = set(framework.rglob('PrivacyInfo.xcprivacy'))
    legacy = framework / 'Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy'
    if manifests == {target}:
        check_plist(target)
        return None
    if repair and platform == 'macos' and manifests == {legacy} and not target.exists():
        check_plist(legacy)
        if any(framework.rglob('CodeResources')):
            raise ValueError(f'Cannot relocate a resource in a sealed framework: {framework}')
        return legacy, target
    raise ValueError(f'Privacy manifest is missing or misplaced: expected {target}')


def validate(root, repair=False):
    root = Path(root)
    with child(root, 'Info.plist').open('rb') as source:
        libraries = plistlib.load(source)['AvailableLibraries']
    moves = []
    for library in libraries:
        slice_root = child(root, library['LibraryIdentifier'])
        framework = child(slice_root, library['LibraryPath'])
        move = check_framework(framework, library['SupportedPlatform'], repair)
        if move:
            moves.append(move)
    # Preflight every slice before changing even the isolated assembly copy.
    for source, target in moves:
        source.rename(target)
        for directory in [source.parent, source.parent.parent, source.parent.parent.parent]:
            if not any(directory.iterdir()):
                directory.rmdir()
        print(f'Relocated macOS privacy resource: {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xcframework', type=Path)
    parser.add_argument('--repair-known-macos-location', action='store_true')
    arguments = parser.parse_args()
    try:
        validate(arguments.xcframework, arguments.repair_known_macos_location)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(f'Invalid WebRTC privacy manifest: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

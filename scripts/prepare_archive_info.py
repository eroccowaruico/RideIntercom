#!/usr/bin/env python3
"""Xcode build phase: reserve Archive numbers and prepare an unsigned input plist."""
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shlex
import sys


def info_contents(source, env):
    """Preserve the app's configured metadata while allowing a fresh build number.

    GENERATE_INFOPLIST_FILE would overwrite CFBundleVersion with Xcode's cached
    setting. Supply the app's explicit keys here; Xcode still merges platform,
    asset-catalog and toolchain metadata in ProcessInfoPlistFile before signing.
    """
    info = plistlib.loads(source.read_bytes())
    for key, setting in {
        'CFBundleDevelopmentRegion': 'DEVELOPMENT_LANGUAGE',
        'CFBundleExecutable': 'EXECUTABLE_NAME',
        'CFBundleIdentifier': 'PRODUCT_BUNDLE_IDENTIFIER',
        'CFBundleName': 'PRODUCT_NAME',
        'CFBundlePackageType': 'PRODUCT_BUNDLE_PACKAGE_TYPE',
        'CFBundleShortVersionString': 'MARKETING_VERSION',
    }.items():
        info[key] = env[setting]
    info['CFBundleInfoDictionaryVersion'] = '6.0'
    for key in ['CFBundleDisplayName', 'LSApplicationCategoryType',
                'NSLocalNetworkUsageDescription', 'NSMicrophoneUsageDescription']:
        value = env.get('INFOPLIST_KEY_' + key)
        if value:
            info[key] = value
    info['UIStatusBarStyle'] = env.get('INFOPLIST_KEY_UIStatusBarStyle', '')
    for key in ['ITSAppUsesNonExemptEncryption', 'UIApplicationSupportsIndirectInputEvents']:
        info[key] = boolean(env.get('INFOPLIST_KEY_' + key) or 'NO')
    for key, setting in [('UISupportedInterfaceOrientations', 'UISupportedInterfaceOrientations'),
                         ('UISupportedInterfaceOrientations~ipad', 'UISupportedInterfaceOrientations_iPad')]:
        value = env.get('INFOPLIST_KEY_' + setting)
        if value:
            info[key] = shlex.split(value)
    if env['PLATFORM_NAME'] in ('iphoneos', 'iphonesimulator'):
        info['LSRequiresIPhoneOS'] = True
    if boolean(env.get('INFOPLIST_KEY_UILaunchScreen_Generation', 'NO')):
        info['UILaunchScreen'] = {}
    if boolean(env.get('INFOPLIST_KEY_UIApplicationSceneManifest_Generation', 'NO')):
        info['UIApplicationSceneManifest'] = {
            'UIApplicationSupportsMultipleScenes': True, 'UISceneConfigurations': {}}
    return info


def boolean(value):
    if value not in ('YES', 'NO'):
        raise ValueError(f'Expected YES or NO, got {value!r}')
    return value == 'YES'


def prepare(env):
    root = Path(env['SRCROOT'])
    config = root / 'Configuration/BuildNumber.xcconfig'
    output = Path(env['SCRIPT_OUTPUT_FILE_0'])
    # Validate metadata before consuming a number. Never edit the source plist.
    info = info_contents(root / 'RideIntercom/Info.plist', env)
    # A separate, persistent lock inode remains valid across atomic config replacement.
    # Both its path and the staging file are declared outputs for Xcode's sandbox.
    with config.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original = config.read_text()
        match = re.fullmatch(r'(?P<comments>(?://[^\n]*\n|\s)*)CURRENT_PROJECT_VERSION = (?P<number>[1-9][0-9]*)\s*', original)
        if not match:
            raise ValueError('BuildNumber.xcconfig must contain one positive decimal CURRENT_PROJECT_VERSION')
        number = int(match['number'])
        # Xcode's Archive action builds with ACTION=install (including standard xcodebuild archive).
        # Release Run/Build/Test still use ACTION=build and never consume a number.
        if env['ACTION'] == 'install':
            number += 1
            pending = config.with_suffix('.next')
            with pending.open('w') as stream:
                stream.write(f"{match['comments']}CURRENT_PROJECT_VERSION = {number}\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(pending, config)
        info['CFBundleVersion'] = str(number)
    # Each build has its own DerivedSources; a parallel Archive cannot change this number.
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(info, sort_keys=False))
    print(f'RideIntercom {env["ACTION"]}: version {info["CFBundleShortVersionString"]}, build {number}')


if __name__ == '__main__':
    try:
        prepare(os.environ)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f'error: Cannot prepare RideIntercom build metadata: {error}', file=sys.stderr)
        sys.exit(1)

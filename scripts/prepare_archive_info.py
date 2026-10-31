#!/usr/bin/env python3
"""Xcode build phase: reserve a shared build number and prepare an unsigned input plist."""
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shlex
import sys
from urllib.parse import urlsplit


def development_internet_defaults(env):
    # Trial credentials remain in an ignored local directory, outside App resources.
    if (env.get('CONFIGURATION') != 'Debug' or env.get('ACTION') == 'install'
            or env.get('RIDEINTERCOM_STORAGE_NAMESPACE', 'RideIntercom') != 'RideIntercom'):
        return None
    host = env.get('RIDEINTERCOM_DEVELOPMENT_WORKER_HOST', '')
    token = env.get('RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN', '')
    if not host and not token:
        return None
    url = 'https://' + host
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment
            or not token.strip() or len(token.strip()) > 256):
        raise ValueError('Invalid local development Internet credentials')
    return {'workerURL': url, 'accessToken': token.strip()}


def info_contents(source, env):
    """Preserve the app's configured metadata while allowing a fresh build number.

    GENERATE_INFOPLIST_FILE would overwrite CFBundleVersion with Xcode's cached
    setting. Supply the app's explicit keys here; Xcode still merges platform,
    asset-catalog and toolchain metadata in ProcessInfoPlistFile before signing.
    """
    info = plistlib.loads(source.read_bytes())
    # Never carry a development credential from a previous source or configuration.
    info.pop('DevelopmentInternetConnection', None)
    is_main_app = env.get("RIDEINTERCOM_INFO_SOURCE", "RideIntercom/Info.plist") == "RideIntercom/Info.plist"
    development = development_internet_defaults(env) if is_main_app else None
    if development:
        info['DevelopmentInternetConnection'] = development
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
    if not is_main_app:
        return info
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
    project = root / 'RideIntercom.xcodeproj'
    project_file = project / 'project.pbxproj'
    output = Path(env['SCRIPT_OUTPUT_FILE_0'])
    reserves = env.get('RIDEINTERCOM_RESERVE_BUILD_NUMBER') == 'YES'
    info = {} if reserves else info_contents(root / env.get('RIDEINTERCOM_INFO_SOURCE', 'RideIntercom/Info.plist'), env)
    # Lock the stable directory inode: no persistent lock/state file is needed,
    # and replacing project.pbxproj atomically does not invalidate the lock.
    directory = os.open(project, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        original = project_file.read_text()
        pattern = r'(CURRENT_PROJECT_VERSION\s*=\s*)([^;]+)(;)'
        values = [m[1].strip() for m in re.findall(pattern, original)]
        if not values or any(not re.fullmatch(r'[1-9][0-9]*', v) for v in values) or len(set(values)) != 1:
            raise ValueError('Xcode CURRENT_PROJECT_VERSION must be one shared positive decimal value')
        number = int(values[0])
        # Run/Build/Test and Archive share one counter; indexing alone does not build an app.
        if reserves and env['ACTION'] in ('build', 'install'):
            number += 1
            updated = re.sub(pattern, lambda m: f'{m[1]}{number}{m[3]}', original)
            pending = project / '.build-number.tmp'
            try:
                with pending.open('w') as stream:
                    stream.write(updated)
                    stream.flush()
                    os.fsync(stream.fileno())
                # Don't overwrite an editor's intervening save with an older snapshot.
                if project_file.read_text() != original:
                    raise ValueError('Project changed while reserving a number; retry the build')
                os.replace(pending, project_file)
            finally:
                pending.unlink(missing_ok=True)
        if not reserves:
            # A single always-running aggregate dependency reserves this build's
            # number. Product targets consume its DerivedData output without
            # changing the project or consulting cached Xcode build settings.
            reserved = plistlib.loads(Path(env['RIDEINTERCOM_BUILD_NUMBER_FROM']).read_bytes()).get('CFBundleVersion')
            if not isinstance(reserved, str) or not re.fullmatch(r'[1-9][0-9]*', reserved) or int(reserved) > number:
                raise ValueError('Invalid build reservation; build the metadata dependency first')
            number = int(reserved)
        info['CFBundleVersion'] = str(number)
    finally:
        os.close(directory)
    # Each build has its own DerivedSources; a parallel Archive cannot change this number.
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(info, sort_keys=False))
    print(f'RideIntercom {env["ACTION"]}: {"reserved" if reserves else "prepared"} build {number}')


if __name__ == '__main__':
    try:
        prepare(os.environ)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f'error: Cannot prepare RideIntercom build metadata: {error}', file=sys.stderr)
        sys.exit(1)

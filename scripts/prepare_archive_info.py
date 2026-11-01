#!/usr/bin/env python3
"""Copy custom App Info keys and inject Debug-only development credentials."""
import os
from pathlib import Path
import plistlib
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


def prepare(env):
    root = Path(env['SRCROOT'])
    output = Path(env['SCRIPT_OUTPUT_FILE_0'])
    info = plistlib.loads((root / 'RideIntercom/Info.plist').read_bytes())
    # Never carry a development credential from another build configuration.
    info.pop('DevelopmentInternetConnection', None)
    development = development_internet_defaults(env)
    if development:
        info['DevelopmentInternetConnection'] = development
    # Xcode generates standard bundle, version and platform metadata afterward.
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(info, sort_keys=False))
    print('RideCom: prepared custom App Info.plist')


if __name__ == '__main__':
    try:
        prepare(os.environ)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f'error: Cannot prepare RideCom build metadata: {error}', file=sys.stderr)
        sys.exit(1)

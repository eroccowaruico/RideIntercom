#!/usr/bin/env python3
"""Prepare corruption only inside this validation run's dedicated Simulator."""
import argparse
import json
import hashlib
from pathlib import Path
import re
from uuid import UUID

CORRUPT = b'{broken-recovery-fixture'


def group_directory(container, device_root, namespace):
    if not re.fullmatch(r'RideIntercom\.Validation\.[A-Za-z0-9_-]+\.ios-tests', namespace):
        raise ValueError('Recovery fixture requires the isolated validation namespace')
    # Reject symlink escapes, a different device, or anything except an App's
    # data container. The caller obtains this path from simctl for its own UUID.
    root = Path(device_root).resolve(strict=True)
    path = Path(container).resolve(strict=True)
    relative = path.relative_to(root)
    if len(relative.parts) != 5 or relative.parts[:4] != ('data', 'Containers', 'Data', 'Application'):
        raise ValueError('Not an application data container on the owned Simulator')
    UUID(relative.parts[4])
    account = hashlib.sha256(b'local-validation-apple-user').hexdigest()
    directory = path / 'Library' / 'Application Support' / (namespace + '.Account.' + account) / 'Groups'
    if directory.resolve().is_relative_to(path) is False:
        raise ValueError('Group directory escapes the owned application container')
    manifest = directory / 'groups.json'
    if manifest.is_symlink():
        raise ValueError('Refusing a symlinked manifest')
    return directory


def prepare(directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'groups.json').write_bytes(CORRUPT)


def verify(directory):
    manifest = json.loads((directory / 'groups.json').read_text())
    if manifest.get('version') != 8 or manifest.get('groups') != [] or not isinstance(manifest.get('users'), list):
        raise ValueError('Recovery did not commit a valid empty group manifest')
    archives = list(directory.glob('groups-corrupt-*.json'))
    if not any(path.read_bytes() == CORRUPT for path in archives):
        raise ValueError('Recovery did not preserve the original corrupt bytes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('action', choices=['prepare', 'verify'])
    args = parser.parse_args()
    out = args.output.resolve()
    simulator = str(UUID((out / 'simulator-id.txt').read_text().strip())).upper()
    root = Path.home() / 'Library/Developer/CoreSimulator/Devices' / simulator
    container_log = 'recovery-container.log' if args.action == 'prepare' else 'recovery-container-after.log'
    directory = group_directory((out / container_log).read_text().strip(), root,
                                'RideIntercom.Validation.' + out.name + '.ios-tests')
    (prepare if args.action == 'prepare' else verify)(directory)
    print(args.action + ': isolated saved-group recovery fixture passed')


if __name__ == '__main__':
    main()

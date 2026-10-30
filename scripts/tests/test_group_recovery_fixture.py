import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from scripts import group_recovery_fixture
from scripts.group_recovery_fixture import CORRUPT, group_directory, prepare, verify


class GroupRecoveryFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / str(uuid4())
        self.container = self.root / 'data/Containers/Data/Application' / str(uuid4())
        self.container.mkdir(parents=True)
        self.namespace = 'RideIntercom.Validation.20261021-1234.ios-tests'

    def test_fixture_and_archive_are_verified_inside_owned_container(self):
        directory = group_directory(self.container, self.root, self.namespace)
        prepare(directory)
        self.assertEqual((directory / 'groups.json').read_bytes(), CORRUPT)
        with self.assertRaises(ValueError):
            verify(directory)
        (directory / 'groups.json').write_text(json.dumps({'version': 3, 'groups': [], 'users': []}))
        with self.assertRaises(ValueError):
            verify(directory)
        (directory / 'groups-corrupt-fixture.json').write_bytes(CORRUPT)
        verify(directory)

    def test_foreign_device_non_app_container_and_normal_namespace_are_rejected(self):
        for container, root, namespace in [
            (self.container, self.container, self.namespace),
            (self.container, self.root, 'RideIntercom'),
            (self.container, self.root, 'RideIntercom.Validation../escape.ios-tests'),
            (self.root, self.root, self.namespace),
        ]:
            with self.assertRaises(ValueError):
                group_directory(container, root, namespace)
        other = Path(self.temporary.name) / str(uuid4())
        other.mkdir()
        with self.assertRaises(ValueError):
            group_directory(self.container, other, self.namespace)

    def test_symlink_cannot_redirect_corruption_outside_container(self):
        outside = Path(self.temporary.name) / 'outside'
        outside.mkdir()
        (self.container / 'Library').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            group_directory(self.container, self.root, self.namespace)
        self.assertEqual(list(outside.iterdir()), [])

    def test_manifest_symlink_is_rejected(self):
        directory = group_directory(self.container, self.root, self.namespace)
        directory.mkdir(parents=True)
        (directory / 'groups.json').symlink_to(self.root / 'untouched')
        with self.assertRaises(ValueError):
            group_directory(self.container, self.root, self.namespace)

    def test_verification_uses_refreshed_container_after_xcode_reinstall(self):
        home = Path(self.temporary.name) / 'home'
        sim = str(uuid4()).upper()
        root = home / 'Library/Developer/CoreSimulator/Devices' / sim
        container = root / 'data/Containers/Data/Application' / str(uuid4())
        container.mkdir(parents=True)
        directory = group_directory(container, root, self.namespace)
        prepare(directory)
        (directory / 'groups-corrupt-fixture.json').write_bytes(CORRUPT)
        (directory / 'groups.json').write_text(json.dumps({'version': 3, 'groups': [], 'users': []}))
        relocated = container.with_name(str(uuid4()))
        container.rename(relocated)
        out = Path(self.temporary.name) / '20261021-1234'
        out.mkdir()
        (out / 'simulator-id.txt').write_text(sim)
        (out / 'recovery-container.log').write_text(str(container))
        (out / 'recovery-container-after.log').write_text(str(relocated))
        with patch('sys.argv', ['fixture', str(out), 'verify']), patch.object(Path, 'home', return_value=home):
            group_recovery_fixture.main()

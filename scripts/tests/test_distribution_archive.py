import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'archive_app_store.sh'


class DistributionArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'scripts').mkdir()
        self.script = self.root / 'scripts/archive_app_store.sh'
        shutil.copy2(SCRIPT, self.script)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.stub('pgrep', 'exit 1')
        self.stub('xcrun', f'echo "reserve:$*" >> "{self.log}"')
        self.stub('xcodebuild', f'echo "archive:$*" >> "{self.log}"')

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\n' + body + '\n')
        p.chmod(0o755)

    def run_archive(self, platform='ios'):
        return subprocess.run([str(self.script), platform, str(self.root / 'app.xcarchive')],
                              env=self.env, capture_output=True, text=True)

    def test_reserves_before_archive_and_never_changes_marketing_version(self):
        for platform, destination in [('ios', 'iOS'), ('macos', 'macOS')]:
            if self.log.exists(): self.log.unlink()
            result = self.run_archive(platform)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = self.log.read_text().splitlines()
            self.assertEqual(calls[0], 'reserve:agvtool -noscm next-version')
            self.assertTrue(calls[1].startswith('archive:archive '))
            self.assertIn('generic/platform=' + destination, calls[1])
            self.assertNotIn('marketing', self.log.read_text().lower())
            self.assertFalse((self.root / '.archive-app-store.lock').exists())

    def test_reservation_failure_stops_archive_and_releases_lock(self):
        self.stub('xcrun', 'exit 1')
        self.assertNotEqual(self.run_archive().returncode, 0)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.root / '.archive-app-store.lock').exists())

    def test_relative_archive_path_is_resolved_from_callers_directory(self):
        result = subprocess.run([str(self.script), 'ios', 'app.xcarchive'],
                                cwd=self.bin, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'-archivePath {self.bin}/app.xcarchive', self.log.read_text())

    def test_archive_failure_releases_lock_without_reverting_number(self):
        self.stub('xcodebuild', 'exit 1')
        self.assertNotEqual(self.run_archive().returncode, 0)
        self.assertEqual(self.log.read_text().strip(), 'reserve:agvtool -noscm next-version')
        self.assertFalse((self.root / '.archive-app-store.lock').exists())

    def test_existing_archive_open_xcode_and_concurrent_build_do_not_reserve(self):
        for kind in ['archive', 'xcode', 'lock']:
            with self.subTest(kind=kind):
                path = None
                if kind == 'archive': path = self.root / 'app.xcarchive'
                if kind == 'lock': path = self.root / '.archive-app-store.lock'
                if path: path.mkdir()
                self.stub('pgrep', 'exit 0' if kind == 'xcode' else 'exit 1')
                self.assertNotEqual(self.run_archive().returncode, 0)
                self.assertFalse(self.log.exists())
                if path: path.rmdir()

"""Regression checks for artifact validation and failed-update preservation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/BuildWebRTC'
ARTIFACT = ROOT / 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'


class WebRTCScriptTests(unittest.TestCase):
    def test_cleanup_rejects_non_checkout_without_removing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / 'important.txt'
            sentinel.write_text('preserve')
            result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                    env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                             CLEAN_MODE='source', DRY_RUN='false'), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), 'preserve')

    def test_cleanup_only_removes_verified_checkout_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'webrtc-build'
            (root / 'src/out').mkdir(parents=True)
            (root / 'src/.git').mkdir()
            (root / '.gclient').write_text('fixture')
            (root / 'src/BUILD.gn').write_text('fixture')
            (root / 'src/out/generated').write_text('remove')
            result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                    env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                             CLEAN_MODE='build-output', DRY_RUN='false'), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / 'src/out').exists())
            self.assertTrue((root / 'src/BUILD.gn').exists())

    def test_cleanup_rejects_symlink_escape_and_misspelled_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'webrtc-build'
            (root / 'src/.git').mkdir(parents=True)
            (root / '.gclient').write_text('fixture')
            (root / 'src/BUILD.gn').write_text('fixture')
            other = Path(directory) / 'important'
            other.mkdir()
            sentinel = other / 'keep'
            sentinel.touch()
            (root / 'src/out').symlink_to(other, target_is_directory=True)
            for mode, dry in [('build-output', 'false'), ('source', 'flase')]:
                if mode == 'source':
                    (root / 'src/out').unlink()
                    (root / 'src/out').mkdir()
                result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                        env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                                 CLEAN_MODE=mode, DRY_RUN=dry), capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(sentinel.exists())
                self.assertTrue((root / 'src/BUILD.gn').exists())

    def test_empty_xcframework_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stdout.decode())

    def test_failed_native_validation_keeps_installed_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/BuildWebRTC'
            shutil.copytree(SCRIPTS, scripts)
            package = root / 'RideIntercom/packages/RTC'
            shutil.copytree(ROOT / 'RideIntercom/packages/RTC', package,
                            ignore=shutil.ignore_patterns('.build', '.swiftpm', '.git'))
            artifact = package / 'BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'
            artifact.write_bytes(b'previous artifact must survive')
            metadata = artifact.with_suffix('.metadata')
            before_metadata = metadata.read_bytes()
            output = root / 'build/src/out'
            output.mkdir(parents=True)
            subprocess.run(['unzip', '-q', str(ARTIFACT), '-d', str(output)], check=True)
            shutil.copy(ARTIFACT, output / 'WebRTC-branch-heads-test.xcframework.zip')
            (scripts / 'build-webrtc-xcframework.sh').write_text('#!/bin/bash\nexit 0\n')
            # A broken candidate package must fail compilation before installation.
            (package / 'Package.swift').write_text('// swift-tools-version: 6.3\ninvalid manifest\n')
            developer = Path(os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
            depot = root / 'depot_tools'
            depot.mkdir()
            for name in ['fetch', 'gclient']:
                (depot / name).touch(mode=0o755)
            environment = dict(os.environ, DEVELOPER_DIR=str(developer), DEPOT_TOOLS_DIR=str(depot),
                               WEBRTC_BUILD_ROOT=str(root / 'build'), RTC_PACKAGE_DIR=str(package),
                               WEBRTC_BRANCH='branch-heads/test', RUN_SWIFTPM_VALIDATION='true', RUN_TESTS='true')
            result = subprocess.run([str(scripts / 'update-webrtc-binary.sh')], env=environment,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Invalid manifest', result.stderr)
            self.assertEqual(artifact.stat().st_size, len(b'previous artifact must survive'))
            self.assertEqual(artifact.read_bytes(), b'previous artifact must survive')
            self.assertEqual(metadata.read_bytes(), before_metadata)


if __name__ == '__main__':
    unittest.main()

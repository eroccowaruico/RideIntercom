"""Artifact publication tests use synthetic zips and real temporary-directory swaps."""
import errno
import hashlib
import importlib.util
import os
from pathlib import Path
import selectors
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/BuildWebRTC'


class ArtifactPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scripts = self.root / 'scripts'
        shutil.copytree(SCRIPTS, self.scripts)
        # These tests isolate publication from SDK validation, which has its own
        # real-binary suite. This fixture accepts only the expected zip layout.
        self.verifier = self.scripts / 'verify-webrtc-xcframework.sh'
        self.verifier.write_text('#!/bin/sh\ntest -f "$1/payload"\n')
        self.destination = self.root / 'artifacts/WebRTC'
        self.destination.mkdir(parents=True)
        self.source = self.root / 'candidate.zip'
        self.make_zip(self.source, 'new')
        self.make_zip(self.destination / 'WebRTC.xcframework.zip', 'old')
        self.old_zip = (self.destination / 'WebRTC.xcframework.zip').read_bytes()
        self.old_metadata = ('source_zip=old.zip\nchecksum=' + hashlib.sha256(self.old_zip).hexdigest() + '\nimported_at=old\n').encode()
        (self.destination / 'WebRTC.xcframework.metadata').write_bytes(self.old_metadata)

    def make_zip(self, path, marker):
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('WebRTC.xcframework/payload', marker)

    def module(self):
        spec = importlib.util.spec_from_file_location('artifact_import', SCRIPTS / 'import_webrtc_artifact.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def assert_old(self):
        self.assertEqual((self.destination / 'WebRTC.xcframework.zip').read_bytes(), self.old_zip)
        self.assertEqual((self.destination / 'WebRTC.xcframework.metadata').read_bytes(), self.old_metadata)

    def assert_new(self):
        data = (self.destination / 'WebRTC.xcframework.zip').read_bytes()
        metadata = dict(line.split('=', 1) for line in (self.destination / 'WebRTC.xcframework.metadata').read_text().splitlines())
        self.assertEqual(data, self.source.read_bytes())
        self.assertEqual(metadata['checksum'], hashlib.sha256(data).hexdigest())
        self.assertEqual(metadata['source_zip'], self.source.name)

    def run_entry(self, environment=None):
        env = dict(os.environ, WEBRTC_XCFRAMEWORK_ZIP=str(self.source), WEBRTC_ARTIFACT_DIR=str(self.destination))
        env.update(environment or {})
        return subprocess.run([str(self.scripts / 'import-webrtc-xcframework.sh')], env=env, capture_output=True, text=True)

    def test_copy_failure_keeps_the_installed_pair(self):
        binary = self.root / 'bin'
        binary.mkdir()
        fault = binary / 'cp'
        fault.write_text('#!/bin/sh\nprintf partial > "$2"\necho "No space left on device" >&2\nexit 1\n')
        fault.chmod(0o755)
        result = self.run_entry({'PATH': str(binary) + os.pathsep + os.environ['PATH']})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No space left on device', result.stderr)
        self.assert_old()

    def test_metadata_failure_keeps_the_installed_pair(self):
        module = self.module()
        def fail(path, *args):
            path.write_text('partial')
            raise OSError(errno.ENOSPC, 'metadata disk full')
        with patch.object(module, '_write_metadata', side_effect=fail):
            with self.assertRaises(OSError):
                module.import_artifact(self.source, self.destination, self.verifier)
        self.assert_old()

    def test_replacement_publishes_a_matching_pair_at_the_fixed_path(self):
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_new()
        self.assertEqual(sorted(p.name for p in self.destination.parent.iterdir()), ['WebRTC'])

    def test_first_install_publishes_the_whole_directory(self):
        shutil.rmtree(self.destination)
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_new()

    def test_failed_validation_does_not_publish(self):
        self.verifier.write_text('#!/bin/sh\nexit 17\n')
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_unsupported_or_failed_exchange_keeps_the_installed_pair(self):
        module = self.module()
        for code in (errno.ENOTSUP, errno.EIO, errno.ENOSPC):
            with self.subTest(errno=code):
                with patch.object(module, '_rename_directory', side_effect=OSError(code, 'exchange failed')):
                    with self.assertRaises(OSError):
                        module.import_artifact(self.source, self.destination, self.verifier)
                self.assert_old()

    def test_initial_publication_does_not_overwrite_a_concurrent_install(self):
        module = self.module()
        shutil.rmtree(self.destination)
        rename = module._rename_directory
        def compete(source, destination, flags):
            self.assertEqual(flags, module.RENAME_EXCL)
            destination.mkdir()
            (destination / 'WebRTC.xcframework.zip').write_bytes(self.old_zip)
            (destination / 'WebRTC.xcframework.metadata').write_bytes(self.old_metadata)
            return rename(source, destination, flags)
        with patch.object(module, '_rename_directory', side_effect=compete):
            with self.assertRaises(FileExistsError):
                module.import_artifact(self.source, self.destination, self.verifier)
        self.assert_old()

    def test_unexpected_existing_files_are_not_discarded(self):
        note = self.destination / 'keep.txt'
        note.write_text('keep')
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(note.read_text(), 'keep')

    def test_file_added_during_validation_is_preserved_without_publication(self):
        note = self.destination / 'added-during-validation.txt'
        self.verifier.write_text('#!/bin/sh\nprintf keep > "$ADDED_NOTE"\ntest -f "$1/payload"\n')
        result = self.run_entry({'ADDED_NOTE': str(note)})
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(note.read_text(), 'keep')

    def test_unknown_file_added_at_exchange_is_not_recursively_deleted(self):
        module = self.module()
        rename = module._rename_directory
        def race(source, destination, flags):
            (destination / 'late-note.txt').write_text('keep')
            return rename(source, destination, flags)
        with patch.object(module, '_rename_directory', side_effect=race):
            module.import_artifact(self.source, self.destination, self.verifier)
        self.assert_new()
        retained = list(self.destination.parent.glob('.WebRTC.import-*/late-note.txt'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0].read_text(), 'keep')

    def test_symbolic_link_artifact_directory_is_not_replaced(self):
        original = self.root / 'original-artifact'
        self.destination.rename(original)
        self.destination.symlink_to(original, target_is_directory=True)
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assert_old()

    def test_sigkill_before_or_after_exchange_leaves_only_a_complete_pair(self):
        for point in ('before', 'after'):
            with self.subTest(point=point):
                (self.destination / 'WebRTC.xcframework.zip').write_bytes(self.old_zip)
                (self.destination / 'WebRTC.xcframework.metadata').write_bytes(self.old_metadata)
                code = '''import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('artifact_import',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=m._rename_directory
def pause(source,destination,flags):
 if sys.argv[5]=='after': original(source,destination,flags)
 print('READY',flush=True)
 sys.stdin.read(1)
 if sys.argv[5]=='before': original(source,destination,flags)
m._rename_directory=pause
m.import_artifact(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]))
'''
                process = subprocess.Popen([sys.executable, '-c', code, str(SCRIPTS / 'import_webrtc_artifact.py'), str(self.source), str(self.destination), str(self.verifier), point], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(process.stdout, selectors.EVENT_READ)
                        self.assertTrue(selector.select(timeout=10), 'Child never reached publication')
                        self.assertEqual(process.stdout.readline().strip(), 'READY')
                    process.kill()
                    process.communicate(timeout=5)
                    self.assertEqual(process.returncode, -signal.SIGKILL)
                    self.assert_old() if point == 'before' else self.assert_new()
                    print(f'renamex_np boundary={point} pid={process.pid} SIGKILL={process.returncode} completePair={"old" if point == "before" else "new"}', flush=True)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)
        # Abandoned staging directories are never selected and cannot block retry.
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_new()


if __name__ == '__main__':
    unittest.main()

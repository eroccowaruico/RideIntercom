"""Privacy resource layout checks without compiling WebRTC or using signing keys."""
import os
from pathlib import Path
import plistlib
import shutil
import stat
import zipfile
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/BuildWebRTC'
PRIVACY = plistlib.dumps({
    'NSPrivacyTracking': False,
    'NSPrivacyTrackingDomains': [],
    'NSPrivacyCollectedDataTypes': [],
    'NSPrivacyAccessedAPITypes': [{
        'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategorySystemBootTime',
        'NSPrivacyAccessedAPITypeReasons': ['35F9.1'],
    }],
})
HEADERS = ('WebRTC RTCAudioSource RTCAudioTrack RTCConfiguration RTCDataChannel '
           'RTCDataChannelConfiguration RTCIceCandidate RTCIceServer RTCMediaConstraints '
           'RTCPeerConnection RTCPeerConnectionFactory RTCSessionDescription').split()


class WebRTCPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'WebRTC.xcframework'
        self.root.mkdir()
        self.commands = self.base / 'bin'
        self.commands.mkdir()
        self.env = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ['PATH'])
        # Stub only Mach-O tools; the real verify/import scripts inspect all paths/plists.
        self.command('lipo', '''case "$*" in
*-archs*ios-arm64*) echo arm64;;
*-archs*) echo arm64 x86_64;;
*) cp "$4" "$3";;
esac''')
        self.command('nm', 'exit 0')
        self.command('xcrun', '''if [ "$1" = dwarfdump ]; then
printf 'UUID: 11111111-1111-1111-1111-111111111111 (arm64) fixture\n'
fi''')
        libraries = []
        for identifier, platform, variant in [('ios-arm64', 'ios', ''),
                ('ios-x86_64_arm64-simulator', 'ios', 'simulator'),
                ('macos-x86_64_arm64', 'macos', '')]:
            framework = self.root / identifier / 'WebRTC.framework'
            contents = framework / 'Versions/A' if platform == 'macos' else framework
            (contents / 'Headers').mkdir(parents=True)
            for header in HEADERS:
                (contents / 'Headers' / (header + '.h')).write_text('// fixture\n')
            (contents / 'WebRTC').write_bytes(b'unchanged binary fixture')
            resource = contents / 'Resources' if platform == 'macos' else contents
            resource.mkdir(exist_ok=True)
            (resource / 'PrivacyInfo.xcprivacy').write_bytes(PRIVACY)
            if platform == 'macos':
                (framework / 'Versions/Current').symlink_to('A')
                for name in ['Headers', 'Resources', 'WebRTC']:
                    (framework / name).symlink_to('Versions/Current/' + name)
                self.mac = framework
            entry = dict(LibraryIdentifier=identifier, LibraryPath='WebRTC.framework',
                         SupportedPlatform=platform, SupportedArchitectures=['arm64'])
            if variant or platform == 'macos':
                entry['SupportedArchitectures'].append('x86_64')
            if variant:
                entry['SupportedPlatformVariant'] = variant
            if identifier == 'ios-arm64':
                entry['DebugSymbolsPath'] = 'dSYMs'
                dwarf = framework.parent / 'dSYMs/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC'
                dwarf.parent.mkdir(parents=True)
                dwarf.write_bytes(b'unchanged symbols fixture')
            libraries.append(entry)
        (self.root / 'Info.plist').write_bytes(plistlib.dumps(dict(AvailableLibraries=libraries)))
        self.manifest = self.mac / 'Versions/A/Resources/PrivacyInfo.xcprivacy'
        self.legacy = self.mac / 'Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy'

    def command(self, name, body):
        path = self.commands / name
        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def verify(self):
        return subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), str(self.root)],
                              env=self.env, capture_output=True, text=True)

    def test_standard_resources_and_manifest_bytes_are_accepted(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.mac / 'Resources/PrivacyInfo.xcprivacy').read_bytes(), PRIVACY)

    def test_missing_manifest_is_rejected(self):
        self.manifest.unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('privacy', result.stderr.lower())

    def test_known_nested_misplacement_is_rejected_by_verification(self):
        self.legacy.parent.mkdir(parents=True)
        self.manifest.rename(self.legacy)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.legacy.exists(), 'Verification must not repair its input')

    def test_broken_plist_is_rejected(self):
        self.manifest.write_bytes(b'not a property list')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)

    def test_external_resources_symlink_is_rejected(self):
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'PrivacyInfo.xcprivacy').write_bytes(PRIVACY)
        (self.mac / 'Resources').unlink()
        (self.mac / 'Resources').symlink_to(outside)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((outside / 'PrivacyInfo.xcprivacy').read_bytes(), PRIVACY)

    def test_cyclic_resources_symlink_is_rejected(self):
        (self.mac / 'Resources').unlink()
        (self.mac / 'Resources').symlink_to('Resources')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)

    def archive(self):
        archive = self.base / 'candidate.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            for path in self.root.rglob('*'):
                name = str(path.relative_to(self.base))
                if path.is_symlink():
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    output.writestr(info, os.readlink(path))
                else:
                    output.write(path, name)
        return archive

    def test_failed_privacy_import_preserves_installed_zip_and_metadata(self):
        self.manifest.unlink()
        archive = self.archive()
        destination = self.base / 'installed'
        destination.mkdir()
        previous = destination / 'WebRTC.xcframework.zip'
        metadata = destination / 'WebRTC.xcframework.metadata'
        previous.write_bytes(b'previous archive')
        metadata.write_bytes(b'previous metadata')
        result = subprocess.run([str(SCRIPTS / 'import-webrtc-xcframework.sh')],
            env=dict(self.env, WEBRTC_XCFRAMEWORK_ZIP=str(archive),
                     WEBRTC_ARTIFACT_DIR=str(destination)), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(previous.read_bytes(), b'previous archive')
        self.assertEqual(metadata.read_bytes(), b'previous metadata')

    def test_assembly_repairs_only_copied_macos_privacy_resource(self):
        self.legacy.parent.mkdir(parents=True)
        self.manifest.rename(self.legacy)
        build = self.base / 'build'
        output = build / 'src/out'
        output.mkdir(parents=True)
        inputs = [('ios-arm64-device', 'ios-arm64'),
                  ('ios-x64-simulator', 'ios-x86_64_arm64-simulator'),
                  ('ios-arm64-simulator', 'ios-x86_64_arm64-simulator'),
                  ('macos-x64', 'macos-x86_64_arm64'),
                  ('macos-arm64', 'macos-x86_64_arm64')]
        for target, identifier in inputs:
            shutil.copytree(self.root / identifier / 'WebRTC.framework',
                            output / target / 'WebRTC.framework', symlinks=True)
        shutil.copytree(self.root / 'ios-arm64/dSYMs/WebRTC.framework.dSYM',
                        output / 'ios-arm64-device/WebRTC.dSYM')
        for name in ['fetch', 'gclient']:
            self.command(name, 'exit 99')  # Assembly must not fetch or compile.
        result = subprocess.run([str(SCRIPTS / 'build-webrtc-xcframework.sh')],
            env=dict(self.env, WEBRTC_BUILD_ROOT=str(build), DEPOT_TOOLS_DIR=str(self.commands),
                     WEBRTC_BRANCH='fixture', ASSEMBLE_ONLY='true'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        assembled = output / 'WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework'
        self.assertTrue((assembled / 'Resources/PrivacyInfo.xcprivacy').is_file())
        self.assertEqual((assembled / 'Resources/PrivacyInfo.xcprivacy').read_bytes(), PRIVACY)
        self.assertFalse((assembled / self.legacy.relative_to(self.mac)).exists())
        self.assertEqual(self.legacy.read_bytes(), PRIVACY)
        self.assertTrue((output / 'macos-x64/WebRTC.framework' / self.legacy.relative_to(self.mac)).exists())

    def normalize(self):
        return subprocess.run(['python3', str(SCRIPTS / 'webrtc_privacy.py'), str(self.root),
                               '--repair-known-macos-location'],
                              env=self.env, capture_output=True, text=True)

    def snapshot(self):
        return {str(p.relative_to(self.root)): ('link', os.readlink(p)) if p.is_symlink()
                else ('file', p.read_bytes()) for p in self.root.rglob('*')
                if p.is_symlink() or p.is_file()}

    def test_relocation_preserves_every_payload_and_is_idempotent(self):
        signature = self.root / 'ios-x86_64_arm64-simulator/WebRTC.framework/_CodeSignature/CodeResources'
        signature.parent.mkdir()
        signature.write_bytes(b'unchanged iOS resource signature')
        self.legacy.parent.mkdir(parents=True)
        self.manifest.rename(self.legacy)
        expected = self.snapshot()
        expected[str(self.manifest.relative_to(self.root))] = expected.pop(str(self.legacy.relative_to(self.root)))
        result = self.normalize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), expected)
        self.assertEqual((self.mac / 'Resources/PrivacyInfo.xcprivacy').read_bytes(), PRIVACY)
        result = self.normalize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), expected)

    def test_normalization_preflights_all_slices_before_moving_any_file(self):
        self.legacy.parent.mkdir(parents=True)
        self.manifest.rename(self.legacy)
        metadata = self.root / 'Info.plist'
        document = plistlib.loads(metadata.read_bytes())
        document['AvailableLibraries'].reverse()  # Mac is checked before the invalid iOS slice.
        metadata.write_bytes(plistlib.dumps(document))
        (self.root / 'ios-arm64/WebRTC.framework/PrivacyInfo.xcprivacy').unlink()
        before = self.snapshot()
        result = self.normalize()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_duplicate_and_sealed_mac_resources_are_not_automatically_rewritten(self):
        self.legacy.parent.mkdir(parents=True)
        self.legacy.write_bytes(PRIVACY)
        before = self.snapshot()
        self.assertNotEqual(self.normalize().returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.manifest.unlink()
        seal = self.mac / 'Versions/A/_CodeSignature/CodeResources'
        seal.parent.mkdir()
        seal.write_bytes(b'existing sealed resources')
        before = self.snapshot()
        self.assertNotEqual(self.normalize().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_plist_root_and_known_field_types_are_checked(self):
        for document in [[], {'NSPrivacyTracking': 'false'}, {'NSPrivacyAccessedAPITypes': 'none'}]:
            with self.subTest(document=document):
                self.manifest.write_bytes(plistlib.dumps(document))
                self.assertNotEqual(self.verify().returncode, 0)

    def test_external_xcframework_metadata_symlink_is_rejected(self):
        metadata = self.root / 'Info.plist'
        outside = self.base / 'outside.plist'
        metadata.rename(outside)
        metadata.symlink_to(outside)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)

    def test_valid_import_preserves_archive_and_records_its_checksum(self):
        import hashlib
        archive = self.archive()
        destination = self.base / 'installed'
        result = subprocess.run([str(SCRIPTS / 'import-webrtc-xcframework.sh')],
            env=dict(self.env, WEBRTC_XCFRAMEWORK_ZIP=str(archive),
                     WEBRTC_ARTIFACT_DIR=str(destination)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / 'WebRTC.xcframework.zip').read_bytes(), archive.read_bytes())
        self.assertIn('checksum=' + hashlib.sha256(archive.read_bytes()).hexdigest(),
                      (destination / 'WebRTC.xcframework.metadata').read_text())


if __name__ == '__main__':
    unittest.main()

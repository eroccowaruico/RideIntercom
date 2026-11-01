import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare_archive_info.py'


class ArchiveNumberingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'RideIntercom.xcodeproj').mkdir()
        (self.root / 'RideIntercom').mkdir()
        self.config = self.root / 'RideIntercom.xcodeproj/project.pbxproj'
        self.config.write_text('CURRENT_PROJECT_VERSION = 315;\nMARKETING_VERSION = 1.0;\nUNRELATED = keep;\n')
        self.source = self.root / 'RideIntercom/Info.plist'
        self.metadata = {'UIBackgroundModes': ['audio'], 'NSBonjourServices': ['_ride-intercom._tcp'],
                         'StorageNamespace': '$(RIDEINTERCOM_STORAGE_NAMESPACE)',
                         'RideIntercomAPNsEnvironment': '$(RIDEINTERCOM_APNS_ENVIRONMENT)',
                         'NSSupportsLiveActivities': True,
                         'CFBundleURLTypes': [{'CFBundleURLSchemes': ['rideintercom']}]}
        self.source.write_bytes(plistlib.dumps(self.metadata))
        self.env = dict(os.environ, SRCROOT=str(self.root), ACTION='build', CONFIGURATION='Debug')
        self.env.pop('RIDEINTERCOM_DEVELOPMENT_WORKER_HOST', None)
        self.env.pop('RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN', None)

    def run_phase(self, action='build', name='one'):
        output = self.root / name / 'Info.plist'
        result = subprocess.run([sys.executable, str(SCRIPT)],
            env=dict(self.env, ACTION=action, SCRIPT_OUTPUT_FILE_0=str(output)),
            capture_output=True, text=True)
        return result, output

    def install_development_credentials(self):
        self.env.update(RIDEINTERCOM_DEVELOPMENT_WORKER_HOST='preview.example.com',
                        RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN='synthetic-token')

    def test_debug_credentials_are_injected_without_logging(self):
        self.install_development_credentials()
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = plistlib.loads(output.read_bytes())['DevelopmentInternetConnection']
        self.assertEqual(config, {'workerURL': 'https://preview.example.com', 'accessToken': 'synthetic-token'})
        self.assertNotIn('synthetic-token', result.stdout + result.stderr)

    def test_release_archive_and_validation_never_embed_development_credentials(self):
        self.install_development_credentials()
        source = dict(self.metadata, DevelopmentInternetConnection={'accessToken': 'stale-secret'})
        self.source.write_bytes(plistlib.dumps(source))
        cases = [('Release', 'build', 'RideIntercom'),
                 ('Debug', 'install', 'RideIntercom'),
                 ('Debug', 'build', 'RideIntercom.Validation.private'),
                 ('Debug-Validation', 'build', 'RideIntercom'),
                 ('Release-Validation', 'build', 'RideIntercom')]
        for index, (configuration, action, namespace) in enumerate(cases):
            self.env.update(CONFIGURATION=configuration, RIDEINTERCOM_STORAGE_NAMESPACE=namespace)
            result, output = self.run_phase(action, name=f'isolated-{index}')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(output.read_bytes()), self.metadata)

    def test_source_custom_metadata_is_preserved_without_standard_field_generation(self):
        # Standard version, executable, platform and INFOPLIST_KEY settings belong
        # to Xcode's ProcessInfoPlistFile rather than this credential-only phase.
        self.env.update(CURRENT_PROJECT_VERSION='315', MARKETING_VERSION='1.0',
                        INFOPLIST_KEY_NSLocalNetworkUsageDescription='Xcode merges this')
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(output.read_bytes()), self.metadata)
        self.assertEqual(plistlib.loads(self.source.read_bytes()), self.metadata)

    def test_repeated_build_archive_and_indexing_leave_project_and_source_unchanged(self):
        before = self.config.read_bytes(), self.source.read_bytes()
        for action in ['build', 'install', 'indexbuild', 'analyze', 'build']:
            result, output = self.run_phase(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(output.read_bytes()), self.metadata)
        self.assertEqual(before, (self.config.read_bytes(), self.source.read_bytes()))
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])

    def test_preparation_needs_no_project_or_standard_metadata_settings(self):
        self.config.unlink()
        self.config.parent.rmdir()
        for key in ['CURRENT_PROJECT_VERSION', 'MARKETING_VERSION', 'EXECUTABLE_NAME',
                    'PRODUCT_BUNDLE_IDENTIFIER', 'PRODUCT_NAME', 'DEVELOPMENT_LANGUAGE', 'PLATFORM_NAME']:
            self.env.pop(key, None)
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(output.read_bytes()), self.metadata)
        self.assertFalse(self.config.parent.exists())

    def test_invalid_debug_credentials_fail_without_logging_or_changing_project(self):
        before = self.config.read_bytes()
        for host, token in [('preview.example.com/path', 'synthetic-token'),
                            ('preview.example.com', ''), ('', 'synthetic-token')]:
            self.env.update(RIDEINTERCOM_DEVELOPMENT_WORKER_HOST=host,
                            RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN=token)
            result, output = self.run_phase()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertNotIn('synthetic-token', result.stdout + result.stderr)
            self.assertEqual(self.config.read_bytes(), before)

    def test_invalid_source_metadata_fails_without_changing_project(self):
        before = self.config.read_bytes()
        self.source.write_bytes(b'not a plist')
        result, output = self.run_phase()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertEqual(self.config.read_bytes(), before)

    def test_output_failure_leaves_project_unchanged(self):
        before = self.config.read_bytes()
        (self.root / 'one').write_text('not a directory')
        result, output = self.run_phase()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_bytes(), before)


class BuildNumberSchemeTests(unittest.TestCase):
    def test_every_shared_scheme_advances_all_configurations_without_extra_state(self):
        import re
        import xml.etree.ElementTree as ET
        root = SCRIPT.parents[1]
        source = (root / 'RideIntercom.xcodeproj/project.pbxproj').read_text()
        pattern = r'CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)\s*;'
        original = {int(value) for value in re.findall(pattern, source)}
        self.assertEqual(len(original), 1)
        for scheme in (root / 'RideIntercom.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'):
            with self.subTest(scheme=scheme.name), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                project = directory / 'RideIntercom.xcodeproj'
                project.mkdir()
                config = project / 'project.pbxproj'
                config.write_text(source)
                actions = ET.parse(scheme).findall('BuildAction/PostActions/ExecutionAction/ActionContent')
                numbering = [action for action in actions if 'agvtool' in action.get('scriptText', '')]
                self.assertEqual(len(numbering), 1)
                result = subprocess.run(['/bin/sh', '-c', numbering[0].get('scriptText')],
                    env=dict(os.environ, PROJECT_DIR=str(directory), SDKROOT='auto',
                             DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                after = config.read_text()
                self.assertEqual({int(value) for value in re.findall(pattern, after)}, {next(iter(original)) + 1})
                self.assertEqual(re.sub(pattern, 'CURRENT_PROJECT_VERSION = <NUMBER>;', source),
                                 re.sub(pattern, 'CURRENT_PROJECT_VERSION = <NUMBER>;', after))
                self.assertEqual(sorted(path.relative_to(directory).as_posix() for path in directory.rglob('*')),
                                 ['RideIntercom.xcodeproj', 'RideIntercom.xcodeproj/project.pbxproj'])

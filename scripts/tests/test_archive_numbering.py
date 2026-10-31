import concurrent.futures
import os
from pathlib import Path
import plistlib
import re
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
        self.config.write_text('CURRENT_PROJECT_VERSION = 7;\nCURRENT_PROJECT_VERSION = 7;\nMARKETING_VERSION = 1.0.0;\nUNRELATED = keep;\n')
        self.source = self.root / 'RideIntercom/Info.plist'
        self.source.write_bytes(plistlib.dumps({'UIBackgroundModes': ['audio'], 'NSBonjourServices': ['_ride-intercom._tcp'], 'StorageNamespace': '$(RIDEINTERCOM_STORAGE_NAMESPACE)'}))
        self.env = dict(os.environ, SRCROOT=str(self.root), ACTION='build', PLATFORM_NAME='iphoneos',
                        CURRENT_PROJECT_VERSION='7', MARKETING_VERSION='1.0.0',
                        DEVELOPMENT_LANGUAGE='en', PRODUCT_BUNDLE_IDENTIFIER='example.Ride',
                        PRODUCT_NAME='Ride', EXECUTABLE_NAME='Ride', PRODUCT_BUNDLE_PACKAGE_TYPE='APPL',
                        INFOPLIST_KEY_CFBundleDisplayName='RideCom',
                        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption='NO',
                        INFOPLIST_KEY_NSLocalNetworkUsageDescription='Local network purpose',
                        INFOPLIST_KEY_NSMicrophoneUsageDescription='Microphone purpose',
                        INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES',
                        INFOPLIST_KEY_UILaunchScreen_Generation='YES',
                        INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents='YES',
                        INFOPLIST_KEY_UISupportedInterfaceOrientations='UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft')

    def run_phase(self, action='build', name='one'):
        output = self.root / name / 'Info.plist'
        reservation = self.root / 'reservations' / (name + '.plist')
        result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(self.env, ACTION=action,
            RIDEINTERCOM_RESERVE_BUILD_NUMBER='YES', SCRIPT_OUTPUT_FILE_0=str(reservation)), capture_output=True, text=True)
        if result.returncode:
            return result, output
        result = subprocess.run([sys.executable, str(SCRIPT)],
            env=dict(self.env, ACTION=action, RIDEINTERCOM_BUILD_NUMBER_FROM=str(reservation), SCRIPT_OUTPUT_FILE_0=str(output)),
            capture_output=True, text=True)
        return result, output

    def value(self):
        values = re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', self.config.read_text())
        self.assertTrue(values)
        self.assertEqual(len(set(values)), 1)
        return int(values[0])

    def install_development_credentials(self):
        self.env.update(RIDEINTERCOM_DEVELOPMENT_WORKER_HOST='preview.example.com',
                        RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN='synthetic-mac-token')

    def test_debug_defaults_select_the_platform_without_logging_credentials(self):
        self.install_development_credentials()
        for platform, token in [('macosx', 'synthetic-mac-token'),
                                ('iphoneos', 'synthetic-phone-token'),
                                ('iphonesimulator', 'synthetic-phone-token')]:
            self.env.update(CONFIGURATION='Debug', PLATFORM_NAME=platform,
                            RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN=token)
            result, output = self.run_phase(name=platform)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = plistlib.loads(output.read_bytes())['DevelopmentInternetConnection']
            self.assertEqual(config, {'workerURL': 'https://preview.example.com', 'accessToken': token})
            self.assertNotIn(token, result.stdout + result.stderr)

    def test_release_archive_and_local_test_builds_never_embed_development_defaults(self):
        self.install_development_credentials()
        source = plistlib.loads(self.source.read_bytes())
        source['DevelopmentInternetConnection'] = {'accessToken': 'stale-secret'}
        self.source.write_bytes(plistlib.dumps(source))
        cases = [('Release', 'build', 'RideIntercom'),
                 ('Debug', 'install', 'RideIntercom'),
                 ('Debug', 'build', 'RideIntercom.Validation.private')]
        for index, (configuration, action, namespace) in enumerate(cases):
            self.env.update(CONFIGURATION=configuration, RIDEINTERCOM_STORAGE_NAMESPACE=namespace)
            result, output = self.run_phase(action, name=f'isolated-{index}')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('DevelopmentInternetConnection', plistlib.loads(output.read_bytes()))

    def test_debug_without_local_credentials_remains_unconfigured(self):
        self.env['CONFIGURATION'] = 'Debug'
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('DevelopmentInternetConnection', plistlib.loads(output.read_bytes()))

    def test_indexing_and_analysis_leave_counter_and_source_untouched(self):
        before = self.config.read_bytes(), self.source.read_bytes()
        for action in ['indexbuild', 'analyze']:
            result, output = self.run_phase(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(output.read_bytes())['CFBundleVersion'], '7')
        self.assertEqual(before, (self.config.read_bytes(), self.source.read_bytes()))

    def test_archives_use_reserved_number_even_with_cached_build_settings(self):
        for number in ['8', '9']:
            result, output = self.run_phase('install')
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads(output.read_bytes())
            self.assertEqual(info['CFBundleVersion'], number)
            self.assertEqual(info['CFBundleShortVersionString'], '1.0.0')
            self.assertEqual(self.value(), int(number))
        result, output = self.run_phase('build')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(output.read_bytes())['CFBundleVersion'], '10')

    def test_parallel_archives_reserve_distinct_numbers(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda n: self.run_phase('install', str(n)), range(8)))
        numbers = []
        for result, output in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            numbers.append(int(plistlib.loads(output.read_bytes())['CFBundleVersion']))
        self.assertEqual(sorted(numbers), list(range(8, 16)))
        self.assertEqual(self.value(), 15)

    def test_invalid_counter_and_metadata_fail_without_reuse(self):
        for bad in ['', 'CURRENT_PROJECT_VERSION = nope;\n', 'CURRENT_PROJECT_VERSION = 0x10;\n', 'CURRENT_PROJECT_VERSION = 7;\nCURRENT_PROJECT_VERSION = 8;\n']:
            self.config.write_text(bad)
            result, output = self.run_phase('install')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(self.config.read_text(), bad)
        self.config.write_text('CURRENT_PROJECT_VERSION = 7;\n')
        self.env['INFOPLIST_KEY_ITSAppUsesNonExemptEncryption'] = 'maybe'
        result, output = self.run_phase('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.value(), 8)

    def test_metadata_types_and_existing_content_survive(self):
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads(output.read_bytes())
        self.assertIs(info['ITSAppUsesNonExemptEncryption'], False)
        self.assertEqual(info['UIBackgroundModes'], ['audio'])
        self.assertEqual(info['NSBonjourServices'], ['_ride-intercom._tcp'])
        self.assertEqual(info['StorageNamespace'], '$(RIDEINTERCOM_STORAGE_NAMESPACE)')
        self.assertTrue(info['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes'])
        self.assertEqual(info['UILaunchScreen'], {})
        self.assertEqual(info['UISupportedInterfaceOrientations'], ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft'])
        self.assertEqual(info['NSMicrophoneUsageDescription'], 'Microphone purpose')

    def test_failed_output_does_not_roll_back_reserved_number(self):
        (self.root / 'one').write_text('not a directory')
        result, output = self.run_phase('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.value(), 8)

    def test_missing_counter_fails_instead_of_resetting(self):
        self.config.unlink()
        result, output = self.run_phase('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse(self.config.exists())

    def test_macos_omits_ios_generation_when_settings_are_absent(self):
        self.env['PLATFORM_NAME'] = 'macosx'
        for key in ['UIApplicationSceneManifest_Generation', 'UILaunchScreen_Generation', 'UIApplicationSupportsIndirectInputEvents']:
            self.env.pop('INFOPLIST_KEY_' + key)
        result, output = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads(output.read_bytes())
        for key in ['LSRequiresIPhoneOS', 'UIApplicationSceneManifest', 'UILaunchScreen']:
            self.assertNotIn(key, info)
        self.assertEqual(info['CFBundleShortVersionString'], '1.0.0')
        self.assertIs(info['UIApplicationSupportsIndirectInputEvents'], False)
        self.assertEqual(info['UIStatusBarStyle'], '')

    def test_archive_preserves_other_settings_and_leaves_no_management_files(self):
        before = self.config.read_text()
        result, output = self.run_phase('install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), before.replace('CURRENT_PROJECT_VERSION = 7;', 'CURRENT_PROJECT_VERSION = 8;'))
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])
        self.assertFalse((self.root / 'Configuration').exists())

    def test_counter_grows_to_eight_digits_without_padding_or_truncation(self):
        self.config.write_text('CURRENT_PROJECT_VERSION = 9999999;\nCURRENT_PROJECT_VERSION = 9999999;\n')
        result, output = self.run_phase('install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.value(), 10000000)
        self.assertEqual(plistlib.loads(output.read_bytes())['CFBundleVersion'], '10000000')

    def test_debug_release_and_archive_share_one_sequence(self):
        sequence = [('Debug', 'build')] * 100 + [('Release', 'build')] * 3 + [('Release', 'install')] * 3 + [('Debug', 'build')]
        for number, (configuration, action) in enumerate(sequence, start=8):
            self.env['CONFIGURATION'] = configuration
            result, output = self.run_phase(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads(output.read_bytes())
            self.assertEqual(info['CFBundleVersion'], str(number))
            self.assertEqual(self.value(), number)
            self.assertEqual(info['CFBundleShortVersionString'], '1.0.0')

    def test_consumers_adopt_same_reservation_without_rewinding_parallel_counter(self):
        outputs = []
        for name in ['first', 'second']:
            reservation = self.root / name / 'number.plist'
            result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(self.env,
                RIDEINTERCOM_RESERVE_BUILD_NUMBER='YES', SCRIPT_OUTPUT_FILE_0=str(reservation)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs.append(reservation)
        self.assertEqual(self.value(), 9)
        for name in ['Widget', 'Watch', 'App']:
            output = self.root / name / 'Info.plist'
            result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(self.env,
                RIDEINTERCOM_BUILD_NUMBER_FROM=str(outputs[0]), SCRIPT_OUTPUT_FILE_0=str(output)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(output.read_bytes())['CFBundleVersion'], '8')
            self.assertEqual(self.value(), 9)

    def test_missing_invalid_or_future_reservation_fails_without_counter_change(self):
        reservation = self.root / 'number.plist'
        for data in [None, b'bad plist', plistlib.dumps({'CFBundleVersion': 'nope'}), plistlib.dumps({'CFBundleVersion': '8'})]:
            if data is not None:
                reservation.write_bytes(data)
            output = self.root / 'consumer.plist'
            result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(self.env,
                RIDEINTERCOM_BUILD_NUMBER_FROM=str(reservation), SCRIPT_OUTPUT_FILE_0=str(output)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(self.value(), 7)

    def test_extension_input_does_not_copy_app_credentials_or_privacy_keys(self):
        self.install_development_credentials(); self.env['CONFIGURATION'] = 'Debug'
        source = self.root / 'RideIntercomWidgets/Info.plist'; source.parent.mkdir()
        source.write_bytes(plistlib.dumps({'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}))
        self.env['RIDEINTERCOM_INFO_SOURCE'] = 'RideIntercomWidgets/Info.plist'
        result, output = self.run_phase(name='widget')
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads(output.read_bytes())
        self.assertIn('NSExtension', info)
        for key in ['DevelopmentInternetConnection', 'NSMicrophoneUsageDescription', 'NSLocalNetworkUsageDescription', 'UIApplicationSceneManifest']:
            self.assertNotIn(key, info)

    def test_failed_widget_attempt_consumes_reservation_and_next_build_reserves_again(self):
        reservation = self.root / 'number.plist'
        env = dict(self.env, RIDEINTERCOM_RESERVE_BUILD_NUMBER='YES', SCRIPT_OUTPUT_FILE_0=str(reservation))
        result = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        # The dependent widget build fails after preparation; no app consumer runs.
        self.assertEqual(self.value(), 8)
        result = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(reservation.read_bytes())['CFBundleVersion'], '9')
        self.assertEqual(self.value(), 9)

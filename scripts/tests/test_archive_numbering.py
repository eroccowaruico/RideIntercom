import concurrent.futures
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
        (self.root / 'Configuration').mkdir()
        (self.root / 'RideIntercom').mkdir()
        self.config = self.root / 'Configuration/BuildNumber.xcconfig'
        self.config.write_text('// Shared build number\nCURRENT_PROJECT_VERSION = 7\n')
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
        result = subprocess.run([sys.executable, str(SCRIPT)],
                                env=dict(self.env, ACTION=action, SCRIPT_OUTPUT_FILE_0=str(output)),
                                capture_output=True, text=True)
        return result, output

    def value(self):
        return int(self.config.read_text().split('=')[1])

    def test_internal_builds_leave_counter_and_source_untouched(self):
        before = self.config.read_bytes(), self.source.read_bytes()
        for action in ['build', 'indexbuild', 'analyze']:
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
        self.assertEqual(plistlib.loads(output.read_bytes())['CFBundleVersion'], '9')

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
        for bad in ['', 'CURRENT_PROJECT_VERSION = nope\n', 'CURRENT_PROJECT_VERSION = 0x10\n', 'CURRENT_PROJECT_VERSION = 7\nCURRENT_PROJECT_VERSION = 8\n']:
            self.config.write_text(bad)
            result, output = self.run_phase('install')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(self.config.read_text(), bad)
        self.config.write_text('CURRENT_PROJECT_VERSION = 7\n')
        self.env['INFOPLIST_KEY_ITSAppUsesNonExemptEncryption'] = 'maybe'
        result, output = self.run_phase('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.value(), 7)

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

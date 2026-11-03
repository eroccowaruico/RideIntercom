"""App product resolution and host isolation without Xcode or Simulator access."""
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from scripts import validate, xcode_paths


class XcodeProductPathTests(unittest.TestCase):
    def settings(self, root, product, platform):
        products = Path(root).resolve() / 'Products'
        return dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(products / ('Debug-Validation-' + platform)),
                    FULL_PRODUCT_NAME=product, CONFIGURATION='Debug-Validation', PLATFORM_NAME=platform,
                    RIDEINTERCOM_STORAGE_NAMESPACE='RideIntercom.Validation.Xcode')

    def test_primary_app_product_preserves_ios_and_mac_and_selects_watch(self):
        with tempfile.TemporaryDirectory() as root:
            for scheme, target, product, platform, destination in [
                ('RideIntercom', 'RideIntercom', 'RideIntercom.app', 'iphonesimulator', 'platform=iOS Simulator,id=owned'),
                ('RideIntercom', 'RideIntercom', 'RideIntercom.app', 'macosx', 'platform=macOS,arch=arm64'),
                ('RideIntercomWatch', 'RideIntercomWatch', 'RideIntercomWatch.app', 'watchsimulator', 'platform=watchOS Simulator,id=owned'),
            ]:
                with self.subTest(platform=platform):
                    expected = self.settings(root, product, platform)
                    rows = [{'target': target, 'buildSettings': expected}]
                    if target != 'RideIntercom':
                        rows.insert(0, {'target': 'RideIntercom', 'buildSettings': self.settings(root, 'RideIntercom.app', 'iphonesimulator')})
                    result = SimpleNamespace(returncode=0, stdout=json.dumps(rows))
                    with patch.object(xcode_paths.subprocess, 'run', return_value=result):
                        self.assertEqual(xcode_paths.xcode_build_settings(validate.ROOT, scheme, destination, 'Debug-Validation'), expected)

    def test_scheme_written_by_xcode_without_target_name_resolves_by_product(self):
        with tempfile.TemporaryDirectory() as root:
            schemes = Path(root) / 'RideIntercom.xcodeproj/xcshareddata/xcschemes'
            schemes.mkdir(parents=True)
            (schemes / 'Watch.xcscheme').write_text(
                '<Scheme><LaunchAction><BuildableProductRunnable><BuildableReference '
                'BuildableName="RideIntercomWatch.app"/></BuildableProductRunnable></LaunchAction></Scheme>')
            self.assertEqual(xcode_paths.scheme_primary_app(root, 'Watch'), (None, 'RideIntercomWatch.app'))
            expected = self.settings(root, 'RideIntercomWatch.app', 'watchsimulator')
            rows = [{'target': 'RideIntercomWatchUITests', 'buildSettings': dict(expected, FULL_PRODUCT_NAME='Tests.xctest')},
                    {'target': 'RideIntercomWatch', 'buildSettings': expected}]
            with patch.object(xcode_paths.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(rows))):
                self.assertEqual(xcode_paths.xcode_build_settings(root, 'Watch', 'platform=watchOS Simulator,id=owned',
                                                                  'Debug-Validation'), expected)

    def test_watch_rejects_wrong_product_platform_and_duplicate_primary_target(self):
        with tempfile.TemporaryDirectory() as root:
            good = self.settings(root, 'RideIntercomWatch.app', 'watchsimulator')
            for values, duplicate in [(dict(good, FULL_PRODUCT_NAME='RideIntercom.app'), False),
                                      (dict(good, PLATFORM_NAME='iphonesimulator'), False), (good, True)]:
                rows = [{'target': 'RideIntercomWatch', 'buildSettings': values}] * (2 if duplicate else 1)
                with patch.object(xcode_paths.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(rows))):
                    with self.assertRaises(ValueError):
                        xcode_paths.xcode_build_settings(validate.ROOT, 'RideIntercomWatch', 'platform=watchOS Simulator,id=owned', 'Debug-Validation')

    def test_watch_host_preflight_checks_selected_app_namespace_and_credentials(self):
        with tempfile.TemporaryDirectory() as root:
            products = Path(root).resolve()
            app = products / 'Debug-Validation-watchsimulator/RideIntercomWatch.app'
            app.mkdir(parents=True)
            info = app / 'Info.plist'
            run = products / 'RideIntercomWatch_watchsimulator.xctestrun'
            run.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{
                'TestHostPath': '__TESTROOT__/Debug-Validation-watchsimulator/WatchUITests-Runner.app',
                'UITargetAppPath': '__TESTROOT__/Debug-Validation-watchsimulator/RideIntercomWatch.app'}]}]}))
            namespace = 'RideIntercom.Validation.Xcode'
            info.write_bytes(plistlib.dumps({'StorageNamespace': namespace}))
            report = validate.test_host_metadata(run, namespace, expected_product='RideIntercomWatch.app')
            self.assertEqual(report['hostInfoPaths'], [str(info)])
            with self.assertRaises(ValueError):
                validate.test_host_metadata(run, namespace)
            for metadata in [{'StorageNamespace': 'RideIntercom'},
                             {'StorageNamespace': namespace, 'DevelopmentInternetConnection': {'accessToken': 'fixture-secret'}}]:
                info.write_bytes(plistlib.dumps(metadata))
                with self.assertRaises(ValueError) as error:
                    validate.test_host_metadata(run, namespace, expected_product='RideIntercomWatch.app')
                self.assertNotIn('fixture-secret', str(error.exception))

    def test_watch_test_configuration_is_isolated_but_run_remains_debug(self):
        self.assertEqual(xcode_paths.scheme_configuration(validate.ROOT, 'RideIntercomWatch'), 'Debug-Validation')
        self.assertEqual(xcode_paths.scheme_configuration(validate.ROOT, 'RideIntercomWatch', 'LaunchAction'), 'Debug')


if __name__ == '__main__':
    unittest.main()

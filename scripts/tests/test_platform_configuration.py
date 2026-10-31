"""Cross-product permissions and distribution inputs must agree before signing."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlatformConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('platform_configuration', ROOT / 'scripts/check_platform_configuration.py')
        cls.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.checker)
        cls.project = cls.checker.load_project(ROOT)

    def test_repository_has_complete_minimum_platform_inputs(self):
        self.assertEqual(self.checker.check(ROOT, self.project), [])

    def test_watch_icon_omission_is_rejected(self):
        project = copy.deepcopy(self.project)
        for settings in self.checker.target_settings(project, 'RideIntercomWatch'):
            settings.pop('ASSETCATALOG_COMPILER_APPICON_NAME', None)
        self.assertTrue(any('Watch AppIcon' in e for e in self.checker.check(ROOT, project)))

    def test_apns_configuration_cannot_drift_from_info_and_entitlement_contract(self):
        project = copy.deepcopy(self.project)
        for settings in self.checker.target_settings(project, 'RideIntercom'):
            settings['RIDEINTERCOM_APNS_ENVIRONMENT'] = 'sandbox'
        self.assertTrue(any('APNs environment' in e for e in self.checker.check(ROOT, project)))

    def test_mac_cannot_use_ios_apns_entitlement(self):
        project = copy.deepcopy(self.project)
        for settings in self.checker.target_settings(project, 'RideIntercom'):
            settings.pop('CODE_SIGN_ENTITLEMENTS[sdk=macosx*]', None)
        self.assertTrue(any('macOS entitlement' in e for e in self.checker.check(ROOT, project)))

    def test_audio_and_local_network_need_both_sandbox_directions(self):
        project = copy.deepcopy(self.project)
        for settings in self.checker.target_settings(project, 'RideIntercom'):
            settings['ENABLE_INCOMING_NETWORK_CONNECTIONS'] = 'NO'
        self.assertTrue(any('sandbox network' in e for e in self.checker.check(ROOT, project)))

    def test_embed_product_cannot_be_removed(self):
        project = copy.deepcopy(self.project)
        for obj in project['objects'].values():
            if obj.get('isa') == 'PBXCopyFilesBuildPhase' and obj.get('dstSubfolderSpec') == '13':
                obj['files'] = []
        self.assertTrue(any('embed Widget' in e for e in self.checker.check(ROOT, project)))


if __name__ == '__main__':
    unittest.main()

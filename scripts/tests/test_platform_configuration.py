"""Cross-product permissions and distribution inputs must agree before signing."""
import copy
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class PlatformConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('platform_configuration', ROOT / 'scripts/check_platform_configuration.py')
        cls.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.checker)
        cls.project = cls.checker.load_project(ROOT)

    def test_watch_scheme_has_standard_run_profile_analyze_and_archive_actions(self):
        scheme = ET.parse(ROOT / 'RideIntercom.xcodeproj/xcshareddata/xcschemes/RideIntercomWatch.xcscheme').getroot()
        for name, configuration in [('LaunchAction', 'Debug'), ('ProfileAction', 'Release'),
                                    ('AnalyzeAction', 'Debug'), ('ArchiveAction', 'Release')]:
            with self.subTest(action=name):
                action = scheme.find(name)
                self.assertIsNotNone(action)
                self.assertEqual(action.get('buildConfiguration'), configuration)
                if name in ('LaunchAction', 'ProfileAction'):
                    reference = action.find('BuildableProductRunnable/BuildableReference')
                    self.assertIsNotNone(reference)
                    self.assertEqual(reference.get('BlueprintIdentifier'), '0CCFFDBF2F4415059F932F5F')
                    self.assertEqual(reference.get('BuildableName'), 'RideIntercomWatch.app')

    def test_repository_has_complete_minimum_platform_inputs(self):
        self.assertEqual(self.checker.check(ROOT, self.project), [])

    def test_named_validation_configurations_allow_mac_fixture_settings(self):
        for name in ('Debug-Validation', 'Debug-StoreKitValidation', 'Release-Validation'):
            with self.subTest(configuration=name):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                target = next(o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'RideIntercom')
                keys = objects[target['buildConfigurationList']]['buildConfigurations']
                config = copy.deepcopy(objects[keys[0]])
                config['name'] = name
                config['buildSettings']['ENABLE_APP_SANDBOX'] = '$(RIDEINTERCOM_VALIDATION_SANDBOX)'
                config['buildSettings']['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = '$(RIDEINTERCOM_VALIDATION_ENTITLEMENTS)'
                objects['TEST_VALIDATION_CONFIG'] = config
                keys.append('TEST_VALIDATION_CONFIG')
                self.assertEqual(self.checker.check(ROOT, project), [])
                config['buildSettings']['ENABLE_APP_SANDBOX'] = 'NO'
                self.assertTrue(any('sandbox network' in e for e in self.checker.check(ROOT, project)))

    def test_shipping_configurations_cannot_borrow_validation_exceptions(self):
        project = copy.deepcopy(self.project)
        for settings in self.checker.target_settings(project, 'RideIntercom'):
            settings['ENABLE_APP_SANDBOX'] = '$(RIDEINTERCOM_VALIDATION_SANDBOX)'
            settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = '$(RIDEINTERCOM_VALIDATION_ENTITLEMENTS)'
        errors = self.checker.check(ROOT, project)
        self.assertTrue(any('macOS entitlement' in e for e in errors))
        self.assertTrue(any('sandbox network' in e for e in errors))

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
        objects = project['objects']
        widget_refs = {key for key, obj in objects.items()
                       if obj.get('isa') == 'PBXFileReference' and obj.get('path') == 'RideIntercomWidgets.appex'}
        self.assertEqual(len(widget_refs), 1)
        widget_build_files = {key for key, obj in objects.items()
                              if obj.get('isa') == 'PBXBuildFile' and obj.get('fileRef') in widget_refs}
        app = next(obj for obj in objects.values()
                   if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        removed = 0
        for phase_id in app['buildPhases']:
            phase = objects[phase_id]
            if phase.get('isa') == 'PBXCopyFilesBuildPhase':
                original = phase.get('files', [])
                phase['files'] = [key for key in original if key not in widget_build_files]
                removed += len(original) - len(phase['files'])
        self.assertEqual(removed, 1, 'The fixture must remove exactly one Widget embed entry.')
        self.assertTrue(any('embed Widget' in e for e in self.checker.check(ROOT, project)))


if __name__ == '__main__':
    unittest.main()

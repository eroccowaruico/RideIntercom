"""Exercise the real local runner without Xcode, devices, or network access."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('validation', Path(__file__).resolve().parents[1] / 'validate.py')


class ValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(cls.module)
        from scripts import xcode_paths
        cls.paths = xcode_paths

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.runner = self.module.Runner(Path(self.temporary.name) / 'run', timeout=1)

    def test_storekit_plan_selects_local_catalog_and_isolated_fixture(self):
        import xml.etree.ElementTree as ET
        root = Path(__file__).resolve().parents[2]
        scheme = ET.parse(root / 'RideIntercom.xcodeproj/xcshareddata/xcschemes/RideIntercom-StoreKitTests.xcscheme')
        reference = scheme.find('TestAction/TestPlans/TestPlanReference')
        self.assertIsNotNone(reference)
        plan_path = root / reference.attrib['reference'].removeprefix('container:')
        plan = json.loads(plan_path.read_text())
        options = plan['defaultOptions']
        catalog = plan_path.parent / options['storeKitConfiguration']['identifier']
        self.assertEqual(catalog.resolve(), (root / 'RideIntercomTests/Fixtures/LocalPurchases.storekit').resolve())
        self.assertTrue(catalog.is_file())
        environment = {v['key']: v['value'] for v in options['environmentVariableEntries']}
        self.assertEqual(environment['RIDEINTERCOM_LOCAL_TESTING'], '1')
        self.assertEqual(environment['RIDEINTERCOM_ACCOUNT_FIXTURE'], 'signed-out')
        target = plan['testTargets'][0]['target']
        self.assertEqual(target['name'], 'RideIntercomTests')
        self.assertEqual(target['identifier'], '93F300D82F93829D0046716D')
        self.assertEqual(target['containerPath'], 'container:RideIntercom.xcodeproj')

    def test_failure_blocks_dependent_but_not_independent_stage(self):
        self.assertFalse(self.runner.run('prepare', [sys.executable, '-c', 'raise SystemExit(3)']))
        marker = Path(self.temporary.name) / 'should-not-exist'
        self.assertFalse(self.runner.run('dependent', [sys.executable, '-c', f'open({str(marker)!r}, "w").close()'], needs=['prepare']))
        self.assertTrue(self.runner.run('independent', [sys.executable, '-c', 'print("ok")']))
        self.assertFalse(marker.exists())
        self.assertEqual(self.runner.results['dependent']['status'], 'blocked')
        self.assertNotEqual(self.runner.exit_code, 0)

    def test_missing_command_and_output_collision_are_failures(self):
        self.assertFalse(self.runner.run('missing', ['/no/such/rideintercom-command']))
        with self.assertRaises(FileExistsError):
            self.module.Runner(self.runner.out)

    def test_timeout_kills_owned_child_process_group(self):
        child = Path(self.temporary.name) / 'child.pid'
        code = ('import subprocess,time; p=subprocess.Popen(["sleep","60"]); '
                f'open({str(child)!r},"w").write(str(p.pid)); time.sleep(60)')
        self.assertFalse(self.runner.run('timeout', [sys.executable, '-c', code], timeout=0.2))
        self.assertEqual(self.runner.results['timeout']['status'], 'timeout')
        pid = int(child.read_text())
        # A terminated child may briefly be a zombie until its parent is reaped.
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith('Z'), state)

    def test_timeout_reaps_separate_session_child_without_touching_unrelated_process(self):
        marker = Path(self.temporary.name) / 'separate-session.pid'
        child_code = ('import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                      f'open({str(marker)!r}, "w").write(str(os.getpid())); time.sleep(60)')
        parent_code = ('import subprocess,time; '
                       f'subprocess.Popen([{sys.executable!r}, "-c", {child_code!r}], start_new_session=True); '
                       'time.sleep(60)')
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        try:
            self.assertFalse(self.runner.run('separate', [sys.executable, '-c', parent_code], timeout=0.5))
            self.assertEqual(self.runner.results['separate']['status'], 'timeout')
            self.assertEqual(self.runner.results['separate']['exit_code'], 124)
            self.assertIsNone(unrelated.poll())
            state = subprocess.run(['ps', '-o', 'stat=', '-p', marker.read_text()], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
            self.assertFalse(self.runner.run('dependent', [sys.executable, '-c', 'pass'], needs=['separate']))
            self.assertTrue(self.runner.run('independent', [sys.executable, '-c', 'pass']))
            self.assertEqual(self.runner.exit_code, 1)
        finally:
            try:
                # Recover the deliberately leaked red fixture, never by executable name.
                if marker.exists():
                    pid = int(marker.read_text())
                    command = subprocess.run(['ps', '-ww', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
                    if str(marker) in command:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            finally:
                unrelated.kill()
                unrelated.wait(timeout=5)

    def test_zero_skipped_and_failed_tests_are_rejected(self):
        for output in ['Ran 0 tests\nOK', 'Ran 2 tests\nOK (skipped=1)',
                       'Test run with 0 tests passed', '# tests 2\n# pass 1\n# fail 1\n# skipped 0']:
            self.assertFalse(self.module.tests_passed(output), output)
        for output in ['Ran 2 tests in 0.1s\n\nOK',
                       '✔ Test run with 5 tests in 1 suite passed after 1.0 seconds.',
                       '# tests 2\n# pass 2\n# fail 0\n# skipped 0\n# cancelled 0\n# todo 0']:
            self.assertTrue(self.module.tests_passed(output), output)

    def test_missing_or_skipped_xcresult_is_rejected(self):
        self.assertFalse(self.module.xcode_tests_passed({}))
        self.assertFalse(self.module.xcode_tests_passed({'totalTestCount': 2, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 1}))
        self.assertTrue(self.module.xcode_tests_passed({'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0}))

    def test_required_swift_version_is_not_just_a_present_binary(self):
        for version in ['Apple Swift version 6.2', '', 'swift-driver version: 1.1']:
            self.assertFalse(self.module.swift_supported(version))
        self.assertTrue(self.module.swift_supported('Apple Swift version 6.3 (swiftlang)'))
        self.assertTrue(self.module.swift_supported('Swift version 7.0'))

    def test_passing_tests_with_runtime_faults_are_rejected(self):
        summary = {'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0}
        for field in ['runtimeWarnings', 'testFailures']:
            self.assertFalse(self.module.xcode_tests_passed({**summary, field: [{'message': 'native runtime fault'}]}))
        self.assertTrue(self.module.xcode_tests_passed({**summary, 'runtimeWarnings': [], 'testFailures': []}))

    def test_interrupt_records_failure_and_stops_owned_children(self):
        folder = Path(self.temporary.name) / 'interrupt'
        marker = Path(self.temporary.name) / 'interrupt-child.pid'
        leaf_code = f'import os,time; open({str(marker)!r}, "w").write(str(os.getpid())); time.sleep(60)'
        child_code = ('import subprocess,time; '
                      f'subprocess.Popen([{sys.executable!r}, "-c", {leaf_code!r}], start_new_session=True); '
                      'time.sleep(60)')
        script = ('from scripts.validate import Runner\n'
                  f'r = Runner({str(folder)!r})\n'
                  'try:\n'
                  f'    r.run("child", [{sys.executable!r}, "-c", {child_code!r}])\n'
                  'except KeyboardInterrupt:\n    raise SystemExit(130)\n')
        process = subprocess.Popen([sys.executable, '-c', script], cwd=self.module.ROOT, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGINT)
            self.assertEqual(process.wait(timeout=5), 130)
            self.assertEqual(json.loads((folder / 'results.json').read_text())['child']['status'], 'interrupted')
            state = subprocess.run(['ps', '-o', 'stat=', '-p', marker.read_text()], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'))
        finally:
            if process.poll() is None:
                process.kill(); process.wait()

    def test_cleanup_failure_preserves_timeout_status_and_exit_code(self):
        with patch.object(self.module, 'stop_process_tree', side_effect=RuntimeError('fixture cleanup failed')):
            self.assertFalse(self.runner.run('cleanup-failure', [sys.executable, '-c', 'import time; time.sleep(60)'], timeout=0.05))
        result = self.runner.results['cleanup-failure']
        self.assertEqual((result['status'], result['exit_code']), ('timeout', 124))
        self.assertIn('fixture cleanup failed', result['reason'])

    def test_results_preserve_command_and_failure(self):
        self.runner.run('bad', [sys.executable, '-c', 'raise SystemExit(7)'])
        saved = json.loads((self.runner.out / 'results.json').read_text())
        self.assertEqual(saved['bad']['exit_code'], 7)
        self.assertEqual(saved['bad']['status'], 'failed')
        self.assertIn('command', saved['bad'])

    def xcode_fixture(self, name, destination, *, fault=None, reuse_build=None,
                      scheme='RideIntercom', only_tests=None, stale_platform=False):
        """Mock Xcode's standard output while exercising the real host gate."""
        commands = {}
        original_run = self.runner.run
        marker = self.runner.out / (name + '-host-started')
        configuration = 'Debug-StoreKitValidation' if 'StoreKit' in scheme else 'Debug-Validation'
        namespace = 'RideIntercom.Validation.XcodeStoreKit' if 'StoreKit' in scheme else 'RideIntercom.Validation.Xcode'
        platform = 'macosx' if destination.startswith('platform=macOS') else 'iphonesimulator'
        products = Path(self.temporary.name) / 'Xcode Default/Build/Products'
        target_dir = products / (configuration + ('' if platform == 'macosx' else '-iphonesimulator'))
        settings = dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(target_dir),
                        FULL_PRODUCT_NAME='RideIntercom.app', CONFIGURATION=configuration,
                        PLATFORM_NAME=platform, RIDEINTERCOM_STORAGE_NAMESPACE=namespace)
        def run(stage, command, **kwargs):
            commands[stage] = command
            code = 'pass'
            if 'build-for-testing' in command:
                app = target_dir / 'RideIntercom.app'
                info = app / ('Contents/Info.plist' if platform == 'macosx' else 'Info.plist')
                info.parent.mkdir(parents=True, exist_ok=True)
                values = {'StorageNamespace': namespace, 'CFBundleVersion': '315'}
                if fault in ('RideIntercom', 'RideIntercom.Validation.other.run', '$(RIDEINTERCOM_STORAGE_NAMESPACE)', ''):
                    values['StorageNamespace'] = fault
                elif fault == 'missing-namespace':
                    values.pop('StorageNamespace')
                elif fault == 'credential':
                    values['DevelopmentInternetConnection'] = {'accessToken': 'must-not-appear-in-diagnostics'}
                info.write_bytes(b'broken' if fault == 'broken' else plistlib.dumps(values))
                if fault == 'missing-info':
                    info.unlink()
                host = '__TESTROOT__/' + str(app.relative_to(products))
                targets = [{'TestHostPath': host}, {'TestHostPath': '__TESTROOT__/UI-Runner.app', 'UITargetAppPath': host}]
                if fault == 'outside-host':
                    targets[0]['TestHostPath'] = str(self.runner.out / 'RideIntercom.app')
                if fault != 'missing-run':
                    (products / (scheme + '_' + platform + '_fixture.xctestrun')).write_bytes(
                        plistlib.dumps({'TestPlan': {'Name': 'StoreKit' if scheme == 'RideIntercom-StoreKitTests' else scheme},
                                       'TestConfigurations': [{'TestTargets': targets}]}))
                if stale_platform:
                    wrong = '__TESTROOT__/Debug-Validation-macosx/RideIntercom.app'
                    (products / (scheme + '_newer_wrong_platform.xctestrun')).write_bytes(plistlib.dumps(
                        {'TestConfigurations': [{'TestTargets': [{'TestHostPath': wrong}]}]}))
                if fault == 'build-failure':
                    code = 'raise SystemExit(3)'
            elif stage.endswith('-summary'):
                code = 'print(' + repr(json.dumps({'totalTestCount': 1, 'passedTests': 1})) + ')'
            else:
                code = 'from pathlib import Path; Path(' + repr(str(marker)) + ').touch()'
            return original_run(stage, [sys.executable, '-c', code], **kwargs)
        with patch.object(self.runner, 'run', side_effect=run), patch.object(
                self.module, 'xcode_build_settings', return_value=settings, create=True):
            self.runner.xcode(name, destination, only=only_tests or ('Recovery' if reuse_build else None),
                              skip=None if reuse_build or only_tests else 'Recovery', reuse_build=reuse_build,
                              scheme=scheme)
        return commands, marker

    def test_recovery_reuses_standard_build_and_checks_its_actual_host(self):
        commands, marker = self.xcode_fixture('ios-tests', 'platform=iOS Simulator,id=owned')
        self.assertTrue(marker.exists())
        commands2, marker2 = self.xcode_fixture('ios-recovery', 'platform=iOS Simulator,id=owned', reuse_build='ios-tests')
        self.assertTrue(marker2.exists())
        original = commands['ios-tests']
        recovery = commands2['ios-recovery']
        self.assertIn('-skip-testing:Recovery', original)
        self.assertIn('-only-testing:Recovery', recovery)
        self.assertEqual(original[original.index('-xctestrun') + 1], recovery[recovery.index('-xctestrun') + 1])
        build = commands['ios-tests-build']
        self.assertNotIn('-derivedDataPath', build)
        self.assertEqual(build[build.index('-configuration') + 1], 'Debug-Validation')
        self.assertFalse(any('=' in arg and not arg.startswith('platform=') for arg in build))
        self.assertNotIn('ios-recovery-build', commands2)
        self.assertEqual(self.runner.results['ios-recovery-host-preflight']['status'], 'passed')
        with self.assertRaisesRegex(ValueError, 'isolated test namespace'):
            self.module.test_host_metadata(Path(original[original.index('-xctestrun') + 1]), 'RideIntercom')
        products = Path(original[original.index('-xctestrun') + 1]).parent
        info = products / 'Debug-Validation-iphonesimulator/RideIntercom.app/Info.plist'
        info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom'}))
        _, marker3 = self.xcode_fixture('stale-recovery', 'platform=iOS Simulator,id=owned', reuse_build='ios-tests')
        self.assertFalse(marker3.exists())
        self.assertEqual(self.runner.results['stale-recovery']['status'], 'blocked')

    def test_invalid_generated_hosts_never_launch(self):
        faults = ['RideIntercom', 'RideIntercom.Validation.other.run', '$(RIDEINTERCOM_STORAGE_NAMESPACE)', '',
                  'missing-namespace', 'missing-info', 'broken', 'credential', 'outside-host', 'missing-run', 'build-failure']
        for index, fault in enumerate(faults):
            with self.subTest(fault=fault):
                name = 'invalid-' + str(index)
                # Keep missing-run cases independent from prior fixture output.
                for path in Path(self.temporary.name).glob('Xcode Default/Build/Products/*.xctestrun'):
                    path.unlink()
                _, marker = self.xcode_fixture(name, 'platform=iOS Simulator,id=owned', fault=fault)
                self.assertFalse(marker.exists())
                self.assertEqual(self.runner.results[name]['status'], 'blocked')
        with patch.object(self.module, 'stop_executable', return_value=[123], create=True) as stop:
            commands, marker = self.xcode_fixture('macos-tests', 'platform=macOS')
            self.assertTrue(marker.exists())
            stop.assert_not_called()
            self.assertNotIn('macos-tests-host-cleanup', self.runner.results)
            self.assertFalse(any(arg.startswith(('CODE_SIGN_', 'ENABLE_APP_SANDBOX=')) for arg in commands['macos-tests-build']))
        self.assertNotIn('must-not-appear-in-diagnostics', (self.runner.out / 'results.json').read_text())

    def test_specialized_scheme_uses_its_native_configuration_and_host_gate(self):
        commands, marker = self.xcode_fixture('storekit', 'platform=macOS', scheme='RideIntercom-StoreKitTests',
            only_tests=['RideIntercomTests/LocalStoreKitTests', 'RideIntercomTests/StoreKitAccessTests'])
        self.assertTrue(marker.exists())
        build = commands['storekit-build']
        self.assertIn('RideIntercom-StoreKitTests', build)
        self.assertEqual(build[build.index('-configuration') + 1], 'Debug-StoreKitValidation')
        self.assertFalse(any(arg.startswith('SWIFT_ACTIVE_COMPILATION_CONDITIONS=') for arg in build))
        self.assertIn('-only-testing:RideIntercomTests/LocalStoreKitTests', commands['storekit'])
        self.assertIn('-only-testing:RideIntercomTests/StoreKitAccessTests', commands['storekit'])
        self.assertEqual(self.runner.results['storekit-host-preflight']['status'], 'passed')

    def test_newer_xctestrun_for_other_platform_is_not_selected(self):
        commands, marker = self.xcode_fixture('ios-tests', 'platform=iOS Simulator,id=owned', stale_platform=True)
        self.assertTrue(marker.exists())
        command = commands['ios-tests']
        self.assertIn('_iphonesimulator_fixture.xctestrun', command[command.index('-xctestrun') + 1])

    def test_explicit_plan_cannot_fall_back_to_an_old_scheme_run(self):
        products = Path(self.temporary.name) / 'Products'
        products.mkdir()
        app = products / 'Debug-StoreKitValidation/RideIntercom.app'
        settings = dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(app.parent), FULL_PRODUCT_NAME=app.name)
        scheme = 'RideIntercom-StoreKitTests'
        stale = products / (scheme + '_old.xctestrun')
        stale.write_bytes(plistlib.dumps({'TestPlan': {'Name': scheme},
            'TestConfigurations': [{'TestTargets': [{'TestHostPath': str(app)}]}]}))
        empty = products / (scheme + '_StoreKit.xctestrun')
        empty.write_bytes(plistlib.dumps({'TestPlan': {'Name': 'StoreKit'},
            'TestConfigurations': [{'TestTargets': []}]}))
        self.assertIsNone(self.paths.select_test_run(settings, scheme))
        empty.write_bytes(plistlib.dumps({'TestPlan': {'Name': 'StoreKit'},
            'TestConfigurations': [{'TestTargets': [{'TestHostPath': str(app)}]}]}))
        self.assertEqual(self.paths.select_test_run(settings, scheme), empty)

    def test_scheme_actions_use_the_native_shared_configurations(self):
        self.assertEqual(self.paths.scheme_configuration(self.module.ROOT, 'RideIntercom'), 'Debug-Validation')
        for scheme in ['RideIntercom-StoreKitTests', 'RideIntercom-StoreKitUITests']:
            self.assertEqual(self.paths.scheme_configuration(self.module.ROOT, scheme), 'Debug-StoreKitValidation')
        self.assertEqual(self.paths.scheme_configuration(self.module.ROOT, 'RideIntercom', 'LaunchAction'), 'Debug')

    def test_build_settings_keep_only_paths_and_reject_other_platform(self):
        products = Path(self.temporary.name) / 'Build/Products'
        values = dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(products / 'Debug-Validation'),
                      FULL_PRODUCT_NAME='RideIntercom.app', CONFIGURATION='Debug-Validation',
                      PLATFORM_NAME='macosx', RIDEINTERCOM_STORAGE_NAMESPACE='RideIntercom.Validation.Xcode',
                      RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN='must-not-appear-in-diagnostics')
        result = SimpleNamespace(returncode=0, stdout=json.dumps([{'target': 'RideIntercom', 'buildSettings': values}]))
        with patch.object(self.paths.subprocess, 'run', return_value=result) as query:
            settings = self.paths.xcode_build_settings(self.module.ROOT, 'RideIntercom', 'platform=macOS', 'Debug-Validation')
            self.assertNotIn('must-not-appear-in-diagnostics', json.dumps(settings))
            self.assertIn('-showBuildSettings', query.call_args.args[0])
            self.assertNotIn('-derivedDataPath', query.call_args.args[0])
            with self.assertRaises(ValueError):
                self.paths.xcode_build_settings(self.module.ROOT, 'RideIntercom', 'platform=iOS Simulator,id=owned', 'Debug-Validation')
        result.returncode = 1
        with patch.object(self.paths.subprocess, 'run', return_value=result):
            with self.assertRaises(ValueError) as error:
                self.paths.xcode_build_settings(self.module.ROOT, 'RideIntercom', 'platform=macOS', 'Debug-Validation')
            self.assertNotIn('must-not-appear-in-diagnostics', str(error.exception))

    def test_malformed_scheme_is_a_controlled_configuration_failure(self):
        root = Path(self.temporary.name)
        folder = root / 'RideIntercom.xcodeproj/xcshareddata/xcschemes'
        folder.mkdir(parents=True)
        (folder / 'Broken.xcscheme').write_text('<Scheme>')
        with self.assertRaises(ValueError):
            self.paths.scheme_configuration(root, 'Broken')

    def test_recovery_cannot_reuse_a_build_for_another_platform(self):
        _, marker = self.xcode_fixture('ios-tests', 'platform=iOS Simulator,id=owned')
        self.assertTrue(marker.exists())
        _, marker = self.xcode_fixture('wrong-platform-recovery', 'platform=macOS', reuse_build='ios-tests')
        self.assertFalse(marker.exists())
        self.assertEqual(self.runner.results['wrong-platform-recovery-build-settings']['status'], 'failed')

    def test_clean_uses_standard_package_outputs_and_reuses_rtc_for_pair(self):
        commands = []
        def command(stage, argv, **kwargs):
            commands.append((stage, argv))
            blocked = [need for need in kwargs.get('needs', []) if self.runner.results.get(need, {}).get('status') != 'passed']
            return self.runner.record(stage, argv, 'blocked' if blocked else 'passed', None if blocked else 0, time.monotonic())
        def snapshot(out):
            (out / 'inputs.json').write_text('{}')
        with patch.object(sys, 'argv', ['validate.py', 'headless', '--clean']), \
             patch.object(self.module, 'Runner', return_value=self.runner), \
             patch.object(self.module, 'snapshot', side_effect=snapshot), \
             patch.object(self.runner, 'run', side_effect=command), patch.dict(os.environ):
            self.assertEqual(self.module.main(), 0)
        cleans = [(stage, argv) for stage, argv in commands if argv[:2] == ['swift', 'package']]
        self.assertEqual(len(cleans), 9)
        self.assertEqual(sum(stage == 'package-RTC-clean' for stage, _ in cleans), 1)
        self.assertTrue(all(argv[-1] == 'clean' and '--package-path' in argv for _, argv in cleans))
        self.assertFalse(any('--scratch-path' in argv for _, argv in commands))
        self.assertFalse((self.runner.out / 'clean-build-root.txt').exists())
        rtc = next(argv for stage, argv in commands if stage == 'package-RTC')
        self.assertIn('RideIntercom/packages/RTC', rtc)
        self.assertIn('swift-worker-pair', self.runner.results)

    def test_pair_only_clean_failure_blocks_pair_without_custom_scratch(self):
        def command(stage, argv, **kwargs):
            blocked = any(self.runner.results.get(need, {}).get('status') != 'passed' for need in kwargs.get('needs', []))
            status = 'blocked' if blocked else 'failed' if stage == 'package-RTC-clean' else 'passed'
            return self.runner.record(stage, argv, status, 1 if status == 'failed' else None if blocked else 0, time.monotonic())
        with patch.object(sys, 'argv', ['validate.py', 'pair', '--clean']), \
             patch.object(self.module, 'Runner', return_value=self.runner), \
             patch.object(self.module, 'snapshot', side_effect=lambda out: (out / 'inputs.json').write_text('{}')), \
             patch.object(self.runner, 'run', side_effect=command), patch.dict(os.environ):
            self.assertEqual(self.module.main(), 1)
        self.assertEqual(self.runner.results['swift-worker-pair']['status'], 'blocked')
        self.assertNotIn('package-RTC', self.runner.results)

    def test_storekit_entry_uses_standard_scheme_and_shared_test_lease(self):
        from contextlib import nullcontext
        from scripts import validate_storekit
        with patch.object(sys, 'argv', ['validate_storekit.py', '--output', str(self.runner.out)]), \
             patch.object(validate_storekit, 'Runner', return_value=self.runner), \
             patch.object(validate_storekit, 'manifest', return_value={'head': 'fixture', 'files': {}}), \
             patch.object(validate_storekit, 'exclusive_run', return_value=nullcontext()) as lease, \
             patch.object(validate_storekit, 'simulator_resource_root', return_value=Path(self.temporary.name) / 'resources', create=True), \
             patch.object(self.runner, 'xcode') as run, patch.dict(os.environ):
            self.assertEqual(validate_storekit.main(), 0)
        self.assertEqual(run.call_args.kwargs['scheme'], 'RideIntercom-StoreKitTests')
        self.assertNotIn('derived_data', run.call_args.kwargs)
        self.assertNotIn('extra_conditions', run.call_args.kwargs)
        self.assertEqual(lease.call_args.args[0], Path(self.temporary.name) / 'resources/run.lock')

    def test_macos_validation_holds_the_same_audio_test_lease(self):
        from contextlib import contextmanager
        entered = []
        @contextmanager
        def lease(path):
            entered.append(path)
            yield
            entered.pop()
        def command(stage, argv, **kwargs):
            return self.runner.record(stage, argv, 'passed', 0, time.monotonic())
        def xcode(*args, **kwargs):
            self.assertEqual(entered, [Path(self.temporary.name) / 'resources/run.lock'])
        with patch.object(sys, 'argv', ['validate.py', 'macos']), \
             patch.object(self.module, 'Runner', return_value=self.runner), \
             patch.object(self.module, 'snapshot', side_effect=lambda out: (out / 'inputs.json').write_text('{}')), \
             patch.object(self.module, 'exclusive_run', side_effect=lease), \
             patch.object(self.module, 'simulator_resource_root', return_value=Path(self.temporary.name) / 'resources'), \
             patch.object(self.runner, 'run', side_effect=command), \
             patch.object(self.runner, 'xcode', side_effect=xcode), patch.dict(os.environ):
            self.assertEqual(self.module.main(), 0)

    def test_launch_verification_matches_physical_path_with_spaces(self):
        root = Path(self.temporary.name)
        scripts = root / 'workspace/scripts'
        scripts.mkdir(parents=True)
        entry = scripts / 'build_and_run.sh'
        shutil.copy2(self.module.ROOT / 'scripts/build_and_run.sh', entry)
        shutil.copy2(self.module.ROOT / 'scripts/xcode_paths.py', scripts / 'xcode_paths.py')
        schemes = scripts.parent / 'RideIntercom.xcodeproj/xcshareddata/xcschemes'
        schemes.mkdir(parents=True)
        (schemes / 'RideIntercom.xcscheme').write_text('<Scheme><LaunchAction buildConfiguration="Debug"/></Scheme>')
        output = root / 'build output'
        output.mkdir()
        alias = root / 'output-link'
        alias.symlink_to(output, target_is_directory=True)
        binary = output.resolve() / 'Build/Products/Debug/RideIntercom.app/Contents/MacOS/RideIntercom'
        stubs = root / 'bin'
        stubs.mkdir()
        for name, code in {
            'xcodebuild': 'printf "%s\\n" "$*" >> "$COMMAND_LOG"; case "$*" in *-showBuildSettings*) printf "%s\\n" "$FIXTURE_SETTINGS";; esac',
            'open': 'printf "%s\\n" "$@" > "$OPEN_LOG"', 'sleep': 'exit 0',
            'ps': 'printf "%s\\n" "$*" >> "$PS_LOG"; if [ "$2" = "comm=" ]; then printf "%s\\n" "$EXPECTED_BINARY"; fi',
        }.items():
            path = stubs / name
            path.write_text('#!/bin/sh\n' + code + '\n')
            path.chmod(0o755)
        environment = dict(os.environ, PATH=str(stubs) + ':' + os.environ['PATH'],
                           EXPECTED_BINARY=str(binary), COMMAND_LOG=str(root / 'commands.log'),
                           PS_LOG=str(root / 'ps.log'), OPEN_LOG=str(root / 'open.log'), FIXTURE_SETTINGS=json.dumps([{
                               'target': 'RideIntercom', 'buildSettings': {
                                   'BUILD_DIR': str(alias / 'Build/Products'),
                                   'TARGET_BUILD_DIR': str(alias / 'Build/Products/Debug'),
                                   'FULL_PRODUCT_NAME': 'RideIntercom.app', 'CONFIGURATION': 'Debug',
                                   'PLATFORM_NAME': 'macosx', 'RIDEINTERCOM_STORAGE_NAMESPACE': 'RideIntercom',
                                   'RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN': 'must-not-appear-in-diagnostics'}}]))
        result = subprocess.run([str(entry), '--verify'], env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(str(output.resolve()), result.stdout)
        self.assertEqual((root / 'open.log').read_text().splitlines(), [str(binary.parents[2])])
        self.assertNotIn('-derivedDataPath', (root / 'commands.log').read_text())
        self.assertEqual((root / 'ps.log').read_text().strip(), '-axo comm=')
        self.assertNotIn('must-not-appear-in-diagnostics', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

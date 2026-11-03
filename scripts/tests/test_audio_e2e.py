"""Failure and interruption coverage for the AI-independent audio E2E runner."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import signal
import shutil
import scripts.audio_e2e as audio
import unittest
from unittest.mock import patch

from scripts.test_lifecycle import exclusive_run, SimulatorLease
from scripts.validate import Runner, file_fingerprint, fingerprints_match
from scripts.audio_e2e_matrix import scenarios
from scripts.audio_e2e import measurements, duplex_latencies, run_pair, configure_test_run


class AudioE2ELifecycleTests(unittest.TestCase):
    def test_configuring_audio_hosts_requires_isolated_real_products(self):
        for platform in ('mac', 'ios'):
            products = self.root / platform
            app = products / ('Release' if platform == 'mac' else 'Release-iphonesimulator') / 'RideIntercom.app'
            info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
            info.parent.mkdir(parents=True)
            source, output = products / 'source.xctestrun', products / ('audio-pair-' + platform + '.xctestrun')
            target = {'BlueprintName': 'RideIntercomAudioE2ETests',
                      'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [target]}]}))
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom'}))
            with self.assertRaises(ValueError):
                configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {})
            self.assertFalse(output.exists())
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {'AUDIO_E2E_ROLE': 'a'})
            configured = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(configured['EnvironmentVariables']['AUDIO_E2E_ROLE'], 'a')
            self.assertEqual(configured['OnlyTestIdentifiers'], ['AudioE2ETests/testDuplexSpeechOverNetwork'])

    def test_audio_debug_and_release_use_native_isolated_configurations(self):
        from scripts.validate import ROOT
        from scripts.xcode_paths import scheme_configuration
        project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'RideIntercom.xcodeproj/project.pbxproj')]))
        objects = project['objects']
        owner = objects[project['rootObject']]
        configs = {objects[key]['name']: objects[key] for key in objects[owner['buildConfigurationList']]['buildConfigurations']}
        self.assertEqual(scheme_configuration(ROOT, 'RideIntercomAudioE2E'), 'Debug-Validation')
        release = configs['Release-Validation']['buildSettings']
        self.assertEqual(release['RIDEINTERCOM_STORAGE_NAMESPACE'], 'RideIntercom.Validation.Xcode')
        self.assertEqual(release['ENABLE_TESTABILITY'], 'YES')
        self.assertNotIn('DEBUG', release.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split())
        self.assertEqual(release.get('SWIFT_OPTIMIZATION_LEVEL', '-O'), configs['Release']['buildSettings'].get('SWIFT_OPTIMIZATION_LEVEL', '-O'))
        for target_id in owner['targets']:
            names = {objects[key]['name'] for key in objects[objects[target_id]['buildConfigurationList']]['buildConfigurations']}
            self.assertIn('Release-Validation', names)

    def test_audio_build_discovers_standard_paths_and_rejects_wrong_namespace(self):
        for configuration in ['Debug', 'Release']:
            runner = Runner(self.root / configuration)
            products = self.root / 'Xcode Default/Build/Products'
            target_dir = products / (configuration + '-Validation-iphonesimulator')
            info = target_dir / 'RideIntercom.app/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            source = products / 'RideIntercomAudioE2E_iphonesimulator_fixture.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{
                'BlueprintName': 'RideIntercomAudioE2ETests',
                'TestHostPath': '__TESTROOT__/' + str(info.parent.relative_to(products))}]}]}))
            settings = dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(target_dir),
                FULL_PRODUCT_NAME='RideIntercom.app', CONFIGURATION=configuration + '-Validation',
                PLATFORM_NAME='iphonesimulator', RIDEINTERCOM_STORAGE_NAMESPACE='RideIntercom.Validation.Xcode')
            def command(stage, argv, **kwargs):
                return runner.record(stage, argv, 'passed', 0, time.monotonic())
            with patch.object(audio, 'xcode_build_settings', return_value=settings, create=True), patch.object(runner, 'run', side_effect=command):
                actual, run = audio.build_audio_host(runner, 'ios', 'platform=iOS Simulator,id=owned', configuration)
            self.assertEqual(actual, settings)
            self.assertEqual(run, source)
            argv = runner.results['build-ios']['command']
            self.assertNotIn('-derivedDataPath', argv)
            self.assertFalse(any(arg.startswith(('ENABLE_TESTABILITY=', 'RIDEINTERCOM_STORAGE_NAMESPACE=', 'CODE_SIGN_')) for arg in argv))
            self.assertEqual(argv[argv.index('-configuration') + 1], configuration + '-Validation')

    def test_shared_products_survive_cleaning_both_platforms(self):
        runner = Runner(self.root / 'evidence')
        products = self.root / 'shared-products'
        events = []
        endpoints = [('a', 'mac', 'platform=macOS'), ('b', 'ios', 'platform=iOS Simulator,id=owned')]
        def settings(root, scheme, destination, configuration):
            platform = 'mac' if destination == 'platform=macOS' else 'ios'
            target = products / (configuration + ('-iphonesimulator' if platform == 'ios' else ''))
            return dict(BUILD_DIR=str(products), TARGET_BUILD_DIR=str(target), FULL_PRODUCT_NAME='RideIntercom.app',
                CONFIGURATION=configuration, PLATFORM_NAME='macosx' if platform == 'mac' else 'iphonesimulator',
                RIDEINTERCOM_STORAGE_NAMESPACE='RideIntercom.Validation.Xcode')
        def command(stage, argv, **kwargs):
            destination = argv[argv.index('-destination') + 1]
            platform = 'mac' if destination == 'platform=macOS' else 'ios'
            if 'clean' in argv:
                events.append(('clean', platform))
                shutil.rmtree(products, ignore_errors=True)
            if 'build-for-testing' in argv:
                events.append(('build', platform))
                values = settings(None, None, destination, 'Debug-Validation')
                app = Path(values['TARGET_BUILD_DIR']) / 'RideIntercom.app'
                info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
                (products / ('RideIntercomAudioE2E_' + platform + '.xctestrun')).write_bytes(plistlib.dumps({
                    'TestConfigurations': [{'TestTargets': [{'BlueprintName': 'RideIntercomAudioE2ETests',
                        'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}]}]}))
            return runner.record(stage, argv, 'passed', 0, time.monotonic())
        with patch.object(audio, 'xcode_build_settings', side_effect=settings), patch.object(runner, 'run', side_effect=command):
            built = audio.build_audio_hosts(runner, endpoints, 'Debug', clean=True)
        for values, test_run in built.values():
            self.assertTrue(test_run.exists(), 'A later clean removed an earlier platform test run')
            self.assertTrue((Path(values['TARGET_BUILD_DIR']) / 'RideIntercom.app').is_dir())
        self.assertEqual(events, [('clean', 'mac'), ('clean', 'ios'), ('build', 'mac'), ('build', 'ios')])

    def test_platform_specific_generated_runs_do_not_overwrite_each_other(self):
        products = self.root / 'products'
        products.mkdir()
        outputs = []
        for platform, role in [('mac', 'a'), ('ios', 'b')]:
            folder = 'Release-Validation' + ('-iphonesimulator' if platform == 'ios' else '')
            app = products / folder / 'RideIntercom.app'
            info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            source = products / (platform + '.xctestrun')
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{
                'BlueprintName': 'RideIntercomAudioE2ETests',
                'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}]}]}))
            output = configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {'AUDIO_E2E_ROLE': role})
            outputs.append(output)
        self.assertNotEqual(*outputs)
        for output, role in zip(outputs, ['a', 'b']):
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['EnvironmentVariables']['AUDIO_E2E_ROLE'], role)

    def test_pair_timeout_recovers_the_owned_process_without_type_error(self):
        runner = Runner(self.root / 'timeout-run')
        command = [sys.executable, '-u', '-c', 'import time; print("AUDIO_E2E_NATIVE_READY", flush=True); time.sleep(60)']
        with self.assertRaises(TimeoutError):
            run_pair(runner, [('only', command)], timeout=0.1)
        self.assertNotEqual(runner.results['only']['exit_code'], 0)

    def test_source_gate_includes_new_surface_code_and_signing_configuration(self):
        from scripts.audio_e2e import source_manifest
        names = ['RideIntercomWatch/WatchApp.swift', 'RideIntercomWidgets/Widget.swift',
                 'RideIntercomWidgets/Widget.entitlements', 'Config/Test.xcconfig',
                 'RideIntercom.xctestplan', 'RideIntercom/RideComAppIcon.icon/icon.json',
                 'RideIntercom/Assets.xcassets/Icon.imageset/Icon.svg',
                 'RideIntercom/Assets.xcassets/Logo.imageset/Logo.pdf',
                 'RideIntercom/Assets.xcassets/Photo.imageset/Photo.jpeg',
                 'RideIntercom/RideComAppIcon.icon/Assets/Background.svg',
                 'RideIntercom/ja.lproj/InfoPlist.strings', 'RideIntercom/PrivacyInfo.xcprivacy',
                 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip']
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        def output(command, **kwargs):
            return ('\0'.join(names) + '\0').encode() if command[1] == 'ls-files' else 'fixture-head\n'
        with patch('scripts.audio_e2e.ROOT', self.root), patch('scripts.audio_e2e.subprocess.check_output', side_effect=output):
            before = source_manifest()
            self.assertEqual(set(before['files']), set(names))
            for name in names:
                with self.subTest(changed=name):
                    (self.root / name).write_text('changed build input')
                    after = source_manifest()
                    self.assertFalse(fingerprints_match(before['files'], after['files']))
                    (self.root / name).write_text('fixture')

    def test_source_gate_rejects_all_project_changes_including_build_number(self):
        project = self.root / 'project.pbxproj'
        def capture(number, setting='Release'):
            project.write_text(f'CURRENT_PROJECT_VERSION = {number};\nCONFIGURATION = {setting};\nCURRENT_PROJECT_VERSION = {number};\n')
            return {'project': file_fingerprint(project)}
        before = capture(42)
        after = capture(44)
        self.assertNotEqual(before['project']['sha256'], after['project']['sha256'])
        self.assertFalse(fingerprints_match(before, after))
        self.assertFalse(fingerprints_match(after, before))
        self.assertFalse(fingerprints_match(before, capture(44, 'Debug')))
        self.assertFalse(fingerprints_match(before, {}))
        source = self.root / 'app.swift'
        source.write_text('let value = 1')
        original = {'source': file_fingerprint(source)}
        source.write_text('let value = 2')
        self.assertFalse(fingerprints_match(original, {'source': file_fingerprint(source)}))
        dotted = capture('44.2.1')
        self.assertTrue(fingerprints_match(dotted, capture('44.2.1')))
        self.assertFalse(fingerprints_match(dotted, capture('44.2.2')))

    def test_pair_initializes_native_audio_before_launching_the_other_host(self):
        ready = self.root / 'ready'
        joined = self.root / 'joined'
        first = ['first', [sys.executable, '-u', '-c',
            'import sys,time; from pathlib import Path; time.sleep(.15); '
            'Path(sys.argv[1]).touch(); print("AUDIO_E2E_NATIVE_READY", flush=True); '
            'time.sleep(.3); assert Path(sys.argv[2]).exists()', str(ready), str(joined)]]
        second = ['second', [sys.executable, '-c',
            'import sys; from pathlib import Path; assert Path(sys.argv[1]).exists(); Path(sys.argv[2]).touch()',
            str(ready), str(joined)]]
        runner = Runner(self.root / 'run')
        run_pair(runner, [first, second], timeout=3)
        self.assertEqual(runner.exit_code, 0)

    def test_pair_does_not_launch_another_host_after_native_setup_failure(self):
        started = self.root / 'second-started'
        runner = Runner(self.root / 'run')
        commands = [('first', [sys.executable, '-c', 'raise SystemExit(1)']),
            ('second', [sys.executable, '-c', 'import sys; from pathlib import Path; Path(sys.argv[1]).touch()', str(started)])]
        with self.assertRaisesRegex(RuntimeError, 'initialization'):
            run_pair(runner, commands, timeout=3)
        self.assertFalse(started.exists())

    def test_identity_matrix_preserves_full_utterance_and_codec_controls(self):
        cases = scenarios('identity', 8)
        self.assertEqual([case['codec'] for case in cases], ['mpeg4AACELD', 'pcm16', 'opus'])
        self.assertTrue(all(case['seconds'] >= 20 for case in cases))
        self.assertEqual([case['transmitIsolation'] for case in cases], [True, False, False])

    def test_duplex_latency_pairs_remote_capture_and_uses_one_global_alignment(self):
        rows = [dict(role='a', transport='local', scenario='speech', expectedSilence=False, continuityPassed=True,
                     firstCaptureHostTime=100, firstOutputHostTime=102.1, localFixtureDurationSeconds=8,
                     continuity=dict(referenceOffsetSeconds=1)),
                dict(role='b', transport='local', scenario='speech', expectedSilence=False, continuityPassed=True,
                     firstCaptureHostTime=101, firstOutputHostTime=109.08, localFixtureDurationSeconds=10,
                     continuity=dict(referenceOffsetSeconds=1))]
        values = duplex_latencies(rows)
        self.assertAlmostEqual(values[0], 0.1)
        self.assertAlmostEqual(values[1], 0.08)
        rows[0]['firstOutputHostTime'] += 0.2
        rows[1]['firstOutputHostTime'] += 0.01
        with self.assertRaisesRegex(ValueError, '125 ms'):
            duplex_latencies(rows)
        self.assertAlmostEqual(rows[1]['captureToRenderLatencySeconds'], 0.09,
                               msg='Keep every measurement even when the first endpoint fails')
        with self.assertRaises(ValueError):
            duplex_latencies(rows[:1])

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)

    def test_concurrent_runs_are_rejected_and_lock_releases_on_failure(self):
        lock = self.root / 'run.lock'
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            with exclusive_run(lock):
                with self.assertRaises(BlockingIOError):
                    with exclusive_run(lock):
                        self.fail('Two runs acquired the same lock')
                raise RuntimeError('injected')
        with exclusive_run(lock):
            pass

    def test_release_matrix_covers_every_exposed_audio_choice(self):
        full = scenarios('full', 8)
        self.assertEqual(len({case['id'] for case in full}), len(full))
        for codec in ['pcm16', 'opus', 'mpeg4AACELD']:
            self.assertEqual({c['format'] for c in full if c['codec'] == codec}, {'mono16k', 'mono24k', 'mono48k'})
        self.assertEqual({c['profile'] for c in full}, {'standard', 'speakerDefault', 'echoCancelledInput', 'voiceChat'})
        session_modes = {'standard': ('standard', False), 'speakerDefault': ('standard', True),
                         'echoCancelledInput': ('standard', True), 'voiceChat': ('voiceChat', False)}
        actual_sessions = {(*session_modes[c['profile']], c.get('speaker', False) or c['profile'] == 'speakerDefault')
                           for c in full}
        self.assertEqual(actual_sessions, {
            ('standard', False, False), ('standard', True, False),
            ('standard', False, True), ('standard', True, True),
            ('voiceChat', False, False), ('voiceChat', False, True),
        })
        self.assertEqual({c['vad'] for c in full}, {'lowNoise', 'standard', 'noisy'})
        for key in ['transmitIsolation', 'masterIsolation', 'peerIsolation', 'duck', 'localMute', 'outputMute']:
            self.assertEqual({c[key] for c in full}, {False, True}, key)
        for rate, aac in [('mono16k', {48000}), ('mono24k', {32000, 64000}), ('mono48k', {48000, 128000})]:
            for codec, limits in [('mpeg4AACELD', aac), ('opus', {48000, 128000})]:
                self.assertTrue(limits <= {c['bitRate'] for c in full if c['codec'] == codec and c['format'] == rate})
        self.assertLess(sum(c['seconds'] for c in scenarios('quick', 8)), 40)

    def test_acceptance_requires_every_scenario_from_the_expected_endpoint(self):
        def write(name, scenario, role='a', transport='local'):
            (self.root / name).write_text(json.dumps(dict(scenario=scenario, role=role, transport=transport)))
        write('one.json', 'voice')
        with self.assertRaisesRegex(ValueError, 'Missing'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'voice')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'mute', role='b')
        with self.assertRaisesRegex(ValueError, 'different endpoint'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'mute')
        self.assertEqual(len(measurements(self.root, ['voice', 'mute'], 'a', 'local')), 2)

    def test_recorded_host_path_cannot_authorize_stopping_a_gui_process(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.state = {'executable': str(self.root / 'Default DerivedData/RideIntercom.app/Contents/MacOS/RideIntercom')}
        with patch('scripts.test_lifecycle.matching_processes', return_value=[123]), \
             patch('scripts.test_lifecycle.stop_executable', return_value=[], create=True) as stop, \
             patch('scripts.test_lifecycle.os.kill') as kill:
            self.assertFalse(lease.cleanup_host('recorded'))
        stop.assert_not_called()
        kill.assert_not_called()
        self.assertEqual(runner.results['recorded-host']['status'], 'failed')
        self.assertIn('ownership', runner.results['recorded-host']['reason'])

    def test_create_failure_is_recovered_by_exact_journaled_name(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.reserve('owned-unique-name')
        # simctl may create the device before its caller is interrupted, so the
        # journal must already contain the name even when no UUID was returned.
        self.assertEqual(json.loads(lease.journal.read_text())['name'], 'owned-unique-name')
        devices = [{'name': 'owned-unique-name', 'udid': 'ours', 'state': 'Booted'},
                   {'name': 'owned-unique-name-extra', 'udid': 'other', 'state': 'Booted'}]
        calls = []
        with patch('scripts.test_lifecycle.simulator_devices', return_value=devices), \
             patch.object(runner, 'run', side_effect=lambda name, command, **kw: calls.append(command) or True):
            SimulatorLease(runner, lease.journal).cleanup('recovery')
        self.assertEqual(calls, [['xcrun', 'simctl', 'shutdown', 'ours'], ['xcrun', 'simctl', 'delete', 'ours']])
        self.assertFalse(lease.journal.exists())

    def test_delete_is_attempted_even_when_shutdown_fails_and_failure_is_retained(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.reserve('owned')
        calls = []
        def run(name, command, **kw):
            calls.append(command)
            return command[2] == 'delete'
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'owned', 'udid': 'ours', 'state': 'Booted'}]), patch.object(runner, 'run', side_effect=run):
            self.assertFalse(lease.cleanup('final'))
        self.assertEqual([c[2] for c in calls], ['shutdown', 'delete'])
        self.assertTrue(lease.journal.exists())

    def test_reusable_device_is_stopped_and_remains_owned_for_the_next_run(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.reserve('one-managed-device', reusable=True)
        lease.identify('our-uuid')
        calls = []
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'one-managed-device', 'udid': 'our-uuid', 'state': 'Booted'}]), \
             patch.object(runner, 'run', side_effect=lambda name, command, **kw: calls.append(command) or True):
            self.assertTrue(lease.cleanup('final'))
        self.assertEqual(calls, [['xcrun', 'simctl', 'shutdown', 'our-uuid']])
        self.assertEqual(SimulatorLease(runner, lease.journal).state['udid'], 'our-uuid')

    def test_missing_journal_adopts_latest_device_and_removes_only_idle_managed_duplicates(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        devices = [dict(name=name, udid=uid, state='Shutdown', runtime='ios',
                        deviceTypeIdentifier='phone', isAvailable=True, lastUsedAt=date)
                   for name, uid, date in [('RideIntercom Audio E2E 12345678', 'old', '2026-01'),
                                           ('RideIntercom Audio E2E abcdef12', 'new', '2026-10'),
                                           ('iPhone 17', 'personal', '2026-11'),
                                           ('RideIntercom Recovery Tests', 'recovery', '')]]
        with patch('scripts.test_lifecycle.simulator_devices', return_value=devices), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertEqual(lease.prepare('ios', 'phone'), 'new')
        self.assertEqual([c.args[1] for c in run.call_args_list],
                         [['xcrun', 'simctl', 'delete', 'old'], ['xcrun', 'simctl', 'delete', 'recovery']])
        self.assertEqual(SimulatorLease(runner, lease.journal).state['udid'], 'new')
        self.assertTrue((runner.out / 'simulator-inventory.json').exists())

    def test_another_device_type_keeps_its_own_managed_simulator(self):
        # The iOS validation leases an iPhone and an iPad; preparing one must not delete the other.
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        devices = [dict(name='RideIntercom Audio E2E 12345678', udid='pad', state='Shutdown', runtime='ios',
                        deviceTypeIdentifier='pad', isAvailable=True, lastUsedAt='2026-10'),
                   dict(name='RideIntercom Audio E2E abcdef12', udid='phone', state='Shutdown', runtime='ios',
                        deviceTypeIdentifier='phone', isAvailable=True, lastUsedAt='2026-09')]
        with patch('scripts.test_lifecycle.simulator_devices', return_value=devices), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertEqual(lease.prepare('ios', 'phone'), 'phone')
        run.assert_not_called()

    def test_busy_managed_device_blocks_reconciliation_without_deleting_anything(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                dict(name='RideIntercom Audio E2E 12345678', udid='busy', state='Booted')]), \
             patch.object(runner, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'in use'):
                lease.prepare('ios', 'phone')
        run.assert_not_called()
        self.assertFalse(lease.acquired)

    def test_cleanup_failure_prevents_creating_a_replacement(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                dict(name='RideIntercom Audio E2E 12345678', udid='old', state='Shutdown', isAvailable=False)]), \
             patch.object(runner, 'run', return_value=False) as run:
            with self.assertRaisesRegex(RuntimeError, 'delete'):
                lease.prepare('ios', 'phone')
        self.assertEqual([c.args[1][2] for c in run.call_args_list], ['delete'])

    def test_inventory_is_checked_before_creation_and_creation_is_journaled(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        def create(name, command, **kwargs):
            self.assertTrue((runner.out / 'simulator-inventory.json').exists())
            self.assertEqual(json.loads(lease.journal.read_text())['name'], command[3])
            (runner.out / 'simulator-create.log').write_text('created-uuid\n')
            return True
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[]), \
             patch.object(runner, 'run', side_effect=create):
            self.assertEqual(lease.prepare('ios', 'phone'), 'created-uuid')
        self.assertTrue(lease.acquired)
        self.assertTrue(lease.state['reusable'])

    def test_cleanup_only_removes_orphans_without_creating_a_device(self):
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                dict(name='RideIntercom Validation old-run', udid='old', state='Shutdown')]), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertIsNone(lease.prepare(None, None, delete_all=True))
        self.assertEqual([c.args[1] for c in run.call_args_list], [['xcrun', 'simctl', 'delete', 'old']])
        self.assertFalse(lease.journal.exists())

    def test_previous_mode_only_checks_old_host_without_touching_simulator(self):
        runner = Runner(self.root / 'evidence')
        old = SimulatorLease(runner, self.root / 'ephemeral.json')
        old.reserve('RideIntercom Audio E2E 12345678')
        old.identify('reused')
        old.state['executable'] = str(self.root / 'old-host')
        old.save()
        with patch('scripts.test_lifecycle.matching_processes', return_value=[]) as matches, \
             patch('scripts.test_lifecycle.os.kill') as kill, \
             patch('scripts.test_lifecycle.simulator_devices') as inventory, \
             patch.object(runner, 'run') as run:
            self.assertTrue(old.cleanup_host('previous-mode'))
        matches.assert_called_once_with(str(self.root / 'old-host'))
        kill.assert_not_called()
        inventory.assert_not_called()
        run.assert_not_called()
        self.assertNotIn('executable', old.state)

    def test_runner_sigterm_stops_child_and_executes_final_cleanup_without_ai(self):
        marker = self.root / 'child.pid'
        cleaned = self.root / 'cleaned'
        child = f'import os,time;open({str(marker)!r},"w").write(str(os.getpid()));time.sleep(60)'
        code = ('import signal\nfrom scripts.validate import Runner, file_fingerprint, fingerprints_match\n'
                'def interrupt(*args): raise KeyboardInterrupt\n'
                'signal.signal(signal.SIGTERM, interrupt)\n'
                f'r=Runner({str(self.root / "run")!r})\n'
                'try:\n'
                f' r.run("child",[{sys.executable!r},"-c",{child!r}])\n'
                'finally:\n'
                f' open({str(cleaned)!r},"w").write("done")\n')
        process = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import time, signal
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGTERM)
            self.assertNotEqual(process.wait(timeout=5), 0)
            self.assertTrue(cleaned.exists())
            state = subprocess.run(['ps', '-o', 'stat=', '-p', marker.read_text()], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
        finally:
            if process.poll() is None:
                process.kill(); process.wait()



class SimulatorAudioDeviceTests(unittest.TestCase):
    """The Simulator's duplex I/O opens only when input and output share one host device."""
    DEVICES = {'inputDevices': [{'uid': 'wave', 'name': 'Wave'}, {'uid': 'mic', 'name': 'Display Mic'}],
               'outputDevices': [{'uid': 'wave', 'name': 'Wave'}, {'uid': 'speaker', 'name': 'Display Speaker'}]}
    HOST = [{'_name': 'Wave', 'coreaudio_device_input': 1, 'coreaudio_device_output': 2,
             'coreaudio_device_srate': 48000, 'coreaudio_default_audio_input_device': 'spaudio_yes'},
            {'_name': 'Display Mic', 'coreaudio_device_input': 1, 'coreaudio_device_srate': 96000},
            {'_name': 'Display Speaker', 'coreaudio_device_output': 8, 'coreaudio_device_srate': 96000,
             'coreaudio_default_audio_output_device': 'spaudio_yes'}]

    def test_selects_the_single_48_khz_device_with_both_directions(self):
        self.assertEqual(audio.shared_host_audio_device(self.DEVICES, self.HOST), 'wave')

    def test_rejects_hosts_without_one_unambiguous_duplex_device(self):
        only_split = [item for item in self.HOST if item['_name'] != 'Wave']
        with self.assertRaises(ValueError):
            audio.shared_host_audio_device(self.DEVICES, only_split)
        twins = {key: value + [{'uid': 'other', 'name': 'Other'}] for key, value in self.DEVICES.items()}
        other = dict(self.HOST[0], _name='Other')
        other.pop('coreaudio_default_audio_input_device')
        self.assertEqual(audio.shared_host_audio_device(twins, self.HOST + [other]), 'wave',
                         'The host default input wins over another eligible device')
        plain = [dict(item) for item in self.HOST]
        plain[0].pop('coreaudio_default_audio_input_device')
        with self.assertRaises(ValueError):
            audio.shared_host_audio_device(twins, plain + [other])

    def test_pins_both_directions_and_restores_the_original_selection(self):
        calls = []
        state = {'audioInputDevice': {'systemDefault': {}}, 'audioOutputDevice': {'systemDefault': {}}, 'volume': 60}

        def run(args):
            calls.append(args)
            if args[:4] == ['xcrun', 'devicectl', 'device', 'info']:
                return dict(state)
            if args[:4] == ['xcrun', 'devicectl', 'list', 'audioDevices']:
                return self.DEVICES
            if args[0] == 'system_profiler':
                return {'SPAudioDataType': [{'_items': self.HOST}]}
            selected = {'audioInputDevice': args[args.index('--input-device') + 1],
                        'audioOutputDevice': args[args.index('--output-device') + 1]}
            for key, value in selected.items():
                state[key] = {'systemDefault': {}} if value == 'systemDefault' else {'device': {'_0': value}}
            return {}

        pin = audio.SimulatorAudioPin('sim', run)
        self.assertEqual(pin.pin(), 'wave')
        self.assertEqual(state['audioInputDevice'], {'device': {'_0': 'wave'}})
        self.assertEqual(state['audioOutputDevice'], {'device': {'_0': 'wave'}})
        pin.restore()
        self.assertEqual(state['audioInputDevice'], {'systemDefault': {}})
        self.assertEqual(state['audioOutputDevice'], {'systemDefault': {}})
        settings = [args for args in calls if args[:4] == ['xcrun', 'devicectl', 'device', 'settings']]
        self.assertEqual(len(settings), 2)
        pin.restore()
        self.assertEqual(len([args for args in calls if args[:4] == ['xcrun', 'devicectl', 'device', 'settings']]), 2,
                         'Restore is idempotent')


if __name__ == '__main__':
    unittest.main()

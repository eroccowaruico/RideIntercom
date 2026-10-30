"""Failure and interruption coverage for the AI-independent audio E2E runner."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts.test_lifecycle import exclusive_run, stop_executable, SimulatorLease
from scripts.validate import Runner, file_fingerprint, fingerprints_match
from scripts.audio_e2e_matrix import scenarios
from scripts.audio_e2e import measurements, duplex_latencies, run_pair


class AudioE2ELifecycleTests(unittest.TestCase):
    def test_source_gate_allows_only_forward_generated_build_numbers(self):
        project = self.root / 'project.pbxproj'
        def capture(number, setting='Release'):
            project.write_text(f'CURRENT_PROJECT_VERSION = {number};\nCONFIGURATION = {setting};\nCURRENT_PROJECT_VERSION = {number};\n')
            return {'project': file_fingerprint(project)}
        before = capture(42)
        after = capture(44)
        self.assertNotEqual(before['project']['sha256'], after['project']['sha256'])
        self.assertTrue(fingerprints_match(before, after))
        self.assertFalse(fingerprints_match(after, before))
        self.assertFalse(fingerprints_match(before, capture(44, 'Debug')))
        self.assertFalse(fingerprints_match(before, {}))
        source = self.root / 'app.swift'
        source.write_text('let value = 1')
        original = {'source': file_fingerprint(source)}
        source.write_text('let value = 2')
        self.assertFalse(fingerprints_match(original, {'source': file_fingerprint(source)}))
        project.write_text('CURRENT_PROJECT_VERSION = 44; CURRENT_PROJECT_VERSION = 45;')
        with self.assertRaises(ValueError):
            file_fingerprint(project)

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

    def test_cleanup_matches_full_binary_path_not_application_name(self):
        expected = self.root / 'E2E Build/RideIntercom.app/Contents/MacOS/RideIntercom'
        rows = f' 101 {expected}\n 202 /Applications/RideIntercom.app/Contents/MacOS/RideIntercom\n'
        with patch('scripts.test_lifecycle.process_listing', side_effect=[rows, rows, '']), \
             patch('scripts.test_lifecycle.os.kill') as kill:
            self.assertEqual(stop_executable(expected), [101])
        self.assertEqual([c.args[0] for c in kill.call_args_list], [101])

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

    def test_previous_mode_host_cleanup_does_not_delete_the_adopted_simulator(self):
        runner = Runner(self.root / 'evidence')
        old = SimulatorLease(runner, self.root / 'ephemeral.json')
        old.reserve('RideIntercom Audio E2E 12345678')
        old.identify('reused')
        old.host(self.root / 'old-host')
        with patch('scripts.test_lifecycle.stop_executable', return_value=[123]) as stop, \
             patch('scripts.test_lifecycle.simulator_devices') as inventory, \
             patch.object(runner, 'run') as run:
            self.assertTrue(old.cleanup_host('previous-mode'))
        stop.assert_called_once_with(str((self.root / 'old-host').resolve()))
        inventory.assert_not_called()
        run.assert_not_called()

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


if __name__ == '__main__':
    unittest.main()

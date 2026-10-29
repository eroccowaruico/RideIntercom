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
from scripts.validate import Runner
from scripts.audio_e2e_matrix import scenarios
from scripts.audio_e2e import measurements


class AudioE2ELifecycleTests(unittest.TestCase):
    def test_identity_matrix_preserves_full_utterance_and_codec_controls(self):
        cases = scenarios('identity', 8)
        self.assertEqual([case['codec'] for case in cases], ['mpeg4AACELDv2', 'pcm16', 'opus'])
        self.assertTrue(all(case['seconds'] >= 20 for case in cases))
        self.assertEqual([case['transmitIsolation'] for case in cases], [True, False, False])

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
        for codec in ['pcm16', 'opus', 'mpeg4AACELDv2']:
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
        for codec, limits in [('opus', {6000, 128000}), ('mpeg4AACELDv2', {12000, 128000})]:
            for rate in ['mono16k', 'mono24k', 'mono48k']:
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

    def test_runner_sigterm_stops_child_and_executes_final_cleanup_without_ai(self):
        marker = self.root / 'child.pid'
        cleaned = self.root / 'cleaned'
        child = f'import os,time;open({str(marker)!r},"w").write(str(os.getpid()));time.sleep(60)'
        code = ('import signal\nfrom scripts.validate import Runner\n'
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

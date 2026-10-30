"""Exercise the real local runner without Xcode, devices, or network access."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('validation', Path(__file__).resolve().parents[1] / 'validate.py')


class ValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(cls.module)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.runner = self.module.Runner(Path(self.temporary.name) / 'run', timeout=1)

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
        child_code = f'import os,time; open({str(marker)!r}, "w").write(str(os.getpid())); time.sleep(60)'
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

    def test_results_preserve_command_and_failure(self):
        self.runner.run('bad', [sys.executable, '-c', 'raise SystemExit(7)'])
        saved = json.loads((self.runner.out / 'results.json').read_text())
        self.assertEqual(saved['bad']['exit_code'], 7)
        self.assertEqual(saved['bad']['status'], 'failed')
        self.assertIn('command', saved['bad'])

    def test_recovery_reuses_build_and_its_isolated_storage_namespace(self):
        commands = {}
        def run(name, command, **kwargs):
            commands[name] = command
            self.runner.results[name] = {'status': 'passed'}
            if name.endswith('-summary'):
                (self.runner.out / (name + '.log')).write_text(json.dumps({'totalTestCount': 1, 'passedTests': 1}))
            return True
        with patch.object(self.runner, 'run', side_effect=run):
            self.runner.xcode('ios-tests', 'owned-device', skip='Recovery')
            self.runner.xcode('ios-recovery', 'owned-device', only='Recovery', reuse_build='ios-tests')
        original = commands['ios-tests']
        recovery = commands['ios-recovery']
        self.assertIn('test-without-building', recovery)
        self.assertIn('-skip-testing:Recovery', original)
        self.assertIn('-only-testing:Recovery', recovery)
        self.assertEqual(original[original.index('-derivedDataPath') + 1], recovery[recovery.index('-derivedDataPath') + 1])
        namespace = 'RIDEINTERCOM_STORAGE_NAMESPACE=RideIntercom.Validation.run.ios-tests'
        self.assertIn(namespace, original)
        self.assertIn(namespace, recovery)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RIDEINTERCOM_VALIDATION', original)
        self.assertFalse(any('SWIFT_ACTIVE_COMPILATION_CONDITIONS=' in value for value in recovery))

    def test_launch_verification_matches_physical_path_with_spaces(self):
        root = Path(self.temporary.name)
        scripts = root / 'workspace/scripts'
        scripts.mkdir(parents=True)
        entry = scripts / 'build_and_run.sh'
        shutil.copy2(self.module.ROOT / 'scripts/build_and_run.sh', entry)
        output = root / 'build output'
        output.mkdir()
        alias = root / 'output-link'
        alias.symlink_to(output, target_is_directory=True)
        binary = output.resolve() / 'Build/Products/Debug/RideIntercom.app/Contents/MacOS/RideIntercom'
        stubs = root / 'bin'
        stubs.mkdir()
        for name, code in {
            'xcodebuild': 'exit 0', 'open': 'exit 0', 'sleep': 'exit 0',
            'ps': 'if [ "$2" = "comm=" ]; then printf "%s\\n" "$EXPECTED_BINARY"; fi',
        }.items():
            path = stubs / name
            path.write_text('#!/bin/sh\n' + code + '\n')
            path.chmod(0o755)
        environment = dict(os.environ, PATH=str(stubs) + ':' + os.environ['PATH'],
                           DERIVED_DATA_PATH=str(alias), EXPECTED_BINARY=str(binary))
        result = subprocess.run([str(entry), '--verify'], env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(str(output.resolve()), result.stdout)


if __name__ == '__main__':
    unittest.main()

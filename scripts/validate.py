#!/usr/bin/env python3
"""Local validation orchestration. No deployment or access to user test data."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test_lifecycle import stop_executable


def swift_supported(output):
    version = re.search(r'Swift version (\d+)\.(\d+)', output)
    return bool(version and tuple(map(int, version.groups())) >= (6, 3))


def verify_swift():
    output = subprocess.check_output(['xcrun', 'swift', '--version'], text=True, timeout=60)
    print(output)
    if not swift_supported(output):
        raise ValueError('Swift 6.3 or newer is required')


def verify_artifact():
    artifact = ROOT / 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'
    metadata = dict(line.split('=', 1) for line in artifact.with_suffix('.metadata').read_text().splitlines() if '=' in line)
    if hashlib.sha256(artifact.read_bytes()).hexdigest() != metadata.get('checksum'):
        raise ValueError('WebRTC archive does not match imported metadata')
    with tempfile.TemporaryDirectory(prefix='rideintercom-artifact-') as folder:
        subprocess.run(['ditto', '-x', '-k', str(artifact), folder], check=True, timeout=60)
        subprocess.run(['bash', str(ROOT / 'scripts/BuildWebRTC/verify-webrtc-xcframework.sh'),
                        str(Path(folder) / 'WebRTC.xcframework')], check=True, timeout=60)


def tests_passed(text):
    """Require an actual nonempty test run; compilation alone is not success."""
    if re.search(r'\bskipped[=: ]+[1-9]|\b[1-9]\d* tests? skipped|Test .* skipped', text, re.I):
        return False
    swift = re.search(r'Test run with (\d+) tests? .*passed', text)
    if swift:
        return int(swift[1]) > 0 and not re.search(r'Test .* failed', text)
    python = re.search(r'Ran (\d+) tests?\b', text)
    if python:
        return int(python[1]) > 0 and re.search(r'^OK\s*$', text, re.M) is not None
    node = dict(re.findall(r'^[#ℹ]\s+(tests|pass|fail|skipped|cancelled|todo)\s+(\d+)', text, re.M))
    return (int(node.get('tests', 0)) > 0 and node.get('pass') == node.get('tests')
            and all(int(node.get(key, 0)) == 0 for key in ['fail', 'skipped', 'cancelled', 'todo']))


def xcode_tests_passed(summary):
    count = summary.get('totalTestCount', 0)
    return (count > 0 and summary.get('passedTests') == count
            and summary.get('failedTests', 0) == 0 and summary.get('skippedTests', 0) == 0)


class Runner:
    def __init__(self, out, timeout=1800):
        self.out = Path(out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        # Exclusive creation protects old evidence, including interrupted runs.
        with (self.out / 'results.tsv').open('x') as f:
            f.write('stage\tstatus\texit_code\tduration_seconds\n')
        self.results = {}
        self.timeout = timeout

    @property
    def exit_code(self):
        return int(any(r['status'] != 'passed' for r in self.results.values()))

    def record(self, name, command, status, code, started, reason=''):
        result = dict(command=command, status=status, exit_code=code,
                      duration_seconds=round(time.monotonic() - started, 3), reason=reason)
        self.results[name] = result
        with (self.out / 'results.tsv').open('a') as f:
            f.write(f'{name}\t{status}\t{code}\t{result["duration_seconds"]}\n')
        (self.out / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')
        print(f'{name}: {status}' + (f' ({reason})' if reason else ''), flush=True)
        return status == 'passed'

    @staticmethod
    def stop(process):
        # Only the session created for this command, never a name-based pkill.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    def run(self, name, command, needs=(), tests=False, timeout=None, reason=''):
        started = time.monotonic()
        if name in self.results:
            raise ValueError(f'Duplicate stage: {name}')
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            return self.record(name, command, 'blocked', None, started, 'requires ' + ', '.join(blocked))
        print(f'Running {name}', flush=True)
        path = self.out / f'{name}.log'
        status, code = 'failed', 1
        process = None
        try:
            with path.open('w') as output:
                process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    code = process.wait(timeout=timeout if timeout is not None else self.timeout)
                    status = 'passed' if code == 0 else 'failed'
                except subprocess.TimeoutExpired:
                    self.stop(process)
                    status, code, reason = 'timeout', 124, 'command exceeded deadline'
                except KeyboardInterrupt:
                    self.stop(process)
                    self.record(name, command, 'interrupted', 130, started)
                    raise
        except OSError as error:
            path.write_text(str(error) + '\n')
            status, code, reason = 'blocked', 127, str(error)
        if status == 'passed' and tests and not tests_passed(path.read_text(errors='replace')):
            status, code, reason = 'failed', 1, 'missing, empty, failed, or skipped test results'
        passed = self.record(name, command, status, code, started, reason)
        if not passed:
            print('\n'.join(path.read_text(errors='replace').splitlines()[-12:]), flush=True)
        return passed

    def xcode(self, name, destination, only=None, needs=(), skip=None, reuse_build=None):
        bundle = self.out / f'{name}.xcresult'
        # Xcode's live Repository group must not recursively discover its own
        # generated package checkout/build tree while constructing the graph.
        if reuse_build:
            derived = Path((self.out / f'{reuse_build}-derived-data.txt').read_text().strip())
        else:
            parent = os.environ.get('VALIDATION_DERIVED_DATA') or tempfile.mkdtemp(prefix='RideIntercom-validation-')
            derived = Path(parent).resolve() / f'DerivedData-{name}'
        if derived.is_relative_to(ROOT):
            return self.record(name, [], 'blocked', None, time.monotonic(), 'DerivedData must be outside the synchronized repository')
        (self.out / f'{name}-derived-data.txt').write_text(str(derived) + '\n')
        command = ['xcodebuild', 'test-without-building' if reuse_build else 'test', '-project', 'RideIntercom.xcodeproj', '-scheme', 'RideIntercom',
                   '-destination', destination, '-parallel-testing-enabled', 'NO',
                   '-derivedDataPath', str(derived), '-resultBundlePath', str(bundle),
                   'RIDEINTERCOM_STORAGE_NAMESPACE=RideIntercom.Validation.' + self.out.name + '.' + (reuse_build or name)]
        if only:
            command.append(f'-only-testing:{only}')
        if skip:
            command.append(f'-skip-testing:{skip}')
        try:
            self.run(name, command, needs=needs)
        finally:
            if destination.startswith('platform=macOS'):
                started = time.monotonic()
                executable = derived / 'Build/Products/Debug/RideIntercom.app/Contents/MacOS/RideIntercom'
                try:
                    stopped = stop_executable(executable)
                    self.record(name + '-host-cleanup', [], 'passed', 0, started, f'Terminated owned PIDs: {stopped}')
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    self.record(name + '-host-cleanup', [], 'failed', 1, started, str(error))
        summary_name = name + '-summary'
        self.run(summary_name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], needs=[name], timeout=60)
        started = time.monotonic()
        try:
            summary = json.loads((self.out / f'{summary_name}.log').read_text())
            passed = self.results[summary_name]['status'] == 'passed' and xcode_tests_passed(summary)
        except (OSError, ValueError):
            passed = False
        self.record(name + '-acceptance', [], 'passed' if passed else 'failed', 0 if passed else 1,
                    started, 'requires nonzero tests, no failures/skips, and a readable xcresult')


def snapshot(out):
    # Hash file contents without copying potential credentials to the report.
    files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    hashes = {}
    for name in sorted(set(filter(None, files))):
        path = ROOT / name
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'deleted'
    (out / 'inputs.json').write_text(json.dumps(hashes, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='all', choices=['all', 'headless', 'packages', 'worker', 'pair', 'macos', 'ios', 'ios-ui', 'scripts'])
    parser.add_argument('--clean', action='store_true', help='Use new private build outputs; never remove existing caches')
    parser.add_argument('--thread-sanitizer', action='store_true', help='Run supported Swift package tests under Thread Sanitizer')
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    os.environ['NO_COLOR'] = '1'
    os.environ['CI'] = '1'  # Noninteractive tool output; this still runs locally.
    out = os.environ.get('VALIDATION_DIR', ROOT / '.validation' / datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    runner = Runner(out, timeout=float(os.environ.get('VALIDATION_TIMEOUT_SECONDS', '1800')))
    build_root = Path(tempfile.mkdtemp(prefix='RideIntercom-clean-')) if args.clean else None
    if build_root:
        (runner.out / 'clean-build-root.txt').write_text(str(build_root) + '\n')
    snapshot(runner.out)
    runner.run('environment', ['sh', '-c', 'git rev-parse HEAD; git status --short; sw_vers; xcodebuild -version; swift --version; node --version; npm --version'], timeout=60)
    python = sys.executable
    runner.run('development-setup', [python, 'scripts/check_development_setup.py'])
    runner.run('documentation', [python, 'scripts/check_documentation.py'])
    mode = args.mode
    swift_needed = mode in ('all', 'headless', 'packages', 'pair', 'macos', 'ios', 'ios-ui')
    node_needed = mode in ('all', 'headless', 'worker', 'pair', 'scripts')
    if swift_needed:
        runner.run('swift-toolchain', [python, '-c', 'from scripts.validate import verify_swift; verify_swift()'], timeout=65)
        runner.run('webrtc-artifact', [python, '-c', 'from scripts.validate import verify_artifact; verify_artifact()'], timeout=180)
    if node_needed:
        runner.run('node-toolchain', ['node', '-e', 'if(Number(process.versions.node.split(".")[0])<22)process.exit(1)'], timeout=30)
    if mode in ('all', 'headless', 'packages'):
        packages = ['Audio/' + name for name in ['AudioCore', 'AudioMixer', 'Codec', 'SessionManager']]
        packages += ['Audio/Effectors/' + name for name in ['DynamicsProcessor', 'PeakLimiter', 'SoundIsolation', 'VADGate']]
        packages += ['RTC']
        for package in packages:
            name = package.split('/')[-1]
            command = ['swift', 'test', '--package-path', 'RideIntercom/packages/' + package]
            if args.clean:
                command += ['--scratch-path', str(build_root / name)]
            if args.thread_sanitizer:
                command += ['--sanitize=thread']
            if name == 'RTC':
                command += ['--skip', 'WorkerPairTests']  # Executed with its server in the pair stage.
            runner.run('package-' + name, command, needs=['swift-toolchain'] + (['webrtc-artifact'] if name == 'RTC' else []), tests=True)
    if mode in ('all', 'headless', 'worker', 'pair'):
        runner.run('worker-install', ['npm', '--prefix', 'server', 'ci'], needs=['node-toolchain'])
        runner.run('worker-types', ['npm', '--prefix', 'server', 'run', 'type-check'], needs=['worker-install'])
        runner.run('worker-test', ['npm', '--prefix', 'server', 'test'], needs=['worker-install'], tests=True)
    if mode in ('all', 'headless', 'pair'):
        if args.clean:
            os.environ['RIDEINTERCOM_PAIR_SCRATCH_PATH'] = str(build_root / 'RTC-pair')
        if args.thread_sanitizer:
            os.environ['RIDEINTERCOM_PAIR_SANITIZER'] = 'thread'
        runner.run('swift-worker-pair', ['npm', '--prefix', 'server', 'run', 'test:pair'], needs=['worker-install', 'swift-toolchain', 'webrtc-artifact'], tests=True)
    if mode in ('all', 'headless', 'scripts'):
        runner.run('script-tests', [python, '-m', 'unittest', 'discover', '-s', 'scripts/tests'], tests=True)
        runner.run('cloudflare-scripts', ['node', '--test', 'scripts/Cloudflare/estimate-cost.test.mjs', 'scripts/Cloudflare/issue-device.test.mjs'], needs=['node-toolchain'], tests=True)
    if mode in ('all', 'macos'):
        runner.xcode('macos-tests', 'platform=macOS,arch=arm64', only='RideIntercomTests', needs=['swift-toolchain', 'webrtc-artifact'])
    if mode in ('all', 'ios', 'ios-ui'):
        sim = None
        try:
            runner.run('simulator-runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], needs=['swift-toolchain'], timeout=60)
            runtimes = json.loads((runner.out / 'simulator-runtimes.log').read_text())['runtimes']
            available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime = os.environ.get('SIMULATOR_RUNTIME') or max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
            device = os.environ.get('SIMULATOR_DEVICE_TYPE', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
            if runner.run('simulator-create', ['xcrun', 'simctl', 'create', 'RideIntercom Validation ' + runner.out.name, device, runtime], timeout=60):
                sim = (runner.out / 'simulator-create.log').read_text().strip()
                (runner.out / 'simulator-id.txt').write_text(sim + '\n')
                runner.run('simulator-boot', ['xcrun', 'simctl', 'boot', sim], needs=['simulator-create'], timeout=120)
                runner.run('simulator-ready', ['xcrun', 'simctl', 'bootstatus', sim, '-b'], needs=['simulator-boot'], timeout=180)
                runner.run('simulator-appearance', ['xcrun', 'simctl', 'ui', sim, 'appearance', os.environ.get('SIMULATOR_APPEARANCE', 'dark')], needs=['simulator-ready'], timeout=30)
                recovery = 'RideIntercomUITests/RideIntercomUITests/testCorruptGroupStoreRecovery'
                runner.xcode('ios-tests', 'platform=iOS Simulator,id=' + sim, only='RideIntercomUITests' if mode == 'ios-ui' else None,
                             needs=['simulator-ready', 'simulator-appearance', 'webrtc-artifact'], skip=recovery)
                runner.run('recovery-container', ['xcrun', 'simctl', 'get_app_container', sim,
                           'com.yowamushi-inc.RideIntercom.RideIntercom', 'data'], needs=['ios-tests-acceptance'], timeout=60)
                fixture = [python, '-m', 'scripts.group_recovery_fixture', str(runner.out)]
                runner.run('recovery-prepare', fixture + ['prepare'], needs=['recovery-container'])
                runner.xcode('ios-recovery', 'platform=iOS Simulator,id=' + sim, only=recovery,
                             needs=['recovery-prepare'], reuse_build='ios-tests')
                # Xcode may reinstall the app and relocate its retained data.
                runner.run('recovery-container-after', ['xcrun', 'simctl', 'get_app_container', sim,
                           'com.yowamushi-inc.RideIntercom.RideIntercom', 'data'], needs=['ios-recovery-acceptance'], timeout=60)
                runner.run('recovery-verify', fixture + ['verify'], needs=['recovery-container-after'])
        except (OSError, ValueError, KeyError) as error:
            runner.record('simulator-availability', [], 'blocked', None, time.monotonic(), str(error))
        finally:
            if sim:
                try:
                    runner.run('simulator-shutdown', ['xcrun', 'simctl', 'shutdown', sim], timeout=60)
                finally:
                    runner.run('simulator-delete', ['xcrun', 'simctl', 'delete', sim], timeout=60)
    # A concurrent edit invalidates evidence rather than silently passing.
    before = (runner.out / 'inputs.json').read_text()
    snapshot(runner.out)
    after = (runner.out / 'inputs.json').read_text()
    (runner.out / 'inputs-before.json').write_text(before)
    runner.record('unchanged-inputs', [], 'passed' if before == after else 'failed', 0 if before == after else 1,
                  time.monotonic(), 'tracked and unignored source hashes before/after validation')
    print(f'Results: {runner.out / "results.tsv"}')
    return runner.exit_code


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)

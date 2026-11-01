#!/usr/bin/env python3
"""Local validation orchestration. No deployment or access to user test data."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test_lifecycle import (exclusive_run, SimulatorLease,
                                    simulator_resource_root, process_snapshot, stop_process_tree)
from scripts.xcode_paths import scheme_configuration, xcode_build_settings, select_test_run


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
            and summary.get('failedTests', 0) == 0 and summary.get('skippedTests', 0) == 0
            and not summary.get('runtimeWarnings') and not summary.get('testFailures'))


def test_host_metadata(test_run, expected_namespace):
    """Validate the product actually referenced by Xcode, before it can start."""
    if not (expected_namespace.startswith('RideIntercom.Validation.')
            and len(expected_namespace) > len('RideIntercom.Validation.')):
        raise ValueError('An isolated test namespace is required')
    if test_run is None:
        raise ValueError('Missing generated xctestrun')
    test_run = Path(test_run)
    products = test_run.parent.resolve()
    if not test_run.resolve().is_relative_to(products):
        raise ValueError('Test run must remain inside its build products')
    data = plistlib.loads(test_run.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if not targets:
        raise ValueError('Missing test targets')
    hosts = set()
    for target in targets:
        resolved = {}
        for key in ('TestHostPath', 'UITargetAppPath'):
            if key not in target:
                continue
            value = target[key].replace('__TESTROOT__', str(products))
            path = Path(value).resolve()
            if '__' in value or not path.is_relative_to(products) or path.suffix != '.app':
                raise ValueError('Test host must be an app inside its build products')
            resolved[key] = path
        app = resolved.get('UITargetAppPath', resolved.get('TestHostPath'))
        if app is None or app.name != 'RideIntercom.app':
            raise ValueError('Missing RideIntercom test host')
        info = app / ('Contents/Info.plist' if (app / 'Contents').is_dir() else 'Info.plist')
        if not info.resolve().is_relative_to(products):
            raise ValueError('Test host Info must remain inside its build products')
        metadata = plistlib.loads(info.read_bytes())
        if metadata.get('StorageNamespace') != expected_namespace:
            raise ValueError('Generated host storage namespace does not match this test run')
        if 'DevelopmentInternetConnection' in metadata:
            raise ValueError('Generated test host contains development connection settings')
        hosts.add(str(info))
    return {'testRun': str(test_run), 'namespace': expected_namespace, 'hostInfoPaths': sorted(hosts)}


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
    def stop(process, original):
        try:
            if original is None and process.returncode is None:
                original = process_snapshot().get(process.pid)
            stop_process_tree(process, original)
            return ''
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            # A cleanup failure must not erase the original timeout/interruption.
            # Popen still owns its unreaped direct child; do not guess other PIDs.
            try:
                process.kill()
                process.wait(timeout=2)
            except (OSError, subprocess.SubprocessError) as fallback:
                return f'process cleanup failed: {error}; direct child cleanup failed: {fallback}'
            return f'process cleanup failed: {error}'

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
                original = None
                try:
                    original = process_snapshot().get(process.pid)
                    code = process.wait(timeout=timeout if timeout is not None else self.timeout)
                    status = 'passed' if code == 0 else 'failed'
                except subprocess.TimeoutExpired:
                    cleanup = self.stop(process, original)
                    status, code, reason = 'timeout', 124, 'command exceeded deadline'
                    if cleanup:
                        reason += '; ' + cleanup
                except KeyboardInterrupt:
                    cleanup = self.stop(process, original)
                    self.record(name, command, 'interrupted', 130, started, cleanup)
                    raise
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.stop(process, original)
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

    def check_test_host(self, name, test_run, namespace, needs=()):
        started = time.monotonic()
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            return self.record(name, [], 'blocked', None, started, 'requires ' + ', '.join(blocked))
        try:
            metadata = test_host_metadata(test_run, namespace)
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            return self.record(name, [], 'failed', 1, started, str(error))
        (self.out / (name + '.json')).write_text(json.dumps(metadata, indent=2) + '\n')
        return self.record(name, [], 'passed', 0, started, 'Generated host isolation verified before launch')

    def xcode(self, name, destination, only=None, needs=(), skip=None, reuse_build=None,
              scheme='RideIntercom'):
        bundle = self.out / f'{name}.xcresult'
        settings_stage = name + '-build-settings'
        started = time.monotonic()
        settings, test_run, configuration, namespace = None, None, '', ''
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            self.record(settings_stage, [], 'blocked', None, started, 'requires ' + ', '.join(blocked))
        else:
            try:
                configuration = scheme_configuration(ROOT, scheme)
                settings = xcode_build_settings(ROOT, scheme, destination, configuration)
                if reuse_build:
                    previous = json.loads((self.out / f'{reuse_build}-build-settings.json').read_text())
                    if settings != previous:
                        raise ValueError('The reused build does not match this scheme configuration and destination')
                (self.out / f'{name}-build-settings.json').write_text(json.dumps(settings, indent=2) + '\n')
                namespace = settings['RIDEINTERCOM_STORAGE_NAMESPACE']
                self.record(settings_stage, [], 'passed', 0, started, 'Resolved standard Xcode product paths')
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                self.record(settings_stage, [], 'failed', 1, started, str(error))
        needs = [settings_stage]
        if not reuse_build:
            command = ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj', '-scheme', scheme,
                       '-destination', destination, '-configuration', configuration]
            self.run(name + '-build', command, needs=needs)
            needs = [name + '-build']
        if settings is not None:
            test_run = select_test_run(settings, scheme)
        preflight = name + '-host-preflight'
        self.check_test_host(preflight, test_run, namespace, needs=needs)
        command = ['xcodebuild', 'test-without-building', '-xctestrun', str(test_run or ''),
                   '-destination', destination, '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle)]
        for identifier in ([only] if isinstance(only, str) else only or []):
            command.append(f'-only-testing:{identifier}')
        if skip:
            command.append(f'-skip-testing:{skip}')
        self.run(name, command, needs=[preflight])
        summary_name = name + '-summary'
        self.run(summary_name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], needs=[name], timeout=60)
        started = time.monotonic()
        try:
            summary = json.loads((self.out / f'{summary_name}.log').read_text())
            passed = self.results[summary_name]['status'] == 'passed' and xcode_tests_passed(summary)
        except (OSError, ValueError):
            passed = False
        self.record(name + '-acceptance', [], 'passed' if passed else 'failed', 0 if passed else 1,
                    started, 'requires nonzero tests, no failures/skips/runtime warnings, and a readable xcresult')


def file_fingerprint(path):
    if not path.is_file():
        return {'sha256': None}
    data = path.read_bytes()
    result = {'sha256': hashlib.sha256(data).hexdigest()}
    if path.name == 'project.pbxproj' and path.parent.name == 'RideIntercom.xcodeproj':
        pattern = rb'(CURRENT_PROJECT_VERSION\s*=\s*)([1-9][0-9]*)(\s*;)'
        numbers = re.findall(pattern, data)
        # Keep the raw hash as evidence. Only the common positive build number
        # may advance; every other project byte remains part of the comparison.
        if numbers and len({row[1] for row in numbers}) == 1:
            result['build_number'] = int(numbers[0][1])
            normalized = re.sub(pattern, rb'\1<BUILD_NUMBER>\3', data)
            result['configuration_sha256'] = hashlib.sha256(normalized).hexdigest()
    return result


def fingerprints_match(before, after):
    if before.keys() != after.keys():
        return False
    for name, original in before.items():
        current = after[name]
        if original == current:
            continue
        if (name != 'RideIntercom.xcodeproj/project.pbxproj'
                or not isinstance(original, dict) or not isinstance(current, dict)
                or set(original) != {'sha256', 'build_number', 'configuration_sha256'}
                or original.keys() != current.keys()
                or original['configuration_sha256'] != current['configuration_sha256']
                or current['build_number'] < original['build_number']):
            return False
    return True


def snapshot(out):
    # Hash file contents without copying potential credentials to the report.
    files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    hashes = {}
    for name in sorted(set(filter(None, files))):
        path = ROOT / name
        hashes[name] = file_fingerprint(path)
    (out / 'inputs.json').write_text(json.dumps(hashes, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='all', choices=['all', 'headless', 'packages', 'worker', 'pair', 'macos', 'ios', 'ios-ui', 'scripts'])
    parser.add_argument('--clean', action='store_true', help='Run standard swift package clean before package tests, using each package .build directory')
    parser.add_argument('--thread-sanitizer', action='store_true', help='Run supported Swift package tests under Thread Sanitizer')
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    os.environ['NO_COLOR'] = '1'
    os.environ['CI'] = '1'  # Noninteractive tool output; this still runs locally.
    out = os.environ.get('VALIDATION_DIR', ROOT / '.validation' / datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    runner = Runner(out, timeout=float(os.environ.get('VALIDATION_TIMEOUT_SECONDS', '1800')))
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
        packages = ['Audio/' + name for name in ['AudioCore', 'AudioMixer', 'Codec', 'SessionManager', 'AudioDevice']]
        packages += ['Audio/Effectors/' + name for name in ['DynamicsProcessor', 'PeakLimiter', 'SoundIsolation', 'VADGate']]
        packages += ['RTC']
        for package in packages:
            name = package.split('/')[-1]
            command = ['swift', 'test', '--package-path', 'RideIntercom/packages/' + package]
            needs = ['swift-toolchain'] + (['webrtc-artifact'] if name == 'RTC' else [])
            if args.clean:
                clean = 'package-' + name + '-clean'
                runner.run(clean, ['swift', 'package', '--package-path', 'RideIntercom/packages/' + package, 'clean'], needs=needs)
                needs += [clean]
            if args.thread_sanitizer:
                command += ['--sanitize=thread']
            if name == 'RTC':
                # Swift Testing otherwise runs suites concurrently even when
                # SwiftPM's default says "no parallel". Keep accelerated ten-minute
                # CPU stress and deliberate actor stalls off the real-time gates.
                command += ['--no-parallel', '--skip', 'WorkerPairTests']  # Pair has its own server stage.
            runner.run('package-' + name, command, needs=needs, tests=True)
    if mode in ('all', 'headless', 'worker', 'pair'):
        runner.run('worker-install', ['npm', '--prefix', 'server', 'ci'], needs=['node-toolchain'])
        runner.run('worker-types', ['npm', '--prefix', 'server', 'run', 'type-check'], needs=['worker-install'])
        runner.run('worker-test', ['npm', '--prefix', 'server', 'test'], needs=['worker-install'], tests=True)
    if mode in ('all', 'headless', 'pair'):
        pair_needs = ['worker-install', 'swift-toolchain', 'webrtc-artifact']
        if args.clean:
            clean = 'package-RTC-clean'
            if clean not in runner.results:
                runner.run(clean, ['swift', 'package', '--package-path', 'RideIntercom/packages/RTC', 'clean'],
                           needs=['swift-toolchain', 'webrtc-artifact'])
            pair_needs += [clean]
        if args.thread_sanitizer:
            os.environ['RIDEINTERCOM_PAIR_SANITIZER'] = 'thread'
        runner.run('swift-worker-pair', ['npm', '--prefix', 'server', 'run', 'test:pair'], needs=pair_needs, tests=True)
    if mode in ('all', 'headless', 'scripts'):
        runner.run('script-tests', [python, '-m', 'unittest', 'discover', '-s', 'scripts/tests'], tests=True)
        runner.run('cloudflare-scripts', ['node', '--test', 'scripts/Cloudflare/estimate-cost.test.mjs', 'scripts/Cloudflare/issue-device.test.mjs'], needs=['node-toolchain'], tests=True)
    if mode in ('all', 'macos'):
        try:
            with exclusive_run(simulator_resource_root() / 'run.lock'):
                runner.xcode('macos-tests', 'platform=macOS,arch=arm64', only='RideIntercomTests', needs=['swift-toolchain', 'webrtc-artifact'])
        except BlockingIOError:
            runner.record('macos-tests', [], 'blocked', None, time.monotonic(), 'Another managed App or audio test run is active')
    if mode in ('all', 'ios', 'ios-ui'):
        try:
            with exclusive_run(simulator_resource_root() / 'run.lock'):
                lease = SimulatorLease(runner, simulator_resource_root() / 'reusable.json')
                try:
                    runner.run('simulator-runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], needs=['swift-toolchain'], timeout=60)
                    runtimes = json.loads((runner.out / 'simulator-runtimes.log').read_text())['runtimes']
                    available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
                    runtime = os.environ.get('SIMULATOR_RUNTIME') or max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
                    device = os.environ.get('SIMULATOR_DEVICE_TYPE', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
                    sim = lease.prepare(runtime, device)
                    if sim:
                        (runner.out / 'simulator-id.txt').write_text(sim + '\n')
                        runner.run('simulator-boot', ['xcrun', 'simctl', 'boot', sim], timeout=120)
                        runner.run('simulator-ready', ['xcrun', 'simctl', 'bootstatus', sim, '-b'], needs=['simulator-boot'], timeout=180)
                        runner.run('simulator-appearance', ['xcrun', 'simctl', 'ui', sim, 'appearance', os.environ.get('SIMULATOR_APPEARANCE', 'dark')], needs=['simulator-ready'], timeout=30)
                        recovery = 'RideIntercomUITests/RideIntercomUITests/testCorruptGroupStoreRecovery'
                        runner.xcode('ios-tests', 'platform=iOS Simulator,id=' + sim, only='RideIntercomUITests' if mode == 'ios-ui' else None,
                                     needs=['simulator-ready', 'simulator-appearance', 'webrtc-artifact'], skip=recovery)
                        runner.xcode('ios-recovery', 'platform=iOS Simulator,id=' + sim, only=recovery,
                                     needs=['ios-tests-acceptance'], reuse_build='ios-tests')
                finally:
                    if lease.acquired:
                        lease.cleanup('simulator-final')
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            runner.record('simulator-availability', [], 'blocked', None, time.monotonic(), str(error))
    # A concurrent edit invalidates evidence rather than silently passing.
    before = (runner.out / 'inputs.json').read_text()
    snapshot(runner.out)
    after = (runner.out / 'inputs.json').read_text()
    (runner.out / 'inputs-before.json').write_text(before)
    runner.record('unchanged-inputs', [], 'passed' if fingerprints_match(json.loads(before), json.loads(after)) else 'failed', 0 if fingerprints_match(json.loads(before), json.loads(after)) else 1,
                  time.monotonic(), 'source/configuration fingerprints must match except for advancing the shared build number')
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

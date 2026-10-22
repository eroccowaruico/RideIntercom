#!/usr/bin/env python3
"""Real Mac/iPhone Simulator speech test. Artifacts and test data are isolated."""
import argparse
import hashlib
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.validate import ROOT, Runner, xcode_tests_passed
from scripts.test_lifecycle import exclusive_run, SimulatorLease
from scripts.audio_e2e_matrix import scenarios


def source_manifest():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    files = {}
    for name in sorted(set(names)):
        path = ROOT / name
        if name and path.suffix in {'.swift', '.py', '.pbxproj', '.xcscheme', '.wav', '.metadata'}:
            files[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), files=files)


def configure_test_run(source, destination, environment, identifiers=None):
    data = plistlib.loads(source.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if len(targets) != 1 or targets[0]['BlueprintName'] != 'RideIntercomAudioE2ETests':
        raise ValueError('Expected the dedicated audio E2E test target')
    targets[0].setdefault('EnvironmentVariables', {}).update(environment)
    targets[0]['OnlyTestIdentifiers'] = identifiers or ['AudioE2ETests/testDuplexSpeechOverNetwork']
    # __TESTROOT__ is relative to the xctestrun, which we keep beside its products.
    if source.parent != destination.parent:
        raise ValueError('Keep the configured xctestrun beside its build products')
    destination.write_bytes(plistlib.dumps(data))


def measurements(folder, expected_ids, role, transport):
    rows = [json.loads(path.read_text()) for path in folder.glob('*.json') if path.name != 'manifest.json']
    actual = [row.get('scenario') for row in rows]
    if len(actual) != len(expected_ids) or set(actual) != set(expected_ids):
        raise ValueError('Missing or duplicate per-scenario speech measurements')
    if any(row.get('role') != role or row.get('transport') != transport for row in rows):
        raise ValueError('Speech measurements belong to a different endpoint or transport')
    return rows


def run_pair(runner, commands, timeout):
    processes = []
    started = time.monotonic()
    try:
        for name, command in commands:
            log = (runner.out / (name + '.log')).open('w')
            try:
                process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                log.close()
            processes.append((name, command, process))
        while any(p.poll() is None for _, _, p in processes):
            if time.monotonic() - started > timeout:
                raise TimeoutError('Audio endpoints exceeded their deadline')
            time.sleep(0.2)
    finally:
        for name, command, process in processes:
            if process.poll() is None:
                Runner.stop(process)
            runner.record(name, command, 'passed' if process.returncode == 0 else 'failed', process.returncode, started)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--build-root', type=Path, default=Path('/tmp/RideIntercom-AudioE2E-Build'))
    parser.add_argument('--ephemeral', action='store_true', help='Delete the owned simulator after this run (CI)')
    parser.add_argument('--cleanup-only', action='store_true', help='Stop owned hosts and delete managed test devices')
    parser.add_argument('--transport', choices=['local', 'webrtc', 'all'], default='all')
    parser.add_argument('--matrix', choices=['smoke', 'quick', 'full'], default='quick')
    parser.add_argument('--seconds', type=int, default=8)
    parser.add_argument('--codec', choices=['default', 'pcm16', 'opus'], default='default')
    parser.add_argument('--isolation', choices=['default', 'off'], default='default')
    args = parser.parse_args()
    if not 6 <= args.seconds <= 600:
        parser.error('--seconds must be between 6 and 600')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    out = (args.output or Path('/tmp') / ('RideIntercom-AudioE2E-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))).resolve()
    if out == ROOT or ROOT in out.parents or args.build_root.resolve().is_relative_to(ROOT):
        parser.error('Evidence/build output must be outside the synchronized repository')
    runner = Runner(out)
    resource_root = Path('/tmp') / f'RideIntercom-AudioE2E-{os.getuid()}'
    try:
        with exclusive_run(resource_root / 'run.lock'):
            return execute(args, runner, resource_root)
    except BlockingIOError:
        runner.record('exclusive-run', [], 'failed', 1, time.monotonic(), 'Another audio E2E run is active')
        return 1


def execute(args, runner, resource_root):
    out = runner.out
    run_id = str(uuid.uuid4())
    cases = scenarios(args.matrix, args.seconds)
    if args.codec != 'default':
        for case in cases: case['codec'] = args.codec
    if args.isolation == 'off':
        for case in cases: case['transmitIsolation'] = False
    (out / 'scenarios.json').write_text(json.dumps(cases, indent=2) + '\n')
    (out / 'configuration.json').write_text(json.dumps(dict(run=run_id, seconds=args.seconds, codec=args.codec,
        isolation=args.isolation, input='bundled synthetic speech WAV', transport=args.transport,
        output='system AVAudioEngine render tap'), indent=2) + '\n')
    simulator = None
    leases = [SimulatorLease(runner, resource_root / name) for name in ['reusable.json', 'ephemeral.json']]
    lease = leases[int(args.ephemeral)]
    sources = source_manifest()
    (out / 'source-manifest.json').write_text(json.dumps(sources, indent=2) + '\n')
    try:
        def command(name, argv, timeout=1800):
            if not runner.run(name, argv, timeout=timeout):
                raise RuntimeError(name + ' failed; see ' + str(out))
        # Recover only journaled resources, including after SIGKILL/power loss.
        for index, old in enumerate(leases):
            if args.cleanup_only:
                old.state['reusable'] = False
            if not old.cleanup(f'recovery-{index}'):
                raise RuntimeError('Previous owned resources could not be cleaned up')
        if args.cleanup_only:
            return runner.exit_code
        reusable = lease.owned_devices() if lease.state else []
        if len(reusable) > 1:
            raise RuntimeError('Ambiguous managed simulator ownership')
        if reusable:
            simulator = reusable[0]['udid']
        else:
            command('runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], 60)
            runtimes = json.loads((out / 'runtimes.log').read_text())['runtimes']
            available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime = max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
            lease.reserve('RideIntercom Audio E2E ' + run_id[:8], reusable=not args.ephemeral)
            command('simulator-create', ['xcrun', 'simctl', 'create', lease.state['name'],
                'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime], 60)
            simulator = (out / 'simulator-create.log').read_text().strip()
            lease.identify(simulator)
        lease.host(args.build_root.resolve() / 'mac/Build/Products/Debug/RideIntercom.app/Contents/MacOS/RideIntercom')
        command('simulator-boot', ['xcrun', 'simctl', 'boot', simulator], 60)
        (out / 'simulator-id.txt').write_text(simulator + '\n')
        command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', simulator, '-b'], 180)
        endpoints = [('a', 'mac', 'platform=macOS,arch=arm64'),
                     ('b', 'ios', 'platform=iOS Simulator,id=' + simulator)]
        products_by_platform = {}
        for role, platform, destination in endpoints:
            derived = args.build_root.resolve() / platform
            command('build-' + platform, ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj',
                '-scheme', 'RideIntercomAudioE2E', '-destination', destination, '-derivedDataPath', str(derived),
                'RIDEINTERCOM_STORAGE_NAMESPACE=RideIntercom.AudioE2E.Host'])
            products = derived / 'Build/Products'
            runs = sorted(products.glob('RideIntercomAudioE2E_*.xctestrun'), key=lambda p: p.stat().st_mtime, reverse=True)
            if not runs:
                raise ValueError('Missing generated xctestrun')
            products_by_platform[platform] = (products, runs[0])
        command('microphone-permission', ['xcrun', 'simctl', 'privacy', simulator, 'grant', 'microphone',
                'com.yowamushi-inc.RideIntercom.RideIntercom'], 60)
        preflight = products / 'audio-preflight.xctestrun'
        configure_test_run(runs[0], preflight, {}, identifiers=[
            'AudioE2ETests/testSpeechMatcherRejectsSilenceAndWrongSpeaker',
            'AudioE2ETests/testSystemSessionAcceptsCallProfiles'])
        command('preflight', ['xcodebuild', 'test-without-building', '-xctestrun', str(preflight),
            '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(out / 'preflight.xcresult')], 120)
        command('preflight-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(out / 'preflight.xcresult'), '--format', 'json'], 60)
        preflight_summary = json.loads((out / 'preflight-summary.log').read_text())
        if not xcode_tests_passed(preflight_summary) or preflight_summary['totalTestCount'] != 2:
            raise RuntimeError('Speech oracle and real iOS session preflight must both pass')
        transports = ['local', 'webrtc'] if args.transport == 'all' else [args.transport]
        measured = []
        for transport in transports:
            # A fresh group per route proves authentication separately. Reuse the
            # same app products and simulator; do not rebuild per scenario/route.
            run_id = str(uuid.uuid4())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            environment = dict(AUDIO_E2E_RUN=run_id, AUDIO_E2E_TRANSPORT=transport,
                AUDIO_E2E_WORKER_URL=f'http://127.0.0.1:{port}', AUDIO_E2E_SCENARIOS=json.dumps(cases))
            (out / (transport + '-configuration.json')).write_text(json.dumps(environment, indent=2) + '\n')
            commands = []
            for role, platform, destination in endpoints:
                products, source = products_by_platform[platform]
                configured = products / 'audio-pair.xctestrun'
                configure_test_run(source, configured, environment | dict(AUDIO_E2E_ROLE=role))
                name = transport + '-' + platform
                commands.append(('test-' + name, ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                    '-destination', destination, '-parallel-testing-enabled', 'NO',
                    '-resultBundlePath', str(out / (name + '.xcresult'))]))
            run_pair(runner, commands, 120 + sum(case['seconds'] + 20 for case in cases))
            for role, platform, _ in endpoints:
                name = transport + '-' + platform
                summary_ok = runner.run('summary-' + name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                    '--path', str(out / (name + '.xcresult')), '--format', 'json'], timeout=60)
                if summary_ok:
                    summary = json.loads((out / ('summary-' + name + '.log')).read_text())
                    passed = xcode_tests_passed(summary) and summary['totalTestCount'] == 1
                    runner.record('accept-' + name, [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
                folder = out / ('attachments-' + name)
                exported = runner.run('attachments-' + name, ['xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', str(out / (name + '.xcresult')), '--output-path', str(folder)], timeout=60)
                if exported:
                    try:
                        measured += measurements(folder, [case['id'] for case in cases], role, transport)
                        runner.record('coverage-' + name, [], 'passed', 0, time.monotonic())
                    except (OSError, ValueError) as error:
                        runner.record('coverage-' + name, [], 'failed', 1, time.monotonic(), str(error))
        (out / 'measurements.json').write_text(json.dumps(measured, indent=2) + '\n')
        unchanged = sources == source_manifest()
        runner.record('source-stability', [], 'passed' if unchanged else 'failed', 0 if unchanged else 1,
                      time.monotonic(), 'Sources must remain unchanged between build and acceptance')
    except (OSError, ValueError, RuntimeError, TimeoutError, KeyboardInterrupt) as error:
        runner.record('audio-e2e', [], 'failed', 1, time.monotonic(), str(error))
    finally:
        # A second Ctrl-C must not skip teardown. SIGKILL is recovered next run.
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in [signal.SIGINT, signal.SIGTERM]}
        try:
            lease.cleanup('cleanup')
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        print('Evidence: ' + str(out), flush=True)
    return runner.exit_code


if __name__ == '__main__':
    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())

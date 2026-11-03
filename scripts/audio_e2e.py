#!/usr/bin/env python3
"""Real Mac/iPhone Simulator speech test. Artifacts and test data are isolated."""
import argparse
from datetime import datetime
import json
import math
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
from scripts.validate import ROOT, Runner, xcode_tests_passed, file_fingerprint, fingerprints_match, test_host_metadata
from scripts.test_lifecycle import exclusive_run, SimulatorLease, simulator_resource_root, process_snapshot
from scripts.xcode_paths import scheme_configuration, xcode_build_settings, select_test_run
from scripts.audio_e2e_matrix import scenarios


def source_manifest():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    files = {}
    for name in sorted(set(names)):
        path = ROOT / name
        is_asset = any(part.endswith(('.xcassets', '.icon')) for part in path.parts)
        if name and (is_asset or path.suffix in {'.swift', '.py', '.pbxproj', '.xcscheme', '.wav', '.metadata', '.json', '.plist', '.resolved', '.xcstrings', '.storekit', '.entitlements', '.xcconfig', '.xctestplan', '.png', '.strings', '.stringsdict', '.xcprivacy', '.zip'}):
            files[name] = file_fingerprint(path)
    return dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), files=files)


def shared_host_audio_device(devices, host_items):
    """Return the one 48 kHz host device that both captures and renders.

    The iOS Simulator opens one duplex I/O. Following separate host defaults
    (for example a USB microphone and a display speaker) leaves its native
    input at 0 Hz, so the measurement never reaches the audio path."""
    inputs = {device['uid']: device['name'] for device in devices['inputDevices']}
    outputs = {device['uid']: device['name'] for device in devices['outputDevices']}
    by_name = {item.get('_name'): item for item in host_items}
    eligible = [uid for uid, name in inputs.items() if outputs.get(uid) == name
                and (item := by_name.get(name)) is not None and item.get('coreaudio_device_input', 0) >= 1
                and item.get('coreaudio_device_output', 0) >= 1 and item.get('coreaudio_device_srate') == 48000]
    for default in ('coreaudio_default_audio_input_device', 'coreaudio_default_audio_output_device'):
        preferred = [uid for uid in eligible if default in by_name[inputs[uid]]]
        if len(preferred) == 1:
            return preferred[0]
    if len(eligible) != 1:
        raise ValueError('Connect exactly one 48 kHz host audio device with both input and output, '
                         f'or make it the default input; found {len(eligible)}')
    return eligible[0]


class SimulatorAudioPin:
    """Pin the owned Simulator's input and output to one host device for a run."""
    def __init__(self, simulator, run_json):
        self.simulator = simulator
        self.run_json = run_json
        self.original = None

    @staticmethod
    def _selection(value):
        if value == {'systemDefault': {}}:
            return 'systemDefault'
        # devicectl encodes a pinned device as {"device": {"_0": uid}}.
        uid = value.get('device', {}).get('_0') if isinstance(value, dict) else None
        if not uid:
            raise ValueError('Unrecognized Simulator audio selection: ' + json.dumps(value))
        return uid

    def _info(self):
        return self.run_json(['xcrun', 'devicectl', 'device', 'info', 'audio', '--device', self.simulator, '--json-output', '-'])

    def _select(self, input_device, output_device):
        self.run_json(['xcrun', 'devicectl', 'device', 'settings', 'audio', '--device', self.simulator,
                       '--input-device', input_device, '--output-device', output_device, '--json-output', '-'])

    def pin(self):
        before = self._info()
        original = (self._selection(before['audioInputDevice']), self._selection(before['audioOutputDevice']))
        devices = self.run_json(['xcrun', 'devicectl', 'list', 'audioDevices', '--json-output', '-'])
        host = [item for group in self.run_json(['system_profiler', 'SPAudioDataType', '-json'])['SPAudioDataType']
                for item in group.get('_items', [])]
        uid = shared_host_audio_device(devices, host)
        self.original = original
        self._select(uid, uid)
        after = self._info()
        if (self._selection(after['audioInputDevice']), self._selection(after['audioOutputDevice'])) != (uid, uid):
            raise RuntimeError('Simulator audio device selection did not apply')
        return uid

    def restore(self):
        if self.original is None:
            return
        original, self.original = self.original, None
        self._select(*original)


def run_devicectl_json(args):
    output = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60, check=True).stdout
    data = json.loads(output)
    return data.get('result', data) if args[0] == 'xcrun' else data


def configure_test_run(source, purpose, platform, namespace, environment, identifiers=None):
    data = plistlib.loads(source.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if len(targets) != 1 or targets[0]['BlueprintName'] != 'RideIntercomAudioE2ETests':
        raise ValueError('Expected the dedicated audio E2E test target')
    test_host_metadata(source, namespace)
    targets[0].setdefault('EnvironmentVariables', {}).update(environment)
    targets[0]['OnlyTestIdentifiers'] = identifiers or ['AudioE2ETests/testDuplexSpeechOverNetwork']
    # Mac and Simulator now share Xcode's product root. Keep distinct files
    # beside their products so __TESTROOT__ stays valid for both endpoints.
    destination = source.parent / f'audio-{purpose}-{platform}.xctestrun'
    destination.write_bytes(plistlib.dumps(data))
    return destination


def build_audio_host(runner, platform, destination, optimization):
    configuration = optimization + '-Validation'
    if optimization == 'Debug' and scheme_configuration(ROOT, 'RideIntercomAudioE2E') != configuration:
        raise ValueError('Audio E2E TestAction must use the native Debug validation configuration')
    settings = xcode_build_settings(ROOT, 'RideIntercomAudioE2E', destination, configuration)
    (runner.out / ('build-settings-' + platform + '.json')).write_text(json.dumps(settings, indent=2) + '\n')
    command = ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj',
        '-scheme', 'RideIntercomAudioE2E', '-configuration', configuration, '-destination', destination]
    if not runner.run('build-' + platform, command):
        raise RuntimeError('Audio E2E build failed')
    test_run = select_test_run(settings, 'RideIntercomAudioE2E')
    if not runner.check_test_host('host-preflight-' + platform, test_run, settings['RIDEINTERCOM_STORAGE_NAMESPACE']):
        raise RuntimeError('Audio E2E host isolation check failed')
    return settings, test_run


def build_audio_hosts(runner, endpoints, optimization, clean=False):
    # Both SDKs share Xcode's product root. Finish every clean before building
    # either endpoint, so the second SDK cannot remove the first SDK's products.
    if clean:
        for _, platform, destination in endpoints:
            command = ['xcodebuild', 'clean', '-project', 'RideIntercom.xcodeproj',
                '-scheme', 'RideIntercomAudioE2E', '-configuration', optimization + '-Validation', '-destination', destination]
            if not runner.run('clean-' + platform, command):
                raise RuntimeError('Audio E2E clean failed')
    products = {}
    for _, platform, destination in endpoints:
        products[platform] = build_audio_host(runner, platform, destination, optimization)
    return products


def measurements(folder, expected_ids, role, transport):
    rows = [json.loads(path.read_text()) for path in folder.glob('*.json') if path.name != 'manifest.json']
    rows = [row for row in rows if 'scenario' in row]
    actual = [row.get('scenario') for row in rows]
    if len(actual) != len(expected_ids) or set(actual) != set(expected_ids):
        raise ValueError('Missing or duplicate per-scenario speech measurements')
    if any(row.get('role') != role or row.get('transport') != transport for row in rows):
        raise ValueError('Speech measurements belong to a different endpoint or transport')
    return rows


def duplex_latencies(rows):
    """Mac and its Simulator share the monotonic host clock, unlike two phones.

    Resolve the known repeating fixture phase ONCE per recording. The bounded
    production queues are much shorter than a fixture period; a per-window fit
    would conceal changes in playback delay and is deliberately not used.
    """
    values, failures = [], []
    for row in rows:
        if row['expectedSilence']:
            continue
        if not row.get('continuityPassed'):
            failures.append('Latency is unavailable without matched speech output')
            continue
        remote = [other for other in rows if other['scenario'] == row['scenario']
                  and other['transport'] == row['transport'] and other['role'] != row['role']]
        if len(remote) != 1:
            failures.append('Latency requires both measured endpoints')
            continue
        sender = remote[0]
        period = sender['localFixtureDurationSeconds']
        delay = row['firstOutputHostTime'] - sender['firstCaptureHostTime'] - row['continuity']['referenceOffsetSeconds']
        if not math.isfinite(period) or period < 2 or not math.isfinite(delay):
            failures.append('Invalid capture/render timing')
            continue
        delay -= round(delay / period) * period
        row['captureToRenderLatencySeconds'] = delay
        values.append(delay)
        # Retain a 10 ms allowance for alignment resolution in the 125 ms budget.
        if delay < -0.01 or delay + 0.01 > 0.125:
            failures.append(f"{row['transport']} {row['scenario']} {row['role']}: {delay * 1000:.2f} ms exceeds 125 ms budget including alignment allowance")
    if failures:
        raise ValueError('; '.join(failures))
    return values


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
            processes.append((name, command, process, None))
            original = process_snapshot().get(process.pid)
            processes[-1] = (name, command, process, original)
            if len(processes) == 1 and len(commands) > 1:
                # Both endpoints share the Mac's CoreAudio service. Initialize
                # their native graphs in order, then measure simultaneous media.
                # This is setup readiness, never an added audio-path delay.
                while 'AUDIO_E2E_NATIVE_READY' not in (runner.out / (name + '.log')).read_text(errors='replace'):
                    if process.poll() is not None:
                        raise RuntimeError('Audio endpoint exited before native initialization completed')
                    if time.monotonic() - started > min(timeout, 30):
                        raise TimeoutError('Audio endpoint native initialization exceeded its deadline')
                    time.sleep(0.05)
        while any(p.poll() is None for _, _, p, _ in processes):
            if time.monotonic() - started > timeout:
                raise TimeoutError('Audio endpoints exceeded their deadline')
            time.sleep(0.2)
    finally:
        for name, command, process, original in processes:
            cleanup = Runner.stop(process, original) if process.poll() is None else ''
            runner.record(name, command, 'passed' if process.returncode == 0 and not cleanup else 'failed', process.returncode, started, cleanup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug', help='Use Release for shipping-performance measurements; thresholds are identical')
    parser.add_argument('--clean-build', action='store_true', help='Clean test products before building, preserving bundle identifiers and signing')
    parser.add_argument('--ephemeral', action='store_true', help='Delete the owned simulator after this run (CI)')
    parser.add_argument('--cleanup-only', action='store_true', help='Recover managed devices and report old running hosts without stopping unknown owners')
    parser.add_argument('--transport', choices=['local', 'webrtc', 'all'], default='all')
    parser.add_argument('--matrix', choices=['smoke', 'quick', 'full', 'identity'], default='quick')
    parser.add_argument('--speech-pair', choices=['english', 'japanese', 'conversation'], default='english')
    parser.add_argument('--switches-only', action='store_true', help='Live codec, format and effect changes with bounded silence and click checks')
    parser.add_argument('--codec-only', action='store_true', help='Native codec identity across four speech fixtures and all supported formats')
    parser.add_argument('--group-only', action='store_true', help='Eight participants with mixed codecs, delayed relay routes and real rendered audio')
    parser.add_argument('--realtime-only', action='store_true', help='Measure real iOS input, VAD, streaming codecs and output against the 125 ms budget')
    parser.add_argument('--pipeline-only', action='store_true', help='Measure the iOS mixer/codec/output without network or VAD')
    parser.add_argument('--seconds', type=int, default=8)
    parser.add_argument('--codec', choices=['default', 'pcm16', 'opus', 'mpeg4AACELD'], default='default')
    parser.add_argument('--isolation', choices=['default', 'off'], default='default')
    args = parser.parse_args()
    if not 6 <= args.seconds <= 600:
        parser.error('--seconds must be between 6 and 600')
    if sum([args.pipeline_only, args.realtime_only, args.group_only, args.codec_only, args.switches_only]) > 1:
        parser.error('Choose one standalone audio test mode')
    if args.speech_pair == 'conversation' and args.seconds < 20:
        parser.error('Conversation coverage requires --seconds 20 or longer')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    out = (args.output or ROOT / '.validation' / ('audio-e2e-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))).resolve()
    if out == ROOT:
        parser.error('Use a separate evidence folder within .validation or another explicit output location')
    runner = Runner(out)
    resource_root = simulator_resource_root()
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
        isolation=args.isolation, buildConfiguration=args.configuration, input='bundled synthetic speech WAV', transport=args.transport,
        speechPair=args.speech_pair, pipelineOnly=args.pipeline_only, realtimeOnly=args.realtime_only, groupOnly=args.group_only, codecOnly=args.codec_only, switchesOnly=args.switches_only,
        output='system AVAudioEngine render tap'), indent=2) + '\n')
    simulator = None
    audio_pin = None
    leases = [SimulatorLease(runner, resource_root / name) for name in ['reusable.json', 'ephemeral.json']]
    lease = leases[int(args.ephemeral)]
    sources = source_manifest()
    (out / 'source-manifest.json').write_text(json.dumps(sources, indent=2) + '\n')
    try:
        def command(name, argv, timeout=1800):
            if not runner.run(name, argv, timeout=timeout):
                raise RuntimeError(name + ' failed; see ' + str(out))
        if args.cleanup_only:
            lease.prepare(None, None, delete_all=True)
        else:
            command('runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], 60)
            runtimes = json.loads((out / 'runtimes.log').read_text())['runtimes']
            available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime = max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
            simulator = lease.prepare(runtime, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', reusable=not args.ephemeral)
        # Retain recovery of hosts recorded by the other (ephemeral/reusable)
        # mode without deleting the device that prepare just adopted.
        for index, old in enumerate(leases):
            if old is not lease and not old.cleanup_host(f'recovery-{index}'):
                raise RuntimeError('A previous host requires ownership review before retrying')
        if args.cleanup_only:
            return runner.exit_code
        command('simulator-boot', ['xcrun', 'simctl', 'boot', simulator], 60)
        (out / 'simulator-id.txt').write_text(simulator + '\n')
        command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', simulator, '-b'], 180)
        audio_pin = SimulatorAudioPin(simulator, run_devicectl_json)
        try:
            device = audio_pin.pin()
        except (ValueError, KeyError, subprocess.SubprocessError) as error:
            runner.record('simulator-audio-device', [], 'failed', 1, time.monotonic(), str(error))
            raise RuntimeError('simulator-audio-device failed; see ' + str(out))
        runner.record('simulator-audio-device', [], 'passed', 0, time.monotonic(), 'Input and output pinned to ' + device)
        endpoints = [('a', 'mac', 'platform=macOS,arch=arm64'),
                     ('b', 'ios', 'platform=iOS Simulator,id=' + simulator)]
        products_by_platform = build_audio_hosts(runner, endpoints, args.configuration, args.clean_build)
        ios_settings, ios_run = products_by_platform['ios']
        command('microphone-permission', ['xcrun', 'simctl', 'privacy', simulator, 'grant', 'microphone',
                'com.yowamushi-inc.RideIntercom.RideIntercom'], 60)
        preflight = configure_test_run(ios_run, 'preflight', 'ios', ios_settings['RIDEINTERCOM_STORAGE_NAMESPACE'], {}, identifiers=[
            'AudioE2ETests/testSpeechMatcherRejectsSilenceAndWrongSpeaker',
            'AudioE2ETests/testContinuityRejectsGapsRepeatsAndMissingSpeech',
            'AudioE2ETests/testMicroGapOverlapAndClickAreRejected',
            'AudioE2ETests/testConversationOracleRejectsMissingAcknowledgements',
            'AudioE2ETests/testSystemSessionAcceptsCallProfiles'])
        command('preflight', ['xcodebuild', 'test-without-building', '-xctestrun', str(preflight),
            '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(out / 'preflight.xcresult')], 120)
        command('preflight-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(out / 'preflight.xcresult'), '--format', 'json'], 60)
        preflight_summary = json.loads((out / 'preflight-summary.log').read_text())
        if not xcode_tests_passed(preflight_summary) or preflight_summary['totalTestCount'] != 5:
            raise RuntimeError('Speech oracle and real iOS session preflight must both pass')
        mac_settings, mac_run = products_by_platform['mac']
        mac_preflight = configure_test_run(mac_run, 'preflight', 'mac', mac_settings['RIDEINTERCOM_STORAGE_NAMESPACE'], {}, identifiers=[
            'AudioE2ETests/testMacFixturePacesCompletedSamples',
            'AudioE2ETests/testFixturePreservesClockGapsWithoutDelayingLaterSpeech'])
        command('preflight-mac', ['xcodebuild', 'test-without-building', '-xctestrun', str(mac_preflight),
            '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(out / 'preflight-mac.xcresult')], 120)
        command('preflight-mac-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(out / 'preflight-mac.xcresult'), '--format', 'json'], 60)
        mac_summary = json.loads((out / 'preflight-mac-summary.log').read_text())
        if not xcode_tests_passed(mac_summary) or mac_summary['totalTestCount'] != 2:
            raise RuntimeError('Mac fixture capture clock must pass before latency measurement')
        transports = ['local', 'webrtc'] if args.transport == 'all' else [args.transport]
        if args.pipeline_only or args.realtime_only or args.group_only or args.codec_only or args.switches_only:
            configured = configure_test_run(ios_run, 'pipeline', 'ios', ios_settings['RIDEINTERCOM_STORAGE_NAMESPACE'], {}, identifiers=(['AudioE2ETests/testInputModeChangesRestoreTheSharedReceiveClock'] if args.switches_only else ['AudioE2ETests/testTransmitChainPreservesConversationAndAcknowledgements'] if args.codec_only else []) + ['AudioE2ETests/testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio' if args.switches_only else 'AudioE2ETests/testNativeCodecsPreserveWholeSpeech' if args.codec_only else 'AudioE2ETests/testEightPersonMixedRouteConversation' if args.group_only else 'AudioE2ETests/testRealtimeAudioLatencyAndIdentity' if args.realtime_only else 'AudioE2ETests/testSpeechContinuityWithoutNetwork'])
            runner.run('test-pipeline', ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
                '-resultBundlePath', str(out / 'pipeline.xcresult')], timeout=600 if args.codec_only or args.realtime_only else 180)
            if runner.run('summary-pipeline', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(out / 'pipeline.xcresult'), '--format', 'json'], timeout=60):
                summary = json.loads((out / 'summary-pipeline.log').read_text())
                passed = xcode_tests_passed(summary) and summary['totalTestCount'] == (2 if args.codec_only or args.switches_only else 1)
                runner.record('accept-pipeline', [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
            folder = out / 'attachments-pipeline'
            if runner.run('attachments-pipeline', ['xcrun', 'xcresulttool', 'export', 'attachments',
                '--path', str(out / 'pipeline.xcresult'), '--output-path', str(folder)], timeout=60):
                expected = ['live-settings', 'input-mode-recovery'] if args.switches_only else ['native-codecs', 'transmit-conversations'] if args.codec_only else ['eight-person-mixed'] if args.group_only else [f'realtime-{fixture}-{codec}' for fixture in ['speech-ja', 'conversation-ja', 'conversation-reply-ja'] for codec in ['pcm16', 'opus', 'mpeg4AACELD']] if args.realtime_only else ['pipeline-20ms', 'pipeline-100ms']
                rows = measurements(folder, expected, 'pipeline', 'none')
                (out / 'pipeline-measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
            transports = []
        measured = []
        for transport in transports:
            # A fresh group per route proves authentication separately. Reuse the
            # same app products and simulator; do not rebuild per scenario/route.
            run_id = str(uuid.uuid4())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            environment = dict(AUDIO_E2E_RUN=run_id, AUDIO_E2E_TRANSPORT=transport,
                AUDIO_E2E_SPEECH_PAIR=args.speech_pair,
                AUDIO_E2E_WORKER_URL=f'http://127.0.0.1:{port}', AUDIO_E2E_SCENARIOS=json.dumps(cases))
            (out / (transport + '-configuration.json')).write_text(json.dumps(environment, indent=2) + '\n')
            commands = []
            for role, platform, destination in endpoints:
                settings, source = products_by_platform[platform]
                configured = configure_test_run(source, 'pair', platform, settings['RIDEINTERCOM_STORAGE_NAMESPACE'], environment | dict(AUDIO_E2E_ROLE=role))
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
                    passed = xcode_tests_passed(summary) and summary['totalTestCount'] == (2 if args.codec_only or args.switches_only else 1)
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
        try:
            duplex_latencies(measured)
            if measured:
                runner.record('duplex-latency', [], 'passed', 0, time.monotonic())
        except (KeyError, TypeError, ValueError) as error:
            runner.record('duplex-latency', [], 'failed', 1, time.monotonic(), str(error))
        (out / 'measurements.json').write_text(json.dumps(measured, indent=2) + '\n')
        after_sources = source_manifest()
        (out / 'source-manifest-after.json').write_text(json.dumps(after_sources, indent=2) + '\n')
        unchanged = sources['head'] == after_sources['head'] and fingerprints_match(sources['files'], after_sources['files'])
        runner.record('source-stability', [], 'passed' if unchanged else 'failed', 0 if unchanged else 1,
                      time.monotonic(), 'Sources/configuration unchanged; all raw input hashes must match exactly')
    except (OSError, ValueError, RuntimeError, TimeoutError, KeyboardInterrupt, subprocess.SubprocessError) as error:
        runner.record('audio-e2e', [], 'failed', 1, time.monotonic(), str(error))
    finally:
        # A second Ctrl-C must not skip teardown. SIGKILL is recovered next run.
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in [signal.SIGINT, signal.SIGTERM]}
        try:
            if audio_pin is not None:
                try:
                    audio_pin.restore()
                    runner.record('simulator-audio-restore', [], 'passed', 0, time.monotonic())
                except (ValueError, KeyError, subprocess.SubprocessError) as error:
                    runner.record('simulator-audio-restore', [], 'failed', 1, time.monotonic(), str(error))
            if lease.acquired:
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

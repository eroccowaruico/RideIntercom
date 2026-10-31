#!/usr/bin/env python3
"""Explicit, local StoreKit integration checks; no Apple account or Simulator."""
import argparse
import json
import os
import subprocess
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.audio_e2e import source_manifest
from scripts.test_lifecycle import exclusive_run, stop_executable
from scripts.validate import Runner, file_fingerprint, fingerprints_match, xcode_tests_passed


def manifest():
    value = source_manifest()
    fixture = 'RideIntercomTests/Fixtures/LocalPurchases.storekit'
    value['files'][fixture] = file_fingerprint(ROOT / fixture)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, default=Path('/private/tmp/RideIntercom-StoreKit'))
    args = parser.parse_args()
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    derived = args.derived_data.resolve()
    if derived.is_relative_to(ROOT):
        parser.error('DerivedData must be outside the repository')
    # The same lock covers build, execution, evidence, and owned-host cleanup.
    with exclusive_run(derived.parent / (derived.name + '.lock')):
        return run(args.output, derived)


def run(output, derived):
    runner = Runner(output)
    (runner.out / 'derived-data.txt').write_text(str(derived) + '\n')
    before = manifest()
    (runner.out / 'source-before.json').write_text(json.dumps(before, indent=2) + '\n')
    bundle = runner.out / 'storekit.xcresult'
    command = [
        'xcodebuild', 'test', '-project', 'RideIntercom.xcodeproj', '-scheme', 'RideIntercom-StoreKitTests',
        '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
        '-derivedDataPath', str(derived), '-resultBundlePath', str(bundle),
        '-only-testing:RideIntercomTests/StoreEntitlementTests',
        '-only-testing:RideIntercomTests/StoreKitAccessTests',
        '-only-testing:RideIntercomTests/LocalStoreKitTests',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RIDEINTERCOM_VALIDATION RIDEINTERCOM_STOREKIT_TESTING',
        'RIDEINTERCOM_STORAGE_NAMESPACE=RideIntercom.Validation.StoreKit.' + runner.out.name,
        'ENABLE_APP_SANDBOX=NO', 'CODE_SIGN_ENTITLEMENTS='
    ]
    try:
        runner.run('storekit', command)
    finally:
        started = time.monotonic()
        try:
            stop_executable(derived / 'Build/Products/Debug/RideIntercom.app/Contents/MacOS/RideIntercom')
            runner.record('owned-host-cleanup', [], 'passed', 0, started)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            runner.record('owned-host-cleanup', [], 'failed', 1, started, str(error))
    runner.run('storekit-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], timeout=60)
    started = time.monotonic()
    try:
        summary = json.loads((runner.out / 'storekit-summary.log').read_text())
        passed = xcode_tests_passed(summary)
    except (OSError, ValueError):
        passed = False
    runner.record('storekit-acceptance', [], 'passed' if passed else 'failed', 0 if passed else 1, started,
                  'requires nonzero tests, no failures/skips/runtime warnings, and readable results')
    after = manifest()
    (runner.out / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
    same = before['head'] == after['head'] and fingerprints_match(before['files'], after['files'])
    runner.record('unchanged-inputs', [], 'passed' if same else 'failed', 0 if same else 1, time.monotonic(),
                  'source, fixture, and configuration unchanged except generated build number')
    return runner.exit_code


if __name__ == '__main__':
    raise SystemExit(main())

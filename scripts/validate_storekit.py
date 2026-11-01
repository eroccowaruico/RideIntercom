#!/usr/bin/env python3
"""Explicit, local StoreKit integration checks; no Apple account or Simulator."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.audio_e2e import source_manifest
from scripts.test_lifecycle import exclusive_run
from scripts.validate import Runner, file_fingerprint, fingerprints_match


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
    runner.xcode('storekit', 'platform=macOS', scheme='RideIntercom-StoreKitTests', derived_data=derived,
                 extra_conditions=['RIDEINTERCOM_STOREKIT_TESTING'],
                 only=['RideIntercomTests/' + name for name in [
                     'StoreEntitlementTests', 'StoreKitAccessTests', 'StoreDistributionAccessTests', 'LocalStoreKitTests']])
    after = manifest()
    (runner.out / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
    same = before['head'] == after['head'] and fingerprints_match(before['files'], after['files'])
    runner.record('unchanged-inputs', [], 'passed' if same else 'failed', 0 if same else 1, time.monotonic(),
                  'source, fixture, and configuration unchanged except generated build number')
    return runner.exit_code


if __name__ == '__main__':
    raise SystemExit(main())

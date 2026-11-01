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
from scripts.test_lifecycle import exclusive_run, simulator_resource_root
from scripts.validate import Runner, file_fingerprint, fingerprints_match

SUITES = ('StoreEntitlementTests', 'StoreKitAccessTests', 'StoreDistributionAccessTests', 'LocalStoreKitTests')
CORE_CASES = (
    'LocalStoreKitTests/productPurchaseIsAdoptedBeforeFinishAndUnrelatedProductsRemainUnfinished()',
    'LocalStoreKitTests/unfinishedPurchasesRecoverOnNewAccountStartAndExplicitRestore()',
    'LocalStoreKitTests/deliveredTicketsFinishBeforeHangingMonthlyStatusAndLateReadCannotFinishNewRenewal()',
)


def record_selection_coverage(runner, bundle):
    runner.run('storekit-executed-tree', ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle)], timeout=60)
    cases = {}
    def visit(value):
        if isinstance(value, dict):
            if value.get('nodeType') == 'Test Case':
                cases[value.get('nodeIdentifier', '')] = value.get('result')
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    try:
        visit(json.loads((runner.out / 'storekit-executed-tree.log').read_text()))
    except (OSError, ValueError):
        pass
    counts = {suite: sum(name.startswith(suite + '/') for name in cases) for suite in SUITES}
    required = {name: cases.get(name, 'NOT EXECUTED') for name in CORE_CASES}
    passed = all(counts.values()) and all(result == 'Passed' for result in required.values())
    (runner.out / 'storekit-selection-coverage.json').write_text(json.dumps({'suites': counts, 'required': required}, indent=2) + '\n')
    runner.record('storekit-selection-coverage', [], 'passed' if passed else 'failed', 0 if passed else 1,
                  time.monotonic(), 'All selected suites and real purchase/restore core cases must execute')


def manifest():
    value = source_manifest()
    fixture = 'RideIntercomTests/Fixtures/LocalPurchases.storekit'
    value['files'][fixture] = file_fingerprint(ROOT / fixture)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    # Use the existing test lease through build, launch, and owned-host cleanup.
    with exclusive_run(simulator_resource_root() / 'run.lock'):
        return run(args.output)


def run(output):
    runner = Runner(output)
    before = manifest()
    (runner.out / 'source-before.json').write_text(json.dumps(before, indent=2) + '\n')
    runner.xcode('storekit', 'platform=macOS,arch=arm64', scheme='RideIntercom-StoreKitTests',
                 only=['RideIntercomTests/' + name for name in SUITES])
    record_selection_coverage(runner, runner.out / 'storekit.xcresult')
    after = manifest()
    (runner.out / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
    same = before['head'] == after['head'] and fingerprints_match(before['files'], after['files'])
    runner.record('unchanged-inputs', [], 'passed' if same else 'failed', 0 if same else 1, time.monotonic(),
                  'source, fixture, and configuration hashes must match exactly')
    return runner.exit_code


if __name__ == '__main__':
    raise SystemExit(main())

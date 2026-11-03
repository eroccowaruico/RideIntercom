#!/usr/bin/env python3
"""Read scheme configuration and product paths from Xcode without overriding them."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def scheme_configuration(root, scheme, action='TestAction'):
    path = Path(root) / 'RideIntercom.xcodeproj/xcshareddata/xcschemes' / (scheme + '.xcscheme')
    try:
        node = ET.parse(path).getroot().find(action)
    except (OSError, ET.ParseError):
        raise ValueError('The shared Xcode scheme is missing or unreadable') from None
    if node is None or not node.get('buildConfiguration'):
        raise ValueError('The shared scheme must specify its action configuration')
    return node.get('buildConfiguration')


def scheme_primary_app(root, scheme):
    """Resolve the scheme's runnable App, rather than assuming a platform target."""
    path = Path(root) / 'RideIntercom.xcodeproj/xcshareddata/xcschemes' / (scheme + '.xcscheme')
    try:
        references = ET.parse(path).getroot().findall('LaunchAction/BuildableProductRunnable/BuildableReference')
        if len(references) != 1:
            raise ValueError('The shared scheme must identify one runnable App')
        reference = references[0]
        # Xcode drops BlueprintName from a runnable it rewrites; the product name still
        # identifies the App, so the target name is optional.
        target, product = reference.get('BlueprintName'), reference.get('BuildableName')
        if not product or Path(product).name != product or Path(product).suffix != '.app':
            raise ValueError('The shared scheme must identify an App product')
        return target, product
    except (OSError, ET.ParseError):
        raise ValueError('The shared Xcode scheme is missing or unreadable') from None


def xcode_build_settings(root, scheme, destination, configuration):
    app_target, app_product = scheme_primary_app(root, scheme)
    command = ['xcodebuild', '-project', 'RideIntercom.xcodeproj', '-scheme', scheme,
               '-destination', destination, '-configuration', configuration, '-showBuildSettings', '-json']
    # Build settings can contain development credentials. Never print or persist
    # the complete response, including Xcode's stderr on a failed query.
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError('Xcode could not resolve the scheme build settings')
    try:
        targets = [row['buildSettings'] for row in json.loads(result.stdout)
                   if (row.get('target') == app_target if app_target
                       else row.get('buildSettings', {}).get('FULL_PRODUCT_NAME') == app_product)]
        if len(targets) != 1:
            raise ValueError('Expected one App target')
        values = targets[0]
        settings = {key: values[key] for key in ('BUILD_DIR', 'TARGET_BUILD_DIR', 'FULL_PRODUCT_NAME',
                    'CONFIGURATION', 'PLATFORM_NAME', 'RIDEINTERCOM_STORAGE_NAMESPACE')}
        if settings['CONFIGURATION'] != configuration:
            raise ValueError('Unexpected configuration')
        destination_platform = dict(part.split('=', 1) for part in destination.split(',') if '=' in part).get('platform')
        platform = {'iOS Simulator': 'iphonesimulator', 'macOS': 'macosx',
                    'watchOS Simulator': 'watchsimulator'}.get(destination_platform)
        if settings['PLATFORM_NAME'] != platform:
            raise ValueError('Unexpected platform')
        for key in ('BUILD_DIR', 'TARGET_BUILD_DIR'):
            path = Path(settings[key])
            if not path.is_absolute():
                raise ValueError('Expected an absolute build path')
            settings[key] = str(path.resolve())
        if not Path(settings['TARGET_BUILD_DIR']).is_relative_to(Path(settings['BUILD_DIR'])):
            raise ValueError('App products must be inside the build products directory')
        if settings['FULL_PRODUCT_NAME'] != app_product:
            raise ValueError('Unexpected App product')
    except (ValueError, KeyError, TypeError, AttributeError):
        raise ValueError('Xcode returned incomplete or inconsistent App build settings') from None
    return settings


def scheme_test_plan(root, scheme):
    scheme_path = Path(root) / 'RideIntercom.xcodeproj/xcshareddata/xcschemes' / (scheme + '.xcscheme')
    action = ET.parse(scheme_path).getroot().find('TestAction')
    plans = action.findall('TestPlans/TestPlanReference') if action is not None else []
    selected_plan = next((plan for plan in plans if plan.get('default') == 'YES'), plans[0] if plans else None)
    return Path(selected_plan.get('reference', '')).stem if selected_plan is not None else None


def select_test_run(settings, scheme):
    plan_name = scheme_test_plan(Path(__file__).resolve().parents[1], scheme)
    products = Path(settings['BUILD_DIR'])
    expected_app = (Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']).resolve()
    candidates = sorted(products.glob(scheme + '_*.xctestrun'), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in candidates:
        try:
            data = plistlib.loads(path.read_bytes())
            if plan_name and data.get('TestPlan', {}).get('Name') != plan_name:
                continue
            targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
            hosts = [target.get('UITargetAppPath', target.get('TestHostPath', '')) for target in targets]
            if hosts and all(Path(host.replace('__TESTROOT__', str(products))).resolve() == expected_app
                             for host in hosts):
                return path
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scheme', default='RideIntercom')
    parser.add_argument('--destination', required=True)
    parser.add_argument('--action', default='LaunchAction')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        configuration = scheme_configuration(root, args.scheme, args.action)
        settings = xcode_build_settings(root, args.scheme, args.destination, configuration)
        app = Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']
        print(configuration + '\t' + str(app))
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError):
        print('Cannot resolve the Xcode scheme product path', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

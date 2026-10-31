#!/usr/bin/env python3
"""Check repository-owned OS and embedded-product settings; never contact Apple."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

APP_GROUP = 'group.com.yowamushi-inc.RideIntercom.CallWidgets'
APNS_SETTING = '$(RIDEINTERCOM_APNS_ENVIRONMENT)'


def load_project(root):
    return json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-',
        str(root / 'RideIntercom.xcodeproj/project.pbxproj')]))


def target_settings(project, name):
    objects = project['objects']
    target = next(obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == name)
    return [objects[key]['buildSettings'] for key in objects[target['buildConfigurationList']]['buildConfigurations']]


def check(root, project=None):
    project = project or load_project(root)
    errors = []
    def require(condition, message):
        if not condition: errors.append(message)
    def plist(path):
        try: return plistlib.loads((root / path).read_bytes())
        except (OSError, plistlib.InvalidFileException):
            errors.append(f'Missing or invalid platform plist: {path}'); return {}
    app_settings = target_settings(project, 'RideIntercom')
    for settings in app_settings:
        require(settings.get('RIDEINTERCOM_APNS_ENVIRONMENT') in ('development', 'production'), 'APNs environment must use development or production and feed both Info and entitlement.')
        require(settings.get('CODE_SIGN_ENTITLEMENTS[sdk=macosx*]') == 'RideIntercom/RideIntercom-macOS.entitlements', 'App needs its macOS entitlement file, separate from the iOS APNs key.')
        require(settings.get('ENABLE_APP_SANDBOX') == 'YES' and settings.get('ENABLE_INCOMING_NETWORK_CONNECTIONS') == 'YES' and settings.get('ENABLE_OUTGOING_NETWORK_CONNECTIONS') == 'YES', 'App sandbox network must allow both incoming and outgoing audio connections.')
        require(settings.get('TARGETED_DEVICE_FAMILY') == '1,2', 'App must include iPhone and iPad device families.')
        require(not any('remote-notification' in str(v) for k,v in settings.items() if k.startswith('INFOPLIST_KEY_UIBackgroundModes')), 'Alert/tap notifications must not request unused remote-notification background execution.')
    for path, required, forbidden in [
        ('RideIntercom/RideIntercom.entitlements', 'aps-environment', 'com.apple.developer.aps-environment'),
        ('RideIntercom/RideIntercom-macOS.entitlements', 'com.apple.developer.aps-environment', 'aps-environment')]:
        values = plist(path)
        require(values.get(required) == APNS_SETTING and forbidden not in values, f'{path}: APNs entitlement must match the platform and common build setting.')
        require(values.get('com.apple.developer.applesignin') == ['Default'], f'{path}: Sign in with Apple is required by all calls.')
        require(values.get('com.apple.security.application-groups') == [APP_GROUP], f'{path}: App Group must match the Widget.')
        require('com.apple.developer.networking.multicast' not in values, f'{path}: fixed Bonjour/unicast does not need a multicast entitlement.')
    require(plist('RideIntercom/RideIntercom-macOS.entitlements').get('com.apple.security.device.audio-input') is True, 'macOS microphone access must remain enabled.')
    widget = plist('RideIntercomWidgets/RideIntercomWidgets.entitlements')
    require(widget == {'com.apple.security.application-groups': [APP_GROUP]}, 'Widget needs only App Group access; call/audio/account/APNs stay in the App.')
    info = plist('RideIntercom/Info.plist')
    require(info.get('RideIntercomAPNsEnvironment') == APNS_SETTING, 'Info APNs environment must use the same build setting as signing.')
    require(set(info.get('NSBonjourServices', [])) == {'_ride-intercom._tcp', '_ride-audio._udp'}, 'Local discovery and datagram Bonjour service declarations must agree with RTC.')
    require(info.get('UIBackgroundModes') == ['audio'], 'Only continuing call audio needs background mode.')
    for locale in ('en', 'ja'):
        file = root / f'RideIntercom/{locale}.lproj/InfoPlist.strings'
        text = file.read_text() if file.is_file() else ''
        require(all('"'+key+'"' in text for key in ('NSMicrophoneUsageDescription', 'NSLocalNetworkUsageDescription')), f'{locale}: OS microphone/local-network explanations need localized InfoPlist.strings.')
    for settings in target_settings(project, 'RideIntercomWatch'):
        require(settings.get('ASSETCATALOG_COMPILER_APPICON_NAME') == 'AppIcon', 'Watch AppIcon must be configured in every build configuration.')
        require(settings.get('TARGETED_DEVICE_FAMILY') == '4', 'Watch must use watchOS device family.')
    icon_path = root / 'RideIntercomWatch/Assets.xcassets/AppIcon.appiconset/Contents.json'
    icon = json.loads(icon_path.read_text()) if icon_path.is_file() else {}
    require(any(i.get('platform') == 'watchos' and i.get('size') == '1024x1024' and (icon_path.parent / i.get('filename', '')).is_file() for i in icon.get('images', [])), 'Watch AppIcon needs a 1024-pixel watchOS source asset.')
    watch = plist('RideIntercomWatch/Info.plist')
    bundle = app_settings[0]['PRODUCT_BUNDLE_IDENTIFIER']
    require(watch.get('WKApplication') is True and watch.get('WKRunsIndependentlyOfCompanionApp') is False and watch.get('WKCompanionAppBundleIdentifier') == bundle, 'Watch app must remain dependent on the matching iPhone app.')
    objects = project['objects']
    embedded = {objects[objects[key]['fileRef']].get('path') for obj in objects.values() if obj.get('isa') == 'PBXCopyFilesBuildPhase' for key in obj.get('files', [])}
    require('RideIntercomWidgets.appex' in embedded, 'App must embed Widget extension.')
    require('RideIntercomWatch.app' in embedded, 'iOS App must embed Watch companion.')
    return errors


if __name__ == '__main__':
    try: errors = check(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error: errors = [str(error)]
    for error in errors: print(error, file=sys.stderr)
    if errors: sys.exit(1)
    print('OS permissions and embedded-product configuration: OK (external signing/distribution not verified)')

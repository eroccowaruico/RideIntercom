#!/usr/bin/env python3
"""Export the approved SVG into Icon Composer layers and flat app icons."""
import argparse
import copy
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'RideIntercom/Assets.xcassets/AppIcon.appiconset'
SOURCE = CATALOG / 'AppIcon-4,096.svg'
LAYERS = ROOT / 'RideIntercom/AppIcon.icon/Assets'
SVG = 'http://www.w3.org/2000/svg'


def export(check=False):
    renderer = shutil.which('rsvg-convert')
    if not renderer:
        raise SystemExit('rsvg-convert is required (brew install librsvg).')
    source = ET.parse(SOURCE).getroot()
    ET.register_namespace('', SVG)
    outputs = {}
    # Keep the original coordinates and paths. Each color is composited into a
    # single SVG layer, so overlapping construction pieces share one glass edge.
    for name, color in [('Road', '#abcee4'), ('Waveform', '#5bf3e2')]:
        layer = ET.Element(f'{{{SVG}}}svg', {
            'width': '1024', 'height': '1024', 'viewBox': source.attrib['viewBox']})
        for path in source.iter(f'{{{SVG}}}path'):
            if path.get('fill') == color:
                layer.append(copy.deepcopy(path))
        if not len(layer):
            raise SystemExit(f'No {name} paths with fill {color} in {SOURCE}.')
        ET.indent(layer, space='  ')
        outputs[LAYERS / f'{name}.svg'] = ET.tostring(
            layer, encoding='utf-8', xml_declaration=True) + b'\n'
    with tempfile.TemporaryDirectory(prefix='rideintercom-icons-') as temp:
        for size in (16, 32, 64, 128, 256, 512, 1024):
            png = Path(temp) / f'{size}.png'
            subprocess.run([renderer, '-w', str(size), '-h', str(size),
                            str(SOURCE), '-o', str(png)], check=True)
            outputs[CATALOG / f'AppIcon-{size}.png'] = png.read_bytes()
        outputs[ROOT / 'RideIntercomWatch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png'] = outputs[CATALOG / 'AppIcon-1024.png']
    changed = []
    for path, data in outputs.items():
        if not path.is_file() or path.read_bytes() != data:
            changed.append(str(path.relative_to(ROOT)))
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
    if check and changed:
        raise SystemExit('App icons need regeneration:\n' + '\n'.join(changed))
    print(f'Approved SVG: {len(outputs)} icon assets {"verified" if check else "exported"}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Reject stale generated assets without writing files.')
    export(parser.parse_args().check)

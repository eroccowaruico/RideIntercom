#!/usr/bin/env python3
"""Check that uncommitted String Catalog changes keep every existing translation.

Xcode syncs catalogs from extracted strings at build time: it adds, reorders,
marks entries stale and drops untranslated entries, but never deletes a
translation. A change that passes this check is a build output anyone may
commit; a lost translation needs its cause fixed instead.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def git(root, *args):
    return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True, check=True).stdout


def translations(data):
    source = data.get('sourceLanguage', 'en')
    return {(key, language)
            for key, entry in data.get('strings', {}).items()
            for language in entry.get('localizations', {})
            if language != source}


def check(root, base):
    changed = git(root, 'diff', '--name-only', base, '--', '*.xcstrings').split()
    errors = []
    for name in changed:
        path = root / name
        try:
            before = json.loads(git(root, 'show', f'{base}:{name}'))
        except subprocess.CalledProcessError:
            continue  # A new catalog cannot lose a committed translation.
        try:
            after = json.loads(path.read_text()) if path.is_file() else {}
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f'{name}: unreadable catalog ({error})')
            continue
        for key, language in sorted(translations(before) - translations(after)):
            errors.append(f'{name}: lost {language} translation for {key!r}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--base', default='HEAD')
    args = parser.parse_args()
    errors = check(args.root, args.base)
    for error in errors:
        print(error)
    if errors:
        return 1
    print('String Catalogs: no committed translation lost')
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Check local links, discoverability, and Settings UI coverage; no network calls."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'\[[^\]\n]*\]\((<[^>]+>|[^\n)]+)\)')
UI_ID = re.compile(r'accessibilityIdentifier\s*[:(]\s*"([^"\\]+)"')


def without_fences(text):
    visible, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif marker:
            fence = marker[1]
        else:
            visible.append(line)
    return ''.join(visible)


def check(root):
    root = root.resolve()
    documents = set((root / 'docs').rglob('*.md'))
    documents.add(root / 'README.md')
    for entry in ['AGENTS.md', 'CLAUDE.md', '.github/copilot-instructions.md']:
        if (root / entry).exists(): documents.add(root / entry)
    errors, edges = [], {}
    for directory in sorted((root / 'docs').rglob('*')):
        if directory.is_dir() and not any(directory.iterdir()):
            errors.append(f'{directory.relative_to(root)}: empty directory')
    for document in sorted(documents):
        text = without_fences(document.read_text())
        targets = set()
        for match in LINK.finditer(text):
            destination = match.group(1).strip('<>')
            if urlsplit(destination).scheme or destination.startswith(('#', '/')):
                continue
            path = unquote(destination.split('#')[0])
            target = (document.parent / path).resolve()
            if not target.exists():
                errors.append(f'{document.relative_to(root)}: missing link {destination}')
            elif target in documents:
                targets.add(target)
        edges[document] = targets
        # Inline root-relative documentation paths are also references, except the migration ledger.
        if document.name != '文書整理記録.md':
            for reference in re.findall(r'`(docs/[^`\n]+)`', text):
                if '*' in reference:
                    exists = any(root.glob(reference))
                else:
                    exists = (root / reference).exists()
                if not exists:
                    errors.append(f'{document.relative_to(root)}: stale document path {reference}')
    reached, pending = set(), [root / 'README.md']
    while pending:
        item = pending.pop()
        if item in reached: continue
        reached.add(item)
        pending.extend(edges.get(item, set()) - reached)
    for document in sorted(documents - reached):
        errors.append(f'{document.relative_to(root)}: not reachable from README')
    ui = root / 'RideIntercom/UI/Settings/SettingsView.swift'
    specification = root / 'docs/spec/App/UI/Settings.md'
    if ui.exists() and specification.exists():
        content = specification.read_text()
        for identifier in sorted(set(UI_ID.findall(ui.read_text()))):
            if f'`{identifier}`' not in content:
                errors.append(f'Settings.md: undocumented UI identifier {identifier}')
    return errors


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    errors = check(root)
    for error in errors: print(error, file=sys.stderr)
    if errors: sys.exit(1)
    print('Documentation links, navigation, empty directories, and Settings coverage: OK')

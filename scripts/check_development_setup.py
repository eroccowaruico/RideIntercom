#!/usr/bin/env python3
"""Read-only check of the shared Xcode / VS Code development contract."""
import json
from pathlib import Path
import subprocess
import sys


def load_project(root):
    return json.loads(subprocess.check_output([
        '/usr/bin/plutil', '-convert', 'json', '-o', '-',
        str(root / 'RideIntercom.xcodeproj/project.pbxproj'),
    ]))


def has_live_repository(project):
    objects = project['objects']
    main = objects[objects[project['rootObject']]['mainGroup']]
    candidates = {key for key in main['children']
                  if objects[key].get('isa') == 'PBXFileSystemSynchronizedRootGroup'
                  and objects[key].get('path') == '.'
                  and objects[key].get('sourceTree') == '<group>'
                  and not objects[key].get('exceptions')}
    build_groups = {key for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget'
                    for key in obj.get('fileSystemSynchronizedGroups', [])}
    build_files = {obj.get('fileRef') for obj in objects.values() if obj.get('isa') == 'PBXBuildFile'}
    return bool(candidates) and not candidates.intersection(build_groups | build_files)


def check(root):
    errors = []
    project = load_project(root)
    if not has_live_repository(project):
        errors.append('Xcode needs a live Repository folder (path = .), visible in mainGroup and absent from all build targets.')
    objects = project['objects']
    for obj in objects.values():
        if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup' and obj.get('path') == '.':
            if obj.get('explicitFileTypes', {}).get('RideIntercom.xcodeproj') != 'folder':
                errors.append('Repository must override RideIntercom.xcodeproj to folder to avoid self-project discovery.')
            if 'RideIntercom/packages' not in obj.get('explicitFolders', []):
                errors.append('Repository must treat RideIntercom/packages as a folder reference to avoid nested project discovery.')
    project_object = objects[project['rootObject']]
    for reference in project_object.get('projectReferences', []):
        obj = objects[reference['ProjectRef']]
        # Xcode retains folder-typed entries here when saving a synchronized root.
        # An explicit folder type overrides both extension and lastKnownFileType.
        if obj.get('explicitFileType') == 'folder':
            continue
        if obj.get('sourceTree') in ('<group>', 'SOURCE_ROOT', '<absolute>') and (root / obj.get('path', '')).resolve() == (root / 'RideIntercom.xcodeproj').resolve():
            errors.append('RideIntercom must not reference itself as a child project.')
    for folder in ['RideIntercom', 'RideIntercomTests', 'RideIntercomUITests']:
        if not any(obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup' and obj.get('path') == folder
                   for obj in objects.values()):
            errors.append(f'{folder} must remain a filesystem-synchronized folder.')
    app_id = next(key for key,obj in objects.items() if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
    exceptions = [obj for obj in objects.values() if obj.get('isa') == 'PBXFileSystemSynchronizedBuildFileExceptionSet'
                  and obj.get('target') == app_id]
    if not any('packages' in obj.get('membershipExceptions', []) for obj in exceptions):
        errors.append('App must exclude packages from automatic target membership (SwiftPM owns them).')
    main = objects[objects[project['rootObject']]['mainGroup']]
    visible_paths = {objects[key].get('path') for key in main['children']}
    for path in ['.vscode', '.codex', '.github', '.gitignore']:
        if path not in visible_paths:
            errors.append(f'Keep the explicit Xcode entry for hidden configuration: {path}')
    settings = json.loads((root / '.vscode/settings.json').read_text())
    if settings.get('explorer.excludeGitIgnore') is not False or settings.get('explorer.fileNesting.enabled') is not False:
        errors.append('VS Code must show ignored files and disable file nesting.')
    if any(value is not False for value in settings.get('files.exclude', {}).values()):
        errors.append('VS Code files.exclude must not hide repository contents.')
    workspace = json.loads((root / 'RideIntercom.code-workspace').read_text())
    if not any(folder['path'] == '.' for folder in workspace['folders']):
        errors.append('VS Code workspace must include the entire repository root.')
    if workspace.get('settings') != settings:
        errors.append('Workspace settings must match .vscode/settings.json, including package roots.')
    package_paths = {obj['relativePath'] for obj in objects.values()
                     if obj.get('isa') == 'XCLocalSwiftPackageReference'}
    if {folder['path'] for folder in workspace['folders']} != package_paths | {'.'}:
        errors.append('VS Code workspace must include the repository and every local Swift package.')
    tasks = json.loads((root / '.vscode/tasks.json').read_text())['tasks']
    for task in tasks:
        if task.get('type') != 'process' or task.get('options', {}).get('cwd') != '${workspaceFolder}':
            errors.append(f"Task {task['label']} must use a process in the repository root.")
        command = task['command']
        if command.startswith('${workspaceFolder}/') and not (root / command.removeprefix('${workspaceFolder}/')).is_file():
            errors.append(f'Missing task command: {command}')
    return errors


if __name__ == '__main__':
    try:
        errors = check(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        errors = [str(error)]
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        sys.exit(1)
    print('Xcode / VS Code development setup: OK')

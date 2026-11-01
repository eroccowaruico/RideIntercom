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


def check(root):
    errors = []
    project = load_project(root)
    objects = project['objects']
    package_paths = {obj['relativePath'] for obj in objects.values()
                     if obj.get('isa') == 'XCLocalSwiftPackageReference'}
    for obj in objects.values():
        if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup':
            directory = (root / obj.get('path', '')).resolve()
            if (root / 'RideIntercom.xcodeproj').resolve().is_relative_to(directory):
                errors.append('Do not synchronize a folder containing the project itself; add its editing subfolders separately.')
            for folder in obj.get('explicitFolders', []):
                forced = (root / obj.get('path', '') / folder).resolve()
                if any((root / path).resolve().is_relative_to(forced) for path in package_paths):
                    errors.append('Do not force a local Swift package or its parent to a folder; Xcode must resolve the package container.')
    project_object = objects[project['rootObject']]
    for reference in project_object.get('projectReferences', []):
        obj = objects[reference['ProjectRef']]
        if obj.get('sourceTree') in ('<group>', 'SOURCE_ROOT', '<absolute>') and (root / obj.get('path', '')).resolve() == (root / 'RideIntercom.xcodeproj').resolve():
            errors.append('RideIntercom must not reference itself as a child project.')
    main = objects[objects[project['rootObject']]['mainGroup']]
    visible = {objects[key].get('path'): key for key in main['children']}
    editing_folders = ['docs', 'scripts', 'server', 'Configuration', '.vscode', '.codex', '.github', '.claude']
    source_folders = ['RideIntercom', 'RideIntercomTests', 'RideIntercomUITests',
                      'RideIntercomAudioE2ETests', 'RideIntercomWidgets', 'RideIntercomWatch']
    for folder in source_folders + editing_folders:
        group = objects.get(visible.get(folder), {})
        if group.get('isa') != 'PBXFileSystemSynchronizedRootGroup':
            errors.append(f'{folder} must remain visible as a filesystem-synchronized folder.')
    build_groups = {key for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget'
                    for key in obj.get('fileSystemSynchronizedGroups', [])}
    build_files = {obj.get('fileRef') for obj in objects.values() if obj.get('isa') == 'PBXBuildFile'}
    for folder in editing_folders + ['.gitignore', 'README.md', 'RideIntercom.code-workspace', 'AGENTS.md', 'CLAUDE.md']:
        key = visible.get(folder)
        if key is None:
            errors.append(f'Keep the explicit Xcode editing entry for {folder}.')
        elif key in build_groups | build_files:
            errors.append(f'{folder} is editing-only and must not be a build input.')
    app_id = next(key for key,obj in objects.items() if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
    for group_id in objects[app_id].get('fileSystemSynchronizedGroups', []):
        group = objects[group_id]
        directory = (root / group.get('path', '')).resolve()
        exceptions = [objects[key] for key in group.get('exceptions', [])
                      if objects[key].get('target') == app_id]
        excluded = {path for obj in exceptions for path in obj.get('membershipExceptions', [])}
        for package in sorted(package_paths):
            package_directory = (root / package).resolve()
            if package_directory.is_relative_to(directory):
                relative = package_directory.relative_to(directory).as_posix()
                if relative not in excluded:
                    errors.append(f'App must exclude local Swift package root {relative} from synchronized target membership (SwiftPM owns it).')
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
    subprocess.run([sys.executable, str(Path(__file__).with_name('check_platform_configuration.py'))], check=True)
    print('Xcode / VS Code development setup: OK')

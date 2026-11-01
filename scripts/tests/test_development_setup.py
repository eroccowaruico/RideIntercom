"""Keep synchronized editing folders visible without recursive self-project discovery."""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('development_setup', ROOT / 'scripts/check_development_setup.py')


class DevelopmentSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.setup = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(cls.setup)
        cls.project = cls.setup.load_project(ROOT)

    def test_repository_and_editor_configuration(self):
        self.assertEqual(self.setup.check(ROOT), [])


    def test_package_folder_override_is_rejected(self):
        for scope, path in [('RideIntercom', 'packages')]:
            with self.subTest(scope=scope):
                project = copy.deepcopy(self.project)
                group = next(obj for obj in project['objects'].values()
                             if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup' and obj.get('path') == scope)
                group.setdefault('explicitFolders', []).append(path)
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any('force' in error and 'package' in error for error in self.setup.check(ROOT)))

    def test_self_project_reference_is_rejected(self):
        project = copy.deepcopy(self.project)
        project['objects']['SELF_PROJECT'] = {
            'isa': 'PBXFileReference', 'path': './RideIntercom.xcodeproj',
            'sourceTree': '<group>', 'lastKnownFileType': 'wrapper.pb-project',
        }
        project['objects'][project['rootObject']]['projectReferences'] = [
            {'ProjectRef': 'SELF_PROJECT'},
        ]
        with patch.object(self.setup, 'load_project', return_value=project):
            self.assertTrue(any('itself' in error for error in self.setup.check(ROOT)))


    def test_package_roots_are_valid_without_parent_exception(self):
        project = copy.deepcopy(self.project)
        app_id = next(key for key, obj in project['objects'].items()
                      if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        exception = next(obj for obj in project['objects'].values()
                         if obj.get('isa') == 'PBXFileSystemSynchronizedBuildFileExceptionSet' and obj.get('target') == app_id)
        exception['membershipExceptions'] = [path for path in exception['membershipExceptions'] if path != 'packages']
        with patch.object(self.setup, 'load_project', return_value=project):
            self.assertEqual(self.setup.check(ROOT), [])

    def test_parent_exception_does_not_hide_missing_package_roots(self):
        roots = [obj['relativePath'].removeprefix('RideIntercom/') for obj in self.project['objects'].values()
                 if obj.get('isa') == 'XCLocalSwiftPackageReference']
        for root in roots:
            with self.subTest(root=root):
                project = copy.deepcopy(self.project)
                app_id = next(key for key, obj in project['objects'].items()
                              if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
                exception = next(obj for obj in project['objects'].values()
                                 if obj.get('isa') == 'PBXFileSystemSynchronizedBuildFileExceptionSet' and obj.get('target') == app_id)
                exception['membershipExceptions'].remove(root)
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any(root in error for error in self.setup.check(ROOT)))

    def test_only_attached_app_exceptions_exclude_package_roots(self):
        for failure in ('detached', 'other-target'):
            with self.subTest(failure=failure):
                project = copy.deepcopy(self.project)
                app = next(obj for obj in project['objects'].values()
                           if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
                group = project['objects'][app['fileSystemSynchronizedGroups'][0]]
                if failure == 'detached':
                    group['exceptions'] = []
                else:
                    project['objects'][group['exceptions'][0]]['target'] = 'another-target'
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any('local Swift package root' in error for error in self.setup.check(ROOT)))

    def test_synchronized_ancestor_is_rejected_even_with_folder_type_override(self):
        for path in ['.', '..', str(ROOT.resolve())]:
            with self.subTest(path=path):
                project = copy.deepcopy(self.project)
                project['objects']['RECURSIVE_ROOT'] = {
                    'isa': 'PBXFileSystemSynchronizedRootGroup', 'path': path,
                    'sourceTree': '<group>', 'explicitFileTypes': {'RideIntercom.xcodeproj': 'folder'},
                }
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any('containing the project' in error for error in self.setup.check(ROOT)))

    def test_editing_folder_must_stay_visible_and_synchronized(self):
        for failure in ['detached', 'static-group']:
            with self.subTest(failure=failure):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                group_id = next(k for k,v in objects.items() if v.get('path') == 'docs')
                if failure == 'detached':
                    main = objects[objects[project['rootObject']]['mainGroup']]
                    main['children'].remove(group_id)
                else:
                    objects[group_id]['isa'] = 'PBXGroup'
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any('docs must remain visible' in error for error in self.setup.check(ROOT)))

    def test_editing_only_folder_must_not_become_a_build_input(self):
        for failure in ['target-group', 'build-file']:
            with self.subTest(failure=failure):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                group_id = next(k for k,v in objects.items() if v.get('path') == 'docs')
                if failure == 'target-group':
                    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget')
                    target.setdefault('fileSystemSynchronizedGroups', []).append(group_id)
                else:
                    objects['DOCS_BUILD_FILE'] = {'isa': 'PBXBuildFile', 'fileRef': group_id}
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any('docs is editing-only' in error for error in self.setup.check(ROOT)))

    def test_self_project_folder_reference_is_also_rejected(self):
        project = copy.deepcopy(self.project)
        project['objects']['SELF_FOLDER'] = {
            'isa': 'PBXFileReference', 'path': 'RideIntercom.xcodeproj',
            'sourceTree': '<group>', 'explicitFileType': 'folder',
        }
        project['objects'][project['rootObject']]['projectReferences'] = [{'ProjectRef': 'SELF_FOLDER'}]
        with patch.object(self.setup, 'load_project', return_value=project):
            self.assertTrue(any('itself' in error for error in self.setup.check(ROOT)))


if __name__ == '__main__':
    unittest.main()

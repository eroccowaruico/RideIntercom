"""Guard against turning the live repository navigator into a stale file list."""
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

    def test_static_file_group_is_rejected(self):
        project = copy.deepcopy(self.project)
        for obj in project['objects'].values():
            if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup' and obj.get('path') == '.':
                obj['isa'] = 'PBXGroup'
        self.assertFalse(self.setup.has_live_repository(project))

    def test_repository_must_not_be_a_build_input(self):
        project = copy.deepcopy(self.project)
        repo_id = next(k for k,v in project['objects'].items() if v.get('isa') == 'PBXFileSystemSynchronizedRootGroup' and v.get('path') == '.')
        target = next(v for v in project['objects'].values() if v.get('isa') == 'PBXNativeTarget')
        target.setdefault('fileSystemSynchronizedGroups', []).append(repo_id)
        self.assertFalse(self.setup.has_live_repository(project))

    def test_detached_repository_group_is_rejected(self):
        project = copy.deepcopy(self.project)
        main = project['objects'][project['objects'][project['rootObject']]['mainGroup']]
        main['children'] = [k for k in main['children'] if project['objects'][k].get('path') != '.']
        self.assertFalse(self.setup.has_live_repository(project))

    def test_repository_container_discovery_is_rejected(self):
        for path in ['RideIntercom.xcodeproj', 'RideIntercom/packages']:
            with self.subTest(path=path):
                project = copy.deepcopy(self.project)
                repository = next(obj for obj in project['objects'].values()
                                  if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup'
                                  and obj.get('path') == '.')
                repository['explicitFolders'] = [p for p in repository.get('explicitFolders', [])
                                                 if p != path]
                repository.get('explicitFileTypes', {}).pop(path, None)
                with patch.object(self.setup, 'load_project', return_value=project):
                    self.assertTrue(any(path in error for error in self.setup.check(ROOT)))

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

    def test_xcode_folder_reference_is_allowed(self):
        project = copy.deepcopy(self.project)
        project['objects']['SELF_FOLDER'] = {
            'isa': 'PBXFileReference', 'path': 'RideIntercom.xcodeproj',
            'sourceTree': '<group>', 'explicitFileType': 'folder',
            'lastKnownFileType': 'wrapper.pb-project',
        }
        project['objects'][project['rootObject']]['projectReferences'] = [
            {'ProjectRef': 'SELF_FOLDER'},
        ]
        with patch.object(self.setup, 'load_project', return_value=project):
            self.assertEqual(self.setup.check(ROOT), [])


if __name__ == '__main__':
    unittest.main()

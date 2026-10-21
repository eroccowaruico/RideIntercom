"""Guard against turning the live repository navigator into a stale file list."""
import copy
import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()

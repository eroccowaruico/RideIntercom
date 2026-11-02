import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_string_catalogs.py'


def catalog(strings):
    return json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'})


def translated(value):
    return {'localizations': {'ja': {'stringUnit': {'state': 'translated', 'value': value}}}}


class StringCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.com')
        self.git('config', 'user.name', 'Test')
        self.path = self.root / 'App/Localizable.xcstrings'
        self.path.parent.mkdir()
        self.path.write_text(catalog({'Kept': translated('保持'), 'Unused': {}}))
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'base')

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.root, check=True)

    def check(self):
        return subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                              capture_output=True, text=True)

    def test_build_sync_that_adds_reorders_marks_stale_and_drops_untranslated_strings_passes(self):
        stale = translated('保持')
        stale['extractionState'] = 'stale'
        self.path.write_text(catalog({'New %lld': {}, 'Kept': stale}))
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_removed_translation_fails_and_names_the_string(self):
        self.path.write_text(catalog({'Unused': {}}))
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Kept', result.stdout)
        self.assertIn('ja', result.stdout)

    def test_removed_language_of_kept_string_fails(self):
        self.path.write_text(catalog({'Kept': {}, 'Unused': {}}))
        self.assertEqual(self.check().returncode, 1)

    def test_unreadable_catalog_fails(self):
        self.path.write_text('{')
        self.assertEqual(self.check().returncode, 1)


if __name__ == '__main__':
    unittest.main()

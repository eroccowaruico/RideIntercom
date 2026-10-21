import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('documentation', ROOT / 'scripts/check_documentation.py')
DOCS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS)


class DocumentationTests(unittest.TestCase):
    def fixture(self, root):
        (root / 'docs').mkdir()
        (root / 'README.md').write_text('[guide](docs/guide.md)\n')
        (root / 'docs/guide.md').write_text('# Guide\n')

    def test_broken_relative_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'docs/guide.md').write_text('[lost](lost.md)')
            self.assertTrue(any('missing link' in error for error in DOCS.check(root)))

    def test_unindexed_document_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'docs/orphan.md').write_text('Still useful information')
            self.assertTrue(any('not reachable' in error for error in DOCS.check(root)))

    def test_new_settings_control_requires_specification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            source = root / 'RideIntercom/UI/Settings/SettingsView.swift'
            source.parent.mkdir(parents=True)
            source.write_text('.accessibilityIdentifier("newSetting")')
            spec = root / 'docs/spec/App/UI/Settings.md'
            spec.parent.mkdir(parents=True)
            spec.write_text('# Settings')
            (root / 'docs/guide.md').write_text('[settings](spec/App/UI/Settings.md)')
            self.assertTrue(any('newSetting' in error for error in DOCS.check(root)))
            spec.write_text('# Settings\n`newSetting`')
            self.assertEqual(DOCS.check(root), [])

    def test_empty_document_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'docs/obsolete/nested').mkdir(parents=True)
            self.assertTrue(any('empty directory' in error for error in DOCS.check(root)))

    def test_agent_entrypoint_links_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'AGENTS.md').write_text('[rules](docs/missing-rules.md)')
            with (root / 'README.md').open('a') as entry:
                entry.write('[agents](AGENTS.md)')
            self.assertTrue(any('missing link' in error for error in DOCS.check(root)))

    def test_archived_source_fence_preserves_obsolete_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'docs/guide.md').write_text(
                '# Historical plan\n~~~~markdown\n[old](deleted.md)\n'
                '```swift\nlet example = 1\n```\n`docs/deleted.md`\n~~~~\n')
            self.assertEqual(DOCS.check(root), [])

    def test_space_paths_and_examples_are_supported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'docs/two words.md').write_text('details')
            (root / 'docs/guide.md').write_text('[details](<two words.md>)\n```markdown\n[example](does-not-exist.md)\n```\n')
            self.assertEqual(DOCS.check(root), [])


if __name__ == '__main__': unittest.main()

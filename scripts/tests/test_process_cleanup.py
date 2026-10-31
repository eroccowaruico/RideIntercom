"""No device access: process ownership and PID-reuse boundaries."""
import signal
import unittest
from unittest.mock import patch

from scripts import test_lifecycle as lifecycle


class ProcessCleanupTests(unittest.TestCase):
    def info(self, pid, ppid=1, uid=501, started=100, command='test command', state='S'):
        return lifecycle.ProcessIdentity(pid, ppid, uid, started, command, state)

    def test_snapshot_parses_command_with_spaces_without_logging_it(self):
        row = ' 42 9 501 S Sat Oct 31 12:34:56 2026 /path with spaces/runner --flag\n'
        with patch.object(lifecycle.subprocess, 'check_output', return_value=row):
            result = lifecycle.process_snapshot()[42]
        self.assertEqual((result.pid, result.ppid, result.uid, result.command),
                         (42, 9, 501, '/path with spaces/runner --flag'))
        self.assertGreater(result.started, 0)

    def test_tree_requires_current_parent_generation_and_uid(self):
        root = self.info(10)
        child = self.info(11, ppid=10, started=101)
        grandchild = self.info(12, ppid=11, started=102)
        unrelated = self.info(13, ppid=1, started=102)
        other_uid = self.info(14, ppid=10, uid=502, started=102)
        older = self.info(15, ppid=10, started=99)
        rows = {item.pid: item for item in [root, child, grandchild, unrelated, other_uid, older]}
        with patch.object(lifecycle, 'process_snapshot', return_value=rows):
            self.assertEqual(lifecycle.owned_process_tree(root), [root, child, grandchild])
        rows[10] = self.info(10, started=200)
        with patch.object(lifecycle, 'process_snapshot', return_value=rows):
            self.assertEqual(lifecycle.owned_process_tree(root), [])

    def test_signal_rechecks_generation_uid_and_command_but_allows_reparenting(self):
        child = self.info(11, ppid=10)
        for replacement in [self.info(11, started=200), self.info(11, uid=502),
                            self.info(11, command='unrelated'), self.info(11, state='Z'), None]:
            with self.subTest(replacement=replacement):
                rows = {11: replacement} if replacement else {}
                with patch.object(lifecycle, 'process_snapshot', return_value=rows), \
                     patch.object(lifecycle.os, 'kill') as kill:
                    lifecycle.signal_owned_process(child, signal.SIGKILL)
                    kill.assert_not_called()
        with patch.object(lifecycle, 'process_snapshot', return_value={11: self.info(11, ppid=1)}), \
             patch.object(lifecycle.os, 'kill') as kill:
            lifecycle.signal_owned_process(child, signal.SIGTERM)
            kill.assert_called_once_with(11, signal.SIGTERM)

    def test_process_disappearing_between_check_and_signal_is_safe(self):
        child = self.info(11)
        with patch.object(lifecycle, 'process_snapshot', return_value={11: child}), \
             patch.object(lifecycle.os, 'kill', side_effect=ProcessLookupError):
            lifecycle.signal_owned_process(child, signal.SIGTERM)


if __name__ == '__main__':
    unittest.main()

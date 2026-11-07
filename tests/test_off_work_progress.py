# SPDX-License-Identifier: AGPL-3.0-only
"""Run down-work history progress UI regressions through the shared test runner."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OffWorkProgressUi(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), '网页行为测试需要 Node.js')
    def test_history_progress_and_poll(self):
        result = subprocess.run([shutil.which('node'), '--test', str(ROOT / 'tests/test_off_work_progress.cjs')],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

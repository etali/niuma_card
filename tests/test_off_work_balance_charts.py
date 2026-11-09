# SPDX-License-Identifier: AGPL-3.0-only
"""下班平衡对比图的数值、缺失值和版本兼容行为回归。"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which(os.environ.get('NODE', 'node')) or '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node'


class OffWorkBalanceCharts(unittest.TestCase):
    @unittest.skipUnless(Path(NODE).is_file(), '网页行为测试需要 Node.js')
    def test_charts_and_comparison(self):
        result = subprocess.run([NODE, '--test', str(ROOT / 'tests/test_off_work_balance_charts.cjs')],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""执行正式桥接代码，验证浏览器选择、取消、离开场景与读取错误的生命周期。"""
from pathlib import Path
import shutil
import subprocess
import unittest


class WebFileBridgeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node"), "需要 Node 执行浏览器桥接逻辑")
    def test_browser_file_lifecycle(self):
        source = (Path(__file__).resolve().parents[1] / "scenes/web_files.gd").read_text()
        bridge = source.split('const BRIDGE_SOURCE := """', 1)[1].split('"""', 1)[0]
        test = r"""
const assert = require('node:assert/strict');
global.window = {};
const inputs = [];
const readers = [];
global.document = {
  body: { appendChild(input) { inputs.push(input); } },
  createElement(tag) {
    assert.equal(tag, 'input');
    return { style: {}, events: {}, files: [],
      addEventListener(name, handler) { this.events[name] = handler; },
      remove() { this.removed = true; }, click() { this.clicked = true; } };
  }
};
global.FileReader = class {
  constructor() { this.readyState = 0; readers.push(this); }
  readAsText(file) { this.file = file; this.readyState = 1; }
  abort() { this.readyState = 2; this.aborted = true; }
};
""" + bridge + r"""
const values = [];
const receive = (...args) => values.push(args);
window.niumaFiles.pick(receive, 100);
let input = inputs.at(-1);
assert.equal(input.accept, '.json,application/json');
assert.equal(input.clicked, true);
input.files = [{name: 'cards.json', size: 10}];
input.events.change();
let reader = readers.at(-1);
reader.result = '{"price":7}'; reader.readyState = 2; reader.onload();
assert.deepEqual(values.pop(), ['cards.json', '{"price":7}', '']);
assert.equal(input.removed, true);

window.niumaFiles.pick(receive, 100);
input = inputs.at(-1); input.events.cancel();
assert.deepEqual(values.pop(), ['', '', 'cancelled']);

window.niumaFiles.pick(receive, 100);
input = inputs.at(-1);
input.files = [{name: 'big.json', size: 101}]; input.events.change();
assert.ok(values.pop()[2].includes('64 MB'));

window.niumaFiles.pick(receive, 100);
input = inputs.at(-1);
input.files = [{name: 'broken.json', size: 10}]; input.events.change();
readers.at(-1).onerror();
assert.ok(values.pop()[2].includes('无法读取'));

window.niumaFiles.pick(receive, 100);
input = inputs.at(-1);
input.files = [{name: 'late.json', size: 10}]; input.events.change();
reader = readers.at(-1);
window.niumaFiles.cancel();
assert.equal(reader.aborted, true);
assert.equal(reader.onload, null);
input.events.cancel(); input.events.change();
assert.equal(values.length, 0, '离开场景后不再回调已释放的Godot节点');
console.log('browser file lifecycle passed');
"""
        result = subprocess.run([shutil.which("node"), "-e", test], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("browser file lifecycle passed", result.stdout)


if __name__ == "__main__":
    unittest.main()

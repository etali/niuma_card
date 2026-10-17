#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""旧入口兼容：imagegen 原稿的局部原像素动画，不再用几何图覆盖插画。

NODE 指定 Node.js，NODE_PATH 指向装有 pngjs、@napi-rs/canvas 的模块目录。
用法：python3 tools/gen_role_icons.py [--source-dir 高清原稿目录] [--install]
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

if __name__ == '__main__':
    node = os.environ.get('NODE') or shutil.which('node')
    if not node:
        sys.exit('需要 Node.js；请安装或通过 NODE 指定，再运行 tools/render_role_hover.cjs。')
    sys.exit(subprocess.call([node, str(Path(__file__).with_name('render_role_hover.cjs')), *sys.argv[1:]]))

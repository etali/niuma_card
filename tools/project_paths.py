#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""项目相对路径与日志中的本机路径脱敏；不改变文件访问所用的真实路径。"""
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def relative_path(path, root=ROOT):
    """返回以项目根为基准、可在 cwd=root 的子进程中使用的路径。"""
    return os.path.relpath(Path(path).expanduser(), root)


def display_path(path, root=ROOT):
    """项目内显示相对路径，家目录内的其他位置显示为 ~/… 。"""
    absolute = Path(os.path.abspath(Path(path).expanduser()))
    for base, prefix in ((Path(root).absolute(), ""), (Path.home(), "~")):
        try:
            suffix = absolute.relative_to(base).as_posix()
        except ValueError:
            continue
        if suffix == ".":
            return prefix or "."
        return (prefix + "/" if prefix else "") + suffix
    return relative_path(absolute, root)


def redact_paths(text, root=ROOT):
    """只处理输出文本；目录边界匹配避免误改名称相似的文件或目录。"""
    replacements = {}
    for path, replacement in ((Path.home(), "~"), (Path(root).absolute(), ".")):
        for variant in (path, path.resolve()):
            if variant != Path(variant.anchor):
                replacements[str(variant)] = replacement
    for prefix in sorted(replacements, key=len, reverse=True):
        text = re.sub(re.escape(prefix) + r"(?=$|[/\\\s\"'<>:;,()\[\]{}，。；：（）【】])",
                      lambda _: replacements[prefix], text)
    return text


def sanitize_file(path, root=ROOT):
    """在日志不再供内部清理或协议解析使用后，移除本机目录前缀。"""
    path = Path(path)
    if path.is_file():
        original = path.read_text(encoding="utf-8", errors="replace")
        clean = redact_paths(original, root)
        if clean != original:
            path.write_text(clean, encoding="utf-8")


if __name__ == "__main__":
    for line in sys.stdin:
        sys.stdout.write(redact_paths(line))

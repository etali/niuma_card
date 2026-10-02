#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""验证并安装 Web 导出模板；完整下载、解压成功后才替换现有模板。"""
import argparse
import fcntl
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile

from release_bundle import publication_signals, publish

NAMES = ("web_release.zip", "web_debug.zip", "web_nothreads_release.zip", "web_nothreads_debug.zip")
REQUIRED = ("godot.html", "godot.js", "godot.wasm")


def valid_template(path):
    try:
        with zipfile.ZipFile(path) as archive:
            return all(archive.getinfo(name).file_size > 0 for name in REQUIRED) and archive.testzip() is None
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, RuntimeError, EOFError):
        return False


def ensure_templates(destination, url):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    # 模板目录属于所有项目；不同项目同时首次构建也只能有一个安装者。
    with publication_signals(), (destination / ".web-templates.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if all(valid_template(destination / name) for name in NAMES):
            print("==> Web 导出模板已就位（完整性验证通过）", flush=True)
            return
        print("==> 下载并校验 Web 导出模板（约 1GB，失败后可重试）", flush=True)
        with tempfile.TemporaryDirectory(prefix=".web-templates-", dir=destination) as temporary:
            stage = Path(temporary)
            download = stage / "templates.tpz"
            with urllib.request.urlopen(url, timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
            with zipfile.ZipFile(download) as archive:
                for name in NAMES:
                    # 只解出约定文件；读完整条目会同时校验外层 ZIP 的 CRC。
                    with archive.open("templates/" + name) as source, (stage / name).open("wb") as target:
                        shutil.copyfileobj(source, target)
                    if not valid_template(stage / name):
                        raise ValueError("Web 模板损坏或缺少运行文件：" + name)
            publish(stage, destination, NAMES)
        print("==> Web 模板安装完成", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("url")
    args = parser.parse_args()
    try:
        ensure_templates(args.directory, args.url)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, RuntimeError, EOFError) as error:
        parser.exit(1, f"Web 模板安装失败：{error}\n")


if __name__ == "__main__":
    main()

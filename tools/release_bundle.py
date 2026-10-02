#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""验证新导出目录，生成独立发布包；验证完成后替换，失败回滚旧产物。"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import shutil
import signal
import tempfile
import zipfile


def nonempty(path):
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f"缺少有效发布文件：{path}")


def validate_app(app):
    metadata = app / "Contents/Info.plist"
    nonempty(metadata)
    info = plistlib.loads(metadata.read_bytes())
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        raise ValueError("App 未声明有效的 CFBundleExecutable")
    binary = app / "Contents/MacOS" / executable
    nonempty(binary)
    if not os.access(binary, os.X_OK):
        raise ValueError(f"App 二进制没有执行权限：{binary}")
    packs = list((app / "Contents/Resources").glob("*.pck"))
    if len(packs) != 1:
        raise ValueError("App 必须有且只有一份游戏 PCK")
    nonempty(packs[0])


def archive_tree(archive, directory, prefix="", exclude_br=False):
    for path in sorted(directory.rglob("*")):
        if path.is_file() and not (exclude_br and path.suffix == ".br"):
            archive.write(path, (Path(prefix) / path.relative_to(directory)).as_posix())


def package(stage):
    validate_app(stage / "牛马牌.app")
    for name in ("index.html", "index.js", "index.wasm", "index.pck"):
        nonempty(stage / "web" / name)
    nonempty(stage / "cards.json")
    names = ["web", "牛马牌.app", "cards.json", "牛马牌_web.zip", "牛马牌_mac.zip"]
    with zipfile.ZipFile(stage / names[3], "w", zipfile.ZIP_DEFLATED) as archive:
        archive_tree(archive, stage / "web", exclude_br=True)
    with zipfile.ZipFile(stage / names[4], "w", zipfile.ZIP_DEFLATED) as archive:
        archive_tree(archive, stage / "牛马牌.app", "牛马牌.app")
        archive.write(stage / "cards.json", "cards.json")
    for name in names[3:]:
        with zipfile.ZipFile(stage / name) as archive:
            if archive.testzip() is not None:
                raise ValueError(f"压缩包校验失败：{name}")
    return names


@contextmanager
def publication_signals():
    # 普通错误和用户中断都走同一回滚；不可恢复的 SIGKILL 留下的备份不主动删除。
    def interrupted(number, _frame):
        raise InterruptedError(f"发布被信号 {number} 中断")
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    old = {sig: signal.signal(sig, interrupted) for sig in signals}
    try:
        yield
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


def publish(stage, destination, names):
    destination.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=".release-previous-", dir=destination))
    replaced, saved = [], []
    try:
        with publication_signals():
            try:
                for name in names:
                    target = destination / name
                    if target.exists() or target.is_symlink():
                        os.replace(target, backup / name)
                        saved.append(name)
                    os.replace(stage / name, target)
                    replaced.append(name)
            except BaseException:
                for name in reversed(replaced):
                    os.replace(destination / name, stage / name)
                for name in reversed(saved):
                    os.replace(backup / name, destination / name)
                raise
    except BaseException:
        if not any(backup.iterdir()):
            backup.rmdir()
        else:
            print(f"发布备份保留在：{backup}")
        raise
    else:
        shutil.rmtree(backup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--app-only", action="store_true")
    args = parser.parse_args()
    if args.app_only:
        validate_app(args.stage / "牛马牌.app")
        names = ["牛马牌.app"]
    else:
        names = package(args.stage)
    publish(args.stage, args.destination, names)


if __name__ == "__main__":
    main()

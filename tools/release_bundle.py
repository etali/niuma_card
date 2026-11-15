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
import struct
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


def archive_tree(archive, directory, prefix=""):
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            archive.write(path, (Path(prefix) / path.relative_to(directory)).as_posix())


def package(stage):
    validate_app(stage / "牛马牌.app")
    card_tables = ("on_work_cards.json", "off_work_cards.json")
    for filename in card_tables:
        nonempty(stage / filename)
    name = "牛马牌_mac.zip"
    with zipfile.ZipFile(stage / name, "w", zipfile.ZIP_DEFLATED) as archive:
        archive_tree(archive, stage / "牛马牌.app", "牛马牌.app")
        for filename in card_tables:
            archive.write(stage / filename, filename)
    with zipfile.ZipFile(stage / name) as archive:
        if archive.testzip() is not None:
            raise ValueError(f"压缩包校验失败：{name}")
    return ["牛马牌.app", *card_tables, name]


def validate_windows(directory):
    binary = directory / "牛马牌.exe"
    nonempty(binary)
    with binary.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise ValueError("Windows 可执行文件缺少 MZ 头")
        stream.seek(0x3C)
        offset = int.from_bytes(stream.read(4), "little")
        if offset < 64 or offset + 26 > binary.stat().st_size:
            raise ValueError("Windows 可执行文件 PE 头无效")
        stream.seek(offset)
        header = stream.read(26)
        if header[:4] != b"PE\0\0" or header[4:6] != b"\x64\x86" or header[24:26] != b"\x0b\x02":
            raise ValueError("Windows 可执行文件必须是 x86_64 PE32+")
    pack = binary.with_suffix(".pck")
    nonempty(pack)
    with pack.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24:
        raise ValueError("Windows 游戏 PCK 头不完整")
    magic, version, _, _, _, flags = struct.unpack("<6I", header)
    if magic != 0x43504447 or version not in (2, 3, 4) or flags & 1:
        raise ValueError("Windows 游戏 PCK 头无效或已加密")
    if {p.name for p in directory.glob("*.pck")} != {pack.name}:
        raise ValueError("Windows 包必须有且只有一份同名游戏 PCK")


def package_windows(stage):
    directory = stage / "windows"
    validate_windows(directory)
    for filename in ("on_work_cards.json", "off_work_cards.json", "LICENSE", "NOTICE"):
        nonempty(directory / filename)
    name = "牛马牌_windows.zip"
    with zipfile.ZipFile(stage / name, "w", zipfile.ZIP_DEFLATED) as archive:
        # 包含 Godot 生成的附属 DLL；EXE/PCK 和卡表保持同目录。
        archive_tree(archive, directory, "牛马牌")
    with zipfile.ZipFile(stage / name) as archive:
        if archive.testzip() is not None:
            raise ValueError(f"压缩包校验失败：{name}")
    return ["windows", name]


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
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--app-only", action="store_true")
    modes.add_argument("--windows", action="store_true", help="验证并发布 Windows x86_64 EXE/PCK 和 ZIP")
    args = parser.parse_args()
    if args.windows:
        names = package_windows(args.stage)
    elif args.app_only:
        validate_app(args.stage / "牛马牌.app")
        names = ["牛马牌.app"]
    else:
        names = package(args.stage)
    publish(args.stage, args.destination, names)


if __name__ == "__main__":
    main()

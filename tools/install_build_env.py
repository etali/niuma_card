#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""在 macOS 上安装 构建游戏.command / 打包发布.command 所需的构建环境。

检查与安装范围：
- Godot 编辑器（只检查，不自动安装；可用 --godot 或 GODOT 指定路径）
- 与当前 Godot 版本匹配的全套导出模板（macOS / Web / Android 共用一次下载）
- Python 依赖：Pillow（应用图标与素材检查）、fonttools（字体子集化）

已就位的项目直接复用；--dry-run 只显示计划，不下载、不修改文件。
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile

import install_android_dependencies as common
from install_android_dependencies import InstallError, download, godot_version, run
from project_paths import redact_paths

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES_ROOT = Path.home() / "Library/Application Support/Godot/export_templates"
# 标准 macOS 构建必须有 macos.zip；其余模板供 打包发布 / 安卓构建使用。
REQUIRED_TEMPLATES = ("macos.zip", "web_release.zip", "web_debug.zip",
                      "web_nothreads_release.zip", "web_nothreads_debug.zip",
                      "android_debug.apk", "android_release.apk", "android_source.zip")
PYTHON_PACKAGES = (("PIL", "Pillow"), ("fontTools", "fonttools"))
MIRRORS = ("https://godot-releases.nbg1.your-objectstorage.com/{version}-stable/{name}",
           "https://github.com/godotengine/godot/releases/download/{version}-stable/{name}")


def log(message: str) -> None:
    print(redact_paths(f"[构建环境] {message}", ROOT), flush=True)


def check_godot(godot: Path) -> tuple[str, str]:
    if not godot.is_file():
        raise InstallError(f"找不到 Godot：{godot}。请从 https://godotengine.org/download/macos/ "
                           "下载并放到 /Applications，或用 GODOT=/path/to/Godot 指定")
    version, folder = godot_version(godot)
    log(f"Godot {version}（模板目录 {folder}）")
    return version, folder


def missing_templates(folder: str) -> list[str]:
    directory = TEMPLATES_ROOT / folder
    return [name for name in REQUIRED_TEMPLATES if not zipfile.is_zipfile(directory / name)]


def install_templates(version: str, folder: str, dry_run: bool) -> None:
    missing = missing_templates(folder)
    if not missing:
        log(f"导出模板已就位：{TEMPLATES_ROOT / folder}")
        return
    log("缺少导出模板：" + "、".join(missing))
    if dry_run:
        log(f"将下载 Godot {version} 全套导出模板（约 1GB）并安装缺少的文件")
        return
    # 与 安装安卓构建环境 共用下载缓存，任一入口下载过都不会重复下载。
    archive = ROOT / "build/android-downloads" / f"Godot_v{version}-stable_export_templates.tpz"
    if not zipfile.is_zipfile(archive):
        errors = []
        for mirror in MIRRORS:
            try:
                download(mirror.format(version=version, name=archive.name), archive)
                break
            except InstallError as error:
                errors.append(str(error))
        else:
            raise InstallError("导出模板下载失败：" + "；".join(errors))
    destination = TEMPLATES_ROOT / folder
    with zipfile.ZipFile(archive) as zipped, tempfile.TemporaryDirectory(prefix="build-templates-") as temp:
        names = {name.rsplit("/", 1)[-1]: name for name in zipped.namelist() if not name.endswith("/")}
        if "version.txt" not in names:
            raise InstallError(f"导出模板包缺少 version.txt：{archive}")
        actual = zipped.read(names["version.txt"]).decode().strip()
        if actual != folder:
            raise InstallError(f"模板版本 {actual} 与编辑器 {folder} 不一致")
        absent = [name for name in missing if name not in names]
        if absent:
            raise InstallError("导出模板包缺少：" + "、".join(absent))
        destination.mkdir(parents=True, exist_ok=True)
        # 先完整解出并校验，再逐个原子替换，中断不会留下半个模板。
        for name in [*missing, "version.txt"]:
            staged = Path(temp) / name
            with zipped.open(names[name]) as source, staged.open("wb") as output:
                shutil.copyfileobj(source, output)
            if name != "version.txt" and not zipfile.is_zipfile(staged):
                raise InstallError(f"无效 Godot 导出模板：{name}")
            temporary = destination / (name + ".partial")
            shutil.copyfile(staged, temporary)
            temporary.replace(destination / name)
    log(f"导出模板安装完成：{destination}")


def module_available(module: str) -> bool:
    return subprocess.run([sys.executable, "-c", f"import {module}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def install_python_packages(dry_run: bool) -> None:
    missing = [package for module, package in PYTHON_PACKAGES if not module_available(module)]
    if not missing:
        log("Python 依赖已就位：" + "、".join(package for _, package in PYTHON_PACKAGES))
        return
    log("缺少 Python 依赖：" + "、".join(missing))
    if dry_run:
        log(f"将执行：{Path(sys.executable).name} -m pip install --user " + " ".join(missing))
        return
    command = [sys.executable, "-m", "pip", "install", "--user", *missing]
    # 虚拟环境不允许 --user，直接装进当前环境。
    if sys.prefix != sys.base_prefix:
        command.remove("--user")
    run(command, timeout=900)
    still = [package for module, package in PYTHON_PACKAGES if not module_available(module)]
    if still:
        raise InstallError("Python 依赖安装后仍无法导入：" + "、".join(still))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=os.environ.get("GODOT", common.GODOT_DEFAULT))
    parser.add_argument("--dry-run", action="store_true", help="只显示安装计划")
    args = parser.parse_args()
    common.LOG_TAG = "构建环境"
    try:
        if platform.system() != "Darwin":
            raise InstallError("此脚本针对 macOS；其他平台请手动安装 Godot 导出模板与 Python 依赖")
        version, folder = check_godot(Path(args.godot))
        install_templates(version, folder, args.dry_run)
        install_python_packages(args.dry_run)
        if args.dry_run:
            log("以上为检查计划；没有安装或修改文件。")
            return 0
        log("构建环境就绪。可以运行：./构建游戏.command")
        return 0
    except (InstallError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(redact_paths(f"构建环境安装失败：{error}", ROOT), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("构建环境安装已中断。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

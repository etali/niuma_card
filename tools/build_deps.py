#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""构建前依赖检查：缺少依赖时询问 Y/N，选择安装或终止构建。

目标：
- macos   标准 macOS 构建：macOS 导出模板、Pillow；fonttools 可选（缺失只跳过字体子集化）
- slim    精简引擎：macos 全部依赖 + git/lipo + Apple Clang 16+
- android Android 构建：Android 导出模板、apksigner、JDK

提问直接读写 /dev/tty：构建输出经过脱敏管道逐行转发，不带换行的提问会卡在管道里。
非交互运行（无终端、CI、CARD_BUILD_NO_PAUSE=1）不会等待输入：缺少必需依赖时直接失败；
设置 CARD_BUILD_ASSUME_YES=1 则自动安装。
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Callable

import install_build_env as env
from install_android_dependencies import InstallError
from project_paths import redact_paths

ROOT = Path(__file__).resolve().parents[1]
GODOT_DEFAULT = "/Applications/Godot.app/Contents/MacOS/Godot"
ANDROID_TEMPLATES = ("android_debug.apk", "android_release.apk", "android_source.zip")
# 用户拒绝安装时的退出码，与构建失败区分。
DECLINED = 3


class DependencyError(RuntimeError):
    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


@dataclass
class Missing:
    title: str                      # 一组同源依赖，例如“Godot 导出模板”
    items: list[str]
    install: Callable[[], None]     # 一次安装整组
    command: str                    # 手动安装命令，非交互或拒绝时提示
    required: bool = True
    effect: str = ""                # 可选依赖缺失时的后果
    details: list[str] = field(default_factory=list)


def log(message: str, stream=None) -> None:
    print(redact_paths(message, ROOT), file=stream or sys.stdout, flush=True)


TTY_PATH = "/dev/tty"


class Terminal:
    """终端不可 seek，不能用 open(..., "r+")（BufferedRandom 会抛 UnsupportedOperation）；读写分开包装。"""

    def __init__(self, fd: int):
        self.reader = os.fdopen(fd, "r", encoding="utf-8", errors="replace")
        self.writer = os.fdopen(os.dup(fd), "w", encoding="utf-8")

    def write(self, text: str) -> int:
        return self.writer.write(text)

    def flush(self) -> None:
        self.writer.flush()

    def readline(self) -> str:
        return self.reader.readline()

    def close(self) -> None:
        self.writer.close()
        self.reader.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def _tty():
    if os.environ.get("CI") or os.environ.get("CARD_BUILD_NO_PAUSE") == "1":
        return None
    try:
        fd = os.open(TTY_PATH, os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        return Terminal(fd)
    except OSError:
        os.close(fd)
        return None


def confirm(question: str) -> bool | None:
    """True=安装，False=拒绝，None=非交互无法询问。"""
    if os.environ.get("CARD_BUILD_ASSUME_YES") == "1":
        log(f"{question} [Y/N] Y（CARD_BUILD_ASSUME_YES=1）")
        return True
    tty = _tty()
    if tty is None:
        return None
    with tty:
        while True:
            tty.write(f"{question} [Y/N] ")
            tty.flush()
            answer = tty.readline()
            if not answer:
                return False
            answer = answer.strip().lower()
            if answer in ("y", "yes"):
                return True
            if answer in ("n", "no"):
                return False
            tty.write("请输入 Y 或 N。\n")


# ---------- 检查 ----------

def godot_version(godot: Path) -> tuple[str, str] | None:
    if not godot.is_file():
        raise DependencyError(f"找不到 Godot：{godot}（安装到 /Applications，或用 GODOT=/path/to/Godot 指定）")
    version = env.godot_bundle_version(godot)
    if version is None:
        log(f"提示：无法从 Godot.app 读出版本（{godot}），跳过导出模板检查")
    return version


def template_check(version: tuple[str, str] | None, names: tuple[str, ...], purpose: str) -> list[Missing]:
    if version is None:
        return []
    missing = env.missing_templates(version[1], names)
    if not missing:
        return []
    return [Missing(f"Godot {version[0]} 导出模板（{purpose}）", missing,
                    lambda: env.install_templates(version[0], version[1], False),
                    "./安装构建环境.command",
                    details=["将下载全套导出模板（约 1GB，仅一次），安装到 ~/Library/Application Support/Godot/export_templates/"])]


def python_check() -> list[Missing]:
    result = []
    if not env.module_available("PIL"):
        result.append(Missing("Python 库 Pillow", ["Pillow"], env.install_python_packages,
                              "./安装构建环境.command", details=["用于生成应用图标、检查素材"]))
    # 管道里的 pyftsubset 和 python3 -m fontTools.subset 都依赖这个模块。
    if not env.module_available("fontTools.subset"):
        result.append(Missing("Python 库 fonttools", ["fonttools"], env.install_python_packages,
                              "./安装构建环境.command", required=False,
                              effect="不安装则跳过字体子集化，App 内嵌完整字体（体积更大）",
                              details=["用于字体子集化"]))
    return result


def toolchain_check() -> list[Missing]:
    missing = [name for name in ("git", "xcrun", "lipo") if not shutil.which(name)]
    if os.environ.get("CXX") or os.environ.get("CC"):
        # 用户显式指定的工具链由匹配源码继续校验版本，避免误挡 Homebrew LLVM。
        major = None
    else:
        major = env.apple_clang_major()
        if major is None:
            missing.append("clang++")
        elif major < env.MINIMUM_CLANG:
            missing.append(f"Apple Clang {env.MINIMUM_CLANG}+（当前 {major}）")
    if not missing:
        return []
    return [Missing("Xcode 命令行工具", missing,
                    lambda: env.install_command_line_tools(False),
                    "./安装构建环境.command --toolchain",
                    details=[f"精简引擎需要 Xcode {env.MINIMUM_CLANG} 或更新的命令行工具",
                             "已装新版 Xcode 时切换 xcode-select；否则通过 softwareupdate 安装（需要管理员密码，下载数 GB）",
                             "也可设置 CXX=/path/to/clang++、CC=/path/to/clang 使用其他工具链"])]


def _editor_setting(key: str, version: tuple[str, str] | None) -> str:
    if version is None:
        return ""
    major_minor = ".".join(version[0].split(".")[:2])
    settings = Path.home() / "Library/Application Support/Godot" / f"editor_settings-{major_minor}.tres"
    try:
        text = settings.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r'^' + re.escape(key) + r'\s*=\s*"([^"]*)"', text, re.M)
    return match[1] if match else ""


def android_check(godot: Path, version: tuple[str, str] | None) -> list[Missing]:
    items = env.missing_templates(version[1], ANDROID_TEMPLATES) if version else []
    sdk = Path(_editor_setting("export/android/android_sdk_path", version)
               or os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
               or Path.home() / "Library/Android/sdk")
    if not any(os.access(path, os.X_OK) for path in sdk.glob("build-tools/*/apksigner")):
        items.append("Android SDK（build-tools / apksigner）")
    java = _editor_setting("export/android/java_sdk_path", version) or os.environ.get("JAVA_HOME", "")
    if not java or not os.access(Path(java) / "bin/java", os.X_OK):
        items.append("JDK 17")
    if not items:
        return []

    def install():
        command = [sys.executable, str(ROOT / "tools/install_android_dependencies.py"), "--godot", str(godot)]
        if subprocess.run(command, cwd=ROOT).returncode:
            raise InstallError("Android 构建环境安装失败")
    return [Missing("Android 构建环境", items, install, "./安装安卓构建环境.command",
                    details=["安装 Android SDK、JDK 17 与匹配的导出模板"])]


def collect(target: str, godot: Path) -> list[Missing]:
    version = godot_version(godot)
    if target == "android":
        return android_check(godot, version)
    # 精简构建复用标准模板里的 App 骨架，并在隔离副本里跑一次标准构建。
    found = template_check(version, ("macos.zip",), "macOS 导出") + python_check()
    if target == "slim":
        found += toolchain_check()
    return found


# ---------- 询问与安装 ----------

def describe(group: Missing) -> None:
    tag = "缺少依赖" if group.required else "缺少可选依赖"
    log(f"{tag}：{group.title} —— " + "、".join(group.items))
    for line in group.details:
        log(f"  · {line}")
    if group.effect:
        log(f"  · {group.effect}")


def resolve(group: Missing) -> None:
    describe(group)
    answer = confirm(f"是否现在安装{group.title}？Y 安装，N {'终止构建' if group.required else '跳过并继续'}")
    if answer is None:
        if group.required:
            raise DependencyError(f"缺少{group.title}，非交互运行无法询问。请先运行：{group.command}"
                                  "（或设置 CARD_BUILD_ASSUME_YES=1 自动安装）")
        log(f"  非交互运行，跳过{group.title}；需要时运行：{group.command}")
        return
    if not answer:
        if group.required:
            raise DependencyError(f"已终止构建：缺少{group.title}。之后可运行：{group.command}", DECLINED)
        log(f"  已跳过{group.title}；需要时运行：{group.command}")
        return
    log(f"开始安装{group.title}…")
    try:
        group.install()
    except (InstallError, OSError, ValueError) as error:
        raise DependencyError(f"{group.title}安装失败：{error}") from error


def ensure(target: str, godot: Path) -> None:
    env.common.LOG_TAG = "构建环境"
    groups = collect(target, godot)
    # 同一安装函数只调用一次（Pillow 与 fonttools 共用一次 pip 安装）。
    handled: set[Callable[[], None]] = set()
    for group in groups:
        if group.install in handled:
            continue
        resolve(group)
        handled.add(group.install)
    if groups:
        remaining = [g for g in collect(target, godot) if g.required]
        if remaining:
            raise DependencyError("安装后仍缺少：" + "；".join(f"{g.title}（{'、'.join(g.items)}）" for g in remaining))
        log("依赖检查通过，继续构建。")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", choices=("macos", "slim", "android"))
    parser.add_argument("--godot", default=os.environ.get("GODOT", GODOT_DEFAULT))
    args = parser.parse_args(argv)
    try:
        ensure(args.target, Path(args.godot))
        return 0
    except DependencyError as error:
        log(f"构建依赖检查未通过：{error}", sys.stderr)
        return error.code
    except KeyboardInterrupt:
        log("依赖安装已中断。", sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""将已编译的 macOS App 制作为可拖入 Applications 安装的只读压缩 DMG。"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from release_bundle import nonempty, publication_signals, publish, validate_app
from project_paths import display_path, redact_paths

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "牛马牌.app"


def run_command(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    if result.stdout:
        print(redact_paths(result.stdout, ROOT), end="" if result.stdout.endswith("\n") else "\n", flush=True)
    result.check_returncode()


def package(app, output=None):
    app = Path(app).expanduser().resolve()
    if not app.exists():
        raise ValueError(f"App 不存在：{display_path(app, ROOT)}；请先运行 ./构建游戏.command，再打包 DMG。")
    if not app.is_dir() or app.suffix.lower() != ".app":
        raise ValueError(f"输入必须是已经编译完成的 .app 目录：{display_path(app, ROOT)}")
    validate_app(app)
    if output is None:
        output = ROOT / "build" / "牛马牌.dmg"
    output = Path(output).expanduser().absolute()
    output = output.parent.resolve() / output.name
    if output.suffix.lower() != ".dmg":
        raise ValueError(f"输出文件必须以 .dmg 结尾：{display_path(output, ROOT)}")
    if app == output or app in output.parents:
        raise ValueError("DMG 输出不能放进输入 App 内部")
    if output.exists() and not output.is_file():
        raise ValueError(f"输出路径已被目录或其他文件类型占用：{display_path(output, ROOT)}")
    if sys.platform != "darwin":
        raise ValueError("DMG 打包需要在 macOS 上运行（使用系统 ditto 和 hdiutil）")
    commands = {}
    for name in ("ditto", "hdiutil"):
        commands[name] = shutil.which(name)
        if commands[name] is None:
            raise ValueError(f"找不到 macOS 系统工具 {name}，无法打包 DMG")
    output.parent.mkdir(parents=True, exist_ok=True)
    # 临时产物和输出在同一文件系统，失败/中断清理；旧 DMG 只在验证通过后替换。
    with publication_signals(), tempfile.TemporaryDirectory(prefix=".dmg-stage-", dir=output.parent) as temporary:
        stage = Path(temporary)
        payload = stage / "payload"
        payload.mkdir()
        print(f"[1/3] 复制已编译应用：{display_path(app, ROOT)}", flush=True)
        run_command([commands["ditto"], str(app), str(payload / APP_NAME)])
        validate_app(payload / APP_NAME)
        (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
        print("[2/3] 创建只读压缩安装镜像…", flush=True)
        pending = stage / "image.dmg"
        run_command([commands["hdiutil"], "create", "-volname", "牛马牌", "-srcfolder", str(payload),
                     "-fs", "HFS+", "-format", "UDZO", "-o", str(pending)])
        nonempty(pending)
        print("[3/3] 验证 DMG 并发布…", flush=True)
        run_command([commands["hdiutil"], "verify", str(pending)])
        pending.rename(stage / output.name)
        publish(stage, output.parent, [output.name])
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="只打包现有 App，不重新编译、不更改签名。打开 DMG 后将牛马牌.app 拖到 Applications。")
    parser.add_argument("--app", type=Path, default=ROOT / "build" / APP_NAME,
                        help="已编译的 App 路径（默认：项目 build/牛马牌.app）")
    parser.add_argument("--output", type=Path,
                        help="输出 .dmg 路径（默认：项目 build/牛马牌.dmg；成功后替换同名文件）")
    args = parser.parse_args(argv)
    try:
        output = package(args.app, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(redact_paths(f"DMG 打包失败：{error}", ROOT), file=sys.stderr)
        return error.returncode if isinstance(error, subprocess.CalledProcessError) and error.returncode > 0 else 1
    except KeyboardInterrupt:
        print("DMG 打包已取消，已有安装包未被替换。", file=sys.stderr)
        return 130
    print(f"DMG 打包完成：{display_path(output, ROOT)}（{output.stat().st_size / 1048576:.1f} MiB）", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

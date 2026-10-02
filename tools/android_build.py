#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""构建 Android APK/AAB；不复制游戏逻辑，只调用 Godot Android 导出预设。"""
from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from android_signing import SigningError, _read_config, _string, prepare_release_signing
from project_paths import display_path, redact_paths, relative_path

ROOT = Path(__file__).resolve().parents[1]
PRESETS = ROOT / "export_presets.cfg"


def fail(message: str) -> int:
    print(redact_paths(f"Android 构建失败：{message}", ROOT), file=sys.stderr)
    return 1


def verify_apk(godot: Path, apk: Path, env: dict[str, str]) -> str:
    """Godot 在签名工具不可用时可能返回成功，因此独立验证最终 APK。"""
    sdk = Path(env.get("ANDROID_SDK_ROOT") or env.get("ANDROID_HOME") or str(Path.home() / "Library/Android/sdk"))
    java_home = env.get("JAVA_HOME", "")
    version = subprocess.run([str(godot), "--version"], capture_output=True, text=True, check=True).stdout.strip()
    major_minor = ".".join(version.split(".")[:2])
    settings = _read_config(Path.home() / "Library/Application Support/Godot" / f"editor_settings-{major_minor}.tres")
    # 使用 Godot 实际选择的 SDK/JDK，兼容用户通过编辑器配置的自定义路径。
    for option in ("android_sdk_path", "java_sdk_path"):
        key = "export/android/" + option
        if settings.has_option("resource", key):
            value = _string(settings, "resource", key)
            if value:
                if option == "android_sdk_path":
                    sdk = Path(value)
                else:
                    java_home = value
    candidates = sorted(sdk.glob("build-tools/*/apksigner"),
                        key=lambda path: tuple(int(n) for n in re.findall(r"\d+", path.parent.name)), reverse=True)
    signer = next((path for path in candidates if os.access(path, os.X_OK)), None)
    if signer is None:
        raise SigningError(f"找不到可执行的 apksigner，无法验证 APK 签名：{sdk}/build-tools；请运行 ./安装安卓构建环境.command")
    verify_env = dict(env)
    if java_home:
        verify_env["JAVA_HOME"] = java_home
        verify_env["PATH"] = str(Path(java_home) / "bin") + os.pathsep + verify_env.get("PATH", "")
    result = subprocess.run([str(signer), "verify", "--verbose", relative_path(apk, ROOT)], cwd=ROOT, env=verify_env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SigningError("APK 签名验证失败：\n" + result.stdout)
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))
    parser.add_argument("--aab", action="store_true", help="输出 Google Play 使用的 AAB")
    parser.add_argument("--debug", action="store_true", help="导出 debug APK，适合首次设备验证")
    args = parser.parse_args()
    godot = Path(args.godot)
    if not godot.is_file():
        return fail(f"找不到 Godot：{godot}")
    preset = "Android AAB" if args.aab else "Android"
    if not PRESETS.is_file() or f'name="{preset}"' not in PRESETS.read_text(encoding="utf-8"):
        return fail(f"export_presets.cfg 没有 {preset} 预设")
    # Python 入口也可直接使用，必须在 Godot 扫描项目前隔离构建目录。
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build/.gdignore").touch()
    # 与 macOS/Web 字体事务使用同一锁。Android 也会导入共享资源，不能读到
    # 另一构建临时替换的字体或在其恢复导入缓存时导出。
    with (ROOT / "build/.font-transaction.lock").open("a+b") as resource_lock:
        fcntl.flock(resource_lock, fcntl.LOCK_EX)
        return export_package(args, godot, preset)


def export_package(args, godot, preset) -> int:
    env = dict(os.environ)
    if not args.debug:
        try:
            env = prepare_release_signing(ROOT, preset, env)
        except (SigningError, OSError) as error:
            return fail(str(error))
    icon_builder = ROOT / "tools/build_android_icons.py"
    icon_result = subprocess.run([sys.executable, relative_path(icon_builder, ROOT)], cwd=ROOT,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(redact_paths(icon_result.stdout, ROOT), end="")
    if icon_result.returncode:
        return fail("Android 图标生成失败")
    if args.aab:
        output = ROOT / "build/牛马牌.aab"
    else:
        output = ROOT / ("build/牛马牌-debug.apk" if args.debug else "build/牛马牌.apk")
    output.parent.mkdir(parents=True, exist_ok=True)
    log_dir = ROOT / "build/logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / ("android-%s-%d.log" % ("aab" if args.aab else ("debug" if args.debug else "release"), int(time.time())))
    started = time.time()
    # 导出失败时可能已产生未签名 APK；只有通过验证才替换最终文件。
    with tempfile.TemporaryDirectory(prefix="android-export-", dir=output.parent) as temporary:
        pending = Path(temporary) / output.name
        command = [str(godot), "--headless", "--path", ".",
                   "--export-debug" if args.debug else "--export-release", preset, relative_path(pending, ROOT)]
        print(redact_paths("执行：" + " ".join(command), ROOT), flush=True)
        result = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log_path.write_text(redact_paths(result.stdout, ROOT), encoding="utf-8")
        print(redact_paths(result.stdout, ROOT), end="")
        if result.returncode != 0 or re.search(r"^(?:SCRIPT ERROR|ERROR):", result.stdout, re.M):
            print(f"Android 构建失败。完整日志：{display_path(log_path, ROOT)}", file=sys.stderr)
            return result.returncode or 1
        if not pending.is_file() or pending.stat().st_size == 0:
            return fail(f"Godot 返回成功但没有生成输出文件。完整日志：{log_path}")
        if not args.aab:
            try:
                verification = verify_apk(godot, pending, env)
            except (SigningError, OSError, subprocess.SubprocessError) as error:
                with log_path.open("a", encoding="utf-8") as log:
                    log.write(redact_paths(f"\nAPK 验证失败：{error}\n", ROOT))
                return fail(f"{error}\n完整日志：{log_path}")
            with log_path.open("a", encoding="utf-8") as log:
                log.write(redact_paths("\nAPK 签名验证：\n" + verification, ROOT))
            print("APK 签名验证通过。")
        pending.replace(output)
    print(f"Android 构建完成：{display_path(output, ROOT)}（{output.stat().st_size / 1048576:.1f} MiB，耗时 {time.time() - started:.1f}s）")
    print(f"构建日志：{display_path(log_path, ROOT)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(fail(str(error))) from None

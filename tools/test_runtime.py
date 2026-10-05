#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Godot 测试进程的临时项目入口；不修改玩家目录、仓库 project.godot 或 HOME。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


def user_data_path(name):
    if sys.platform == "darwin":
        base = Path.home() / "Library/Application Support"
    elif sys.platform == "win32":
        base = Path(os.environ["APPDATA"])
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    return base / name


def isolated_project(root, target, token):
    """只复制项目配置；大资源/导入缓存共用只读路径，脚本仍使用原来的 res://。"""
    target.mkdir()
    for source in root.iterdir():
        if source.name not in {"project.godot", "override.cfg", ".git", "build", "tmp", "reports"}:
            (target / source.name).symlink_to(source, target_is_directory=source.is_dir())
    config = (root / "project.godot").read_text(encoding="utf-8")
    # override.cfg 属于玩家的本地配置；测试始终从版本化项目配置开始。
    config += '\n[application]\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="' + token + '"\n'
    (target / "project.godot").write_text(config, encoding="utf-8")


def cleanup_user_data(path):
    path = Path(path)
    # 只清理本模块/harness 约定的独立测试目录，绝不根据任意日志删除其他路径。
    if path.parent.name == "card-combine-tests" and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)


def preserve_project_paths(args, root, temporary):
    """切换隔离项目之前解析原项目的文件参数；不改调用方的持久请求。"""
    args = list(args)
    split = args.index("--") if "--" in args else len(args)

    def absolute(value):
        if not value or value.startswith(("res://", "user://")):
            return value
        return str((root / value).resolve())

    script = ""
    for index in range(split - 1):
        if args[index] == "--log-file":
            args[index + 1] = absolute(args[index + 1])
        elif args[index] in ("-s", "--script"):
            script = Path(args[index + 1]).name
            # 项目内部脚本已有同名符号链接；外部脚本仍须从原项目解析。
            value = args[index + 1]
            if not value.startswith(("res://", "user://")):
                source = (root / value).resolve()
                if not source.is_relative_to(root): args[index + 1] = str(source)

    for index in range(split + 1, len(args)):
        value = args[index]
        if value.startswith("--cards-config="):
            args[index] = "--cards-config=" + absolute(value.split("=", 1)[1])
        elif value and not value.startswith("-") and "://" not in value:
            # 输入文件可能没有扩展名；探针输出尚未创建，只识别明确的文件路径。
            if (root / value).exists() or "/" in value or Path(value).suffix.lower() in (".json", ".png", ".csv", ".txt", ".log"):
                args[index] = absolute(value)

    if script in ("eval_report.gd", "bot_duel_report.gd") and len(args) == split + 2:
        request_path = Path(args[-1])
        try: request = json.loads(request_path.read_text(encoding="utf-8"))
        except (OSError, ValueError): return args
        if isinstance(request, dict):
            for key in ("cards_path", "output_path", "progress_path"):
                if isinstance(request.get(key), str): request[key] = absolute(request[key])
            copy = temporary / "eval-request.json"
            copy.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
            args[-1] = str(copy)
    return args


def main():
    root = Path(os.environ["CARD_TEST_PROJECT_ROOT"]).resolve()
    runtime = Path(os.environ["CARD_TEST_RUNTIME_ROOT"])
    godot = os.environ["CARD_TEST_REAL_GODOT"]
    args = sys.argv[1:]
    project = Path.cwd()
    if "--path" in args:
        project = Path(args[args.index("--path") + 1])
    # 其他测试自行创建的临时项目要保留原项目配置，不能改成游戏工程。
    if project.resolve() != root:
        return subprocess.call([godot, *args])
    token = "card-combine-tests/" + uuid.uuid4().hex
    user_dir = user_data_path(token)
    record = runtime / (token.rsplit("/", 1)[1] + ".user.json")
    record.write_text(json.dumps(str(user_dir)))
    try:
        with tempfile.TemporaryDirectory(prefix="project-", dir=runtime) as temporary:
            project = Path(temporary) / "game"
            isolated_project(root, project, token)
            args = preserve_project_paths(args, root, Path(temporary))
            if "--path" in args:
                args[args.index("--path") + 1] = str(project)
            else:
                args[:0] = ["--path", str(project)]
            if "--log-file" not in args:
                args[:0] = ["--log-file", str(Path(temporary) / "godot.log")]
            env = dict(os.environ, CARD_TEST_USER_DIR_NAME=token)
            return subprocess.call([godot, *args], env=env)
    finally:
        cleanup_user_data(user_dir)
        record.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())

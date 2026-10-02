# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""准备本机 Android 发布签名；保留已有配置，首次生成的密钥独立于构建缓存。"""
from __future__ import annotations

import configparser
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

from project_paths import display_path

SIGNING_FIELDS = {
    "path": ("keystore/release", "GODOT_ANDROID_KEYSTORE_RELEASE_PATH"),
    "user": ("keystore/release_user", "GODOT_ANDROID_KEYSTORE_RELEASE_USER"),
    "password": ("keystore/release_password", "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"),
}


class SigningError(RuntimeError):
    pass


def _read_config(path: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None)
    if path.is_file():
        try:
            config.read_string(path.read_text(encoding="utf-8"))
        except configparser.Error:
            raise SigningError(f"无法解析签名配置：{display_path(path)}") from None
    return config


def _string(config: configparser.ConfigParser, section: str, key: str) -> str:
    try:
        value = json.loads(config.get(section, key))
        if not isinstance(value, str):
            raise ValueError
        return value
    except (ValueError, configparser.Error):
        # 不回显配置内容，避免错误消息泄露密码。
        raise SigningError(f"签名配置 {section}/{key} 必须是双引号字符串") from None


def _find_keytool(env: dict[str, str]) -> Path:
    candidates = []
    if env.get("JAVA_HOME"):
        candidates.append(Path(env["JAVA_HOME"]) / "bin/keytool")
    candidates.append(Path.home() / "Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home/bin/keytool")
    command = shutil.which("keytool", path=env.get("PATH"))
    if command:
        candidates.append(Path(command))
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return path
    raise SigningError("找不到 JDK keytool，请先运行 ./安装安卓构建环境.command 或设置 JAVA_HOME")


def _local_signing(root: Path, env: dict[str, str]) -> dict[str, str]:
    directory = root / ".android-signing"
    config_path = directory / "release.json"
    if not directory.exists():
        keytool = _find_keytool(env)
        # mkdir 不允许覆盖：并发构建也不能重新生成已有密钥。
        directory.mkdir(mode=0o700)
        (directory / ".gdignore").touch()
        signing = {"path": "release.keystore", "user": "cardcombine", "password": secrets.token_hex(24)}
        # 先保存密码。即使生成被中断，也保留信息供恢复，不自动换签名。
        with open(config_path, "x", encoding="utf-8", opener=lambda path, flags: os.open(path, flags, 0o600)) as file:
            json.dump(signing, file, ensure_ascii=False, indent=2)
            file.write("\n")
        key_env = dict(env, CARD_ANDROID_KEYSTORE_PASSWORD=signing["password"])
        try:
            subprocess.run([
                str(keytool), "-genkeypair", "-noprompt", "-storetype", "PKCS12",
                "-keystore", str(directory / signing["path"]), "-alias", signing["user"],
                "-keyalg", "RSA", "-keysize", "3072", "-validity", "10000",
                "-dname", "CN=Card Combine, OU=Android, O=Card Combine, C=CN",
                "-storepass:env", "CARD_ANDROID_KEYSTORE_PASSWORD",
                "-keypass:env", "CARD_ANDROID_KEYSTORE_PASSWORD",
            ], env=key_env, capture_output=True, text=True, check=True)
        except (OSError, subprocess.CalledProcessError):
            raise SigningError(f"生成发布密钥失败；请检查 JDK 并恢复 {display_path(directory, root)} 中的签名文件，已有信息已保留") from None
        (directory / signing["path"]).chmod(0o600)
        print(f"已生成本机发布密钥：{display_path(directory / signing['path'], root)}")
        print(f"请备份整个 {display_path(directory, root)}；后续版本复用此签名，清理 build/ 或 .godot/ 不会删除它。")
    try:
        signing = json.loads(config_path.read_text(encoding="utf-8"))
        if not isinstance(signing, dict) or any(not isinstance(signing.get(key), str) or not signing[key] for key in SIGNING_FIELDS):
            raise ValueError
    except (OSError, ValueError):
        raise SigningError(f"本机签名配置缺失或损坏：{display_path(config_path, root)}；请恢复备份，不会自动更换签名") from None
    path = Path(signing["path"]).expanduser()
    signing["path"] = str(path if path.is_absolute() else directory / path)
    return signing


def prepare_release_signing(root: Path, preset: str, env: dict[str, str]) -> dict[str, str]:
    presets = _read_config(root / "export_presets.cfg")
    section = next((name for name in presets.sections()
                    if presets.has_option(name, "name") and _string(presets, name, "name") == preset), None)
    if section is None:
        raise SigningError(f"export_presets.cfg 没有 {preset} 预设")
    section += ".options"
    credentials = _read_config(root / ".godot/export_credentials.cfg")
    signing = {}
    configured = False
    for field, (option, variable) in SIGNING_FIELDS.items():
        # 与 Godot 一致：非空环境变量 > credentials 中存在的值 > 预设。
        if env.get(variable):
            signing[field] = env[variable]
            configured = True
        elif credentials.has_option(section, option):
            signing[field] = _string(credentials, section, option)
            configured |= bool(signing[field])
        elif presets.has_option(section, option):
            signing[field] = _string(presets, section, option)
            configured |= bool(signing[field])
        else:
            signing[field] = ""
    # 编辑器保存预设时会写入默认空字符串；三项全空仍表示未配置。
    if not configured:
        signing = _local_signing(root, env)
    missing = [SIGNING_FIELDS[field][0] for field in SIGNING_FIELDS if not signing[field]]
    if missing:
        raise SigningError("发布签名配置不完整，缺少 " + "、".join(missing) + "；请补全现有签名，不会自动更换密钥")
    path_text = signing["path"]
    path = root / path_text[6:] if path_text.startswith("res://") else Path(path_text).expanduser()
    if not path.is_absolute():
        path = root / path
    if not path.is_file():
        raise SigningError(f"找不到发布密钥库：{display_path(path, root)}；请恢复原密钥或修正签名路径，不会自动更换密钥")
    signing["path"] = str(path.resolve())
    result = dict(env)
    for field, (_, variable) in SIGNING_FIELDS.items():
        result[variable] = signing[field]
    print(f"发布签名密钥库：{display_path(signing['path'], root)}")
    return result

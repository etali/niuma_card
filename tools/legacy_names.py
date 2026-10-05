# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""历史实验的读取适配；不改写历史文件，新接口只使用 BOT 名称。"""
import re

_LOWER = re.compile(r"(?<![a-zA-Z0-9])ai(?=$|[^a-z0-9])")
_UPPER = re.compile(r"(?<![A-Z])AI(?=$|[^a-z]|[A-Z][a-z])")


def normalize_legacy(value):
    if isinstance(value, dict):
        return {normalize_legacy(key): normalize_legacy(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize_legacy(item) for item in value]
    if isinstance(value, str):
        return _UPPER.sub("BOT", _LOWER.sub("bot", value))
    return value

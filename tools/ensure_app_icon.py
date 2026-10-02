#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""构建与发布共同使用的图标闸门：从桌宠源图生成标准方形导出图。"""
from build_art import build_app_icon


def main():
    log = []
    if not build_app_icon(False, log):
        print("缺少 assets/art/app_icon.png（桌宠源图），请从 Git 恢复该素材")
        return 1
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

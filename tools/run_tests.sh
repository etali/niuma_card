#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 统一回归入口：自动发现；支持名称、--suite、--list、JOBS、TEST_SPEED、TEST_TIMEOUT。
# Python 手动调参测试会运行 Node 行为用例。详细计数与失败日志由 runner 保留。
cd "$(dirname "$0")/.." || exit 1
exec python3 tools/test_runner.py "$@"

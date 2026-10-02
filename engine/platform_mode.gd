# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name PlatformMode
extends RefCounted

## 平台差异只在启动/窗口壳层处理；规则、牌桌、录像和联网不按平台复制。
static func is_mobile() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("mobile")

static func force_mobile() -> bool:
	if OS.get_environment("CARD_MOBILE_MODE") == "1":
		return true
	return "--mobile" in OS.get_cmdline_user_args()

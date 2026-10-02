# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Rules = preload("res://engine/card_config_rules.gd")

## 评估与正式游戏共享完整卡表校验，跨语言规格位于 data/card_config_schema.json。
static func validate(candidate: Dictionary, baseline: Dictionary) -> Array:
	return Rules.validate(candidate, baseline)

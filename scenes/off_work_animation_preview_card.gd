# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends OffWorkCard
## 只隔离预览速度；卡面、居中、连续动作与暂停均来自正式 OffWorkCard。
func _configured_hover_speed() -> float:
	return 1.0

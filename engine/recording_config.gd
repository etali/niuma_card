# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 保存生效配置而非文件路径；加载只比较影响裁决的规则，显示/BOT偏好留作记录。
static func rules() -> Dictionary:
	return StateCodec.rules_snapshot()

static func dump() -> Dictionary:
	var bot := BOTSearch.prefs()
	Palette._ensure_loaded()
	return {"rules": rules(), "cards_json": JSON.parse_string(FileAccess.get_file_as_string(CardDB.loaded_from)), "settings": {"bot_model": bot.model, "bot_strength": BOTSearch.pref_strength(),
		"bot_parameters": bot.resolved_parameters().duplicate(true), "ui_defaults": UIConfig.read_defaults(),
		"sfx": CardDB.sfx_rules().duplicate(true), "palette": Palette._cfg.duplicate(true)}}

## 加入角色之前录的录像存的是那时的完整规则；和当前规则去掉角色部分后一致也算匹配
## （见 StateCodec.pre_role_rules_snapshot）
static func matches(snapshot: Dictionary) -> bool:
	if not snapshot.get("rules") is Dictionary:
		return false
	var saved := StateCodec.canon_hash(snapshot["rules"])
	return saved == StateCodec.canon_hash(rules()) or saved == StateCodec.pre_role_table_hash()

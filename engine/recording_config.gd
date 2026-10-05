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

static func matches(snapshot: Dictionary) -> bool:
	return snapshot.get("rules") is Dictionary and StateCodec.canon_hash(snapshot["rules"]) == StateCodec.canon_hash(rules())

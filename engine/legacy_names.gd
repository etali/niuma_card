# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 仅用于读取历史文件；运行时类、配置和新数据统一使用 BOT。
const OLD_SEAT := "ai"
const HASH_ENCODING := "legacy-seat-v1"
static var _rules := {}

static func normalize(value: Variant, reverse := false) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[normalize(key,reverse)] = normalize(value[key],reverse)
		return result
	if value is Array:
		return value.map(func(item): return normalize(item,reverse))
	if value is String:
		if not _rules.has(reverse):
			var lower := RegEx.new()
			lower.compile("(?<![a-zA-Z0-9])%s(?=$|[^a-z0-9])" % ("bot" if reverse else OLD_SEAT))
			var upper := RegEx.new()
			upper.compile("(?<![A-Z])%s(?=$|[^a-z]|[A-Z][a-z])" % ("BOT" if reverse else "AI"))
			_rules[reverse] = [lower,upper]
		var lower: RegEx = _rules[reverse][0]
		var upper: RegEx = _rules[reverse][1]
		return upper.sub(lower.sub(value,OLD_SEAT if reverse else "bot",true),"AI" if reverse else "BOT",true)
	return value

static func state_hash(state: GameState) -> String:
	return StateCodec.canon_hash(normalize(StateCodec._hash_payload(state),true))

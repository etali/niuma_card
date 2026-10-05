# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Replay = preload("res://engine/replay_session.gd")
const LegacyNames = preload("res://engine/legacy_names.gd")

func _initialize() -> void:
	CardDB.load_from("res://data/cards.json")
	check(GameState.BOT == "bot" and BOTSearch.models() == [{"id":"bot","label":"BOT"}],"新座位、模型和展示名称统一为 BOT")
	var path := "res://tests/fixtures/legacy_recording_v2.json"
	var original := FileAccess.get_file_as_string(path)
	var loaded := Tape.load_from(path)
	if not need(loaded.ok,"历史录像能经读取适配载入"):
		finish();return
	var tape: Tape = loaded.tape
	check(tape.head.players.has(GameState.BOT) and not tape.head.players.has(LegacyNames.OLD_SEAT),"历史座位转成新运行时标识")
	check(tape.configuration.settings.has("bot_parameters") and tape.configuration.settings.bot_model=="bot","历史配置键和模型转换为 BOT")
	var replay := Tape.replay(tape)
	check(replay.ok and replay.played==6,"真实历史录像的六步意图逐步通过原哈希校验")
	var roundtrip := Tape.from_dict(tape.to_dict())
	check(roundtrip.ok and Tape.replay(roundtrip.tape).ok,"转换后的录像再次保存加载仍能校验历史哈希")
	var session := Replay.load_path(path)
	if need(session.ok,"历史录像可以进入交互回放"):
		var player = session.session
		while player.cursor < tape.size() and player.error=="": player.advance()
		check(player.cursor==tape.size() and player.error=="","交互逐步播放沿用历史哈希编码")
	check(FileAccess.get_file_as_string(path)==original,"历史源文件原样保留")
	var fresh := Tape.new();fresh.start(IntentApply.new(GameState.new()))
	check(fresh.to_dict().hash_encoding=="bot-seat-v1","新录像统一使用 BOT 哈希编码")
	fresh.stop()
	finish()

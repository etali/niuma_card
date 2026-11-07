# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Slots = preload("res://engine/shift_slot.gd")
const On = preload("res://scenes/on_work_main.tscn")
const Off = preload("res://scenes/off_work_main.tscn")
const WorkSession = preload("res://engine/off_work_session.gd")
var errors: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()

func check(value: bool, text: String) -> void:
	checks += 1
	if not value: errors.append(text)

func open_game(scene: PackedScene) -> Node:
	var game := scene.instantiate()
	game.set_meta("shift_session_enabled", true)
	root.add_child(game)
	game.set_process(false)
	return game

func _relaunch(args: PackedStringArray) -> void:
	var on = open_game(On)
	check(OnWorkStateCodec.state_hash(on.state) == args[1] and on.tape.size() == int(args[2]), "新进程上班规则和录像")
	on.free()
	var expected := Slots.load_slot(Slots.OFF_WORK)
	var off = open_game(Off)
	for key in WorkSession.STATE_FIELDS: check(off.state.get(key) == expected.world[key], "新进程下班：" + key)
	check(off.hud._manual_paused and off.bot.is_started(), "新进程下班暂停和 BOT")
	off.free()
	for e in errors: printerr(e)
	quit(0 if errors.is_empty() else 1)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 3 and args[0] == "--verify-relaunch":
		_relaunch(args)
		return
	# Integration tests always isolate both modes, even if called outside the suite.
	var sandbox := OS.get_temp_dir().path_join("niuma-shift-test-" + Crypto.new().generate_random_bytes(10).hex_encode())
	OS.set_environment("CARD_DATA_DIR", sandbox)
	OS.set_environment("WORK_DATA_DIR", sandbox.path_join("off_work"))
	var on = open_game(On)
	on._invalidate_session()
	on.state.set_seed(619)
	on.state.new_game(on.my_seat)
	for i in 12: on.state.add_card(on.my_seat, OnWorkCardDB.unit_id(OnWorkCardDB.RES_CASH))
	on._rebuild_pipe()
	on._sync_round()
	var bought: Dictionary = await on.pipe.submit(OnWorkIntent.buy(on.my_seat, 0), on.my_seat)
	check(bought.ok, "上班购买失败")
	on._respawn_all()
	var state_hash := OnWorkStateCodec.state_hash(on.state)
	var step_count: int = on.tape.size()
	check(step_count > 0 and on.save_shift_session(), "上班牌局未存盘")
	var original_on := FileAccess.get_file_as_bytes(Slots.path(Slots.ON_WORK))
	on.free()
	var off = open_game(Off)
	off.state.config.rules.initial.groups = [{"employee": 1,"work": 4}]
	off._new_game()
	off.bot.start()
	off.state.advance(1.25)
	off.state.drain_events()
	off.board.sync_state(off.state)
	off.hud.set_manual_paused(true)
	check(off.save_shift_session(), "下班牌局未存盘")
	var off_checkpoint := Slots.load_slot(Slots.OFF_WORK)
	check(off_checkpoint.has("bot") and not off_checkpoint.has("ai"), "新存档只写 BOT 配置")
	# Exercise a real old-format slot in the fresh process and in the parent.
	off_checkpoint.ai = off_checkpoint.bot
	off_checkpoint.erase("bot")
	Slots.save(Slots.OFF_WORK, off_checkpoint)
	var original_off := FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK))
	var expected_world: Dictionary = off_checkpoint.world.duplicate(true)
	off.state.advance(1.75)
	var next_world := {}
	for key in WorkSession.STATE_FIELDS: next_world[key] = off.state.get(key).duplicate(true) if off.state.get(key) is Dictionary or off.state.get(key) is Array else off.state.get(key)
	var bot_next: float = off.bot._next_think
	# Expected continuation was measured on the live original; test restoration from
	# the saved boundary rather than replacing it with this later state at teardown.
	off._shift_enabled = false
	off.free()
	paused = false
	check(original_on == FileAccess.get_file_as_bytes(Slots.path(Slots.ON_WORK)), "下班写入影响上班槽")
	var output := []
	var child_status := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", get_script().resource_path, "--", "--verify-relaunch", state_hash, str(step_count)], output, true)
	check(child_status == 0 and not "SCRIPT ERROR" in str(output), "跨进程恢复：" + str(output))
	var restored_on = open_game(On)
	check(OnWorkStateCodec.state_hash(restored_on.state) == state_hash, "上班快照或随机数变化")
	check(restored_on.tape.size() == step_count and restored_on.tape.recording(), "上班录像未接续")
	check(restored_on._actor == restored_on.my_seat and not restored_on.board.input_locked, "上班未回到玩家行动")
	check(Slots.load_slot(Slots.OFF_WORK).world == expected_world, "上班读取影响下班槽")
	restored_on.free()
	var restored_off = open_game(Off)
	for key in WorkSession.STATE_FIELDS: check(restored_off.state.get(key) == expected_world[key], "下班还原：" + key)
	check(restored_off.hud._manual_paused and restored_off.bot.is_started() and restored_off.bot._next_think == bot_next, "暂停或 BOT 时钟变化")
	check(restored_off.state._rng.state == off_checkpoint.rng and restored_off.bot._rng.state == off_checkpoint.bot_rng, "下班随机数游标变化")
	restored_off.state.advance(1.75)
	for key in WorkSession.STATE_FIELDS: check(restored_off.state.get(key) == next_world[key], "下班续算：" + key)
	restored_off.free()
	paused = false
	var damaged := FileAccess.open(Slots.path(Slots.OFF_WORK), FileAccess.WRITE)
	damaged.store_buffer(original_off.slice(0, 99))
	damaged.close()
	check(Slots.load_slot(Slots.OFF_WORK).is_empty() and not Slots.load_slot(Slots.ON_WORK).is_empty(), "损坏的存档应独立拒绝")
	OS.move_to_trash(sandbox)
	for e in errors: printerr(e)
	print("SHIFT_PERSISTENCE: %d 通过 / %d 失败" % [checks - errors.size(), errors.size()])
	quit(0 if errors.is_empty() else 1)

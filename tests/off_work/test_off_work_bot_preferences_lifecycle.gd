# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Preferences = preload("res://engine/off_work_bot_preferences.gd")
const Config = preload("res://engine/off_work_config.gd")

func _initialize() -> void:
	root.size = Vector2i(1440, 810)
	run.call_deferred()

func _enabled(panel: Control) -> CheckBox:
	for row in panel._rows:
		if row.key == "enabled": return row.node
	return null

func _set_enabled(host: Node, panel: Control, value: bool) -> void:
	var checkbox := _enabled(panel)
	check(checkbox != null and checkbox.name == "BOTEnabled", "当前参数绑定保留实际启用控件")
	if checkbox == null: return
	# Practice/replay deliberately disallow opening the BOT settings page. This
	# lifecycle test exercises binding isolation through the same control signal;
	# test_work_hud covers real mouse input on the available single-player page.
	checkbox.button_pressed = value
	check(checkbox.button_pressed == value and host.state.config.rules.bot.enabled == value
		and host.bot._policy.enabled == value, "勾选回调同步控件、当前绑定配置和BOT策略")

func run() -> void:
	var host: Node = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(host)
	await process_frame
	host.set_process(false)
	var panel: Control = host.hud.table_hud.get_node("BOTPanel")
	check(_enabled(panel) != null and _enabled(panel).button_pressed and host.bot._policy.enabled, "首次正式对局的启用勾选默认为开")
	panel._slider.value = 1.0
	panel._on_knob_number(7, "search_root_width", "int")
	_set_enabled(host, panel, false)
	panel._slider.value = 0.5
	panel._slider.value = 1.0
	var selected: Dictionary = host.bot._policy.duplicate(true)
	check(selected.think_seconds == 2.0 and Config.decision_budget_ms(selected) == 1800 and selected.decision_budget_ratio == 0.9, "真实HUD滑块把最高档写入正在运行的BOT")
	check(not selected.enabled and not _enabled(panel).button_pressed, "关闭后调整整体强度不会重新开启BOT")
	host._rematch()
	await process_frame
	check(host.bot._policy == selected, "再来一局保留整体强度和独立调参")
	check(panel._slider.value == 1.0 and Preferences.has_overrides(), "重开后滑块和自定义标记仍对应真实策略")
	check(not _enabled(panel).button_pressed and not host.bot._policy.enabled, "再来一局保持关闭状态且勾选同步")

	var cards: Dictionary = host.state.config.balance_document()
	cards.rules.conveyor.slots = 4
	var path := SavePaths.settings_file("off_work_lifecycle_cards.json")
	preload("res://engine/json_store.gd").save(path, cards)
	check(host.choose_card_config(path).ok and host.apply_selected_card_config().ok, "真实卡表选择流程仍可重开")
	await process_frame
	check(host.state.offers.size() == 4 and host.bot._policy == selected, "换卡表只更新牌桌规则并保留BOT设置")
	check(not _enabled(panel).button_pressed, "换卡表重开不会重新勾选启用")

	var original: RefCounted = host.state
	host.begin_practice("first")
	await process_frame
	check(Preferences._state == host.state and Preferences._state != original, "练习面板绑定当前练习牌桌")
	check(not Preferences.prefs().get_knob("enabled"), "练习面板反映课程禁用BOT的实际配置")
	check(not _enabled(panel).button_pressed, "进入课程时勾选与课程禁用BOT配置一致")
	panel._slider.value = 1.0
	panel._on_knob_number(2, "search_root_width", "int")
	check(not _enabled(panel).button_pressed and not host.bot._policy.enabled, "练习中改变强度不改变课程的禁用状态")
	_set_enabled(host, panel, true)
	check(original.config.rules.bot == selected, "练习中的调参不修改停放的正式对局")
	host.finish_practice()
	await process_frame
	check(host.state == original and Preferences._state == original, "退出练习恢复正式对局的参数绑定")
	check(host.bot._policy == selected and panel._slider.value == 1.0 and Preferences.has_overrides(), "退出练习还原原策略和自定义标记")
	check(not _enabled(panel).button_pressed, "练习中启用BOT不会覆盖正式对局的关闭勾选")

	var replay_path: String = host.replay.save(host)
	check(host._load_replay(replay_path).ok, "可进入真实录像播放路径")
	check(Preferences._state == host.state and Preferences._state != original, "录像面板不再指向停放的对局")
	panel._on_knob_number(3, "search_root_width", "int")
	host.stop_replay()
	check(Preferences._state == original and host.bot._policy == selected, "退出录像恢复原BOT参数且不受播放期间调参污染")
	check(panel._slider.value == 1.0 and Preferences.has_overrides(), "录像退出后强度读数与覆盖标记恢复")
	check(not _enabled(panel).button_pressed, "录像退出后恢复正式对局的关闭勾选")
	_set_enabled(host, panel, true)
	var enabled_selection: Dictionary = host.bot._policy.duplicate(true)
	host._rematch()
	await process_frame
	check(host.bot._policy == enabled_selection and _enabled(panel).button_pressed, "重新勾选启用后再来一局保留恢复后的真实策略")
	host.queue_free()
	await process_frame

	var recovered := Config.new()
	recovered.rules.bot.merge(Preferences.strength_parameters(1.0, recovered.rules.bot, recovered.bot_preferences), true)
	var restored := OffWorkState.new(recovered)
	Preferences.bind(restored, recovered.bot_preferences)
	check(Preferences.pref_strength() == 1.0, "载入已保存的最高档策略时从实际参数还原滑块")
	recovered.rules.bot.think_seconds = 3.7
	Preferences.bind(restored, recovered.bot_preferences)
	check(Preferences.has_overrides() and recovered.rules.bot.think_seconds == 3.7, "旧档自定义参数保留并显示覆盖标记")
	finish()

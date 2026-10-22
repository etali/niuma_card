# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends PanelContainer

## 正式单机局的按需提示；不锁牌桌、不切换教学局，也不要求通过额外考试。
const Catalog = preload("res://engine/tutorial_catalog.gd")
const Progress = preload("res://engine/tutorial_progress.gd")
var presentation: Node
var _message: Label
var _pending := ""
var _seen: Dictionary = {}
var _poll := 0.0
var _game := -1
var _first_game := false
var _teach_upgrade := false

func bind(owner_presentation: Node) -> void:
	presentation = owner_presentation
	name = "ContextualCoach"
	set_meta("drawer_surface", Palette.plate_color("plate_t3", "face"))
	set_meta("drawer_margin_base", 10)
	var body := VBoxContainer.new()
	add_child(body)
	_message = presentation._label("", 14)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_message)
	var dismiss: Button = presentation._button(Catalog.ui("context.dismiss"), 13)
	dismiss.name = "DismissContextHelp"
	dismiss.pressed.connect(func(): _pending = ""; hide())
	body.add_child(dismiss)
	presentation._apply_tree_theme(self)
	presentation._guard_table_panel(self, true)
	var tips: Variant = Progress.read().get("tips", {})
	_seen = tips.duplicate() if tips is Dictionary else {}
	_game = presentation._main._session_generation
	resume_after_tutorial()
	hide()

func resume_after_tutorial() -> void:
	_first_game = Progress.consume_first_game_help()
	_teach_upgrade = Progress.course("income").get("status") == "completed"

func clear(id: String) -> void:
	if _pending == id: _pending = ""; hide()

func offer(id: String) -> void:
	if _seen.get(id, false): return
	_pending = id

func _available() -> bool:
	var main: Node = presentation._main
	return not presentation._table_panels_blocked() \
		and not presentation.panels_open() and not presentation.is_learning_invitation_open() \
		and not main._tutorial_active and main.replay_session == null and main._net == null \
		and main.phase == main.PHASE_ACTION and main._actor == main.my_seat and main.state.winner.is_empty()

func _process(delta: float) -> void:
	_poll += delta
	if _poll < 0.25: return
	_poll = 0.0
	if not is_instance_valid(presentation) or not is_instance_valid(presentation._main): return
	var main: Node = presentation._main
	if _game != main._session_generation:
		_game = main._session_generation
		_pending = ""
	if not _available(): hide(); return
	if _pending.is_empty() and _first_game:
		_pending = "first_game"
		_first_game = false
	if _pending.is_empty() and not _seen.get("upgrade", false) \
			and _teach_upgrade and _has_upgrade(main):
		_pending = "upgrade"
	visible = not _pending.is_empty()
	if not visible: return
	_message.text = Catalog.ui("context." + _pending, {"title": Catalog.course("upgrade").get("title", "")})
	if not _seen.get(_pending, false):
		_seen[_pending] = true
		Progress.mark_tip_seen(_pending)
	var bounds: Rect2 = presentation.content_rect().grow(-8)
	var width := minf(bounds.size.x, 340 * presentation._responsive_factor())
	_message.custom_minimum_size.x = maxf(80, width - 24)
	size = Vector2(width, 0)
	position = bounds.end - size

func _has_upgrade(main: Node) -> bool:
	var counts := {}
	for card in main.state.players[main.my_seat]["cards"]:
		var id := str(card["def_id"])
		counts[id] = int(counts.get(id, 0)) + 1
	for id in CardDB.all_cards():
		var definition := CardDB.get_def(str(id))
		var source := str(definition.get("upgrade_from", ""))
		if not source.is_empty() and int(definition.get("upgrade_dup_n", 0)) > 1 \
				and int(counts.get(source, 0)) >= int(definition["upgrade_dup_n"]): return true
	return false

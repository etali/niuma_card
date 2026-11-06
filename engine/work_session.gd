# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

const Slots = preload("res://engine/shift_slot.gd")
const State = preload("res://engine/work_state.gd")
const Config = preload("res://engine/work_config.gd")
const Bot = preload("res://engine/work_bot.gd")

# Only authoritative game state is stored. Membership indexes and presentation
# events are rebuilt on load, without replaying purchases, strikes or income.
const STATE_FIELDS := State.WORLD_FIELDS
const BOARD_FIELDS := ["_origin_by_gid", "_compact_by_gid", "group_overrides",
	"_spawned_by_owner", "_opening_counts"]

static func save_session(host: Node) -> bool:
	var state: RefCounted = host.state
	if state == null or host.bot == null or not is_instance_valid(host.board): return false
	var world := {}
	for key in STATE_FIELDS: world[key] = state.get(key)
	var layout := {}
	for key in BOARD_FIELDS: layout[key] = host.board.get(key)
	var bot: RefCounted = host.bot
	return Slots.save(Slots.OFF_WORK, {"world": world, "layout": layout,
		"balance": state.config.balance_document(),
		"bot": {"bot": state.config.rules.bot, "preferences": state.config.bot_preferences},
		"rng": state._rng.state, "bot_rng": bot._rng.state,
		"bot_started": bot.is_started(), "bot_next": bot._next_think,
		"bot_scan": bot._planner.save_scan_hints(),
		"replay_frames": host.replay.frames, "active_config": host._active_config, "paused": host.hud._manual_paused})

static func read_session(host: Node) -> Dictionary:
	var saved := Slots.load_slot(Slots.OFF_WORK)
	if not saved.get("world") is Dictionary or not saved.get("layout") is Dictionary: return {}
	var world: Dictionary = saved.world
	if not world.has_all(STATE_FIELDS) or not saved.layout.has_all(BOARD_FIELDS): return {}
	var strategy: Variant = saved.get("bot", saved.get("ai")) # 兼容旧下班存档
	if not saved.get("balance") is Dictionary or not strategy is Dictionary: return {}
	var config := Config.new(saved.balance, strategy)
	if not config.errors.is_empty(): return {}
	var state := State.new(config)
	for key in STATE_FIELDS:
		if typeof(world[key]) != typeof(state.get(key)): return {}
		state.set(key, world[key])
	state._rng.state = saved.rng
	var bot := Bot.new(state, config.integer("bot", "owner"))
	bot._started = saved.bot_started
	bot._rng.state = saved.bot_rng
	bot._next_think = saved.bot_next
	if saved.get("bot_scan") is Dictionary:
		bot._planner.restore_scan_hints(saved.bot_scan)
	host.state = state
	host.bot = bot
	return saved

static func restore_view(host: Node, saved: Dictionary) -> void:
	for key in BOARD_FIELDS: host.board.set(key, saved.layout[key])
	host.board.sync_state(host.state)
	host._player_activity_snapshot = host._capture_player_activity()
	host.hud.set_manual_paused(saved.paused)
	host._update_hud()
	host.message.text = str(host.settings.text.hint)
	if host.state.winner != -1:
		host._result_started = true
		host._show_result()

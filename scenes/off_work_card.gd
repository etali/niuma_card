# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkCard
extends CardEntity

## 共享 CardEntity 构建牌面、碰撞和悬停反馈；下班扩展连续动作与任务进度。
func _init() -> void:
	card_catalog = OffWorkCardDB
	combo_rules = OffWorkComboRules

func _ready() -> void:
	super._ready()
	# Godot enables scripted _process on entry even when configure() ran before
	# add_child(). Apply the covered-material policy after entering the tree.
	_sync_material_processing()

var type: String = "work"
var card_owner: int = 0
var group_id: int = -1
var record: Dictionary = {}
var definition: Dictionary = {}
var is_offer := false
var selected := false
var target := Vector3.ZERO
var _realtime: Node3D
var _task_progress: Node3D
var _task_progress_frame: MeshInstance3D
var _task_progress_material: ShaderMaterial
var _debug_timer: Label3D
var _debug_timer_enabled := false
var _debug_remaining := -1.0
var _task_progress_value := 0.0
var _task_progress_active := false
var _task_progress_paused := false
var _task_progress_phase := "work"
var _task_progress_source := -1
var _meeting_participant := false
var _strike_participant := false
var _task_completion_hold := 0.0
# Work/money have no intrinsic activity. Their generic idle visuals only need
# rebuilding after a real visual write, while record/ownership always rebind.
var _material_record_visuals_current := false
var _elapsed := 0.0
var _retired := false
var face_deferred := false
var _leave_tween: Tween
const TitleInk = preload("res://scenes/card_title_ink.gd")
var _upgrade_ring: MeshInstance3D
var _upgrade_remaining := 0.0
var _upgrade_visual_active := false
var _animation_running := false
var _motion_material: ShaderMaterial
var _motion_time := 0.0
var _motion_synced_material: ShaderMaterial
var _motion_synced_texture: Texture2D
var _motion_synced_type := ""
var _motion_synced_striking := false
var _motion_synced_time := NAN
var _motion_synced_tint := Color.WHITE

static func prewarm_event_stamps() -> void:
	# The inherited table warmup covers its original words. Our work/meeting/
	# strike and role names must also be baked before the first live event;
	# baking a new word reads a viewport back from the GPU during settlement.
	var words: Array = []
	var rig := OffWorkUI.section("rig")
	for key in ["stamp_word", "meeting_word", "strike_word"]: words.append(str(rig[key]))
	words.append(str(OffWorkUI.section("upgrade").stamp_word))
	words.append(str(OffWorkUI.section("animation").leave_stamp))
	for kind in OffWorkCardDB.role_rules(): words.append(str(OffWorkCardDB.get_def(str(kind)).get("name", "")))
	InkStamp.prewarm(words)

func configure(data: Dictionary, card_definition: Dictionary, offer := false, defer_face := false) -> void:
	record = data
	definition = card_definition
	type = str(data.type)
	card_owner = int(data.get("owner", 0))
	group_id = int(data.get("group", -1))
	is_offer = offer
	is_market = offer
	uid = int(data.id)
	def_id = type
	_build_collision()
	for child in get_children():
		if child is CollisionShape3D:
			_material_collision = child
			break
	if defer_face:
		# Keep a real physics/picking identity and a label visibility flag on
		# each covered sheet. Build the printed face when its layer is exposed.
		face_deferred = true
		label = Label3D.new()
		_add_visual(label)
		_task_progress = Node3D.new()
		_task_progress.hide()
		_add_visual(_task_progress)
		_debug_timer = Label3D.new()
		_debug_timer.hide()
		_task_progress.add_child(_debug_timer)
		_visual.hide()
		_visual.visibility_changed.connect(_on_face_visibility_changed)
		set_process(false)
	else:
		_build_printed_face()
	update_record(data)

func reveal_stack_face() -> void:
	if face_deferred: _build_printed_face()
	_visual.show()

func _on_face_visibility_changed() -> void:
	if face_deferred and _visual.visible: _build_printed_face()

func _build_printed_face() -> void:
	_material_record_visuals_current = false
	face_deferred = false
	if _visual and _visual.visibility_changed.is_connected(_on_face_visibility_changed):
		_visual.visibility_changed.disconnect(_on_face_visibility_changed)
	_build_face()
	# Keep the title layout/visibility API shared with the board. Its pixels
	# are printed by the opaque paper, so lower-card letters cannot float up.
	label.layers = 0
	label.visibility_changed.connect(_sync_printed_title_visibility)
	TitleInk.apply(def_id, label, _plate.material_override)
	_build_realtime()
	_apply_color()
	if not _visual.visibility_changed.is_connected(_sync_material_processing):
		_visual.visibility_changed.connect(_sync_material_processing)
	_sync_material_processing()

var _material_collision: CollisionShape3D

func _sync_material_processing() -> void:
	# Covered inert material has no autonomous clock. Its real record and body
	# stay alive, and revealing the same UID resumes its ordinary hover feedback.
	var covered := type in ["work", "money"] and (face_deferred or (_visual != null and not _visual.visible))
	set_process(not face_deferred and _visual != null and not covered)
	# Hidden material occupies the exact same stack slot as a visible layer.
	# Moving thousands of duplicate broadphase shapes adds no pickable surface.
	# Keep the real body and layer/mask (including flight locks) untouched.
	if _material_collision != null and _material_collision.disabled != covered:
		_material_collision.disabled = covered

func card_size() -> Vector2:
	return CardArt.FRAME_SIZE

func _build_realtime() -> void:
	_center_illustration()
	_prepare_illustration_motion()
	_realtime = Node3D.new()
	_realtime.name = "RealtimeLayers"
	# Only the truthful task bar and event ring remain above the original icon.
	# Their depth stays below the next card in the unchanged original stack gap.
	var reference := OffWorkUI.vector2("frame", "size")
	var reference_y := OffWorkUI.number("frame", "icon_y")
	var max_y := maxf(OffWorkUI.number("task_progress", "surface_y"), OffWorkUI.number("upgrade", "ring_y"))
	var depth_scale := (Y_OVERLAY - Y_ICON) / (max_y - reference_y)
	_realtime.scale = Vector3(CARD_SIZE.x / reference.x, depth_scale, CARD_SIZE.z / reference.y)
	_realtime.position.y = Y_ICON - reference_y * depth_scale
	_add_visual(_realtime)
	_face_elems.append(_realtime)
	_build_task_progress()
	if _is_person(): _build_upgrade_fx()

func _center_illustration() -> void:
	if _icon == null: return
	_icon.position = Vector3((OffWorkUI.number("frame", "art_cx") - 0.5) * CARD_SIZE.x,
		Y_ICON, _frac_to_z(OffWorkUI.number("frame", "art_cy")))
	var art_scale := float(OffWorkUI.section("frame").get("art_scale_by_type", {}).get(type, 1.0))
	_icon.pixel_size = CARD_SIZE.x * OffWorkUI.number("frame", "art_width") * art_scale / float(_icon.texture.get_width())
	_hover_pixel_size = _icon.pixel_size
	_icon.show()

func _sync_printed_title_visibility() -> void:
	var front := _feedback_material()
	if front: front.set_shader_parameter("print_title", label.visible)

func _push_plate_colors(front: ShaderMaterial) -> void:
	super._push_plate_colors(front)
	front.set_shader_parameter("title_ink", _ink)

func _is_person() -> bool:
	return str(definition.get("category", "")) == "person"

func _add_effect_badge(_def: Dictionary, _textured: bool) -> void:
	# Faces show the original title and illustration only. Amounts remain in the
	# stack-side list and header; price tags keep their independent purchase price.
	pass

func _add_recipe_badge(_def: Dictionary, _textured: bool) -> void:
	pass

func _add_kind_badge(_def: Dictionary, _textured: bool) -> void:
	pass

func _build_task_progress() -> void:
	var spec := OffWorkUI.section("task_progress")
	if _task_progress == null:
		_task_progress = Node3D.new()
		_realtime.add_child(_task_progress)
	else:
		_task_progress.reparent(_realtime, false)
	_task_progress.name = "TaskProgress"
	_task_progress.position = Vector3(0.0, float(spec.surface_y), float(spec.center_z))
	var size := Vector2(float(spec.width), float(spec.height))
	_task_progress_frame = MeshInstance3D.new()
	_task_progress_frame.name = "ProgressSurface"
	var plane := PlaneMesh.new()
	plane.size = size
	_task_progress_frame.mesh = plane
	_task_progress_material = ShaderMaterial.new()
	_task_progress_material.shader = preload("res://shaders/off_work_task_progress.gdshader")
	_task_progress_material.set_shader_parameter("border_uv", Vector2.ONE * float(spec.border) / size)
	_task_progress_frame.material_override = _task_progress_material
	_task_progress_frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_task_progress.add_child(_task_progress_frame)
	var debug: Dictionary = spec.debug_timer
	if _debug_timer == null:
		_debug_timer = Label3D.new()
		_task_progress.add_child(_debug_timer)
	_debug_timer.name = "DebugTimer"
	_debug_timer.font = Fonts.zh_bold()
	_debug_timer.font_size = int(debug.font_size)
	_debug_timer.pixel_size = float(debug.pixel_size)
	_debug_timer.outline_size = int(debug.outline_size)
	_debug_timer.position = Vector3(0.0, float(debug.surface_offset), float(debug.z_offset))
	_debug_timer.rotation_degrees.x = -90.0
	_debug_timer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_refresh_task_progress_palette()
	_render_task_progress()

func set_debug_timer(enabled: bool, remaining: float) -> void:
	_debug_timer_enabled = enabled
	_debug_remaining = remaining
	_render_task_progress()

func _render_debug_timer() -> void:
	if _debug_timer == null: return
	_debug_timer.visible = _debug_timer_enabled and _debug_remaining >= 0.0 and _task_progress_active
	if not _debug_timer.visible: return
	var spec: Dictionary = OffWorkUI.section("task_progress").debug_timer
	_debug_timer.text = str(spec.paused_format if _task_progress_paused else spec.format) % _debug_remaining
	_debug_timer.pixel_size = float(spec.pixel_size)
	var width := _debug_timer.font.get_string_size(_debug_timer.text, HORIZONTAL_ALIGNMENT_CENTER, -1, _debug_timer.font_size).x * _debug_timer.pixel_size
	if width > float(spec.max_width): _debug_timer.pixel_size *= float(spec.max_width) / width
	_debug_timer.modulate = Palette.semantic(str(spec.color))
	_debug_timer.outline_modulate = Palette.semantic(str(spec.outline_color))

## Ordinary work belongs to a combination; Board chooses its one visible bar.
## Personnel records retain progress for animation/detail, not separate timers.
func set_task_progress(value: float, active: bool, paused := false, phase := "work", source_uid := -1) -> void:
	# A group may project progress onto an otherwise idle material UID. Its next
	# record refresh must clear that projection before Board selects the new one.
	_material_record_visuals_current = false
	if _task_progress_phase != phase: _task_completion_hold = 0.0
	if not active: _task_completion_hold = 0.0
	_task_progress_value = clampf(value, 0.0, 1.0)
	_task_progress_active = active and not is_offer and not _retired
	_task_progress_paused = paused
	_task_progress_phase = phase
	_task_progress_source = uid if source_uid < 0 else source_uid
	_render_task_progress()

## These cards own their timers even while ready. A neighbouring worker's
## projected work bar must never look like a meeting or an upgrade countdown.
func has_dedicated_progress() -> bool:
	return OffWorkUI.section("task_progress").dedicated_cards.has(type)

func flash_task_completion() -> void:
	if is_offer or _retired or has_dedicated_progress() or is_meeting_participant(): return
	if _task_progress_phase == "work" and not _task_progress_active: return
	_material_record_visuals_current = false
	_task_completion_hold = OffWorkUI.number("task_progress", "completion_hold_seconds")
	_render_task_progress()

## Meeting choreography owns the visible person, not their saved task. Keep
## progress hidden through the return flight, then reveal the true task again.
func set_meeting_participant(on: bool) -> void:
	_meeting_participant = on and _is_person()
	if _meeting_participant: _task_completion_hold = 0.0
	_render_task_progress()

func is_meeting_participant() -> bool:
	return _is_person() and (_meeting_participant or bool(record.get("paused", false)) or str(record.get("activity", "idle")) == "meeting")

func set_strike_participant(on: bool) -> void:
	var next := on and _is_person() and not is_offer and not _retired
	if next == _strike_participant: return
	_strike_participant = next
	_motion_time = 0.0
	_hover_elapsed = 0.0
	_hover_frame = 0
	_animation_running = false
	hover_animation_duration = illustration_duration()
	_sync_illustration_material()
	if _strike_participant: _task_completion_hold = 0.0
	_render_task_progress()

func _render_task_progress() -> void:
	if _task_progress_frame == null: return
	var spec := OffWorkUI.section("task_progress")
	_task_progress_frame.visible = true
	_task_progress.visible = (_task_progress_active or _task_completion_hold > 0.0) and not is_offer and not _retired and not is_meeting_participant() and not _strike_participant
	_render_debug_timer()
	# Logical clocks and Debug stay current on every card. The large majority
	# have no visible bar; upload its latest appearance only when it is shown.
	if not _task_progress.visible or not _task_progress_frame.visible: return
	_task_progress_material.set_shader_parameter("progress", task_progress_display_value())
	var color_key: String = str(spec.phase_colors.get(_task_progress_phase, spec.fill_color))
	if _task_progress_paused: color_key = str(spec.paused_color)
	_task_progress_material.set_shader_parameter("fill_color", Palette.semantic(color_key))

func task_progress_display_value() -> float:
	if _task_progress_material == null: return 0.0
	# Inspection must read the true display value, even while the hidden
	# surface deliberately retains its last uploaded shader parameters.
	var reverse_phases: Array = OffWorkUI.section("task_progress").get("reverse_phases", {}).get(type, [])
	if _task_completion_hold > 0.0: return 1.0
	return 1.0 - _task_progress_value if _task_progress_phase in reverse_phases else _task_progress_value

func _refresh_task_progress_palette() -> void:
	if _task_progress == null: return
	var spec := OffWorkUI.section("task_progress")
	_task_progress_material.set_shader_parameter("frame_color", Palette.semantic(str(spec.frame_color)))
	_task_progress_material.set_shader_parameter("track_color", Palette.semantic(str(spec.track_color)))
	_render_task_progress()

func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat

func _refresh_role_identity(next_type: String) -> void:
	# An upgrade changes the existing person, never replaces its physics body,
	# pointer identity, stack entry or task-progress surface.
	_stop_hover_animation()
	type = next_type
	def_id = next_type
	definition = OffWorkCardDB.get_def(next_type)
	label.text = str(definition.name)
	label.pixel_size = _text_scale(200)
	_fit_label_in_band(label, CardArt.band_frac(def_id) * CARD_SIZE.z)
	_fit_label(label, CARD_SIZE.x * (1112.0 / CARD_ART_SIZE.x))
	TitleInk.apply(def_id, label, _feedback_material())
	var icon := CardArt.illustration_texture(next_type, OffWorkCardDB)
	if icon == null: icon = CardArt.icon_texture(next_type, OffWorkCardDB)
	if _icon != null and icon != null:
		var width := float(_icon.texture.get_width()) * _icon.pixel_size
		_icon.texture = icon
		_icon.pixel_size = width / float(icon.get_width())
		_hover_original = icon
		_hover_pixel_size = _icon.pixel_size
		_center_illustration()
	_prepare_illustration_motion()
	refresh_palette()

func _build_upgrade_fx() -> void:
	_upgrade_ring = MeshInstance3D.new()
	_upgrade_ring.name = "UpgradeRing"
	var ring := TorusMesh.new()
	ring.inner_radius = OffWorkUI.number("upgrade", "ring_inner_radius")
	ring.outer_radius = OffWorkUI.number("upgrade", "ring_outer_radius")
	_upgrade_ring.mesh = ring
	var material := _flat(Palette.semantic(str(OffWorkUI.section("upgrade").color)))
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = false
	_upgrade_ring.material_override = material
	_upgrade_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_upgrade_ring.position = Vector3(0, OffWorkUI.number("upgrade", "ring_y"), OffWorkUI.number("upgrade", "ring_z"))
	_realtime.add_child(_upgrade_ring)
	_upgrade_ring.hide()

func _update_upgrade_fx() -> void:
	if _upgrade_ring == null or not _upgrade_visual_active: return
	_upgrade_ring.visible = _upgrade_remaining > 0.0 and not _retired and not is_offer
	var progress := 1.0 - _upgrade_remaining / OffWorkUI.number("upgrade", "duration_seconds")
	var strength := sin(clampf(progress, 0.0, 1.0) * PI) if _upgrade_remaining > 0.0 else 0.0
	var ring_scale := lerpf(OffWorkUI.number("upgrade", "ring_start_scale"), OffWorkUI.number("upgrade", "ring_end_scale"), progress)
	_upgrade_ring.scale = Vector3(ring_scale, 1.0, ring_scale)
	var color := Palette.semantic(str(OffWorkUI.section("upgrade").color))
	color.a = strength * OffWorkUI.number("upgrade", "ring_peak_alpha")
	(_upgrade_ring.material_override as StandardMaterial3D).albedo_color = color
	_icon.scale = Vector3.ONE * (1.0 + strength * OffWorkUI.number("upgrade", "body_scale_kick"))
	_icon.position.z = _frac_to_z(OffWorkUI.number("frame", "art_cy")) - strength * OffWorkUI.number("upgrade", "body_kick_z")
	if _upgrade_remaining <= 0.0: _upgrade_visual_active = false

func update_record(data: Dictionary) -> void:
	if str(data.type) != type: _refresh_role_identity(str(data.type))
	record = data
	card_owner = int(data.get("owner", 0))
	group_id = int(data.get("group", -1))
	var status := str(data.get("status", "ready"))
	var activity := str(data.get("activity", "idle"))
	var paused := bool(data.get("paused", false))
	var progress := clampf(float(data.get("progress", 0.0)), 0.0, 1.0)
	var idle_material := type in ["work", "money"] and status == "ready" and activity == "idle" and not paused
	if idle_material and _material_record_visuals_current:
		# Work records retain their group's batch fraction for rule continuity;
		# it is not an intrinsic visible timer on every sheet.
		_task_progress_value = progress
		return
	set_strike_participant(status == "striking" or activity == "striking")
	var task_active := activity in ["transfer", "slack", "meeting", "coffee", "recruitment"] or (activity == "work" and _can_work())
	set_task_progress(progress, _is_person() and task_active and activity not in ["work", "transfer", "slack"], paused, activity)
	if type in ["meeting", "transfer", "coffee", "slack", "outsource"]:
		var total := float(data.get("total", 0.0))
		if total > 0.0:
			progress = clampf(1.0 - float(data.get("remaining", 0.0)) / total, 0.0, 1.0)
		elif status == "ready":
			progress = 0.0
	if has_dedicated_progress():
		var timers: Dictionary = OffWorkUI.section("task_progress").dedicated_cards[type]
		var phase: String = str(timers.get(status, ""))
		set_task_progress(progress, not phase.is_empty() and float(data.get("total", 0.0)) > 0.0, paused, phase)
	if _icon != null:
		_icon.modulate = Color.WHITE.darkened((1.0 - progress) * OffWorkUI.number("animation", "recovery_dim")) if status == "recovering" else Color.WHITE
	_update_upgrade_fx()
	_material_record_visuals_current = idle_material

func uses_continuous_animation() -> bool:
	return OffWorkIconMotion.enabled(type)

func illustration_profile() -> String:
	return OffWorkIconMotion.profile_key(type, "striking" if _strike_participant else "")

func illustration_duration() -> float:
	return OffWorkIconMotion.duration(illustration_profile())

func illustration_sample_fps() -> float:
	return OffWorkIconMotion.sample_fps()

func illustration_sample_count() -> int:
	return OffWorkIconMotion.sample_count(illustration_profile())

func illustration_time() -> float:
	return _motion_time

func illustration_ready() -> bool:
	return uses_continuous_animation() and _icon != null and _icon.texture != null and _motion_material != null

func _prepare_illustration_motion() -> void:
	if not uses_continuous_animation() or _icon == null: return
	_motion_material = OffWorkIconMotion.make_material(illustration_profile())
	hover_animation_duration = illustration_duration()
	_motion_time = 0.0
	_hover_elapsed = 0.0
	_hover_frame = 0
	_hover_frames.clear()
	CardArt.release_hover_frames(_art_id, get_instance_id())
	_sync_illustration_material()

func _sync_illustration_material() -> void:
	if _motion_material == null or _icon == null: return
	# Keep the original sprite alive for all original transforms, face masking,
	# stamps, dimming and exit tweens. Only its sampling material is adapted.
	if _icon.texture != _hover_original: _icon.texture = _hover_original
	if _icon.material_override != _motion_material: _icon.material_override = _motion_material
	var tint := _icon.modulate
	# Hundreds of idle/covered cards have the same appearance across frames.
	# Keep clocks advancing, but do not repeat profile/metadata/material work
	# unless an input changed. Material identity also invalidates new roles.
	if _motion_synced_material == _motion_material and _motion_synced_texture == _hover_original \
		and _motion_synced_type == type and _motion_synced_striking == _strike_participant \
		and _motion_synced_time == _motion_time and _motion_synced_tint == tint:
		return
	OffWorkIconMotion.sync_material(_motion_material, illustration_profile(), _hover_original, _motion_time, tint)
	_motion_synced_material = _motion_material
	_motion_synced_texture = _hover_original
	_motion_synced_type = type
	_motion_synced_striking = _strike_participant
	_motion_synced_time = _motion_time
	_motion_synced_tint = tint

func make_illustration_preview_material() -> ShaderMaterial:
	var material := OffWorkIconMotion.make_material(illustration_profile(), true)
	sync_illustration_preview_material(material)
	return material

func sync_illustration_preview_material(material: ShaderMaterial) -> void:
	if _icon == null: return
	OffWorkIconMotion.sync_material(material, illustration_profile(), _hover_original, _motion_time, _icon.modulate)

func hover_animation_time() -> float:
	if uses_continuous_animation(): return fposmod(_hover_elapsed, illustration_duration())
	return super.hover_animation_time()

func seek_hover_animation(seconds: float) -> void:
	if not uses_continuous_animation():
		super.seek_hover_animation(seconds)
		return
	_set_illustration_time(seconds)
	_sync_illustration_material()

func _set_illustration_time(seconds: float) -> void:
	_motion_time = clampf(seconds, 0.0, illustration_duration())
	_hover_elapsed = _motion_time
	# This index is for inspecting samples. Rendering never snaps time to it.
	_hover_frame = clampi(floori(_motion_time * illustration_sample_fps() + 0.00001), 0, illustration_sample_count() - 1)

func _stop_hover_animation() -> void:
	_animation_running = false
	super._stop_hover_animation()
	_motion_time = 0.0
	_sync_illustration_material()
	set_process(true)

func set_hover_visual(on: bool, lift_allowed := true) -> void:
	if not uses_continuous_animation():
		super.set_hover_visual(on, lift_allowed)
		return
	var preserve := illustration_is_active() and _animation_running
	var elapsed := _hover_elapsed
	var motion_time := _motion_time
	# The original routine owns lift, pointer state and price-tag interaction.
	# Temporarily omit only the icon so it cannot request legacy hdelta poses;
	# no copied UI logic and no background decoding of an unused sequence.
	var icon := _icon
	_icon = null
	super.set_hover_visual(on, lift_allowed)
	_icon = icon
	if preserve and not _visual_dragging and not _visual_retired:
		_hover_elapsed = elapsed
		_motion_time = motion_time
		_hover_frame = clampi(floori(_motion_time * illustration_sample_fps() + 0.00001), 0, illustration_sample_count() - 1)
		_animation_running = true
	elif on and not _visual_dragging and not _visual_retired and not _face_down:
		_animation_running = true
	_sync_illustration_material()
	set_process(true)

func set_hovered(on: bool) -> void:
	set_hover_visual(on)

func set_drag_visual(on: bool) -> void:
	# Handling may move the card, but does not restart or stop the person dancing
	# inside it. Only the inherited pickup/lift channel owns the frame's pose.
	var elapsed := _hover_elapsed
	var seconds := _motion_time
	super.set_drag_visual(on)
	if _strike_participant and not _retired and not _visual_retired:
		_hover_elapsed = elapsed
		_motion_time = seconds
		_animation_running = true
		_sync_illustration_material()

func update_drag_motion(velocity: Vector3, delta: float) -> void:
	# Board still moves every real collider/UID. Covered material has no visible
	# tilt to update, and keeps the same pickup/landing animation when exposed.
	if type in ["work", "money"] and (face_deferred or not _visual.visible): return
	super.update_drag_motion(velocity, delta)

func pulse_landed() -> void:
	var elapsed := _hover_elapsed
	var seconds := _motion_time
	super.pulse_landed()
	if _strike_participant and not _retired and not _visual_retired:
		_hover_elapsed = elapsed
		_motion_time = seconds
		_animation_running = true
		_sync_illustration_material()

func tear_apart() -> Array:
	set_strike_participant(false)
	return super.tear_apart()

func set_selected(on: bool) -> void:
	selected = on
	set_highlight(on, Palette.semantic("focus"))

func move_to(at: Vector3, _immediate := false) -> void:
	target = at
	position = at

func _process(delta: float) -> void:
	if face_deferred:
		set_process(false)
		return
	if type in ["work", "money"] and not _visual.visible:
		set_process(false)
		return
	_advance_illustration(delta)
	_sync_illustration_material()
	set_process(true)
	if _visual == null or _retired or _visual_retired:
		return
	_elapsed += delta
	_upgrade_remaining = maxf(0.0, _upgrade_remaining - delta)
	_update_upgrade_fx()
	if _task_completion_hold > 0.0:
		_task_completion_hold = maxf(0.0, _task_completion_hold - delta)
		_render_task_progress()

func _can_work() -> bool:
	return str(record.get("activity", "idle")) == "work" or bool(OffWorkCardDB.role_rules().get(type, {}).get("can_work", true))

## One immutable GPT master and continuous sampling map, shared by the real
## card, hover interaction and the independent animation viewer.
func illustration_is_active() -> bool:
	if is_offer or _retired: return false
	if _is_person():
		var activity := str(record.get("activity", "idle"))
		if _strike_participant: return true
		var activities: Array = OffWorkUI.section("animation").person_task_activities.get(type, [])
		# Only genuine activities animate automatically; idle portraits remain
		# still while their real task progress may still be shown.
		return activity in activities and (activity != "work" or _can_work())
	if has_dedicated_progress(): return str(record.get("status", "ready")) == "active"
	return _task_progress_active or str(record.get("status", "ready")) == "active"

func _advance_illustration(delta: float) -> void:
	if _icon == null or _retired or _visual_retired or (_visual_dragging and not _strike_participant) or _face_down:
		if _animation_running: _stop_hover_animation()
		return
	var automatic := illustration_is_active()
	if not automatic and not _visual_hovered:
		if _animation_running: _stop_hover_animation()
		return
	if not illustration_ready(): return
	_animation_running = true
	# Explicit time freezes with a meeting or the drawer's SceneTree pause.
	# No TIME uniform and no floor(time*fps): every render tick has a new pose.
	if hover_animation_paused or ((bool(record.get("paused", false)) or _task_progress_paused) and not _strike_participant): return
	var speed := _configured_hover_speed()
	if automatic:
		speed = OffWorkUI.number("animation", "task_playback_speed") * clampf(
			float(record.get("rate_multiplier", 1.0)), 1.0, OffWorkUI.number("animation", "motion_speed_scale_max"))
	_hover_elapsed += delta * hover_animation_speed * speed
	# _process synchronizes once after advancing, including inherited fades.
	# Explicit seeks still upload immediately through seek_hover_animation.
	_set_illustration_time(hover_animation_time())

func play_event(kind: String) -> void:
	if kind == "win":
		leave()
		return
	if kind == "coffee_upgrade":
		_upgrade_remaining = OffWorkUI.number("upgrade", "duration_seconds")
		_upgrade_visual_active = true
		pulse_feedback("upgrade", Palette.semantic(str(OffWorkUI.section("upgrade").color)))
		_reset_art_motion()
		flash_stamp(str(definition.get("name", OffWorkUI.section("upgrade").stamp_word)), OffWorkUI.number("upgrade", "stamp_seconds"))
		_update_upgrade_fx()
		return
	if kind in ["work_complete", "completed"]: flash_task_completion()
	pulse_feedback("attack" if kind in ["meeting_start", "strike"] else "produce")
	# The top work face now releases its file illustration as a real paper
	# ball. A completion stamp over that same icon obscures the whole fold.
	if kind in ["work_complete", "completed", "strike", "meeting_start"] and not (kind == "work_complete" and def_id == "work"):
		var word_key := "strike_word" if kind == "strike" else ("meeting_word" if kind == "meeting_start" else "stamp_word")
		flash_stamp(str(OffWorkUI.section("rig")[word_key]), OffWorkUI.number("interaction", "pulse_duration"))
func _ensure_stamp() -> void:
	if is_instance_valid(_void_stamp): return
	# A mark printed on this sheet keeps its depth during the squash animation.
	# A small raster bias avoids flicker against its own paper.
	_stamp_parts = InkStamp.build(_ensure_visual(), Vector3(0, Y_PLATE + 0.0005, 0.08),
		"作废", InkStamp.CARD_WIDTH, 2, true)
	_void_stamp = _stamp_parts.mesh

func leave(clearance_x := 0.0) -> void:
	if not _is_person() or _retired: return
	set_strike_participant(false)
	_retired = true
	_upgrade_remaining = 0.0
	_upgrade_visual_active = false
	# Retire the whole illustrated card. Moving only the portrait left an empty
	# frame behind throughout the result screen. Keep every face layer together.
	var departure_pose := _visual.transform
	reset_interaction_visual()
	_visual.transform = departure_pose
	draggable = false
	input_ray_pickable = false
	collision_layer = 0
	collision_mask = 0
	freeze = true
	if _upgrade_ring != null: _upgrade_ring.hide()
	_task_completion_hold = 0.0
	set_task_progress(0.0, false)
	# The original slam deliberately renders above neighboring cards. At the
	# end of a closed stack that looks like penetration, so reveal this same
	# ink only after extraction, resting on its own face with depth testing.
	_ensure_stamp()
	if _stamp_tween != null and _stamp_tween.is_valid(): _stamp_tween.kill()
	_stamp_flash_on = true
	_set_stamp_text(str(OffWorkUI.section("animation").leave_stamp))
	_refresh_overlay_colors()
	_void_stamp.position = _void_stamp.get_meta("stamp_rest")
	_void_stamp.scale = Vector3.ONE
	InkStamp.set_alpha(_stamp_parts, 1.0)
	_void_stamp.hide()
	_visual_retired = true
	var duration := OffWorkUI.number("animation", "leave_duration")
	# First pull the whole frame sideways at its existing layer height. A card
	# buried under tools cannot rise directly through the cards above it.
	if is_zero_approx(clearance_x): clearance_x = CARD_SIZE.x + OffWorkUI.number("animation", "leave_clearance_padding")
	var clear_position := _visual.position + global_basis.inverse() * Vector3(clearance_x, 0.0, 0.0)
	var destination := clear_position + Vector3(0.0, OffWorkUI.number("animation", "leave_height"), OffWorkUI.number("animation", "leave_distance"))
	var start_scale := _visual.scale
	_leave_tween = create_tween()
	_leave_tween.tween_interval(OffWorkUI.number("animation", "leave_anticipation"))
	_leave_tween.tween_property(_visual, "position", clear_position, OffWorkUI.number("animation", "leave_clearance_duration")).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_leave_tween.parallel().tween_property(_visual, "scale", start_scale * OffWorkUI.number("animation", "leave_clearance_scale"), OffWorkUI.number("animation", "leave_clearance_duration")).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_leave_tween.tween_callback(_void_stamp.show)
	_leave_tween.tween_property(_visual, "position", destination, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_leave_tween.parallel().tween_property(_visual, "scale", start_scale * OffWorkUI.number("animation", "leave_scale"), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_leave_tween.parallel().tween_property(_visual, "rotation_degrees:y", _visual.rotation_degrees.y + OffWorkUI.number("animation", "leave_tilt_degrees"), duration)
	_leave_tween.tween_callback(hide)

func _exit_tree() -> void:
	if _leave_tween != null and _leave_tween.is_valid(): _leave_tween.kill()
	super._exit_tree()

func impact() -> void:
	if not dragging and not _retired:
		pulse_landed()

func recipe_status_text() -> String:
	var words := OffWorkUI.section("card_status")
	if _is_person():
		if str(record.get("activity", "idle")) == "striking": return str(words.striking)
		return str(words.get("paused" if bool(record.get("paused", false)) else str(record.get("activity", "idle")), ""))
	if has_dedicated_progress():
		if bool(record.get("paused", false)): return str(words.paused)
		return str(OffWorkUI.section("timer_status")[type].get(str(record.get("status", "ready")), ""))
	return str(definition.get("description", ""))

func set_recipe_progress(have: int, done: bool) -> void:
	# Preserve the original Board call protocol without recreating face badges.
	_recipe_have = have
	_recipe_done = done

func refresh_palette() -> void:
	if face_deferred: return # The face reads the current palette on first exposure.
	super.refresh_palette()
	_refresh_task_progress_palette()
	_sync_illustration_material()

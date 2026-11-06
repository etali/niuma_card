extends Node3D

## Presentation-only conveyor. The simulation owns offers; one carrier keeps
## the groove, seam and offer on the same trajectory even when bought empty.
const Surface = preload("res://scenes/table_surface.gd")
const Regions = preload("res://scenes/table_regions.gd")

var board: WorkBoard
var spec: Dictionary
var carriers: Array[Node3D] = []
var departing: Array[Node3D] = []
var _motions: Dictionary = {}
var _exiting: Dictionary = {}
var _last_supply := -1
var _count := 0
var _pitch := 0.0
var _left := 0.0
var _right := 0.0
var _belt: MeshInstance3D
var _rails: Array[MeshInstance3D] = []

func setup(presenter: WorkBoard, host: Node3D) -> void:
	board = presenter
	spec = board._settings.conveyor_visual
	_count = int(WorkCardDB.game_rules().market_size)
	_pitch = Regions.market_gap(_count)
	_left = Regions.market_slot(0, _count, board.drawer_mode).x - _pitch * 0.5
	_right = Regions.market_slot(_count - 1, _count, board.drawer_mode).x + _pitch * 0.5
	for index in _count:
		var old := host.get_node_or_null("MarketSlot_%d" % index)
		if old != null: old.hide()
	var former_tray := host.get_node_or_null("TableSurface_market")
	if former_tray != null: former_tray.hide()
	_build_belt()
	Palette.bus().changed.connect(_refresh_palette)
	process_priority = 50
	board.conveyor = self

func _build_belt() -> void:
	var region := Regions.market_rect(_count, board.drawer_mode)
	_belt = Surface.new()
	_belt.configure(Vector2(_right - _left, region.size.y), "market")
	_belt.name = "ConveyorBelt"
	_belt.position = Vector3((_left + _right) * 0.5, float(spec.belt_height), region.get_center().y)
	add_child(_belt)
	_belt._surface_material.set_shader_parameter("folded", false)
	# Keep the dismissal bay on the original cream paper beside the moving
	# belt, without drawing the old full-row tray over the conveyor surface.
	var bay := Surface.new()
	bay.configure(Vector2(region.end.x - _right, region.size.y), "market")
	bay.name = "DismissalBay"
	bay.position = Vector3((_right + region.end.x) * 0.5, float(spec.belt_height), region.get_center().y)
	add_child(bay)
	for z in [region.position.y, region.end.y]:
		var rail := Surface.new()
		rail.configure(Vector2(_right - _left, float(spec.rail_width)), "divider")
		rail.position = Vector3((_left + _right) * 0.5, float(spec.rail_height), z)
		add_child(rail)
		_rails.append(rail)
	for x in [_left, _right]:
		var roller := Surface.new()
		roller.configure(Vector2(float(spec.end_width), region.size.y), "divider")
		roller.position = Vector3(x, float(spec.rail_height), region.get_center().y)
		add_child(roller)
		_rails.append(roller)
	_refresh_palette()

func _refresh_palette(_section := "", _key := "", _color := Color.WHITE) -> void:
	var ink := Palette.get_color("card", "frame")
	var paper := Palette.get_color("world", "table_frame")
	var felt := Palette.get_color("world", "table_felt")
	_belt._surface_material.set_shader_parameter("fill_color", felt.lerp(paper, float(spec.belt_paper_mix)))
	_belt._surface_material.set_shader_parameter("edge_color", ink)
	for rail in _rails:
		rail._surface_material.set_shader_parameter("fill_color", paper.lerp(ink, float(spec.rail_ink_mix)))
		rail._surface_material.set_shader_parameter("edge_color", ink)

func _new_carrier(index: int, at: Vector3) -> Node3D:
	var carrier := Node3D.new()
	carrier.name = "ConveyorCarrier"
	add_child(carrier)
	carrier.position = at
	carrier.set_meta("offer_id", -1)
	carrier.set_meta("card", null)
	carrier.set_meta("index", index)
	var frame := Surface.new()
	frame.configure(Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), "slot", CardArt.table_texture("market_slot"))
	frame.name = "MovingGroove"
	frame.position.y = CardEntity.Y_PLATE - float(spec.slot_below_card)
	carrier.add_child(frame)
	var seam := Surface.new()
	seam.configure(Vector2(float(spec.seam_width), Regions.MARKET_DEPTH - float(spec.seam_inset)), "divider")
	seam.name = "BeltSeam"
	seam.position = Vector3(-_pitch * 0.5, float(spec.seam_height) - at.y, Regions.MARKET_LABEL_OFFSET)
	carrier.add_child(seam)
	var arrow := Label3D.new()
	arrow.name = "LeftwardMark"
	arrow.text = str(spec.direction_mark)
	arrow.font = Fonts.zh()
	arrow.font_size = int(spec.mark_font_size)
	arrow.pixel_size = float(spec.mark_pixel_size)
	arrow.modulate = Palette.get_color("card", "frame")
	arrow.outline_size = 0
	arrow.rotation_degrees.x = -90.0
	arrow.position = Vector3(-_pitch * 0.5 + float(spec.mark_inset), float(spec.seam_height) - at.y, float(spec.mark_z))
	carrier.add_child(arrow)
	return carrier

func sync_market(offers: Array, supply: int) -> void:
	if carriers.is_empty() or supply < _last_supply:
		reset()
		for index in offers.size():
			carriers.append(_new_carrier(index, Regions.market_slot(index, offers.size(), board.drawer_mode)))
		_last_supply = supply
	else:
		var steps := maxi(0, supply - _last_supply)
		if steps > 0:
			for old in departing.duplicate():
				var destination: Vector3 = old.get_meta("destination", old.global_position)
				_move_carrier(old, destination - Vector3(_pitch * steps, 0, 0), true)
		for _step in steps:
			var tail: Vector3 = carriers.back().global_position + Vector3(_pitch, 0, 0)
			var old: Node3D = carriers.pop_front()
			departing.append(old)
			var old_id := int(old.get_meta("offer_id", -1))
			if old_id >= 0: _exiting[old_id] = old
			_move_carrier(old, Regions.market_slot(_step - steps, offers.size(), board.drawer_mode), true)
			carriers.append(_new_carrier(offers.size() - 1, tail))
		if steps > 0:
			for index in carriers.size():
				_move_carrier(carriers[index], Regions.market_slot(index, offers.size(), board.drawer_mode))
		_last_supply = supply
	for index in carriers.size():
		var id := int(offers[index].id) if not offers[index].is_empty() else -1
		var carrier := carriers[index]
		carrier.set_meta("index", index)
		if id != int(carrier.get_meta("offer_id", -1)):
			carrier.set_meta("offer_id", id)
			carrier.set_meta("card", null)
		_apply_carrier(carrier)

func attach_offer(id: int, card: CardEntity, index: int) -> void:
	var carrier := carriers[index]
	carrier.set_meta("offer_id", id)
	carrier.set_meta("card", weakref(card))
	if not card.has_meta("conveyor_geometry"):
		card.set_meta("conveyor_geometry", card.find_children("*", "GeometryInstance3D", true, false))
		card.set_meta("conveyor_collision", [card.collision_layer, card.collision_mask, card.input_ray_pickable])
	_apply_carrier(carrier)

func position_for_slot(index: int) -> Vector3:
	return carriers[index].global_position

func release_offer(id: int, card: CardEntity) -> bool:
	if not _exiting.has(id): return false
	var carrier: Node3D = _exiting[id]
	card.collision_layer = 0
	card.collision_mask = 0
	card.input_ray_pickable = false
	card.draggable = false
	card.set_meta("conveyor_retiring", true)
	carrier.set_meta("card", weakref(card))
	carrier.set_meta("retire_card", true)
	_apply_carrier(carrier)
	return true

func _move_carrier(carrier: Node3D, destination: Vector3, retire := false) -> void:
	if _motions.has(carrier): _motions[carrier].kill()
	carrier.set_meta("destination", destination)
	var motion := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_motions[carrier] = motion
	motion.tween_method(_set_position.bind(carrier), carrier.global_position, destination, float(board._settings.market_move_seconds))
	motion.tween_callback(func():
		_motions.erase(carrier)
		if retire: _finish_departure(carrier))

func _set_position(at: Vector3, carrier: Node3D) -> void:
	if not is_instance_valid(carrier): return
	carrier.global_position = at
	_apply_carrier(carrier)

func _card_of(carrier: Node3D) -> CardEntity:
	if not carrier.has_meta("card"): return null
	var reference: Variant = carrier.get_meta("card")
	return reference.get_ref() if reference is WeakRef else null

func _opacity(at: Vector3) -> float:
	# Keep the WHOLE card and price label before the dismissal entrance. A
	# partly visible incoming card must never cover that independent facility.
	var half := CardEntity.CARD_SIZE.x * 0.5 + float(spec.end_card_margin)
	var left := _left + half
	var right := _right - half
	return clampf(minf(at.x - left, right - at.x) / float(spec.edge_fade_width), 0.0, 1.0)

func _apply_carrier(carrier: Node3D) -> void:
	var opacity := _opacity(carrier.global_position)
	carrier.visible = opacity > 0.0
	for child in carrier.get_children():
		if child is MeshInstance3D: child._surface_material.set_shader_parameter("opacity", opacity)
		elif child is GeometryInstance3D: child.transparency = 1.0 - opacity
	var card := _card_of(carrier)
	if not is_instance_valid(card): return
	if card.dragging or (board._press_snap.get("card") == card and not board._press_snap.get("price_tag", false)):
		_set_card_opacity(card, 1.0)
		return
	card.global_position = carrier.global_position
	_set_card_opacity(card, opacity)

func _set_card_opacity(card: CardEntity, opacity: float) -> void:
	card.visible = opacity > 0.0
	var interactive := card.visible and not bool(card.get_meta("conveyor_retiring", false))
	var collision: Array = card.get_meta("conveyor_collision", [0, 0, false])
	card.collision_layer = int(collision[0]) if interactive else 0
	card.collision_mask = int(collision[1]) if interactive else 0
	card.input_ray_pickable = bool(collision[2]) and interactive
	for item in card.get_meta("conveyor_geometry", []):
		if is_instance_valid(item): item.transparency = 1.0 - opacity

func _process(_delta: float) -> void:
	if board._state != null and board._state.winner != -1:
		for motion in _motions.values(): motion.pause()
	for carrier in carriers + departing:
		if is_instance_valid(carrier): _apply_carrier(carrier)

func _finish_departure(carrier: Node3D) -> void:
	if not is_instance_valid(carrier): return
	var id := int(carrier.get_meta("offer_id", -1))
	if _exiting.get(id) == carrier: _exiting.erase(id)
	var card := _card_of(carrier)
	if is_instance_valid(card) and bool(carrier.get_meta("retire_card", false)): card.queue_free()
	departing.erase(carrier)
	carrier.queue_free()

func reset() -> void:
	for motion in _motions.values(): motion.kill()
	_motions.clear()
	for carrier in departing.duplicate(): _finish_departure(carrier)
	for carrier in carriers:
		if is_instance_valid(carrier):
			carrier.hide()
			carrier.queue_free()
	carriers.clear()
	departing.clear()
	_exiting.clear()
	_last_supply = -1

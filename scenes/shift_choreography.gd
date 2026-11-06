# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted
## 换班只移动画面。牌局拥有的刚体、组内次序和计时器始终留在原处。
const Surface = preload("res://scenes/table_surface.gd")
const PriceTag = preload("res://scenes/market_price_tag.gd")
const Deck = preload("res://scenes/shift_deck.gd")
const STACK := Vector3(0, 0.57, 0.38)
const VISIBLE_SHEETS := 8

var faces: Array[Node3D] = []
var resting: Array[Transform3D] = []
var mats: Array[MeshInstance3D] = []
var trim: Array[Node3D] = []
var boards: Array[Board] = []
var deck: Deck
var layer_step: float
var depth: float

func capture(game: Node3D, carried: Deck = null) -> void:
	for child in game.get_children():
		if child is Node3D: _collect(child)
	# Preserve top/bottom order as existing piles leave the table. Traversal
	# order can put the lowest material above the tool that was covering it.
	faces.sort_custom(func(a: Node3D, b: Node3D):
		if a.global_position.y == b.global_position.y:
			return a.get_instance_id() < b.get_instance_id()
		return a.global_position.y < b.global_position.y)
	var facility := game.get_node_or_null("MarketFacility") as Node3D
	if facility and facility.is_visible_in_tree():
		faces.push_front(facility)
		var action := facility.get_node_or_null("FacilityAction")
		if action and action.is_visible_in_tree(): trim.append(action)
	for face in faces: resting.append(face.transform)
	var gaps := maxi(1, faces.size() - 1)
	depth = Board.COMPACT_GAP.y * mini(gaps, VISIBLE_SHEETS - 1)
	layer_step = depth / gaps
	var cover: Node3D
	if not faces.is_empty():
		# Copy a visual branch only. Its original can return to its parked match.
		cover = faces.back().duplicate(0) as Node3D
		cover.transform = Transform3D.IDENTITY
	if carried:
		deck = carried
		deck.reparent(game, false)
		deck.set_reverse(cover, depth)
	else:
		deck = Deck.new()
		game.add_child(deck)
		deck.setup(cover, depth, faces.size())
	deck.position = STACK

func _collect(node: Node3D) -> void:
	if not node.is_visible_in_tree() or node.is_queued_for_deletion(): return
	if node.has_meta("motion_event") or (node is CardEntity and node._visual_retired):
		trim.append(node)
		return
	if node is CardEntity:
		if node._visual and node._visual.is_visible_in_tree(): faces.append(node._visual)
		for child in node.get_children():
			if child is PriceTag and child.is_visible_in_tree(): trim.append(child)
		return
	if node is Board: boards.append(node)
	if node is Surface:
		if node._role in ["zone", "market"]: mats.append(node)
		else: trim.append(node)
		return
	if node is PriceTag or node is TableLighting or node.name == "LeftwardMark":
		trim.append(node)
		return
	if node.name == "MarketFacility": return
	for child in node.get_children():
		if child is Node3D: _collect(child)

func pose(gather: float, roll: float) -> void:
	# Separate the flight planes before the cards slide across one another.
	# A large deck compresses each card's *whole* visual height, including ink;
	# compressing only the distance between cards lets their icons intersect.
	var lift := smoothstep(0.0, 0.24, gather)
	var slide := smoothstep(0.14, 1.0, gather)
	var paper_scale := lerpf(1.0, layer_step / Board.COMPACT_GAP.y, lift)
	var packed := slide >= 0.9999
	deck.visible = packed and not faces.is_empty()
	for i in faces.size():
		var face := faces[i]
		if not is_instance_valid(face): continue
		face.visible = not packed
		if packed: continue
		var rest := face.get_parent_node_3d().global_transform * resting[i]
		var target := Transform3D(Basis.IDENTITY, STACK)
		var moving := rest.interpolate_with(target, slide)
		moving.basis = moving.basis.scaled_local(Vector3(1.0, paper_scale, 1.0))
		moving.origin.y += i * layer_step * lift - depth * 0.5 * slide + sin(PI * slide) * 0.48
		face.global_transform = moving
	for mat in mats:
		if is_instance_valid(mat): mat.set_shift_roll(roll)
	for item in trim:
		if is_instance_valid(item): item.visible = gather < 0.2
	for board in boards:
		if is_instance_valid(board): board.set_shift_gather(gather)

func restore() -> void:
	deck.hide()
	for i in faces.size():
		if is_instance_valid(faces[i]):
			faces[i].transform = resting[i]
			faces[i].show()
	for mat in mats:
		if is_instance_valid(mat): mat.set_shift_roll(0.0)
	for item in trim:
		if is_instance_valid(item): item.show()
	for board in boards:
		if is_instance_valid(board): board.set_shift_gather(0.0)

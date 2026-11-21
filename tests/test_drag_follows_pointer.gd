# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 拖着牌走：指针一直压在抓住的那一点上，牌落在画面上它所在的地方。
##
## 镜头是透视的。直着把牌抬到拖拽高度，它的画面会往桌子外侧滑，滑多少取决于在哪儿拎起来
## （桌边最多三分之二张牌），而且这个偏差一路带着走：在桌子左边拎起、拖到右边，指针和牌
## 就不在一处了，松手后牌还会再滑一次。现在牌沿视线抬起、沿视线放下（Board.along_view）。
var board: Board
var camera: Camera3D
var host: Node3D
var pointer := Vector2.ZERO

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
	host = Node3D.new()
	root.add_child(host)
	camera = Camera3D.new()
	host.add_child(camera)
	# The table camera: tilted, 44° field of view.
	camera.fov = 44.0
	camera.position = Vector3(0.0, 16.25, 5.52)
	camera.rotation_degrees = Vector3(-74.0, 0.0, 0.0)
	camera.current = true
	# A table top for loose cards to rest on once they go back to physics.
	var table := StaticBody3D.new()
	var top := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(60.0, 1.0, 60.0)
	top.shape = slab
	table.add_child(top)
	host.add_child(table)
	table.position = Vector3(0.0, -0.5, 0.0)
	board = Board.new()
	host.add_child(board)
	board.camera = camera
	board.touch_mode = true
	await process_frame
	_along_view()
	await _held_card_stays_under_the_pointer()
	await _lands_where_it_is_shown()
	await _picked_up_and_put_down_in_place()
	await _pile_grabbed_by_its_top()
	host.queue_free()
	await process_frame
	finish()

func _card(at: Vector3) -> CardEntity:
	var card := CardEntity.new()
	card.setup(board.cards.size() + 1, OnWorkCardDB.unit_id(OnWorkCardDB.RES_CASH))
	host.add_child(card)
	card.global_position = at
	card.freeze = true
	board.register_card(card)
	return card

## Picking is a physics ray: a new body has to reach the physics space first.
func _physics() -> void:
	await physics_frame
	await physics_frame

func _screen(at: Vector3) -> Vector2:
	return camera.unproject_position(at)

func _button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)
	await process_frame

func _move(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = at
	root.push_input(event)
	await process_frame
	# The board places what is held in its own _process; give it this pointer.
	board._process(0.0)

func _along_view() -> void:
	var at := Vector3(-9.0, Board.REST_HEIGHT, 2.0)
	var lifted := board.along_view(at, Board.DRAG_HEIGHT)
	check(is_equal_approx(lifted.y, Board.DRAG_HEIGHT) and _screen(lifted).distance_to(_screen(at)) < 0.01,
		"沿视线抬起的点在画面上还是同一个位置")
	check(Vector2(lifted.x - at.x, lifted.z - at.z).length() > 0.4, "夹具：在桌子边上，直上直下和沿视线差着小半张牌（%.2f）" % Vector2(lifted.x - at.x, lifted.z - at.z).length())
	check(board.along_view(lifted, Board.REST_HEIGHT).distance_to(at) < 0.001, "放下是抬起的反过程，回到原处")
	var straight_up := Vector3(at.x, Board.DRAG_HEIGHT, at.z)
	check(_screen(straight_up).distance_to(_screen(at)) > 30.0, "直着抬起来，画面上要挪开几十个像素（%.0f）" % _screen(straight_up).distance_to(_screen(at)))

## Grabbed off-centre at the far left, carried to the far right and up the table: the pointer
## stays on the very point of the face that was grabbed.
func _held_card_stays_under_the_pointer() -> void:
	var card := _card(Vector3(-9.0, Board.REST_HEIGHT, 3.0))
	await _physics()
	var grip := Vector3(0.3, 0.0, -0.4)
	var press := _screen(card.global_position + grip)
	pointer = press
	await _button(press, true)
	await _move(press + Vector2(14, 0))
	check(not board._drag_cards.is_empty() and is_equal_approx(card.global_position.y, Board.DRAG_HEIGHT), "牌被拎到拖拽高度")
	var worst := 0.0
	var stops := [press + Vector2(14, 0), Vector2(press.x + 200, press.y - 60), _screen(Vector3(0.0, 0.0, 1.0)), _screen(Vector3(8.5, 0.0, -2.5)), _screen(Vector3(9.5, 0.0, 3.5))]
	for stop in stops:
		await _move(stop)
		# The grabbed point of the held face, in the picture.
		var grabbed := _screen(card.global_position + grip)
		worst = maxf(worst, grabbed.distance_to(pointer))
	# A raised card is drawn slightly larger, so an off-centre grip is a few pixels out; the
	# straight-up lift this replaces was out by sixty to a hundred and twenty.
	check(worst < 10.0, "从左边拎起、拖过整张桌子，指针离抓住的那一点始终不到 10 个像素（最远 %.1f）" % worst)
	check(_screen(board.drag_hand_point()).distance_to(pointer) < 0.5, "抓握手画在指针上")
	board.cancel_pointer()
	await _button(pointer, false)

func _lands_where_it_is_shown() -> void:
	var card := _card(Vector3(-8.0, Board.REST_HEIGHT, 0.0))
	await _physics()
	var press := _screen(card.global_position)
	pointer = press
	await _button(press, true)
	await _move(press + Vector2(14, 0))
	var to := _screen(Vector3(8.0, Board.REST_HEIGHT, 2.0))
	await _move(to)
	var shown := _screen(card.global_position)
	check(shown.distance_to(to) < 1.0, "抓着牌的正中拖到右边：牌的画面就在指针下（差 %.1f 像素）" % shown.distance_to(to))
	await _button(to, false)
	for item in board._move_tw.values():
		if item.tw != null and item.tw.is_valid(): item.tw.custom_step(1.0)
	# A loose card goes back to physics a little above its landing point and settles.
	for frame in 30: await physics_frame
	var rest := _screen(card.global_position)
	check(card.global_position.y <= Board.REST_HEIGHT + 0.001 and rest.distance_to(shown) < 3.0,
		"松手后牌落在画面上它原来所在的地方，不再横着滑一截（差 %.1f 像素）" % rest.distance_to(shown))
	check(Vector2(card.global_position.x - 8.0, card.global_position.z - 2.0).length() < 0.05, "也就是指针指着的桌面那一点")
	if card._drag_visual_tween != null and card._drag_visual_tween.is_valid(): card._drag_visual_tween.custom_step(1.0)
	check(card._visual.position.is_zero_approx(), "落桌动画把卡面收回到卡身上，不留偏移")

## A closed pile is grabbed by its top card, which is held above the drag plane by the pile's
## height. The pointer is followed at that card's own height, so it stays on the grabbed point
## all the way across the table, and the pile comes down where it is shown.
func _pile_grabbed_by_its_top() -> void:
	var members: Array = []
	for index in 6: members.append(_card(Vector3(-8.5, Board.REST_HEIGHT, 1.0)))
	var pile: Dictionary = board.make_group(members, true)
	board.groups.append(pile)
	board._layout_group(pile, Vector3(-8.5, Board.REST_HEIGHT, 1.0))
	for item in board._move_tw.values():
		if item.tw != null and item.tw.is_valid(): item.tw.custom_step(1.0)
	await _physics()
	var top: CardEntity = pile.cards[board._top_index(pile)]
	check(top.global_position.y > Board.REST_HEIGHT + 0.1, "夹具：摞顶比桌面高出一截（%.2f）" % top.global_position.y)
	var press := _screen(top.global_position)
	pointer = press
	await _button(press, true)
	await _move(press + Vector2(14, 0))
	check(board._drag_cards.size() == 6 and board._grab_card == top, "整摞被拎起，抓住的是摞顶那张")
	var worst := 0.0
	for stop in [press + Vector2(14, 0), _screen(Vector3(0.0, 0.0, 2.0)), _screen(Vector3(8.5, 0.0, -2.0)), _screen(Vector3(9.0, 0.0, 3.0))]:
		await _move(stop)
		worst = maxf(worst, _screen(top.global_position).distance_to(pointer))
	check(worst < 1.0, "抓着摞顶拖过整张桌子，摞顶的画面一直在指针下（最远 %.2f 像素）" % worst)
	var shown := _screen(top.global_position)
	await _button(pointer, false)
	for item in board._move_tw.values():
		if item.tw != null and item.tw.is_valid(): item.tw.custom_step(1.0)
	check(_screen(top.global_position).distance_to(shown) < 1.5 and absf(top.global_position.y - (Board.REST_HEIGHT + board._grab_lift)) < 0.01,
		"松手后整摞落在画面上它所在的地方，摞顶回到原来的高度（差 %.1f 像素）" % _screen(top.global_position).distance_to(shown))

func _picked_up_and_put_down_in_place() -> void:
	var home := Vector3(9.0, Board.REST_HEIGHT, -2.0)
	var card := _card(home)
	await _physics()
	var press := _screen(home)
	pointer = press
	await _button(press, true)
	await _move(press + Vector2(14, 0))
	await _move(press)
	await _button(press, false)
	for item in board._move_tw.values():
		if item.tw != null and item.tw.is_valid(): item.tw.custom_step(1.0)
	for frame in 30: await physics_frame
	check(Vector2(card.global_position.x - home.x, card.global_position.z - home.z).length() < 0.02 and card.global_position.y <= Board.REST_HEIGHT + 0.001,
		"在桌子边上拎起来又原地放下，牌回到原处（差 %.3f）" % Vector2(card.global_position.x - home.x, card.global_position.z - home.z).length())

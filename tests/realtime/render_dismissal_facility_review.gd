extends "res://tests/realtime/test_work_dismiss_zone.gd"

## Review the new artwork on the real table, then run the original Viewport
## dismissal suite (single/mixed personnel, invalid cards, refund and restart).
var _reviewed_art := false

func _restart() -> void:
	await super._restart()
	if _reviewed_art: return
	_reviewed_art = true
	var facility: Node3D = game.get_node("MarketFacility")
	var plate: MeshInstance3D = facility.get_node("PawnshopFacilityCard")
	var material := plate.material_override as ShaderMaterial
	_check(not bool(material.get_shader_parameter("has_artwork")), "new dismissal facility disables the old pawnshop artwork")
	_check(plate.mesh.size.is_equal_approx(CardArt.FRAME_SIZE), "dismissal keeps the source facility frame dimensions")
	_check(material.shader.resource_path == CardEntity.PLATE_SHADER, "dismissal keeps the original palette-aware card frame shader")
	for label in facility.find_children("*", "Label3D", true, false):
		_check(not str(label.text).contains("典当"), "facility label has no pawnshop wording: " + str(label.name))
	var illustrations: Array[Node] = facility.find_children("*", "Sprite3D", true, false)
	_check(illustrations.size() == 1, "facility has one clear new illustration")
	if illustrations.size() == 1:
		var icon := illustrations[0] as Sprite3D
		_check(icon.visible and icon.texture != null, "new dismissal illustration is visible and loaded")
		if icon.texture != null:
			_check(not icon.texture.resource_path.contains("pawnshop"), "new icon does not reuse the pawnshop image")
			var pixels := icon.texture.get_image()
			_check(pixels != null and pixels.detect_alpha() != Image.ALPHA_NONE, "new illustration has genuine transparency")
		_check(icon.position.y > plate.position.y, "illustration is above the original paper surface")
		var old_texture := icon.texture
		game._on_palette_changed("card", "facility_face")
		_check(icon.texture == old_texture and not bool(material.get_shader_parameter("has_artwork")), "palette refresh preserves the replacement illustration")
	var rightmost_x := -INF
	for offer in board.offers_by_id.values():
		rightmost_x = maxf(rightmost_x, offer.get_meta("market_slot").x)
	_check(facility.position.x > rightmost_x and board.offers_by_id.size() == 6, "redrawn facility remains beyond six conveyor positions")
	_check(facility.position.is_equal_approx(board.pawn_pos), "visual replacement preserves the existing drag hit position")
	if DisplayServer.get_name() != "headless":
		await create_timer(0.8).timeout
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("res://reports")
		var error := root.get_texture().get_image().save_png("res://reports/dismissal-facility-redrawn.png")
		_check(error == OK, "save actual rendered dismissal facility")
	print("DISMISSAL_ART_REVIEW complete; continuing real pointer and refund tests")

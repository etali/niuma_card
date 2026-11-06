# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Rasterise each distinct card name once from the same shaped font glyphs as
## Label3D. The result is sampled by the paper itself, including on frame one.
static var _by_type := {}
const MAX_WIDTH := 1024

static func apply(kind: String, label: Label3D, paper: ShaderMaterial) -> void:
	var cached: Dictionary = _by_type.get(kind, {})
	if cached.get("text") != label.text:
		cached = _rasterize(label)
		_by_type[kind] = cached
	var extent: Vector2 = cached.extent * label.pixel_size / CardArt.FRAME_SIZE
	var center := Vector2(0.5, 0.5) + Vector2(label.position.x, label.position.z) / CardArt.FRAME_SIZE
	paper.set_shader_parameter("title_mask", cached.texture)
	paper.set_shader_parameter("title_rect", Vector4(center.x - extent.x * 0.5,
		center.y - extent.y * 0.5, extent.x, extent.y))
	paper.set_shader_parameter("title_ink", label.modulate)
	paper.set_shader_parameter("print_title", label.visible)

static func _rasterize(label: Label3D) -> Dictionary:
	var line := TextLine.new()
	line.add_string(label.text, label.font, label.font_size)
	var extent := line.get_size().ceil() + Vector2(4, 4)
	var ratio := minf(1.0, MAX_WIDTH / extent.x)
	var size := Vector2i((extent * ratio).ceil())
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var pen := Vector2(2, 2 + line.get_line_ascent())
	var ts := TextServerManager.get_primary_interface()
	for glyph in ts.shaped_text_get_glyphs(line.get_rid()):
		var font: RID = glyph.font_rid
		var px := Vector2i(glyph.font_size, 0)
		if font.is_valid() and glyph.index != 0:
			ts.font_render_glyph(font, px, glyph.index)
			var atlas_id := ts.font_get_glyph_texture_idx(font, px, glyph.index)
			if atlas_id >= 0:
				var atlas := ts.font_get_texture_image(font, px, atlas_id)
				var uv := Rect2i(ts.font_get_glyph_uv_rect(font, px, glyph.index))
				var dimensions := Vector2i((ts.font_get_glyph_size(font, px, glyph.index) * ratio).round())
				if atlas != null and uv.has_area() and dimensions.x > 0 and dimensions.y > 0:
					var ink := atlas.get_region(uv)
					ink.convert(Image.FORMAT_RGBA8)
					if ink.get_size() != dimensions: ink.resize(dimensions.x, dimensions.y, Image.INTERPOLATE_BILINEAR)
					var offset: Vector2 = ts.font_get_glyph_offset(font, px, glyph.index) + glyph.offset
					for i in int(glyph.repeat):
						var at := (pen + offset + Vector2(i * float(glyph.advance), 0)) * ratio
						out.blend_rect(ink, Rect2i(Vector2i.ZERO, dimensions), Vector2i(at.round()))
		pen.x += float(glyph.advance) * int(glyph.repeat)
	out.generate_mipmaps()
	return {"text": label.text, "extent": extent, "texture": ImageTexture.create_from_image(out)}

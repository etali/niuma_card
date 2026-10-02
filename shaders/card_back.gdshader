// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
#include "res://shaders/card_frame.gdshaderinc"
uniform bool has_artwork = false;
uniform sampler2D artwork : source_color, filter_linear_mipmap;
uniform vec3 artwork_ink : source_color = vec3(0.94, 0.91, 0.83);
void fragment() {
	float d = card_distance(UV);
	if (d > 0.0) { discard; }
	// 卡背内框与外框一起随笔迹轻微起伏；位图只提供中间的飞钞插画。
	float aa = max(fwidth(d), 0.0005);
	float inset = card_size.x * 0.065;
	float width = card_stroke(UV) * 0.25;
	float inner = 1.0 - smoothstep(width - aa, width + aa, abs(d + inset));
	vec3 color = mix(face_color, artwork_ink, inner * 0.60);
	if (has_artwork && UV.x > 0.14 && UV.x < 0.86 && UV.y > 0.20 && UV.y < 0.80) {
		vec3 art = texture(artwork, UV).rgb;
		float ink = smoothstep(0.35, 0.75, min(min(art.r, art.g), art.b));
		color = mix(color, artwork_ink, ink);
	}
	ALBEDO = card_outline(UV, color, d) * tint;
}

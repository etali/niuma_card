// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

shader_type spatial;
// 实心卡面保留深度写入，堆叠时标题和数字不会穿透前面的牌。
render_mode unshaded, cull_disabled, depth_draw_opaque;
#include "res://shaders/card_frame.gdshaderinc"

// 设施牌可复用旧插画内部，不采样其毛边外框与标题分隔线。
uniform bool has_artwork = false;
uniform sampler2D artwork : source_color, filter_linear_mipmap;
// 反馈只改变纸面颜色与边缘，不移动卡体、图标或拾取碰撞。
uniform float handling_light = 0.0;
uniform float feedback_phase = 1.0;
uniform vec3 feedback_color : source_color = vec3(0.8, 0.65, 0.3);
void fragment() {
	float d = card_distance(UV);
	if (d > 0.0) { discard; }
	vec3 color = card_front(UV, d);
	if (has_artwork) {
		vec3 art = texture(artwork, UV).rgb;
		float art_area = smoothstep(0.06, 0.12, UV.x) * (1.0 - smoothstep(0.88, 0.94, UV.x));
		art_area *= smoothstep(0.22, 0.28, UV.y) * (1.0 - smoothstep(0.88, 0.94, UV.y));
		color = mix(color, art, art_area);
	}
	float inner = 1.0 - smoothstep(-border_width * 2.8, -border_width * 1.15, d);
	float raised_light = (0.5 - UV.x) * 0.055 + (0.5 - UV.y) * 0.035;
	color *= 1.0 + handling_light * raised_light * inner;
	float strength = sin(clamp(feedback_phase, 0.0, 1.0) * 3.14159265);
	float rim = (1.0 - smoothstep(border_width * 1.6, border_width * 4.5, -d)) * inner;
	float sweep = 1.0 - smoothstep(0.04, 0.15, abs(UV.y - feedback_phase));
	vec3 lit = card_tint(color, d);
	color = mix(lit, feedback_color, strength * (rim * 0.58 + sweep * inner * 0.10));
	ALBEDO = color;
}

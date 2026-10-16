// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

shader_type spatial;
// 完整卡面上的受击层：盖在插画、卡名和墨团之上，只画折痕、裂口与纸面压暗。
// 卡牌撕开后这一层撤掉，折痕改由撕片着色器自己画。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
#include "res://shaders/card_frame.gdshaderinc"

void fragment() {
	float d = card_distance(UV);
	if (d > 0.0) { discard; }
	vec2 damage = card_damage(UV);
	ALBEDO = ink_color;
	ALPHA = max(damage.x, damage.y);
}

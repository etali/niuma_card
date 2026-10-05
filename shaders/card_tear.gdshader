// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

shader_type spatial;
// 撕口保留手撕效果，外框和标题带与正面使用同一套程序化几何。
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
#include "res://shaders/card_frame.gdshaderinc"

// 卡面图标：贴图 + 它在卡面 UV 里占的矩形（中心 xy、半宽半高 zw）+ 颜色。
// has_icon=0 时整段跳过，没有图标的卡（纯资源牌之外的某些槽位）不至于取到黑块
uniform sampler2D icon : source_color, filter_linear_mipmap;
uniform bool icon_full_color = false;
uniform vec4 icon_rect = vec4(0.5, 0.489, 0.3, 0.16);
uniform vec3 icon_color : source_color = vec3(0.12, 0.12, 0.12);
uniform float has_icon = 0.0;

// side: -1 留上半（UV.y 小的那头，标题带那边），+1 留下半
uniform float side = 1.0;
uniform float fade = 1.0;
uniform float jag = 0.022;
uniform float edge = 0.012;
uniform vec3 edge_color : source_color = vec3(0.35, 0.3, 0.28);

// 撕口所在的 UV.y，随 UV.x 抖动。三个不同频率的正弦叠加：
// 单一正弦看着像波浪剪纸，叠起来才像手撕的毛边
float tear_y(float u) {
	return 0.5 + jag * sin(u * 37.0) + jag * 0.55 * sin(u * 91.0 + 1.7)
		+ jag * 0.30 * sin(u * 173.0 + 4.2);
}

void fragment() {
	float outline_distance = card_distance(UV);
	if (outline_distance > 0.0) { discard; }
	float ty = tear_y(UV.x);
	// 只留自己那一侧：另一侧交给对面那片画
	if ((UV.y - ty) * side < 0.0) { discard; }

	vec3 c = card_tint(card_front(UV, outline_distance), outline_distance);

	// 图标合成：把卡面 UV 折算成图标自己的 UV，落在框外就不取
	if (has_icon > 0.5) {
		vec2 iuv = (UV - icon_rect.xy) / (icon_rect.zw * 2.0) + vec2(0.5);
		if (iuv.x >= 0.0 && iuv.x <= 1.0 && iuv.y >= 0.0 && iuv.y <= 1.0) {
			vec4 ic = texture(icon, iuv);
			c = mix(c, icon_full_color ? ic.rgb : icon_color, ic.a);
		}
	}

	// 撕口两侧压一条暗边：纸被撕开会露出纤维，没有这条边看着像刀切
	float d = abs(UV.y - ty);
	c = mix(edge_color, c, clamp(d / edge, 0.0, 1.0));

	ALBEDO = c;
	ALPHA = fade;
}

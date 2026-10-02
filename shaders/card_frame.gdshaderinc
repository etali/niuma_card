// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

// 连续墨线的手绘卡框。扰动固定在局部坐标，移动、翻面和撕片时笔迹不会跳动。
// 不用随机像素颗粒或 TIME；只模拟落笔路径和笔压的缓慢变化。
uniform vec2 card_size = vec2(1.2, 1.6);
uniform float corner_radius = 0.10;
uniform float border_width = 0.025;
uniform float band_height = 0.18;
uniform float stroke_wobble = 0.0075;
uniform float stroke_pressure = 0.18;
uniform vec3 face_color : source_color = vec3(0.91, 0.82, 0.53);
uniform vec3 band_color : source_color = vec3(0.88, 0.72, 0.31);
uniform vec3 ink_color : source_color = vec3(0.12);
uniform vec3 tint : source_color = vec3(1.0);

float hand_curve(vec2 uv) {
	return 0.60 * sin(uv.x * 15.0 + uv.y * 2.4 + 0.7)
		+ 0.30 * sin(uv.y * 20.0 - uv.x * 3.8 + 2.1)
		+ 0.10 * sin(uv.x * 39.0 + uv.y * 29.0 + 4.6);
}

float card_stroke(vec2 uv) {
	float pressure = 0.60 * sin(uv.x * 11.0 + uv.y * 7.0 + 1.4)
		+ 0.40 * sin(uv.y * 17.0 - uv.x * 5.0 + 0.2);
	return border_width * (1.0 + stroke_pressure * pressure);
}

float card_distance(vec2 uv) {
	vec2 q = abs((uv - vec2(0.5)) * card_size) - card_size * 0.5 + vec2(corner_radius);
	float distance_to_card = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner_radius;
	// 起伏只向画布内收，最外边仍不会越过实体边界或被 Quad 截成断线。
	return distance_to_card + stroke_wobble * (0.55 + 0.45 * hand_curve(uv));
}

vec3 card_outline(vec2 uv, vec3 fill, float distance_to_edge) {
	float aa = max(fwidth(distance_to_edge), 0.0005);
	float width = card_stroke(uv);
	float line = smoothstep(-width - aa, -width + aa, distance_to_edge);
	return mix(fill, ink_color, line);
}

vec3 card_front(vec2 uv, float distance_to_edge) {
	// 分隔线也有手绘弧度，标题与卡面填充贴着同一条线，不露白缝。
	float bend = stroke_wobble * 0.75 * hand_curve(vec2(uv.x, band_height));
	float y = (uv.y - band_height) * card_size.y + bend;
	float aa = max(fwidth(y), 0.0005);
	vec3 fill = mix(band_color, face_color, smoothstep(-aa, aa, y));
	// 固定在纸面上的细纤维，不用TIME，拖动和撕开时保持同一笔触。
	float fiber = sin(uv.x * 410.0 + sin(uv.y * 31.0)) * sin(uv.y * 287.0 + uv.x * 23.0);
	float weave = sin(uv.x * 59.0 + uv.y * 17.0) * sin(uv.y * 83.0);
	fill *= 1.0 + fiber * 0.009 + weave * 0.006;
	float width = card_stroke(vec2(uv.x, band_height)) * 0.5;
	float divider = 1.0 - smoothstep(width - aa, width + aa, abs(y));
	return card_outline(uv, mix(fill, ink_color, divider), distance_to_edge);
}

// 正面和撕片共用高亮口径，避免完整卡的纸色在撕开瞬间变成旧的荧光色。
vec3 card_tint(vec3 color, float distance_to_edge) {
	float inner = 1.0 - smoothstep(-border_width * 2.8, -border_width * 1.15, distance_to_edge);
	float highlight = clamp(max(tint.r, max(tint.g, tint.b)) - 1.0, 0.0, 1.0);
	vec3 emphasized = mix(color, clamp(tint * 0.65, vec3(0.0), vec3(1.0)), highlight * 0.22 * inner);
	return highlight > 0.0 ? emphasized : color * tint;
}

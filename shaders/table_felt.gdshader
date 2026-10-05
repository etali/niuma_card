// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 felt_color : source_color;
uniform sampler2D doodle_pattern : filter_linear_mipmap, repeat_enable;
uniform vec3 doodle_ink : source_color;
uniform float pattern_density = 1.0;
uniform float pattern_spacing = 0.0;
uniform vec2 extent = vec2(60.0);
void fragment() {
	vec2 p = (UV - vec2(0.5)) * extent;
	// 纸纤维固定在桌面；远景衰减，避免织纹格子与手机摩尔纹。
	vec2 frequency = p * vec2(43.0, 67.0);
	float fibers = sin(frequency.x + sin(p.y * 3.7) * 2.3) * sin(frequency.y + p.x * 2.1);
	float attenuation = 1.0 / (1.0 + length(fwidth(frequency)) * 2.0);
	float pulp = sin(p.x * 2.9 + sin(p.y * 1.7)) * sin(p.y * 4.1 - p.x * 0.8);
	float crease = exp(-abs(p.y + p.x * 0.13 - 1.2) * 2.0) * 0.009;
	float crease_light = exp(-abs(p.y + p.x * 0.13 - 1.27) * 3.0) * 0.006;
	vec3 paper = felt_color * (1.0 + fibers * attenuation * 0.017 + pulp * 0.004 - crease + crease_light);
	// 世界坐标重复，缩窗不改变图案尺寸；单色重复印花铺满空隙。
	vec2 tile_uv = fract(p / vec2(5.1, 3.4) * sqrt(pattern_density));
	vec2 stamp_uv = (tile_uv - vec2(0.5)) * (1.0 + pattern_spacing) + vec2(0.5);
	float inside = step(0.0, stamp_uv.x) * step(stamp_uv.x, 1.0) * step(0.0, stamp_uv.y) * step(stamp_uv.y, 1.0);
	float doodle = texture(doodle_pattern, stamp_uv).a * inside;
	ALBEDO = mix(paper, doodle_ink, doodle * 0.48);
}

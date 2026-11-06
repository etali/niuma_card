// SPDX-License-Identifier: AGPL-3.0-only
uniform bool print_title = false;
uniform sampler2D title_mask : filter_linear_mipmap, repeat_disable;
uniform vec4 title_ink : source_color;
uniform vec4 title_rect = vec4(0.0, 0.0, 1.0, 1.0);

vec3 printed_face(vec2 uv, vec3 paper) {
	if (print_title) {
		vec2 at = (uv - title_rect.xy) / title_rect.zw;
		if (all(greaterThanEqual(at, vec2(0.0))) && all(lessThanEqual(at, vec2(1.0)))) {
			return mix(paper, title_ink.rgb, texture(title_mask, at).a * title_ink.a);
		}
	}
	return paper;
}

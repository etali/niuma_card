// Shared inverse map: spatial card and canvas magnifier sample exactly the
// same immutable GPT master. Time is supplied by gameplay, never shader TIME.
uniform sampler2D art_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float motion_seconds = 0.0;
uniform float motion_duration = 1.0;
uniform vec4 motion_tint : source_color = vec4(1.0);
uniform vec2 motion_global_pivot = vec2(0.5);
uniform vec4 motion_global = vec4(0.0);
uniform vec4 motion_global_secondary = vec4(0.0, 0.0, 1.0, 0.0);
uniform int motion_inverse_iterations = 2;
uniform int motion_region_count = 0;
uniform vec4 motion_shapes[8];
uniform vec4 motion_pivots[8];
uniform vec4 motion_moves[8];
uniform vec4 motion_extras[8];

float motion_wave(vec4 extra) {
	return sin(6.28318530718 * extra.z * motion_seconds / motion_duration + extra.y) - sin(extra.y);
}

vec2 motion_rotate(vec2 point, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(c * point.x - s * point.y, s * point.x + c * point.y);
}

vec2 motion_local_displacement(vec2 source) {
	vec2 delta = vec2(0.0);
	for (int i = 0; i < 8; i++) {
		if (i >= motion_region_count) { break; }
		vec4 shape = motion_shapes[i];
		vec4 pivot = motion_pivots[i];
		vec4 move = motion_moves[i];
		vec4 extra = motion_extras[i];
		float weight = 1.0 - smoothstep(pivot.z, 1.0, length((source - shape.xy) / shape.zw));
		float wave = motion_wave(extra);
		vec2 size = vec2(1.0) + vec2(move.w, extra.x) * wave;
		vec2 transformed = pivot.xy + motion_rotate((source - pivot.xy) * size, move.x * wave) + move.yz * wave;
		delta += (transformed - source) * weight;
	}
	return delta;
}

vec2 work_motion_source_uv(vec2 uv) {
	// Idle and paused-at-start cards sample their master directly. Large work
	// queues do not pay for all the local transforms while nothing is moving.
	if (motion_seconds == 0.0) { return uv; }
	float wave = motion_wave(motion_global_secondary);
	vec2 size = vec2(1.0) + vec2(motion_global.w, motion_global_secondary.x) * wave;
	vec2 target = motion_global_pivot + motion_rotate(uv - motion_global_pivot - motion_global.yz * wave, -motion_global.x * wave) / size;
	vec2 source = target;
	// Small bounded local transforms make fixed-point inversion stable and keep
	// smooth joints without raster crossfades, duplicate outlines or cuts.
	for (int step = 0; step < 4; step++) {
		if (step >= motion_inverse_iterations) { break; }
		source = target - motion_local_displacement(source);
	}
	return source;
}

vec4 work_motion_color(vec2 uv) {
	vec2 source = work_motion_source_uv(uv);
	// Sample unconditionally: a divergent return before texture() invalidates
	// implicit mip derivatives along the moving quad edge on Compatibility GL,
	// producing hairline rectangles even when the PNG border is transparent.
	vec4 color = texture(art_texture, source);
	float inside = step(0.0, source.x) * step(source.x, 1.0) * step(0.0, source.y) * step(source.y, 1.0);
	color.a *= inside;
	return color * motion_tint;
}

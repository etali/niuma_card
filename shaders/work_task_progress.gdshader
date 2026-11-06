shader_type spatial;
// One opaque surface avoids coplanar frame/track/fill depth conflicts. It still
// obeys the original card stack's depth, so covered cards cannot show through.
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec2 border_uv;
uniform vec3 frame_color : source_color;
uniform vec3 track_color : source_color;
uniform vec3 fill_color : source_color;

void fragment() {
	bool inside = UV.x >= border_uv.x && UV.x <= 1.0 - border_uv.x
		&& UV.y >= border_uv.y && UV.y <= 1.0 - border_uv.y;
	// Keep the left edge fixed; progress changes only the right boundary.
	float task_x = (UV.x - border_uv.x) / (1.0 - 2.0 * border_uv.x);
	vec3 content = task_x < progress ? fill_color : track_color;
	ALBEDO = inside ? content : frame_color;
}

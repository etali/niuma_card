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
	// 两头圆、墨线略有起伏的进度条，和卡框是同一种线。border_uv 是墨线占条宽、条高的
	// 比例，两者之比就是条的长宽比，不另传尺寸。
	float aspect = border_uv.y / max(border_uv.x, 0.0001);
	vec2 p = (UV - vec2(0.5)) * vec2(aspect, 1.0);
	vec2 q = abs(p) - vec2(aspect * 0.5 - 0.5, 0.0);
	float capsule = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.5;
	if (capsule > 0.0) { discard; }
	float line = border_uv.y * 1.35 * (1.0 + 0.16 * sin(UV.x * 21.0 + 1.3));
	// Keep the left edge fixed; progress changes only the right boundary.
	float task_x = (UV.x - border_uv.x) / (1.0 - 2.0 * border_uv.x);
	vec3 content = task_x < progress ? fill_color : track_color;
	// 四等分刻度：读得出走到几成了。
	float tick = step(abs(fract(task_x * 4.0 + 0.5) - 0.5), 0.012) * step(0.02, task_x) * step(task_x, 0.98);
	content = mix(content, frame_color, tick * 0.55);
	ALBEDO = capsule > -line ? frame_color : content;
}

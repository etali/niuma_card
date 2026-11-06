shader_type spatial;
// Respect the original card stack depth. Do not draw through the upper card.
render_mode unshaded, cull_disabled, depth_draw_never;
#include "work_icon_motion.gdshaderinc"

void fragment() {
	vec4 color = work_motion_color(UV);
	ALBEDO = color.rgb;
	ALPHA = color.a;
}

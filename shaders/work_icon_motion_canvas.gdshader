shader_type canvas_item;
#include "work_icon_motion.gdshaderinc"

void fragment() {
	COLOR = work_motion_color(UV);
}

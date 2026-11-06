// SPDX-License-Identifier: AGPL-3.0-only
shader_type spatial;
render_mode unshaded;
uniform vec4 stock : source_color;
uniform vec4 seam : source_color;
uniform float sheets;
void fragment() {
	float layer = UV.y * sheets;
	float edge = min(fract(layer), 1.0 - fract(layer));
	float line = 1.0 - smoothstep(0.0, max(fwidth(layer), 0.08), edge);
	ALBEDO = mix(stock.rgb, seam.rgb, line * 0.52);
}

shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;
uniform sampler2D paper_texture : source_color, filter_linear_mipmap;
uniform float fold : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform vec2 source_size = vec2(1.0);
uniform float ball_size = 0.18;
varying float crease;
void vertex() {
	float t = smoothstep(0.0, 1.0, fold);
	vec2 paper = VERTEX.xz;
	float ridge = sin(paper.x * 29.0) * cos(paper.y * 23.0);
	float longitude = paper.x * 6.2831853;
	float latitude = (paper.y + 0.5) * 3.1415927;
	float radius = ball_size * (0.5 + ridge * 0.085);
	vec3 ball = vec3(cos(longitude) * sin(latitude), cos(latitude), sin(longitude) * sin(latitude)) * radius;
	ball.y += ball_size * 0.5;
	// The sheet's opposite edges converge into a faceted, irregular closed
	// ball. Merely shrinking a flat quad would still look like a tiny card.
	VERTEX = mix(vec3(paper.x * source_size.x, 0.0, paper.y * source_size.y), ball, t);
	crease = ridge * t;
}
void fragment() {
	vec4 tex = texture(paper_texture, UV);
	float t = smoothstep(0.0, 1.0, fold);
	float alpha = mix(tex.a, 1.0, t) * opacity;
	if (alpha < 0.025) discard;
	vec3 paper_color = mix(vec3(0.96, 0.91, 0.80), tex.rgb, tex.a);
	ALBEDO = mix(tex.rgb, paper_color, t) * (0.86 + crease * 0.14);
	ALPHA = alpha;
}

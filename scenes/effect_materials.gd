# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 临时特效消失后仍持有材质模板，避免每次重新编译相同着色器。
## 会改颜色/透明度的特效取独立副本；粒子色来自顶点，可共享只读材质。
static var _flat: Dictionary = {}
## 纯表现的随机数（抖线种子、飞散方向、彩纸）。不用全局 randf：到货落点等表现用的是全局随机，
## 教学与录像回放会固定全局种子来复现路线，特效多抽一次就会把后面所有落点都挪开。
static var _rng: RandomNumberGenerator
static var _particles: Dictionary = {}
static var _particle_shader: Shader

## 粒子形状：硬币、小人、纸屑、星花，以及朝右/朝左跑的小人。
## 同一形状的所有事件共用一份材质；颜色仍来自每个粒子的顶点色。
const PARTICLE_SHAPES := {"coin": 0, "user": 1, "scrap": 2, "spark": 3, "runner_r": 4, "runner_l": 5}
## 硬币和小人直接用资源牌上那两枚图（现金牌的 ¥ 金币、用户牌的小人），不另画一个角色。
const PARTICLE_FIGURES := {"coin": CardDB.RES_CASH, "user": CardDB.RES_USER,
	"runner_r": CardDB.RES_USER, "runner_l": CardDB.RES_USER}

## 纸屑与星花是墨线小画：填色取顶点色，墨线取牌框墨色，用距离场画，任何缩放下线条都不糊。
## 硬币与小人贴资源牌原图，保留原色，只用顶点色的透明度淡出。
const PARTICLE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
uniform int shape = 3;
uniform vec3 ink : source_color = vec3(0.19, 0.17, 0.15);
uniform vec3 paper : source_color = vec3(0.96, 0.92, 0.85);
uniform sampler2D figure : source_color, filter_linear_mipmap;
varying float seed_a;
varying float seed_b;

float hash1(float n) { return fract(sin(n * 91.3458 + 0.71) * 47453.5453); }
float seg(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}
mat2 turn(float a) { return mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))); }

void vertex() {
	// 始终正对镜头，保留粒子自身的缩放。
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	seed_a = hash1(float(INSTANCE_ID) + 1.0);
	seed_b = hash1(float(INSTANCE_ID) * 3.17 + 5.0);
}

vec4 art(vec2 uv) {
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return vec4(0.0); }
	return texture(figure, uv);
}

void fragment() {
	vec2 p = UV - vec2(0.5);
	if (shape == 0) {
		// 硬币：现金牌那枚金币，横向收窄模拟在空中翻面。
		float spin = abs(cos(TIME * (7.0 + seed_a * 6.0) + seed_b * 6.2831853));
		vec4 c = art(vec2(p.x / max(spin, 0.16), p.y) + vec2(0.5));
		ALBEDO = c.rgb;
		ALPHA = c.a * COLOR.a;
	} else if (shape == 1 || shape >= 4) {
		// 用户：用户牌上那个小人。跑的时候整张图前倾，身后加三道速度线。
		bool running = shape >= 4;
		if (shape == 5) { p.x = -p.x; }
		vec2 q = running ? turn(-0.20) * p * 1.12 + vec2(0.04, 0.0) : p;
		vec4 c = art(q + vec2(0.5));
		vec3 col = c.rgb;
		float alpha = c.a;
		if (running) {
			float lines = min(seg(p, vec2(-0.49, -0.06), vec2(-0.31, -0.06)), seg(p, vec2(-0.47, 0.08), vec2(-0.29, 0.08)));
			lines = min(lines, seg(p, vec2(-0.49, 0.22), vec2(-0.33, 0.22))) - 0.014;
			float aa = max(fwidth(lines), 0.002);
			float stroke = 1.0 - smoothstep(-aa, aa, lines);
			col = mix(col, ink, stroke * (1.0 - alpha));
			alpha = max(alpha, stroke);
		}
		ALBEDO = col;
		ALPHA = alpha * COLOR.a;
	} else {
		vec3 fill = COLOR.rgb;
		float body;
		float strokes;
		if (shape == 2) {
			// 纸屑：歪斜的小纸片，一边是手撕毛边，中间残留一道墨线。
			p = turn(seed_a * 6.2831853 + TIME * (seed_b - 0.5) * 9.0) * p;
			vec2 q = p;
			q.x += q.y * (seed_b - 0.5) * 0.6;
			vec2 half_size = vec2(0.26 + 0.16 * seed_a, 0.16 + 0.14 * seed_b);
			vec2 d = abs(q) - half_size;
			body = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
			if (q.y > 0.0) { body += 0.03 * (sin(q.x * 55.0 + seed_a * 30.0) * 0.5 + 0.5); }
			// 纸屑就是被撕那张牌的碎片：填色直接取顶点色（调用方给牌面底色）。
			fill = COLOR.rgb;
			strokes = abs(body) - 0.018;
			if (abs(q.x) < half_size.x * 0.7) { strokes = min(strokes, abs(q.y + 0.04) - 0.008); }
		} else {
			// 星花：四角尖星，购买与典当的小闪光。
			p = turn(TIME * 2.0 * (seed_a - 0.5) + seed_b * 3.0) * p;
			vec2 a = abs(p) + vec2(0.0001);
			body = pow(pow(a.x, 0.55) + pow(a.y, 0.55), 1.0 / 0.55) - 0.40;
			strokes = abs(body) - 0.02;
		}
		float aa_body = max(fwidth(body), 0.002);
		float aa_ink = max(fwidth(strokes), 0.002);
		float covered = 1.0 - smoothstep(-aa_body, aa_body, body);
		float inked = 1.0 - smoothstep(-aa_ink, aa_ink, strokes);
		ALBEDO = mix(fill, ink, inked);
		ALPHA = max(covered, inked) * COLOR.a;
	}
}
"""

static func rng() -> RandomNumberGenerator:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	return _rng

static func flat(color: Color, double_sided := false) -> StandardMaterial3D:
	if not _flat.has(double_sided):
		var template := StandardMaterial3D.new()
		template.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		template.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		template.cull_mode = BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
		# 模板本身不上屏；取得 RID 才会让 BaseMaterial3D 注册并持有生成的 shader。
		# 只保留尚未初始化的模板仍会在最后一个副本释放时丢掉缓存。
		template.get_rid()
		_flat[double_sided] = template
	var material := _flat[double_sided].duplicate() as StandardMaterial3D
	material.albedo_color = color
	return material

## 同一形状只有一份材质；墨色与纸色每次取当前配色，选色面板改色后下一次特效即跟随。
static func particles(shape := "spark") -> ShaderMaterial:
	var key := shape if PARTICLE_SHAPES.has(shape) else "spark"
	if _particle_shader == null:
		_particle_shader = Shader.new()
		_particle_shader.code = PARTICLE_SHADER
	if not _particles.has(key):
		var material := ShaderMaterial.new()
		material.shader = _particle_shader
		material.render_priority = 6
		material.set_shader_parameter("shape", int(PARTICLE_SHAPES[key]))
		if PARTICLE_FIGURES.has(key):
			material.set_shader_parameter("figure", CardArt.res_icon_texture(str(PARTICLE_FIGURES[key])))
		_particles[key] = material
	var shared: ShaderMaterial = _particles[key]
	shared.set_shader_parameter("ink", Palette.get_color("card", "frame"))
	shared.set_shader_parameter("paper", Palette.semantic("surface"))
	return shared

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends MeshInstance3D

## 桌面分区/卡槽是无碰撞的绘制层。尺寸使用牌桌坐标，缩窗和透视都与卡牌一起投影。
## 位图可替换默认画法；没有位图时仍有圆角分区和空槽，不依赖额外素材包。
const SURFACE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec2 extent = vec2(1.2, 1.6);
uniform vec4 fill_color : source_color;
uniform vec4 edge_color : source_color;
uniform float radius = 0.12;
uniform float stroke = 0.02;
uniform bool dashed = false;
uniform bool use_artwork = false;
uniform sampler2D artwork : source_color, filter_linear_mipmap;
void fragment() {
	if (use_artwork) {
		vec4 texel = texture(artwork, UV);
		ALBEDO = texel.rgb;
		ALPHA = texel.a;
	} else {
		vec2 p = (UV - vec2(0.5)) * extent;
		vec2 q = abs(p) - extent * 0.5 + vec2(radius + stroke);
		float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
		float aa = max(fwidth(d), 0.002);
		float inside = 1.0 - smoothstep(-aa, aa, d);
		float line = (1.0 - smoothstep(stroke - aa, stroke + aa, abs(d)));
		if (dashed) {
			float along = abs(p.x) > extent.x * 0.5 - radius - stroke ? p.y : p.x;
			line *= 1.0 - step(0.62, fract(along / 0.25));
		}
		vec4 color = mix(fill_color, edge_color, line);
		ALBEDO = color.rgb;
		ALPHA = max(inside * fill_color.a, line * edge_color.a);
	}
}
"""

static var _shader: Shader
var _role := "zone"
var _surface_material: ShaderMaterial

func configure(extent: Vector2, role: String, artwork: Texture2D = null) -> void:
	_role = role
	name = "TableSurface_" + role
	var plane := PlaneMesh.new()
	plane.size = extent
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SURFACE_SHADER
	_surface_material = ShaderMaterial.new()
	_surface_material.shader = _shader
	# 从桌布到分区、空槽、接触阴影(-32)，最后才是牌面，透明绘制顺序固定。
	_surface_material.render_priority = -48 if role == "slot" else (-60 if role == "market" else -64)
	_surface_material.set_shader_parameter("extent", extent)
	_surface_material.set_shader_parameter("radius", 0.12 if role == "slot" else 0.24)
	_surface_material.set_shader_parameter("dashed", role == "slot")
	_surface_material.set_shader_parameter("use_artwork", artwork != null)
	if artwork:
		_surface_material.set_shader_parameter("artwork", artwork)
	material_override = _surface_material
	refresh_palette()

func _ready() -> void:
	Palette.bus().changed.connect(_on_palette_changed)

func _on_palette_changed(_section: String, _key: String) -> void:
	refresh_palette()

func refresh_palette() -> void:
	if _surface_material == null:
		return
	var table := Palette.get_color("world", "table_felt")
	var paper := Palette.get_color("world", "table_frame")
	var ink := Palette.get_color("card", "frame")
	# 双方牌区要看得见边界，但不能压过卡牌；市场带保持同级而非独占焦点。
	var fill := table.lerp(paper, 0.18)
	var edge := table.lerp(ink, 0.22)
	if _role == "market":
		fill = table.lerp(paper, 0.30)
		edge = table.lerp(Palette.get_color("world", "market_floor"), 0.30)
	elif _role == "slot":
		fill = Color(paper, 0.06)
		edge = Color(paper, 0.55)
	_surface_material.set_shader_parameter("fill_color", fill)
	_surface_material.set_shader_parameter("edge_color", edge)

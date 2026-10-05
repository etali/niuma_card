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
uniform vec3 feedback_color : source_color;
uniform float radius = 0.12;
uniform float stroke = 0.016;
uniform bool dashed = false;
uniform bool folded = true;
uniform float fold_size = 0.43;
uniform bool hanging_tag = false;
uniform float feedback = 0.0;
uniform float opacity = 1.0;
uniform bool use_artwork = false;
uniform sampler2D artwork : source_color, filter_linear_mipmap;
float paper_distance(vec2 p, vec2 half_size) {
    vec2 q = abs(p) - half_size + vec2(radius);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}
// 五边形服装吊牌：一端收尖，另一端保留完整的长方形牌身。
float tag_distance(vec2 p, vec2 half_size) {
    float shoulder = (-p.x - half_size.x + abs(p.y) * 0.85) / 1.3124;
    return max(max(abs(p.y) - half_size.y, p.x - half_size.x), shoulder);
}
void fragment() {
    vec2 p = (UV - vec2(0.5)) * extent;
    float wave = sin(p.x * 4.3 + p.y * 1.7) * 0.012 + sin(p.y * 7.1 - p.x * 0.8) * 0.006;
    float margin = min(0.055, min(extent.x, extent.y) * 0.18);
    float d = paper_distance(p, extent * 0.5 - vec2(margin)) + wave;
    if (hanging_tag) {
        d = tag_distance(p, extent * 0.5 - vec2(margin)) + wave * 0.35;
    }
    float aa = max(fwidth(d), 0.002);
    float inside = 1.0 - smoothstep(-aa, aa, d);
    float line = 1.0 - smoothstep(stroke - aa, stroke + aa, abs(d + stroke));
    if (dashed) {
        float along = abs(p.x) > extent.x * 0.5 - radius - 0.06 ? p.y : p.x;
        line *= 1.0 - step(0.64, fract(along / 0.24));
    }
    vec4 color = mix(fill_color, edge_color, line);
    if (hanging_tag) {
        float hole = length(p - vec2(-extent.x * 0.5 + margin + 0.17, 0.0));
        float ring = 1.0 - smoothstep(0.004, 0.008, abs(hole - 0.035));
        color.rgb = mix(color.rgb, edge_color.rgb, ring);
        inside *= smoothstep(0.028, 0.035, hole);
    }
    vec2 f = p * vec2(57.0, 81.0);
    float fiber = sin(f.x + sin(p.y * 3.7)) * sin(f.y - p.x * 1.9);
    float attenuation = 1.0 / (1.0 + length(fwidth(f)) * 2.0);
    color.rgb *= 1.0 + fiber * attenuation * 0.012;
    // 小折角与折线，区域中间保持空净，卡牌不会压在装饰图案上。
    if (folded) {
        float fold = extent.x * 0.5 + extent.y * 0.5 - fold_size - p.x - p.y;
        float corner = 1.0 - smoothstep(-aa, aa, fold);
        color.rgb = mix(color.rgb, fill_color.rgb * 1.065, corner * 0.85);
        float seam = 1.0 - smoothstep(0.01, 0.024, abs(fold));
        color.rgb = mix(color.rgb, edge_color.rgb, seam * 0.30);
    }
    color.rgb = mix(color.rgb, feedback_color, line * feedback * 0.80);
    // 阴影与纸垫同一个绘制层，只在外缘出现，不改变碰撞或区域尺寸。
    float shadow_d = paper_distance(p - vec2(0.016, 0.025), extent * 0.5 - vec2(margin));
    if (hanging_tag) {
        shadow_d = tag_distance(p - vec2(0.012, 0.018), extent * 0.5 - vec2(margin));
    }
    float shadow = exp(-max(shadow_d, 0.0) * 32.0) * (1.0 - inside) * 0.17;
    float alpha = max(inside * fill_color.a, line * edge_color.a);
    ALBEDO = mix(vec3(0.20, 0.22, 0.17), color.rgb, inside);
    ALPHA = max(alpha, shadow) * opacity;
    if (use_artwork) {
        vec4 texel = texture(artwork, UV);
        ALBEDO = texel.rgb;
        ALPHA = texel.a * opacity;
    }
}
"""

static var _shader: Shader
var _role := "zone"
var _surface_material: ShaderMaterial
var _owner := ""
var _board: Board
var _feedback := 0.0
var _feedback_target := 0.0

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
	_surface_material.render_priority = -16 if role == "price" else (-48 if role in ["slot", "divider"] else (-60 if role == "market" else -64))
	_surface_material.set_shader_parameter("extent", extent)
	_surface_material.set_shader_parameter("radius", minf(0.055, extent.x * 0.2) if role in ["price", "divider"] else (0.12 if role == "slot" else 0.24))
	_surface_material.set_shader_parameter("fold_size", 0.12 if role == "price" else 0.43)
	_surface_material.set_shader_parameter("dashed", role == "slot")
	_surface_material.set_shader_parameter("folded", role in ["zone", "market"])
	_surface_material.set_shader_parameter("hanging_tag", role == "price")
	if role == "price":
		_surface_material.set_shader_parameter("stroke", CardArt.FRAME_BORDER * 0.4)
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
	var fill := table.lerp(paper, 0.32)
	var edge := fill.lerp(ink, 0.38)
	if _role == "market":
		fill = table.lerp(paper, 0.70)
		edge = fill.lerp(Palette.get_color("world", "market_floor"), 0.40)
	elif _role == "slot":
		fill = Color(ink, 0.07)
		edge = Color(ink, 0.22)
	elif _role == "price":
		fill = paper
		edge = ink
	elif _role == "divider":
		fill = Color(ink, 0.25)
		edge = Color(ink, 0.25)
	_surface_material.set_shader_parameter("feedback_color", Palette.semantic("success"))
	_surface_material.set_shader_parameter("fill_color", fill)
	_surface_material.set_shader_parameter("edge_color", edge)

func set_zone_owner(owner: String) -> void:
	_owner = owner
	refresh_palette()

func bind_board(board: Board) -> void:
	_board = board

func set_feedback(on: bool) -> void:
	_feedback_target = 1.0 if on else 0.0

func _process(delta: float) -> void:
	if _role == "zone" and _owner == "player" and is_instance_valid(_board):
		var valid := false
		if not _board.input_locked and not _board.attack_mode and not _board._drag_cards.is_empty() and is_instance_valid(_board._drag_cards[0]):
			var at: Vector3 = _board._drag_cards[0].global_position
			var bounds := _board.player_bounds
			valid = bounds.has_point(Vector2(at.x, at.z)) if Board.has_table_bounds(bounds) else at.z >= _board.player_min_z and at.z <= _board.player_max_z
		set_feedback(valid)
	_feedback = lerpf(_feedback, _feedback_target, 1.0 - exp(-18.0 * delta))
	if _surface_material:
		_surface_material.set_shader_parameter("feedback", _feedback)

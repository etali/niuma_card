// SPDX-License-Identifier: AGPL-3.0-only
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
// Each tray retains its paper pattern as its left edge curls over to the right.
uniform float roll = 0.0;
varying float roll_shade;
void vertex() {
    float edge = (roll - 0.5) * extent.x;
    float roll_radius = min(0.23, extent.x * 0.12);
    float arc = max(0.0, edge - VERTEX.x) / roll_radius;
    // Wind the trailing paper inside a compact cylinder instead of piling up
    // coincident faces. Leave the flat, untouched portion exactly in place.
    float r = roll_radius / (1.0 + 0.09 * arc);
    if (arc > 0.0) {
        VERTEX.x = edge - sin(arc) * r;
        VERTEX.y += roll_radius - cos(arc) * r;
    }
    roll_shade = cos(min(arc, 3.14159)) * 0.15 + 0.85;
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
    ALBEDO *= roll_shade;
    ALPHA *= 1.0 - smoothstep(0.96, 1.0, roll);
}

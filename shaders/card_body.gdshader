// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

shader_type spatial;
// 卡身（卡面下面那块深色的厚度）。跟着卡面的外形裁切：攻击牌切掉的角、
// 增益牌折掉的角下面不再露出一块深色。圆角牌裁掉的只是原来就被卡框盖住的四个尖角。
render_mode unshaded, cull_disabled;
#include "res://shaders/card_frame.gdshaderinc"

// 卡身比卡面每边内缩这么多（CardEntity.PLATE_ART_INSET），裁切线也按同一个量内缩。
uniform float body_inset = 0.05;
varying vec2 local_xz;

void vertex() {
	local_xz = VERTEX.xz;
}

void fragment() {
	if (card_silhouette(local_xz, card_size * 0.5) > -body_inset * 0.9) { discard; }
	ALBEDO = ink_color;
}

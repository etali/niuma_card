# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 悬停说明测试：每张卡都有说明；说明里不重复卡名/标价/配方进度；
## 每一行都窄于文本框宽度（否则 autowrap 会在汉字之间断词）


func _initialize() -> void:
	print("=== 悬停说明测试 ===")
	CardDB.ensure_loaded()
	var board := Board.new()
	root.add_child(board)
	# 等节点真进树：_initialize 里刚 add_child 的节点还没入树，
	# 此时读写 global_position / global_rotation 会被引擎驳回并返回单位变换
	await physics_frame

	var font := Fonts.zh_bold()
	var raster := 40   # 与 Board._ensure_desc 的 font_size 一致
	var max_line := 0.0
	var widest := ""
	var missing: Array = []
	var leaked: Array = []

	for def_id in CardDB.all_cards().keys():
		var def: Dictionary = CardDB.get_def(def_id)
		var t: String = board.hover_desc_text(def_id)
		if t == "":
			missing.append(def_id)
			continue
		# 卡名已在标题带上、标价已在牌外价签上、进度已在 D 位墨团上。
		# 单位卡跳过卡名这一条：现金/用户卡的卡名就是资源名，
		# 说明里写「配方材料：用户」是在说资源种类，不是在重复卡名
		var repeats_name: bool = str(def["name"]) in t \
			and def.get("kind", "") != CardDB.KIND_UNIT
		if repeats_name or "标价" in t or "配方进度" in t:
			leaked.append(def_id)
		for line in t.split("\n"):
			var w: float = font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, raster).x \
				* Board.DESC_PIXEL
			if w > max_line:
				max_line = w
				widest = line

	check(missing.is_empty(), "每张卡都有悬停说明（缺：%s）" % str(missing))
	check(leaked.is_empty(), "说明不重复卡名/标价/进度（越界：%s）" % str(leaked))
	print("       最宽一行：「%s」= %.2f 世界单位（框宽 %.2f）" % [widest, max_line, Board.DESC_WIDTH])
	check(max_line <= Board.DESC_WIDTH,
		"最长一行不超文本框宽（%.2f ≤ %.2f，不会在汉字间断词）" % [max_line, Board.DESC_WIDTH])
	# 说明字号要明显小于「浮动大字」那一档（pixel_size 0.014 / font_size 44）：
	# 这块白板是贴着卡读的说明，不是盖住半张桌子的提示
	check(Board.DESC_PIXEL * raster < 0.014 * 44 * 0.7,
		"字号够小（行高 %.3f < 大字 %.3f 的 7 成）" % [Board.DESC_PIXEL * raster, 0.014 * 44])

	# ---- 衬底：说明右边十有八九还是张卡，字必须落在自己的底板上 ----
	# 一张两行的卡（刷不停）和一张一行的卡（组内产出×2），
	# 底板都要恰好包住文字、且随文字长短伸缩
	var card := CardEntity.new()
	root.add_child(card)
	card.setup(90001, "shuabuting")
	await physics_frame
	card.global_position = Vector3(0, 0.02, 0)
	board._show_desc(board.hover_desc_text("shuabuting"), card)
	check(board._desc.visible and board._desc_panel.visible and board._desc_edge.visible,
		"说明连衬底一起显示")
	var two := _plate_covers(board)
	check(two, "两行说明：文字完全落在衬底内")
	var big: Vector3 = (board._desc_panel.mesh as BoxMesh).size
	# 文字左沿应贴着卡右沿 + 间距，不能压在卡上
	var lx: float = board._desc.global_position.x
	check(lx > card.global_position.x + CardEntity.CARD_SIZE.x / 2.0,
		"说明落在卡右侧（文字左沿 %.2f > 卡右沿 %.2f）" \
			% [lx, card.global_position.x + CardEntity.CARD_SIZE.x / 2.0])
	check(is_equal_approx(board._desc.rotation_degrees.x, -90.0),
		"说明与卡同平面（-90°，不是立起来的提示）")

	board._show_desc("组内产出 ×2", card)
	check(_plate_covers(board), "一行说明：文字完全落在衬底内")
	var small: Vector3 = (board._desc_panel.mesh as BoxMesh).size
	check(small.x < big.x and small.z < big.z,
		"衬底随文字伸缩（一行 %.2f×%.2f < 两行 %.2f×%.2f）" % [small.x, small.z, big.x, big.z])

	# ---- 纵向跟着光标走，横向不跟（横向跟就会爬到卡上） ----
	var t2 := board.hover_desc_text("shuabuting")
	board._show_desc(t2, card, card.global_position.z + 0.5)
	var z_lo: float = board._desc.global_position.z
	var x_lo: float = board._desc.global_position.x
	board._show_desc(t2, card, card.global_position.z - 0.5)
	var z_hi: float = board._desc.global_position.z
	check(absf(z_lo - z_hi) > 0.3, "说明纵向跟着光标走（%.2f → %.2f）" % [z_lo, z_hi])
	check(absf(board._desc.global_position.x - x_lo) < 0.001,
		"说明横向不跟光标（始终贴在卡右沿之外，不遮卡）")
	# 光标压在卡边缘时，说明钳在卡的上下缘内，不飘到卡外
	board._show_desc(t2, card, card.global_position.z + 99.0)
	var half: float = CardEntity.CARD_SIZE.z / 2.0
	check(board._desc.global_position.z <= card.global_position.z + half + 0.001,
		"光标越出卡缘时说明钳回卡内（%.2f ≤ %.2f）" % [
			board._desc.global_position.z, card.global_position.z + half])
	# 不传 at_z = 对齐卡中心（测试与非鼠标调用走这条）
	board._show_desc(t2, card)
	check(absf(board._desc.global_position.z - card.global_position.z) < 0.001,
		"省略光标位置时对齐卡中心")
	# 衬底跟着一起挪（不然字飘出板子）
	check(_plate_covers(board), "跟随后文字仍落在衬底内")

	board._hide_desc()
	check(not board._desc.visible and not board._desc_panel.visible \
		and not board._desc_edge.visible, "隐藏说明时衬底一起收掉")
	# 光标离开卡（射线打空）时 _update_hover_hint 会走 _hide_desc：
	# 这里直接验证它在没有卡可指时不会把说明留在桌上
	board._show_desc(t2, card)
	board._update_hover_hint()
	check(not board._desc.visible, "光标不在任何卡上时说明消失")

	# 合成提示区分普通同名升级与任意同档生产卡的传说路线。
	var tier_counts := {1: [], 2: []}
	for tier in [1, 2]:
		for n in range(2, CardDB.max_upgrade_n() + 1):
			if ComboRules.legend_upgrade_target(tier, n) != "":
				tier_counts[tier].append(n)
	var with_t2 := "shuabuting"
	var t2_id := t2_of(with_t2)
	var t2_step := int(CardDB.get_def(t2_id)["upgrade_dup_n"])
	check(board.hover_desc_text(with_t2).contains("同名×%d → %s" % [t2_step, CardDB.card_name(t2_id)]),
		"普通T1→T2仍明确需要同名材料")
	for sample in [with_t2, t2_id, "chunwan"]:
		var tier := int(CardDB.get_def(sample)["tier"])
		var description := board.hover_desc_text(sample)
		check(description.contains("同档T%d×%s" % [tier, dup_slashed(tier_counts[tier])]),
			"%s展示同档传说的全部精确张数" % CardDB.card_name(sample))
		check(description.contains("可异名") and description.contains("张数须精确") and description.contains("不能夹杂其他牌"),
			"%s明确同档可异名、数量精确、不能夹杂" % CardDB.card_name(sample))
	check(t2_of("chunwan") == "" and not board.hover_desc_text("chunwan").contains("同名×%d →" % t2_step),
		"没有对应T2的卡不虚构普通同名升级路线")
	for tier in [1, 2]:
		for n in tier_counts[tier]:
			var target := ComboRules.legend_upgrade_target(tier, n)
			var description := board.hover_desc_text(target)
			check(description.contains("同档T%d生产卡×%d" % [tier, n]) and description.contains("同名异名均可"),
				"%s说明按真实规则展示T%d来源与张数" % [CardDB.card_name(target), tier])
			check(not description.contains("同名巨头") and not description.contains("同名产品"), "传说说明不再要求同名材料")
	var original_upgrade := CardDB.UPGRADE
	CardDB.UPGRADE = original_upgrade.duplicate(true)
	for route in CardDB.UPGRADE["routes"]:
		if route.get("kind") == CardDB.KIND_PRODUCT and route.get("tier") == 1 and route.get("key") == "dup_key":
			route["per"] = 3
	var configured_counts: Array = []
	for n in range(2, CardDB.max_upgrade_n() + 1):
		var target := ComboRules.legend_upgrade_target(1, n)
		if target != "":
			configured_counts.append(n)
			check(board.hover_desc_text(target).contains("同档T1生产卡×%d" % n), "传说说明实时跟随per变化，不硬编码dup×2")
	check(board.hover_desc_text(with_t2).contains("同档T1×%s" % dup_slashed(configured_counts)),
		"生产卡说明实时跟随传说路线折算配置")
	CardDB.UPGRADE = original_upgrade
	check(board.hover_desc_text(with_t2).contains("同档T1×%s" % dup_slashed(tier_counts[1])), "恢复配置后悬停提示不保留旧张数")

	# ---- 两种防御膜共用一句模板，res 从 buff_type 反解（protect_<res>）----
	# 两张卡各念自己那种资源的**卡名**：反解错了会两张都说同一种资源，
	# 玩家照着贴膜会贴反（现金膜贴到用户引擎上）
	for buff_id in ["tuisong", "jiangjia"]:
		var description: String = board.hover_desc_text(buff_id)
		check(description.contains("入组立即保护") and not description.contains("下回合"),
			"防御卡悬停说明明确即时保护：%s" % CardDB.card_name(buff_id))
	check(board.hover_desc_text("tuisong").contains("组内用户不可被移除"),
		"推送弹窗说的是用户不可被移除")
	check(board.hover_desc_text("jiangjia").contains("组内现金不可被移除"),
		"降价补贴说的是现金不可被移除（卡名，不是「资金」）")

	# ---- 拖拽浮动提示已删除：board 上不该再留着那套文案构建器 ----
	# （配方进度只看牌面 D 位墨团，不另起一块浮动大字）
	for gone in ["recipe_hint_text", "card_hint_text", "pawn_hint_text", "_show_hint"]:
		check(not board.has_method(gone), "拖拽提示的 %s 已移除" % gone)

	finish()

## 衬底是否包住了文字外廓（x 与 z 两个方向都留有余白）。
## 文字左沿 = Label3D 原点（autowrap 关掉后左对齐从原点向右画），
## 竖向则是原点上下各半个外廓（VERTICAL_ALIGNMENT_CENTER）
func _plate_covers(board: Board) -> bool:
	var box: Vector2 = board._desc_extent(board._desc.text)
	var o: Vector3 = board._desc.global_position
	var p: Vector3 = board._desc_panel.global_position
	var size: Vector3 = (board._desc_panel.mesh as BoxMesh).size
	var ok := o.x >= p.x - size.x / 2.0 and o.x + box.x <= p.x + size.x / 2.0 \
		and o.z - box.y / 2.0 >= p.z - size.z / 2.0 \
		and o.z + box.y / 2.0 <= p.z + size.z / 2.0
	if not ok:
		print("       文字 x[%.2f,%.2f] z[%.2f,%.2f] / 衬底 x[%.2f,%.2f] z[%.2f,%.2f]" % [
			o.x, o.x + box.x, o.z - box.y / 2.0, o.z + box.y / 2.0,
			p.x - size.x / 2.0, p.x + size.x / 2.0,
			p.z - size.z / 2.0, p.z + size.z / 2.0])
	return ok

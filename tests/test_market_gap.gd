# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 市场由可购买的卡与最右侧设施组成同一行；设施占一个完整卡位。
## 判据只约束可见几何：等距、居中、不相叠和跨度，不依赖旧柜台尺寸。
const Main = preload("res://scenes/main.gd")
const Regions = preload("res://scenes/table_regions.gd")

func _initialize() -> void:
	print("=== 公共区卡位与设施间距 ===")
	check(is_equal_approx(Main.market_gap(6), 2.6), "6张可购卡加设施仍有2.6间距")
	check(is_equal_approx(Main.market_gap(8), 2.3), "8张可购卡加设施均匀分配18.4中心跨度")
	var counts: Array[int] = [1, 6, 8, 10, 12]
	var current: int = CardDB.game_rules()["market_size"]
	if current not in counts:
		counts.append(current)
	for drawer in [false, true]:
		for count in counts:
			var label := "%s n=%d" % ["抽屉" if drawer else "横屏", count]
			var first: Vector3 = Regions.market_slot(0, count, drawer)
			var facility: Vector3 = Regions.facility_position(count, drawer)
			var gap: float = Main.market_gap(count)
			check(gap <= 2.6 + 0.0001, "%s间距有上限" % label)
			check(is_zero_approx(first.x + facility.x), "%s整行包含设施后居中" % label)
			check(facility.x - first.x <= 18.4 + 0.0001, "%s整行中心跨度不超内容宽度" % label)
			check(gap > CardEntity.CARD_SIZE.x, "%s完整卡位互不相叠" % label)
			var previous := first
			for index in range(1, count + 1):
				var at: Vector3 = Regions.market_slot(index, count, drawer)
				check(is_equal_approx(at.x - previous.x, gap) and is_equal_approx(at.z, first.z),
					"%s卡位%d与前一位等距同排" % [label, index])
				previous = at
			var last: Vector3 = Regions.market_slot(count - 1, count, drawer)
			var last_right := last.x + CardEntity.CARD_SIZE.x * 0.5
			var facility_left := facility.x - CardEntity.CARD_SIZE.x * 0.5
			check(facility_left > last_right, "%s最后一张卡与设施真实外沿保留空隙" % label)
			check(facility.is_equal_approx(previous), "%s设施使用末尾完整卡位" % label)
			var market: Rect2 = Regions.market_rect(count, drawer)
			var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
			check(market.encloses(Rect2(Vector2(first.x, first.z) - half, half * 2.0))
				and market.encloses(Rect2(Vector2(facility.x, facility.z) - half, half * 2.0)),
				"%s托盘宽度覆盖全部商品及设施的完整卡面" % label)
	finish()

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 市场、设施和装饰托盘的唯一几何配置。实际可拖放边界仍由 Board/镜头独立计算。
const PLAYER_ZONE_Z := 1.8
const AI_ZONE_Z := -4.5
const MARKET_GAP_MAX := 2.6
const MAX_MARKET_SPAN := 18.4
const MARKET_DEPTH := 2.35
const MARKET_PAD := 0.25
const MARKET_LABEL_OFFSET := 0.20
const DRAWER_MARKET_Z := -0.70
const TABLE_MARKET_Z := -1.60
const MARKET_CARD_Y := 0.20
const ZONE_WIDTH := 21.0
const TABLE_ZONE_WIDTH := 23.0
const DRAWER_ZONE_GAP := 0.525
const TABLE_ZONE_GAP := 0.8

static func market_gap(count: int) -> float:
	# count 个商品 + 1 个设施，共 count 段间距；设施也计入整行宽度。
	return minf(MARKET_GAP_MAX, MAX_MARKET_SPAN / float(maxi(count, 1)))

static func market_slot(index: int, count: int, drawer: bool) -> Vector3:
	var total := maxi(count, 0)
	return Vector3((float(index) - float(total) * 0.5) * market_gap(total),
		MARKET_CARD_Y, DRAWER_MARKET_Z if drawer else TABLE_MARKET_Z)

static func facility_position(count: int, drawer: bool) -> Vector3:
	return market_slot(maxi(count, 0), count, drawer)

static func market_rect(count: int, drawer: bool) -> Rect2:
	var first := market_slot(0, count, drawer)
	var last := facility_position(count, drawer)
	var half_width := CardArt.FRAME_SIZE.x * 0.5 + MARKET_PAD
	return Rect2(first.x - half_width,
		first.z + MARKET_LABEL_OFFSET - MARKET_DEPTH * 0.5,
		last.x - first.x + half_width * 2.0, MARKET_DEPTH)

static func zone_rect(mine: bool, drawer: bool, count: int) -> Rect2:
	var market := market_rect(count, drawer)
	var gap := DRAWER_ZONE_GAP if drawer else TABLE_ZONE_GAP
	var width := ZONE_WIDTH if drawer else TABLE_ZONE_WIDTH
	var far := -5.15 if drawer else -8.30
	var near := 5.85 if drawer else 6.2
	var north := market.end.y + gap if mine else far
	var south := near if mine else market.position.y - gap
	return Rect2(-width * 0.5, north, width, south - north)

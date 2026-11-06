# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://scenes/market_price_tag.gd"

## The original hanging tag, hit testing and hover feedback remain unchanged.
## This tag is a child of its moving offer, so the original static-shelf drag
## snapshot must not move it back to an earlier shelf position on release.
func sync_card_position() -> void:
	pass

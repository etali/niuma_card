# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Public distribution, never the world's random generator or sampled offers.
## A tool not owned now has a waiting cost even when the player can afford it.
static func expected_supply_wait(config: OffWorkConfig, kind: String) -> float:
	if not config.can_purchase(kind): return INF
	var chance := float(config.conveyor_probabilities().get(kind,0.0))
	if chance<=0.0: return INF
	var interval := config.number("conveyor","interval_seconds")
	# Starting just after an unknown arrival is conservative by one interval.
	return interval/chance

# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Public distribution, never the world's random generator or sampled offers.
## A tool not owned now has a waiting cost even when the player can afford it.
## Forced employee arrivals occupy conveyor slots but cannot supply that tool.
static func expected_supply_wait(config: OffWorkConfig, kind: String) -> float:
	if not config.can_purchase(kind): return INF
	var pool: Dictionary = config.rules.conveyor.pool
	var total := 0.0
	for weight in pool.values(): total += maxf(0.0,float(weight))
	var chance := float(pool.get(kind,0.0))/maxf(1.0,total)
	if chance<=0.0: return INF
	var every := config.integer("conveyor","employee_every")
	if every==1 and kind!="employee": return INF
	var interval := config.number("conveyor","interval_seconds")
	# Starting just after an unknown arrival is conservative by one interval.
	# The periodic forced arrival has no hidden phase dependency in this tail.
	var random_fraction := 1.0-1.0/every if every>1 else 1.0
	return interval/(chance*random_fraction)

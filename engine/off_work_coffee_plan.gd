# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkCoffeePlan
extends RefCounted

## Resolve a coffee round from its opening snapshot. Selection follows the
## virtual current ranks; neither the supplied people nor the world is changed.
static func plan(config: OffWorkConfig, people: Array, coffee_count: int) -> Dictionary:
	var order := []
	for index in people.size():
		order.append({"person": people[index].id, "kind": str(people[index].kind),
			"rank": config.coffee_rank(str(people[index].kind)), "index": index})
	order.sort_custom(func(a, b): return a.rank > b.rank if a.rank != b.rank else a.index < b.index)
	var result := {"upgrades": [], "coffee_used": 0}
	var remaining := maxi(0, coffee_count)
	# Once selected, an upgraded person has an even higher rank. If their
	# next step is unaffordable, spending on others cannot make it affordable.
	# Thus this ordered pass is identical to selecting again at every step.
	for person in order:
		var kind := str(person.kind)
		var upgrade := {"person": person.person, "from_type": kind, "to_type": kind, "cost": 0, "steps": []}
		var step: Dictionary = config.coffee_upgrade(kind)
		while not step.is_empty() and int(step.cost) <= remaining:
			var cost := int(step.cost)
			upgrade.steps.append({"from_type": kind, "to_type": str(step.to), "cost": cost})
			kind = str(step.to)
			upgrade.to_type = kind
			upgrade.cost += cost
			remaining -= cost
			result.coffee_used += cost
			step = config.coffee_upgrade(kind)
		if not upgrade.steps.is_empty(): result.upgrades.append(upgrade)
	return result

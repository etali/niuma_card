# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## The existing search copy/release estimates, shared by tree nodes and
## executable continuations. These are scheduling guards, not strategy knobs.
static func fork_cost(world: OffWorkState) -> int:
	return 250 + world.cards.size() * 6 + world.groups.size() * 12

static func release_cost(world: OffWorkState) -> int:
	return 250 + world.cards.size() * 2 + world.groups.size() * 6

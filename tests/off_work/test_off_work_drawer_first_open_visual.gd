# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/test_drawer_first_open_visual.gd"

## Separate process: the off-work startup must also warm its own first table,
## rather than borrowing a native image already rendered by the on-work game.
func _initial_mode() -> int:
	return 1

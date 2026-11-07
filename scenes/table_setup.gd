# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Only the native host stages construction. Direct scene callers still receive
## a fully initialized table from add_child(). No gameplay ticks run between slices.
signal finished
var complete := false
var slice_started := Time.get_ticks_usec()

func checkpoint(tree: SceneTree) -> void:
	if Time.get_ticks_usec() - slice_started >= 4000:
		await tree.process_frame
		slice_started = Time.get_ticks_usec()

func finish(table: Node) -> void:
	complete = true
	table.remove_meta("shift_setup")
	finished.emit()

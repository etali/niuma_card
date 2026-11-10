extends SceneTree

## Real players under the Dummy mixer, deterministic event clock, no user-data writes.
class ClockedSfx:
	extends "res://scenes/sfx.gd"
	var clock_usec := 1000000
	func _now_usec() -> int:
		return clock_usec

class ClockedAudio:
	extends "res://scenes/off_work_audio.gd"
	var clock_usec := 1000000
	func _now_usec() -> int:
		return clock_usec

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, description: String) -> void:
	checks+=1
	if not ok: failures.append(description)

func _run() -> void:
	var previous_mute := AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0,true)
	var settings: Dictionary = UIConfig.read_section("presentation").audio
	var sfx := ClockedSfx.new()
	root.add_child(sfx)
	sfx.user_muted=false
	sfx.set_drawer_suspended(false)
	_arrivals(sfx,settings)
	var audio := ClockedAudio.new()
	root.add_child(audio)
	audio.setup(settings,true)
	audio.set_process(false)
	_production(audio,settings)
	_ordinary_event_budget(audio,settings)
	_pending(audio)
	audio.stop_all()
	for player in sfx._players: player.stop()
	# All bursts run in the first frame. Let the actual mixer consume their
	# starts/stops before freeing players; a game-time timer can include loading.
	await _wait_real(0.08)
	sfx.queue_free()
	audio.queue_free()
	await process_frame
	await _wait_real(0.08)
	AudioServer.set_bus_mute(0,previous_mute)
	for failure in failures: printerr("FAIL ",failure)
	print("OFF_WORK_AUDIO_BURSTS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func _wait_real(seconds: float) -> void:
	var deadline := Time.get_ticks_usec()+int(seconds*1000000.0)
	while Time.get_ticks_usec()<deadline: await process_frame

func _arrivals(sfx: Node, settings: Dictionary) -> void:
	# Without the realtime scene's overrides, original per-card arrivals remain.
	for _index in 5: sfx.play("produce_land")
	check(sfx._next==5, "shared default keeps every original-mode arrival")
	check(is_equal_approx(Sfx.action("produce_land").db,Sfx.action("card_drop").db), "shared arrival loudness contract is unchanged")
	for player in sfx._players: player.stop()
	sfx._next=0
	sfx.configure_action_overrides(settings.arrival_actions)
	for _index in 1000: sfx.play("produce_land")
	check(sfx._next==1, "one thousand simultaneous arrivals coalesce into one hit")
	check(is_equal_approx(sfx._players[0].volume_db,float(settings.arrival_actions.produce_land.db)), "realtime arrival uses its quieter scene-local gain")
	sfx.clock_usec+=int(float(settings.arrival_actions.produce_land.min_interval_seconds)*1000000.0)
	sfx.play("produce_land")
	check(sfx._next==2, "a spaced arrival preserves its own feedback")
	sfx.clock_usec+=1000000
	sfx.play("produce_land")
	check(sfx._next==2, "overlapping hits remain bounded even after the time gate opens")
	sfx._players[0].stop()
	sfx.play("produce_land")
	check(sfx._next==3, "a finished hit releases its voice for the next arrival")
	check(sfx._players[1].playing, "new arrivals do not truncate an existing hit")
	# Simulate a full effects pool: automatic bursts may not clip manual feedback.
	for _index in sfx._players.size(): sfx.play("card_pickup")
	var before: int = sfx._next
	sfx.clock_usec+=1000000
	sfx.play("produce_coin")
	check(sfx._next==before, "automatic coin sound cannot steal from a full pool")
	sfx.play("card_pickup")
	check(sfx._next==(before+1)%sfx._players.size(), "manual card feedback still responds during a burst")
	# The instance policy cannot mutate the shared action dictionary.
	check(not Sfx.action("produce_land").has("max_voices"), "scene-specific arrival limits do not leak into the other mode")
	sfx.configure_action_overrides({})
	before=sfx._next
	sfx.play("produce_land")
	sfx.play("produce_land")
	check(sfx._next==(before+2)%sfx._players.size(), "missing optional arrival configuration keeps legacy behavior")

func _production(audio: Node, settings: Dictionary) -> void:
	for _index in 1000: audio.play("work_complete")
	check(audio._played==1, "dense production settles with one bounded sound")
	# A per-frame cap alone fails this case at high refresh rates.
	audio._process(0.0)
	audio.play("work_complete")
	check(audio._played==0, "a new render frame cannot bypass the real-time sound interval")
	for player in audio._players: player.stop()
	audio.clock_usec+=int(float(settings.actions.work_complete.min_interval_seconds)*1000000.0)
	audio.play("work_complete")
	check(audio._played==1, "separate completed production still gives feedback")
	audio.play("transfer")
	audio.play("outsource")
	check(audio._played==int(settings.max_per_frame), "automatic actions share the bounded per-frame transient budget")
	audio.play("coffee_upgrade")
	check(audio._played==int(settings.max_per_frame), "another automatic action cannot exceed the burst budget")
	audio.play("pickup")
	audio.play("win")
	check(audio._played==int(settings.max_per_frame)+2, "manual interaction and victory feedback survive a production burst")
	audio.stop_all()
	check(audio._last_started_usec.is_empty(), "new game clears old sound timing gates")
	audio.play("work_complete")
	check(audio._played==1, "new game can immediately produce its first sound")
	audio.stop_all()

func _ordinary_event_budget(audio: Node, settings: Dictionary) -> void:
	# These events have no per-action voice cap; omission must not make them
	# unlimited or let a burst repeatedly restart all ten pooled players.
	for action in ["fire","meeting_start","meeting_end","strike","buy"]:
		audio.stop_all()
		for _index in 1000: audio.play(action)
		check(audio._played==int(settings.max_per_frame), "ordinary %s keeps the original frame budget without an explicit voice limit" % action)
	audio.stop_all()
	for _index in int(settings.max_per_frame): audio.play("fire")
	var accepted: int = audio._played
	for action in ["pickup","drop","deny","win","lose","off_work_result_stamp","off_work_result_tail"]:
		audio.play(action)
		accepted+=1
		check(audio._played==accepted, "explicitly prioritized %s remains audible after an ordinary burst" % action)
	audio.stop_all()

func _pending(audio: Node) -> void:
	for index in 1000: audio.schedule("transfer",1.0+float(index%3)*0.01)
	check(audio._pending.size()==1, "simultaneous delayed transfers do not accumulate a playback backlog")
	audio.schedule("transfer",0.99)
	check(is_equal_approx(audio._pending[0].delay,0.99), "coalescing keeps the first arrival time")
	audio.schedule("transfer",2.0)
	check(audio._pending.size()==2, "distinct arrivals keep their own delayed feedback")
	audio.muted=true
	check(audio._pending.is_empty(), "muting discards delayed sounds instead of replaying them later")
	audio.schedule("transfer",1.0)
	check(audio._pending.is_empty(), "muted production cannot queue stale sounds")
	audio.muted=false

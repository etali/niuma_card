# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Lesson = preload("res://engine/off_work_tutorial.gd")
const Progress = preload("res://engine/tutorial_progress.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	OS.set_environment("CARD_DATA_DIR", OS.get_cache_dir().path_join("niuma-tests/tool-lessons-%d" % OS.get_process_id()))
	_extract()
	_meeting()
	_meeting_recovery()
	_misassigned_host()
	_transfer()
	_transfer_recovery()
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_TOOL_LESSON_LOGIC %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func course(id: String) -> Dictionary:
	var tutor := Lesson.new()
	check(tutor.start(id), id + " exists in the real course catalog")
	var world := OffWorkState.new(tutor.make_config())
	world.new_game(43)
	tutor.setup_world(world)
	world.drain_events()
	return {"tutor": tutor, "world": world}

func settle(c: Dictionary, seconds: float) -> Array:
	c.world.advance(c.tutor.clock_delta(c.world, seconds))
	var events: Array = c.world.drain_events()
	c.tutor.observe(c.world, events)
	return events

func move(c: Dictionary, ids: Array, group := -1, person := -1) -> void:
	check(c.world.move_cards(ids, group, person) >= 0, "guided combination uses a legal real move")
	c.tutor.observe(c.world, c.world.drain_events())

func owned(c: Dictionary, kind: String, owner := 0) -> Array:
	return c.world._owner_type(owner, kind)

func _extract() -> void:
	var c := course("extract")
	var source: int = c.tutor.source_group()
	var people: Array = c.tutor.extract_ids()
	check(people.size() == 3 and c.world.group_cards(source).size() == 204, "the deep stack contains the exact mixed demonstration materials")
	settle(c, 60)
	check(c.world.time == 0 and c.world.work_count(0) == 200, "reading the extraction instruction never consumes work")
	c.tutor.observe(c.world, [], {"source_group":source,"type":"work","inspected":true})
	check(c.tutor.step == 0, "looking at another material type cannot complete employee inspection")
	c.tutor.observe(c.world, [], {"source_group":source,"type":"employee","inspected":true})
	check(c.tutor.step == 1 and c.world.group_cards(source).size() == 204, "inspection advances without splitting any logical cards")
	move(c, [people[0]])
	check(not c.tutor.complete(), "taking just one employee cannot complete extraction of the whole type")
	var destination: int = c.world.cards[people[0]].group
	var overtime: int = owned(c, "overtime")[0]
	move(c, [people[1],people[2],overtime], destination)
	check(not c.tutor.complete(), "employees mixed with an accidentally extracted material do not pass")
	move(c, [overtime], source)
	check(c.tutor.complete() and c.world.group_cards(source).size() == 201, "putting the extra material back completes a true three-employee extraction")
	check(Progress.course("extract",true).status == "completed", "manual classification extraction records completion")
	var demo := course("extract")
	check(demo.tutor.demonstrate(demo.world) and demo.tutor.step == 0, "the model waits for real panel inspection after the scene's demo request")
	demo.tutor.observe(demo.world, [], {"source_group":demo.tutor.source_group(),"type":"employee","inspected":true})
	move(demo, [demo.tutor.extract_ids()[0]])
	check(demo.tutor.step == 1, "extracting only one employee leaves the remaining type extraction actionable")
	check(demo.tutor.demonstrate(demo.world), "extraction demo reunites all tracked UIDs after a partial manual extraction")
	demo.tutor.observe(demo.world, demo.world.drain_events())
	check(demo.tutor.complete() and demo.tutor.used_demo, "demo completion is distinguished from a fresh manual attempt")

func _meeting() -> void:
	var c := course("meeting")
	settle(c, 60)
	check(c.world.time == 0, "meeting setup instructions pause both tables")
	var tool: int = owned(c, "meeting")[0]
	var leader: int = owned(c, "leader")[0]
	var worker: int = owned(c, "employee")[0]
	var enemy: int = owned(c, "employee",1)[0]
	move(c, [tool], c.world.cards[leader].group, leader)
	check(c.tutor.step == 1 and c.world.tasks[leader].kind == "meeting", "a real independent host starts the meeting objective")
	check(c.world.is_meeting_target(enemy) and c.world.tasks[worker].kind == "work", "the rival pauses while our other employee keeps working")
	var events := settle(c, 60)
	check(c.world.time == 2.0 and c.world.work_count(0) == 39 and c.world.work_count(1) == 40, "the waiting clock stops at our first income while the rival remains interrupted")
	check(c.tutor.complete() and events.any(func(e): return e.kind == "work_complete" and e.owner == 0), "the meeting lesson requires real work settlement during the meeting")
	settle(c, 60)
	check(c.world.time == 2.0, "reading completed meeting feedback cannot expire the meeting")

func _meeting_recovery() -> void:
	var c := course("meeting")
	check(c.tutor.demonstrate(c.world), "meeting demo uses the real tool combination")
	c.tutor.observe(c.world,c.world.drain_events())
	var tool: int = owned(c, "meeting")[0]
	move(c, [tool])
	check(c.tutor.step == 0 and "冷却" in c.tutor.last_feedback, "breaking the meeting returns to a concrete recovery instruction")
	var remaining: float = c.world.cards[tool].remaining
	check(remaining > 0 and c.tutor.clock_delta(c.world, 90) == remaining, "a cancelled meeting can finish its actual cooldown")
	settle(c, 90)
	check(c.world.cards[tool].status == "ready" and c.world.time == remaining and c.world.winner < 0, "recovery stops at readiness without a new meeting or match ending")
	settle(c, 90)
	check(c.world.time == remaining, "after cooldown, reading the setup step freezes time again")
	check(c.tutor.demonstrate(c.world), "the same recovered meeting card can be demonstrated again")
	c.tutor.observe(c.world,c.world.drain_events())
	settle(c, 60)
	check(c.tutor.complete(), "a cancelled meeting can still finish the lesson")

func _misassigned_host() -> void:
	var c := course("meeting")
	var tool: int = owned(c, "meeting")[0]
	var worker: int = owned(c, "employee")[0]
	var leader: int = owned(c, "leader")[0]
	var workplace: int = c.world.cards[worker].group
	move(c, [tool], workplace, worker)
	check(c.tutor.step == 0, "using the sole worker as host cannot skip the requirement to retain production")
	settle(c, 90)
	check(c.world.time == 0 and c.world.winner < 0, "reading after a mistaken worker-host assignment cannot exhaust the lesson")
	check(c.tutor.demonstrate(c.world), "demonstration undoes the mistaken meeting using an actual tool move")
	c.tutor.observe(c.world,c.world.drain_events())
	check(c.tutor.step == 1 and c.world.meetings.has(tool), "the misplaced tool never claimed the work pile and can immediately move to an independent host")
	move(c, [leader], workplace)
	check(c.tutor.step == 0, "moving the leader away from the meeting returns to its setup")
	settle(c, 90)
	check(c.world.winner < 0 and c.tutor.clock_delta(c.world, 90) == 0,
		"two successive mistakes finish cooldown without ending the match or running during rereading")
	check(c.tutor.demonstrate(c.world), "demonstration separates the misassigned leader from the work stack")
	c.tutor.observe(c.world,c.world.drain_events())
	settle(c, 90)
	check(c.tutor.complete(), "reassigning the host and then undoing that mistake still allows completion")

func _transfer() -> void:
	var c := course("transfer")
	settle(c, 60)
	check(c.world.time == 0, "transfer setup does not silently send a batch")
	var tool: int = owned(c, "transfer")[0]
	var worker: int = owned(c, "employee")[0]
	var group: int = c.world.cards[tool].group
	var cash: int = c.world.money(0)
	check(c.world.group_people(group).is_empty() and not c.world.tasks.has(worker), "transfer lesson starts with an independent employee and a prepared work/tool pile")
	move(c, [worker], group, worker)
	check(c.tutor.step == 1 and c.world.tasks[worker].kind == "transfer", "combining the actual tool creates a transfer task")
	var events := settle(c, 60)
	check(c.tutor.step == 2 and c.world.time == c.world.config.number("transfer","seconds"), "the wait stops on the first actual transfer")
	check(c.world.work_count(0) == 11 and c.world.work_count(1) == 13 and c.world.money(0) == cash, "sent work is received by the rival with zero work income")
	check(events.any(func(e): return e.kind == "transfer" and e.owner == 0), "the transfer objective is grounded in the settlement event")
	var at: float = c.world.time
	settle(c, 60)
	check(c.world.time == at and c.world.work_count(1) == 13, "reading the removal instruction cannot send another batch")
	move(c, [tool])
	events = settle(c, 60)
	check(c.tutor.complete() and c.world.money(0) > cash and events.any(func(e): return e.kind == "work_complete" and e.owner == 0), "removing the tool restores real production and income")

func _transfer_recovery() -> void:
	var c := course("transfer")
	check(c.tutor.demonstrate(c.world), "transfer demonstration starts through the real action")
	c.tutor.observe(c.world,c.world.drain_events())
	settle(c, 1.0)
	var tool: int = owned(c, "transfer")[0]
	move(c, [tool])
	check(c.tutor.step == 0, "breaking the first cycle returns to its combination step")
	settle(c, 60)
	check(c.world.time == 1.0, "reading after a broken transfer does not finish the practice match")
	check(c.tutor.demonstrate(c.world), "transfer can be assembled again after a mistaken extraction")
	c.tutor.observe(c.world,c.world.drain_events())
	settle(c, 60)
	check(c.tutor.step == 2, "the repaired combination sends a real full batch")
	check(c.tutor.demonstrate(c.world), "resume demonstration actually removes the transfer tool")
	c.tutor.observe(c.world,c.world.drain_events())
	settle(c, 60)
	check(c.tutor.complete() and c.tutor.used_demo, "repaired and demonstrated transfer can complete")

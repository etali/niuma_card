extends SceneTree

const Plans = preload("res://engine/off_work_bot_attack_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_owned_strike()
	_public_purchase()
	_meeting_sample()
	_availability()
	_deadline()
	for failure in failures: printerr("FAIL ",failure)
	print("OFF_WORK_BOT_ATTACK_PLANS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func _world(people := 2) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":people,"work":40}]
	config.rules.initial.money = 20
	var world := OffWorkState.new(config)
	world.new_game(341)
	world.offers.clear()
	world.drain_events()
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	fields.append(world._rng.state)
	return var_to_bytes(fields)

func _owned_strike() -> void:
	var world := _world()
	var target: int = world._owner_type(1,"employee")[0]
	var group: int = world.cards[target].group
	var boss := world.add_card("boss",1,group)
	var protected := world.add_card("union",1)
	var protected_group: int = world.cards[protected].group
	world.add_card("employee",1,protected_group)
	world.add_card("work",1,protected_group)
	var tool := world.add_card("strike",0)
	world.add_card("strike",1)
	for i in 12: world.add_card("strike",0)
	world.advance(0.0)
	var before := _snapshot(world)
	var generated: Dictionary = Plans.plans(world,0)
	_check(generated.complete and _snapshot(world)==before,"enumeration preserves all world fields and the private RNG")
	_check(generated.plans.size()==1,"equivalent owned inventory is one single-use continuation, never thirteen free attacks")
	if generated.plans.is_empty(): return
	var plan: Dictionary = generated.plans[0]
	_check(plan.kind=="strike" and plan.tool==tool and plan.target_group==group,"owned strike selects a real enemy target and tool")
	_check(plan.targets.size()==2 and not plan.targets.has(boss),"targets contain the actual eligible people, excluding the immune boss")
	_check(not plan.has("host") and not plan.has("price"),"strike needs neither a host nor a fictitious purchase")
	_check(is_equal_approx(plan.flight_seconds,1.2) and is_equal_approx(plan.duration_seconds,20.0),"travel and strike duration come from current rules")
	_check(Actions.apply_action(world,0,{"kind":"activate","tool":plan.tool,"group":plan.target_group}),"owned plan can launch through the shared real action path")
	_check(world.pending_strikes.has(tool),"attack waits for its authoritative flight rather than applying immediate damage")
	world.advance(float(plan.flight_seconds)*0.5)
	_check(plan.targets.all(func(id): return not world.is_striking(id)),"targets keep working during the response window")
	world.advance(float(plan.flight_seconds)*0.5)
	_check(plan.targets.all(func(id): return world.is_striking(id)),"arrival strikes every eligible target from the plan")
	_check(world.cards.has(boss) and not world.is_striking(boss) and not world.cards.has(tool),"real arrival preserves the boss and consumes exactly the used strike")

func _public_purchase() -> void:
	var world := _world()
	var offer: Dictionary = world._make_offer("strike")
	world.offers = [offer,{},world._make_offer("meeting")]
	world._conveyor_elapsed = 0.75
	var before := _snapshot(world)
	var generated: Dictionary = Plans.plans(world,0)
	_check(generated.complete and before==_snapshot(world),"public plans neither consume the quote nor sample the future market")
	var strikes: Array = generated.plans.filter(func(plan): return plan.kind=="strike")
	_check(strikes.size()==1,"each currently visible strike quote gets its own purchase-use alternative")
	if strikes.is_empty(): return
	var plan: Dictionary = strikes[0]
	_check(plan.offer==offer.id and plan.price==offer.price and not plan.has("tool"),"the purchase plan records the exact public quote and price")
	_check(is_equal_approx(plan.expires,1.25),"quote expiry includes its conveyor position and elapsed time")
	var money := world.money(0)
	var bought := world.buy(int(plan.offer),0)
	_check(bought>=0 and world.money(0)==money-int(plan.price),"buying pays the actual quoted price once")
	_check(world.pending_strikes.is_empty(),"purchase alone never grants a free activation")
	world.advance(0.2)
	_check(Actions.apply_action(world,0,{"kind":"activate","tool":bought,"group":plan.target_group}),"a separate later operation legally uses the purchased card")
	var stale := _world()
	var stale_offer: Dictionary = stale._make_offer("strike")
	stale.offers=[stale_offer]
	var stale_plan: Dictionary = Plans.plans(stale,0).plans[0]
	stale.advance(float(stale_plan.expires))
	_check(stale.buy(int(stale_plan.offer),0)<0,"the rule engine rejects a plan whose purchase missed its public expiry")
	var limited := _world()
	limited.config.cards.strike.max_per_owner=1
	limited.add_card("strike",0)
	limited.offers=[limited._make_offer("strike")]
	_check(Plans.plans(limited,0).plans.all(func(row): return not row.has("offer")),"real ownership limits suppress an impossible extra purchase")

func _meeting_sample() -> void:
	var world := _world(6)
	var host := world.add_card("leader",0)
	var tool := world.add_card("meeting",0)
	var enemy_leader := world.add_card("leader",1)
	var enemy_boss := world.add_card("boss",1)
	world.offers=[world._make_offer("meeting")]
	var before := _snapshot(world)
	var generated: Dictionary = Plans.plans(world,0)
	_check(generated.complete and before==_snapshot(world),"meeting hypotheses do not draw from the real meeting RNG")
	var matches: Array = generated.plans.filter(func(plan): return plan.kind=="meeting" and plan.host==host)
	_check(matches.size()==2,"ready owned meeting and public purchase share a real eligible host")
	if matches.size()!=2: return
	var plan: Dictionary = matches.filter(func(row): return row.has("tool"))[0]
	var purchase: Dictionary = matches.filter(func(row): return row.has("offer"))[0]
	_check(plan.targets==purchase.targets and plan.sample_seed==purchase.sample_seed,"owning versus purchasing cannot change the public target sample")
	_check(plan.sampled_targets and plan.targets.size()==world.config.meeting_capacity("leader"),"sample uses the host's configured capacity")
	_check(not plan.targets.has(enemy_leader) and not plan.targets.has(enemy_boss),"meeting immunity is read from real role rules")
	_check(plan.targets.all(func(id): return world.meeting_candidates(0).has(id)),"all sampled targets are presently legal")
	var seen := {}
	for id in plan.targets: seen[id]=true
	_check(seen.size()==plan.targets.size(),"meeting sample draws without replacement")
	world._rng.seed=93741
	var different_secret: Dictionary = Plans.plans(world,0)
	_check(generated.plans==different_secret.plans,"changing private RNG state does not change the public continuation")
	world._rng.seed=int(plan.sample_seed)
	_check(Actions.apply_action(world,0,{"kind":"move","ids":[tool,host],"group":-1,"person":host}),"one real assembly operation starts the host and owned meeting in an independent group")
	_check(world.meetings.has(tool) and world.meetings[tool].targets==plan.targets,"with the public hypothetical seed the real rule draws exactly this legal sample")
	_check(world.tasks[host].kind=="meeting" and plan.targets.all(func(id): return world.is_meeting_target(id)),"the host is occupied and only the sampled opponents are paused")
	_check(is_equal_approx(world.meetings[tool].remaining,plan.duration_seconds),"projected meeting duration matches real activation")
	_check(Plans.plans(world,0).plans.all(func(row): return row.get("tool",-1)!=tool),"an already active meeting is not counted as another free attack")

func _availability() -> void:
	var world := _world()
	var host: int = world._owner_type(0,"employee")[0]
	var tool := world.add_card("meeting",0)
	world.cards[tool].status="recovering"
	world.cards[tool].remaining=3.5
	world.cards[tool].total=24.0
	var generated: Dictionary = Plans.plans(world,0)
	_check(not generated.plans.is_empty() and generated.plans.all(func(plan): return is_equal_approx(plan.ready_seconds,3.5)),"recovering tools retain their real readiness delay for the common scheduler")
	_check(not world.activate(tool,int(world.cards[tool].group),host),"the real tool cannot be activated before readiness")
	var cup := world.add_card("coffee",0)
	world.move_cards([host,cup],-1,host)
	_check(world.tasks.get(host,{}).get("kind")=="coffee","busy-host fixture starts a real recipe")
	_check(Plans.plans(world,0).plans.all(func(plan): return plan.host!=host),"an upgrading person is not a free meeting host")
	world.advance(3.5)
	_check(world.cards[tool].status=="ready","the recorded readiness matches the real cooldown")

func _deadline() -> void:
	var world := _world()
	world.add_card("strike",0)
	var before := _snapshot(world)
	var generated: Dictionary = Plans.plans(world,0,Time.get_ticks_usec()-1)
	_check(not generated.complete and generated.plans.is_empty(),"expired budget returns no partially fabricated plans")
	_check(_snapshot(world)==before,"deadline exit preserves the entire observation")
	_check(Plans.plans(world,9).plans.is_empty(),"unknown owners receive no legal attack plans")
	world.winner=0
	_check(Plans.plans(world,0).plans.is_empty(),"finished matches have no future attack continuation")

func _check(condition: bool, message: String) -> void:
	checks+=1
	if not condition: failures.append(message)

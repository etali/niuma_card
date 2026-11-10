# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## One continuation tree for every legal action. Search ordering may decide
## which prefix receives computation next; only a complete, rule-executed
## prefix and the common completion-time evaluator decide its value.
## In particular there are no card-specific recipes, investment priorities,
## stock targets, or bonuses for owning a production resource here.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Cursor = preload("res://engine/off_work_bot_plan_cursor.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")

static func available(world: OffWorkState, _owner: int, until := -1, cancelled: Callable = Callable()) -> bool:
	return world.winner < 0 and (until < 0 or Time.get_ticks_usec() < until) \
		and not (cancelled.is_valid() and cancelled.call())

static func visit(world: OffWorkState, owner: int, policy: Dictionary, until: int,
		clock: Array, visitor: Callable, cancelled: Callable = Callable(), options: Dictionary = {}) -> Dictionary:
	var empty := {"complete":false,"plans":0,"examined":0,"pending":false,"root_actions":0,
		"root_serviced":0,"max_depth":0,"release_reserve_us":0}
	if not available(world,owner,until,cancelled):
		empty.complete = world.winner >= 0
		return empty
	var state: Dictionary = options.get("planner_state",{})
	var identity := [world.get_instance_id(),world.revision,world.time,owner]
	if state.get("identity",[]) != identity:
		state.clear()
		var planner := Planner.new()
		planner.source=world
		planner.owner=owner
		planner.policy=policy
		planner.period=maxf(0.001,float(policy.get("think_seconds",world.config.rules.bot.think_seconds)))
		planner.horizon=maxf(planner.period,float(policy.get("evaluation_max_seconds",1800.0)))
		planner.next_actions=clock.duplicate() if clock.size()==2 else [planner.period,planner.period]
		planner.options=options.duplicate()
		planner.options.erase("planner_state")
		planner.until=until
		planner.cancelled=cancelled
		state.identity=identity
		state.planner=planner
	var planner: RefCounted = state.planner
	planner.until=until
	planner.cancelled=cancelled
	planner.visitor=visitor
	return planner.run(int(options.get("checkpoint_limit",-1)))

class Planner extends Cursor:
	var options := {}
	var visitor: Callable
	var evaluator := Evaluation.new()
	var nodes: Array = []
	var initialized := false
	var finished := false
	var emitted := 0
	var examined := 0
	var depth_reached := 0
	var access_clock := 0
	var release_reserve := 0
	var cache_limit := 2
	var root_serviced := {}
	var root_count := 0
	var refined_roots := {}
	var episode_node := -1
	var episode_active := false
	var episode_expansions := 0
	var episode_deferred := {}
	var episode_path_peak := 0
	var episode_peak := 0
	var exploration_episodes := 0
	var empty_wait_yields := 0
	const EPISODE_EXPANSION_LIMIT := 20
	var episode_batch: Array = []
	var sampled_root_for_batch := false
	var seed_only := false
	var episodes := 0
	var warm_started := false
	var warm_active := false
	var warm_pending_root := false
	var warm_complete := false
	var warm_root_index := -1
	var warm_examined := 0

	func _open() -> bool:
		# Retained worlds are freed when this search-local planner is released.
		# Their destruction belongs to this same decision's wall-clock budget.
		if (until>=0 and Time.get_ticks_usec()>=until-release_reserve) \
			or (cancelled.is_valid() and cancelled.call()):
			complete=false
		return complete

	func _cursor(world: OffWorkState, previous: Dictionary = {}) -> Dictionary:
		if not _open(): return {}
		if until>=0 and until-release_reserve-Time.get_ticks_usec()<=Budget.fork_cost(world)+Budget.release_cost(world):
			complete=false
			return {}
		var cursor: Dictionary=super._cursor(world,previous)
		if not cursor.is_empty():
			cursor.enemy_context=previous.get("enemy_context",{}).duplicate(true)
			cursor.enemy_next=float(previous.get("enemy_next",next_actions[1-owner]))
			cursor.enemy_bound=previous.get("enemy_bound",false)
			cursor.root_replied=previous.get("root_replied",false)
			cursor.enemy_use=previous.get("enemy_use",{}).duplicate(true)
			var cost: int=Budget.release_cost(cursor.world)
			cursor["_release_reservation"]=cost
			release_reserve+=cost
		return cursor

	func _discard_cursor(cursor: Dictionary) -> void:
		cursor.world=null
		release_reserve-=int(cursor.get("_release_reservation",0))
		cursor.erase("_release_reservation")

	func _advance(cursor: Dictionary, at: float) -> bool:
		if not _open() or cursor.world.winner>=0 or at>horizon: return false
		var delta := maxf(0.0,source.time+at-float(cursor.world.time))
		var limit := until-release_reserve if until>=0 else -1
		if delta>0.0 and not cursor.world.advance_for_search(delta,limit,cancelled):
			complete=false
			return false
		cursor.world.mask_search_market(source._next_offer)
		return _open() and cursor.world.winner<0

	func _bind_opponent(cursor: Dictionary, value: Dictionary, elapsed: float, clock: Array = []) -> void:
		if not options.get("physical_opponent",false) or cursor.enemy_bound: return
		cursor.enemy_bound=true
		var sides: Array=value.get("detail",{}).get("sides",[])
		if sides.size()!=2: return
		var steps := _physical_steps(cursor.world,sides[1-owner].get("forecast_commands",[]))
		# These are only dispatches already assumed by this physical tail.
		# No deeper leaf can invent another investment or postpone this queue.
		for step in steps: step.independent=true
		cursor.enemy_context={} if steps.is_empty() else {"observed_at":cursor.world.time,"source":"forecast","steps":steps}
		var next := float(next_actions[1-owner])
		if not cursor.replies.is_empty(): next=maxf(next,float(cursor.replies[-1].at)+period)
		if next<elapsed: next+=ceil((elapsed-next)/period)*period
		cursor.enemy_next=elapsed+float(clock[1-owner]) if clock.size()==2 else next

	func _refresh_opponent(cursor: Dictionary, value: Dictionary) -> void:
		if not options.get("physical_opponent",false): return
		var sides: Array=value.get("detail",{}).get("sides",[])
		if sides.size()!=2: return
		var pending: Array=cursor.enemy_context.get("steps",[])
		var steps := _physical_steps(cursor.world,sides[1-owner].get("forecast_commands",[]))
		for step in steps:
			# A later real strike can create a new return obligation. Preserve
			# every already scheduled obligation and add only newly idle people;
			# re-evaluating a deeper leaf must never shift an existing ready_at.
			step.items=step.items.filter(func(item):return not pending.any(func(prior):
				return Execution.same_destination(prior.group,step.group) and prior.items.any(func(existing):return item==existing)))
			if step.items.is_empty(): continue
			step.independent=true
			_merge_physical_step(pending,step)
		if not pending.is_empty():
			cursor.enemy_context={"observed_at":cursor.world.time,"source":"forecast","steps":pending}

	func _physical_steps(world: OffWorkState, commands: Array) -> Array:
		return Execution.physical_steps(world,1-owner,commands,0.0,{},until-release_reserve if until>=0 else -1)

	func _merge_physical_step(steps: Array, step: Dictionary) -> void:
		Execution.merge_physical_step(steps,step)

	func _slot(cursor: Dictionary) -> bool:
		return _advance_shared(cursor,float(cursor.next))

	func _advance_shared(cursor: Dictionary, at: float) -> bool:
		if not options.get("physical_opponent",false) and cursor.get("enemy_use",{}).is_empty(): return _advance(cursor,at)
		# At equal times use the engine's seat order, and leave this owner's
		# next command unspent. All other elapsed enemy slots are consumed once.
		var edge := at-1e-8 if owner<1-owner else at+1e-8
		while float(cursor.enemy_next)<=edge and _open() and cursor.world.winner<0:
			if cursor.enemy_context.is_empty() and cursor.get("enemy_use",{}).is_empty():
				cursor.enemy_next+=maxf(1.0,floor((edge-float(cursor.enemy_next))/period)+1.0)*period
				break
			var slot := float(cursor.enemy_next)
			if not _advance(cursor,slot): return false
			if not cursor.get("enemy_use",{}).is_empty() and float(cursor.enemy_use.at)<=slot+1e-8:
				var use := _enemy_use_choice(cursor,slot)
				if use.is_empty(): return false
				var paid: Dictionary=Execution.resolve(cursor.world,1-owner,cursor.enemy_context,until-release_reserve if until>=0 else -1)
				cursor.enemy_context=paid.context
				cursor.enemy_use={}
				if not _reply(cursor,1-owner,use.action,slot): return false
				if _same_action(paid.action,use.action): cursor.enemy_context=Execution.consumed(cursor.enemy_context,paid.action)
				cursor.enemy_next=slot+period
				_refresh_opponent(cursor,use.value)
				continue
			var resolved: Dictionary=Execution.resolve(cursor.world,1-owner,cursor.enemy_context,
				until-release_reserve if until>=0 else -1)
			cursor.enemy_context=resolved.context
			if not _open(): return false
			if resolved.action.kind!="wait":
				var action: Dictionary=resolved.action.duplicate(true)
				action.erase("execution_continuation")
				action.erase("execution_step")
				if not _reply(cursor,1-owner,action,slot): return false
				cursor.enemy_context=Execution.consumed(cursor.enemy_context,resolved.action)
			cursor.enemy_next=slot+period
		return _advance(cursor,at)

	func _plan(cursor: Dictionary, kind: String, person := -1) -> Dictionary:
		var plan: Dictionary=super._plan(cursor,kind,person)
		if options.get("physical_opponent",false):
			plan.next_actions[1-owner]=maxf(0.0,float(cursor.enemy_next)-float(plan.elapsed))
		plan["opponent_use_pending"]=cursor.world.winner<0 and not cursor.get("enemy_use",{}).is_empty()
		return plan

	func _reply_resources(before: OffWorkState, after: OffWorkState) -> Array:
		var ids := []
		for id in after.activity_card_ids(1-owner):
			if not _open(): break
			# An already used tool becoming busy has delivered its real effect;
			# it does not create another use obligation. New/converted resources
			# still need their own subsequent command, independent of card kind.
			if not before.cards.has(id) or before.cards[id].type!=after.cards[id].type: ids.append(id)
		return ids

	func _enemy_use_choice(cursor: Dictionary, at: float) -> Dictionary:
		# One finite response to resources created/activated by the first reply.
		# Use the authoritative action set again at the real slot: a defence can
		# change which uses remain legal. No tool receives a stand-alone bonus.
		var ids: Array=cursor.enemy_use.get("ids",[])
		var generated: Dictionary=Actions.generate(cursor.world,1-owner,policy,
			until-release_reserve if until>=0 else -1,cancelled)
		if not generated.complete or not _open(): complete=false;return {}
		var paid: Dictionary=Execution.resolve(cursor.world,1-owner,cursor.enemy_context,until-release_reserve if until>=0 else -1)
		var actions: Array=generated.actions
		if paid.action.kind!="wait":
			var service: Dictionary=paid.action.duplicate(true)
			service.erase("execution_continuation")
			service.erase("execution_step")
			actions=actions.filter(func(action):return not _same_action(action,service))
			actions.push_front(service)
		var best := {}
		for action in actions:
			if not _open(): return {}
			if action.kind!="wait" and not action.get("ids",[]).any(func(id):return ids.has(id)) \
				and not ids.has(int(action.get("person",-1))) and not ids.has(int(action.get("tool",-1))) \
				and not _same_action(action,paid.action): continue
			var trial := _cursor(cursor.world,cursor)
			if trial.is_empty(): return {}
			if not _reply(trial,1-owner,action,at):
				_discard_cursor(trial)
				if not _open(): return {}
				continue
			trial.enemy_next=at+period
			trial.enemy_use={}
			var plan := _plan(trial,"legal_continuation")
			var value: Dictionary=evaluator.evaluate_current(trial.world,owner,policy,
				until-release_reserve if until>=0 else -1,plan.next_actions)
			if not value.get("complete",false):
				_discard_cursor(trial)
				complete=false
				return {}
			var utility := _reply_utility(value,trial)
			if best.is_empty() or utility[0]<best.utility[0] or (utility[0]==best.utility[0] and utility[1]<best.utility[1]):
				best={"action":action.duplicate(true),"value":value,"utility":utility}
			_discard_cursor(trial)
		return best if _open() else {}

	func _root_response(cursor: Dictionary, baseline: Dictionary = {}) -> Dictionary:
		# Every root faces the same finite reply portfolio discovered by the
		# tactical search. Select the worst fully executed reply in THIS world;
		# an unranked root never receives a free pass from the other seat.
		var at := float(next_actions[1-owner])
		if not _advance(cursor,at):
			if cursor.world.winner<0 or not _open(): return {}
			# Natural completion before the enemy slot is a real terminal result,
			# not an invalid reply. Keep this cursor; no enemy action occurred.
			var terminal := evaluator.evaluate_current(cursor.world,owner,policy,until-release_reserve if until>=0 else -1)
			cursor.root_replied=true
			cursor.enemy_bound=true
			cursor.enemy_context={}
			return {"cursor":cursor,"value":terminal,"reuse_cursor":true}
		var clock := [0.0,0.0]
		clock[owner]=maxf(0.0,float(cursor.next)-at)
		var value: Dictionary=baseline
		if value.is_empty(): value=evaluator.evaluate_current(cursor.world,owner,policy,until-release_reserve if until>=0 else -1,clock)
		if not value.get("complete",false): return {}
		cursor.enemy_bound=false
		cursor.enemy_context={}
		_bind_opponent(cursor,value,at,clock)
		var candidates: Array=options.get("root_replies",[]).duplicate(true)
		# Servicing an already paid worker is a common physical policy, too.
		# A wait-only tactical portfolio must not postpone that first service.
		var paid: Dictionary=Execution.resolve(cursor.world,1-owner,cursor.enemy_context,until-release_reserve if until>=0 else -1)
		if paid.action.kind!="wait":
			candidates=candidates.filter(func(action):return not _same_action(action,paid.action))
			var action: Dictionary=paid.action.duplicate(true)
			action.erase("execution_continuation")
			action.erase("execution_step")
			# Keep the already paid service first only for exactly equal values;
			# a worse evaluated reply still replaces it normally below.
			candidates.push_front(action)
		var best := {}
		for action in candidates:
			if not _open(): break
			var reply := _cursor(cursor.world,cursor)
			if reply.is_empty(): break
			if not _reply(reply,1-owner,action,at):
				_discard_cursor(reply)
				continue
			reply.enemy_next=at+period
			var plan := _plan(reply,"legal_continuation")
			var candidate: Dictionary=evaluator.evaluate_current(reply.world,owner,policy,
				until-release_reserve if until>=0 else -1,plan.next_actions)
			if not candidate.get("complete",false):
				_discard_cursor(reply)
				complete=false
				break
			var utility := _reply_utility(candidate,reply)
			var resources := _reply_resources(cursor.world,reply.world)
			if not resources.is_empty() and reply.world.winner<0:
				reply.enemy_use={"ids":resources,"at":at+period}
				# Rank first replies using a finite passive-own preview only. Keep
				# the actual cursor/value at the first slot so the owner can still
				# respond before this use. Pending prefixes cannot be published.
				var preview := _cursor(reply.world,reply)
				if preview.is_empty(): _discard_cursor(reply);break
				if not _advance(preview,at+period):
					if preview.world.winner>=0 and _open():
						var terminal: Dictionary=evaluator.evaluate_current(preview.world,owner,policy,until-release_reserve if until>=0 else -1)
						if not terminal.get("complete",false):
							complete=false;_discard_cursor(preview);_discard_cursor(reply);break
						utility=_reply_utility(terminal,preview)
					else:
						complete=false;_discard_cursor(preview);_discard_cursor(reply);break
				else:
					var use := _enemy_use_choice(preview,at+period)
					if use.is_empty(): complete=false;_discard_cursor(preview);_discard_cursor(reply);break
					utility=use.utility
				_discard_cursor(preview)
			var worse: bool=best.is_empty() or utility[0]<best.utility[0] or (utility[0]==best.utility[0] and utility[1]<best.utility[1])
			if worse:
				if not best.is_empty(): _discard_cursor(best.cursor)
				best={"cursor":reply,"value":candidate,"utility":utility}
			else: _discard_cursor(reply)
		if not _open():
			if not best.is_empty(): _discard_cursor(best.cursor)
			return {}
		if best.is_empty(): return {}
		best.cursor.enemy_bound=false
		best.cursor.enemy_context={}
		best.cursor.root_replied=true
		var future := [0.0,0.0]
		future[owner]=maxf(0.0,float(best.cursor.next)-at)
		future[1-owner]=period
		_bind_opponent(best.cursor,best.value,at,future)
		if not _open():
			_discard_cursor(best.cursor)
			return {}
		return best

	func _reply_utility(value: Dictionary, cursor: Dictionary) -> Array:
		if value.detail.get("terminal",false): return [float(value.score),float(value.get("tie_score",0))]
		var elapsed: float=cursor.world.time-source.time
		var sides: Array=value.detail.sides.duplicate(true)
		for side in 2: sides[side].eta=float(sides[side].eta)+elapsed
		var own_count: int=cursor.commands.filter(func(command):return command.action.kind!="wait" and float(command.at)>1e-8).size()
		var other_count: int=cursor.replies.filter(func(command):return command.action.kind!="wait" and float(command.at)>1e-8).size()
		return [snappedf(1000.0*evaluator._race(sides,owner),0.0000001),
			int(sides[1-owner].required_actions)+other_count-int(sides[owner].required_actions)-own_count]

	func run(checkpoint_limit: int) -> Dictionary:
		var before_emitted := emitted
		var before_examined := examined
		complete=true
		if not _open(): return _status(before_emitted,before_examined)
		if not initialized and not _initialize(): return _status(before_emitted,before_examined)
		while not finished and _open():
			if int(options.get("expansion_limit",-1))>=0 and examined>=int(options.expansion_limit): break
			var selected := _select()
			if selected.is_empty():
				finished=_open()
				break
			var prior_emitted := emitted
			var prior_nodes := nodes.size()
			if not _expand(int(selected.node),selected.action):
				if not _open():
					if emitted==prior_emitted and nodes.size()==prior_nodes: nodes[int(selected.node)].next_action-=1
					break
			if checkpoint_limit>0 and emitted-before_emitted>=checkpoint_limit: break
		return _status(before_emitted,before_examined)

	func _status(before_emitted: int, before_examined: int) -> Dictionary:
		return {"complete":finished and complete,"plans":emitted-before_emitted,
			# A local fork/cleanup guard may stop us before the wall-clock edge.
			# Retrying under the same deadline cannot fit that indivisible step;
			# yield the remaining budget instead of spinning zero-work visits.
			"examined":examined-before_examined,"pending":not finished and complete,
			"root_actions":root_count,"root_serviced":root_serviced.size(),"max_depth":depth_reached,
			"root_refined":refined_roots.size(),"episodes":episodes,
			"exploration_episodes":exploration_episodes,"episode_peak_expansions":episode_peak,
			"episode_peak_new_operations":episode_path_peak,
			"empty_wait_yields":empty_wait_yields,
			"episode_expansion_limit":EPISODE_EXPANSION_LIMIT,
			"warm_started":warm_started,"warm_complete":warm_complete,"warm_root_index":warm_root_index,"warm_examined":warm_examined,
			"release_reserve_us":release_reserve,"nodes":nodes.size()}

	func _initialize() -> bool:
		if not _open(): return false
		# Initialization can itself run out of time while binding root seeds.
		# A resumed visit must not append a second root to that partial tree.
		if not nodes.is_empty():
			nodes.clear()
			release_reserve=0
			root_serviced.clear()
		var remaining: int = 1000000 if until<0 else maxi(0,until-Time.get_ticks_usec())
		cache_limit=maxi(2,int(sqrt(float(remaining)/maxi(1,Budget.fork_cost(source)))))
		var root_cursor := _cursor(source)
		if root_cursor.is_empty(): return false
		_bind_opponent(root_cursor,options.get("source_evaluation",{}),0.0,next_actions)
		var root := _node(root_cursor,-1,{},0.0,0)
		root.context=options.get("execution_context",{}).duplicate(true)
		nodes.append(root)
		_hold(root)
		var seeds: Array = options.get("root_candidates",[])
		if not seeds.is_empty():
			root_count=seeds.size()
			for seed in seeds:
				if not _open(): return false
				var action: Dictionary=seed.action.duplicate(true)
				var at := float(next_actions[owner])
				var command := {"at":at,"action":action,"binding":Execution.describe(source,owner,action)}
				var commands: Array=seed.get("commands",[command]).duplicate(true)
				var replies: Array=seed.get("replies",[]).duplicate(true)
				var purchases := {}
				for actor in 2:
					for step in commands if actor==owner else replies:
						if step.action.kind=="buy": purchases[int(step.action.offer)]={"at":float(step.at),"owner":actor}
				var elapsed := float(seed.get("elapsed",at))
				var cursor := {"world":null,"next":float(seed.get("next_action",at+period)),"commands":commands,"replies":replies,"purchases":purchases,
					"enemy_context":{},"enemy_next":float(next_actions[1-owner]),"enemy_bound":false,"root_replied":not replies.is_empty()}
				var value: Dictionary=seed.get("value",{}).duplicate(true)
				var child := _node(cursor,0,value,elapsed,commands.size())
				child.seed=true
				child.seed_clock=seed.get("next_actions",[]).duplicate()
				child.context=_remaining_context(source,root.context,action)
				child.root_index=root.children.size()
				child.visits=1
				nodes.append(child)
				root.children.append(nodes.size()-1)
				root.visits+=1
				root_serviced[child.root_index]=true
			root.initial_children=root.children.size()
			# The caller puts its incumbent first. Establish that root's complete
			# common-response baseline before reward-based exploration reorders
			# the remaining frontier; a cutoff must not compare unlike models.
			if not options.get("root_replies",[]).is_empty() and not _materialize(int(root.children[0])): return false
		initialized=true
		return _open()

	func _node(cursor: Dictionary, parent: int, value: Dictionary, elapsed: float, depth: int) -> Dictionary:
		var score := _reward(value,elapsed)
		return {"cursor":cursor,"parent":parent,"value":value,"elapsed":elapsed,"depth":depth,
			"root_index":-1,"children":[],"actions":[],"next_action":0,"generated":false,
			"finished":false,"visits":0,"initial_children":0,"best":score,"changed":{},"context":{},
			"seed":false,"seed_clock":[],"seed_published":false,"pending_event":-1.0,"episodes":0,"selections":0,"touched":0,"release_cost":0,"warm_invalid":false,
			"created_episode":-1,"operation":0}

	func _reward(value: Dictionary, elapsed: float) -> float:
		var detail: Dictionary=value.get("detail",{})
		if detail.get("terminal",false): return 1.0 if int(detail.get("winner",-1))==owner else 0.0
		var sides: Array=detail.get("sides",[])
		if sides.size()!=2: return 0.5
		var own_eta := maxf(0.000001,elapsed+float(sides[owner].eta))
		var other_eta := maxf(0.000001,elapsed+float(sides[1-owner].eta))
		if sides[owner].get("unreachable",false)!=sides[1-owner].get("unreachable",false):
			return 0.0 if sides[owner].get("unreachable",false) else 1.0
		# A bounded monotone transform of the same ETA ratio is used ONLY to
		# allocate exploration. It is never returned as an evaluation score.
		return other_eta/(own_eta+other_eta)

	func _select() -> Dictionary:
		while _open():
			if warm_active and episode_expansions>=EPISODE_EXPANSION_LIMIT:
				warm_active=false
				episode_active=false
			if episode_node>=0 and (warm_active or episode_active) and episode_expansions<EPISODE_EXPANSION_LIMIT:
				var edge := _episode_edge(episode_node)
				if not edge.is_empty(): return edge
				if not _open(): return {}
				warm_active=false
				episode_node=-1
				episode_active=false
			if not _generate(0): return {}
			var root: Dictionary=nodes[0]
			if not warm_started:
				var edge := _start_warm(root)
				if not edge.is_empty(): return edge
				if warm_active: continue
			if episode_batch.is_empty():
				# Cover one previously unscored root between batches. Already
				# evaluated seeds do not force another breadth-only pass before
				# a single multi-command consequence can become visible.
				if not sampled_root_for_batch and int(root.next_action)<root.actions.size():
					sampled_root_for_batch=true
					seed_only=true
					var action: Dictionary=root.actions[int(root.next_action)]
					root.next_action+=1
					return {"node":0,"action":action}
				var live: Array=root.children.filter(func(child):return not nodes[int(child)].finished)
				if live.is_empty():
					if int(root.next_action)<root.actions.size(): sampled_root_for_batch=false;continue
					return {}
				# Alternate value-guided allocation with a deterministic rotation.
				# The turn also alternates which mode starts a cold tree, so a
				# deadline fitting only one episode cannot starve exploration.
				var turn := maxi(0,int(floor(source.time/period)))
				var exploring := (episodes+turn)%2==1
				var offset := turn%maxi(1,root_count)
				live.sort_custom(func(a,b):
					if int(nodes[a].episodes)!=int(nodes[b].episodes): return int(nodes[a].episodes)<int(nodes[b].episodes)
					if exploring:
						return (int(nodes[a].root_index)-offset+root_count)%root_count<(int(nodes[b].root_index)-offset+root_count)%root_count
					if not is_equal_approx(float(nodes[a].best),float(nodes[b].best)): return float(nodes[a].best)>float(nodes[b].best)
					return int(a)<int(b))
				episode_batch=live.slice(0,1)
				if exploring: exploration_episodes+=1
				sampled_root_for_batch=false
			var selected: int=episode_batch.pop_front()
			if nodes[selected].finished: continue
			episode_node=selected
			episode_active=true
			episode_expansions=0
			episode_deferred.clear()
			nodes[selected].episodes+=1
			episodes+=1
		return {}

	func _start_warm(root: Dictionary) -> Dictionary:
		warm_started=true
		var context: Dictionary=options.get("execution_context",{})
		if context.is_empty() or not _open(): return {}
		var resolved: Dictionary=Execution.resolve(source,owner,context,until-release_reserve if until>=0 else -1)
		if resolved.context.is_empty() or not _open(): return {}
		# This is a candidate calculation, never a protected execution queue.
		# Reuse its first legal root under the same opponent response model.
		for index in root.children:
			if _same_action(nodes[int(index)].cursor.commands[0].action,resolved.action):
				_begin_warm(int(index))
				return {}
		for index in range(int(root.next_action),root.actions.size()):
			if not _same_action(root.actions[index],resolved.action): continue
			var action: Dictionary=root.actions[index]
			root.actions.remove_at(index)
			root.actions.insert(int(root.next_action),action)
			root.next_action+=1
			seed_only=true
			warm_pending_root=true
			return {"node":0,"action":action}
		return {}

	func _begin_warm(index: int) -> void:
		warm_active=true
		warm_pending_root=false
		warm_root_index=int(nodes[index].root_index)
		episode_node=index
		episode_active=false
		episode_expansions=0
		nodes[index].episodes+=1
		episodes+=1

	func _episode_edge(start: int) -> Dictionary:
		var index := start
		var operations := 0
		while _open():
			var node: Dictionary=nodes[index]
			if not warm_active and index!=start and int(node.created_episode)==episodes:
				operations+=int(node.operation)
			if not warm_active and operations>=maxi(1,int(policy.get("search_max_depth",4))):
				# This path has received its new-operation depth for this episode.
				# Siblings keep their own allowance; old nodes cost no depth when
				# another episode revisits the frontier. The total node cap remains.
				episode_deferred[index]=true
				index=start
				operations=0
				continue
			if not _generate(index): return {}
			if warm_active:
				if node.warm_invalid: return {}
				if node.context.is_empty() or node.cursor.world.winner>=0:
					warm_complete=true
					return {}
				if node.finished: return {}
				for order in range(int(node.next_action),node.actions.size()):
					if not node.actions[order].get("_warm",false): continue
					var action: Dictionary=node.actions[order]
					node.actions.remove_at(order)
					node.actions.insert(int(node.next_action),action)
					node.next_action+=1
					return {"node":index,"action":action}
				return {}
			var live: Array=node.children.filter(func(child):return not nodes[int(child)].finished and not episode_deferred.has(int(child)))
			node.selections+=1
			var width := maxi(1,int(policy.get("search_reply_width",3)))+int(sqrt(float(node.episodes)))
			# Alternate widening with continuing the best completed frontier.
			# Filling every sibling first would multiply the root count by width
			# before any delayed multi-command return could become visible.
			var widen: bool=node.children.size()<width and int(node.selections)%2==1
			if int(node.next_action)<node.actions.size() and (widen or live.is_empty()):
				var action: Dictionary=node.actions[int(node.next_action)]
				node.next_action+=1
				return {"node":index,"action":action}
			if live.is_empty():
				node.finished=node.children.all(func(child):return nodes[int(child)].finished)
				if index==start: return {}
				episode_deferred[index]=true
				index=start
				operations=0
				continue
			live.sort_custom(func(a,b):
				if not is_equal_approx(float(nodes[a].best),float(nodes[b].best)): return float(nodes[a].best)>float(nodes[b].best)
				return int(nodes[a].visits)<int(nodes[b].visits))
			index=int(live[0])
		return {}

	func _episode_operations(index: int) -> int:
		var operations := 0
		while index>=0 and index!=episode_node:
			var node: Dictionary=nodes[index]
			if int(node.created_episode)==episodes: operations+=int(node.operation)
			index=int(node.parent)
		return operations

	func _generate(index: int) -> bool:
		var node: Dictionary=nodes[index]
		if node.generated: return true
		if not _materialize(index): return false
		var cursor: Dictionary=node.cursor
		if float(cursor.next)>horizon or cursor.world.winner>=0 \
			or (int(options.get("depth_limit",-1))>=0 and int(node.depth)>=int(options.depth_limit)):
			node.generated=true
			node.finished=true
			return true
		if not _slot(cursor):
			if cursor.world.winner<0 or not _open(): return false
			# A pending enemy use can lie after a natural terminal boundary.
			# That settled real outcome must replace the unpublished prefix.
			node.elapsed=float(cursor.world.time)-source.time
			var terminal: Dictionary=evaluator.evaluate_current(cursor.world,owner,policy,until-release_reserve if until>=0 else -1)
			if not terminal.get("complete",false) or not _open(): return false
			node.value=terminal
			node.best=_reward(terminal,float(node.elapsed))
			node.generated=true
			node.finished=true
			var plan := _plan(cursor,"legal_continuation")
			plan.evaluation=terminal
			plan.growth={"policy":"legal_action_search","depth":node.depth,"root_index":node.root_index}
			emitted+=1
			if visitor.is_valid(): visitor.call(plan)
			return true
		node.elapsed=float(cursor.world.time)-source.time
		if node.seed:
			node.changed=_changed(source,cursor.world)
			if not cursor.commands.is_empty(): node.pending_event=_completion_slot(source,cursor.world,cursor.commands[-1].action,float(cursor.next))
		var generated: Dictionary=Actions.generate(cursor.world,owner,policy,until-release_reserve if until>=0 else -1,cancelled)
		if not generated.complete or not _open(): return false
		var actions: Array=[]
		for action in generated.actions:
			if index==0 and options.get("root_action_filter",Callable()).is_valid() \
				and not options.root_action_filter.call(action): continue
			actions.append(action)
		_warm_candidate(node,cursor.world,actions,index)
		if index==0:
			# Seeds are only the root prefix which fitted the earlier phase's
			# budget. Keep every unscored legal root in this same frontier.
			actions=actions.filter(func(action):return not node.children.any(func(child):
				return _same_action(action,nodes[int(child)].cursor.commands[0].action)))
			if options.get("seed_roots_only",false): actions=[]
		node.actions=actions
		var event_at := _event_slot(cursor.world,float(cursor.next))
		var allow_wait: bool = index!=0 or not options.get("seed_roots_only",false)
		if allow_wait and event_at>float(cursor.next)+period+1e-8 and event_at<=horizon:
			var waiting := {"kind":"wait","intent":"wait","reason":"等待下一次实际状态变化","_event_at":event_at}
			if index!=0 or not options.get("root_action_filter",Callable()).is_valid() or options.root_action_filter.call(waiting):
				node.actions.append(waiting)
		var completion := float(node.pending_event)
		if allow_wait and completion>float(cursor.next)+period+1e-8 and completion<=horizon:
			var waiting := {"kind":"wait","intent":"wait","reason":"等待当前真实任务完成","_event_at":completion,"_causal":true}
			if index!=0 or not options.get("root_action_filter",Callable()).is_valid() or options.root_action_filter.call(waiting):
				node.actions.append(waiting)
		# Prefer inspecting a newly produced resource, then an optional wait for
		# this action's real task result. Assigning a worker to a task is NOT a
		# new output and does not prioritize immediately undoing that task.
		for order in node.actions.size(): node.actions[order]["_enumeration"]=order
		# The incumbent's saved suffix supplies a comparable complete baseline.
		# Other roots first inspect their own real outputs and task completion;
		# replaying the old suffix first everywhere would consume the episode
		# before any newly started production could demonstrate its return.
		# These weights allocate computation only; all legal choices remain and
		# the completed shared-world ETA alone determines the winning action.
		var incumbent: bool = int(node.root_index)==0 and not options.get("root_replies",[]).is_empty()
		var warm_order := 3 if incumbent else 1
		var output_order := 2 if incumbent else 3
		var completion_order := 1 if incumbent else 2
		node.actions.sort_custom(func(a,b):
			var left := maxi(warm_order if a.get("_warm",false) else 0,
				maxi(output_order if _touches(a,node.changed) else 0,completion_order if a.get("_causal",false) else 0))
			var right := maxi(warm_order if b.get("_warm",false) else 0,
				maxi(output_order if _touches(b,node.changed) else 0,completion_order if b.get("_causal",false) else 0))
			# Array.sort_custom is not stable. Without this tie-break a new
			# worker's dismiss proposal could jump ahead of its other uses.
			return int(a._enumeration)<int(b._enumeration) if left==right else left>right)
		if index==0: root_count=node.children.size()+node.actions.size()
		node.generated=true
		return true

	func _warm_candidate(node: Dictionary, world: OffWorkState, actions: Array, index: int) -> void:
		if node.context.is_empty() or not _open(): return
		var original: Array=node.context.get("steps",[]).duplicate(true) if warm_active else []
		var resolved: Dictionary=Execution.resolve(world,owner,node.context,until-release_reserve if until>=0 else -1)
		for step in original:
			if resolved.context.get("steps",[]).has(step): continue
			var bound: Dictionary=Execution._bind(world,owner,step,until-release_reserve if until>=0 else -1)
			if bound.get("invalid",false) or (resolved.context.is_empty() and not bound.get("satisfied",false)): node.warm_invalid=true
		node.context=resolved.context
		if node.context.is_empty(): return
		var step: Dictionary=node.context.steps[0]
		var existing: Dictionary=resolved.action.duplicate(true)
		if existing.kind=="wait" and resolved.get("wait_reason","")!="scheduled":
			# A different legal root may have changed a known person's job.
			# Rebind against the SAME generated legal set, rather than turning
			# the old job label into an artificial prerequisite for its suffix.
			for action in actions:
				if _matches_step(world,action,step):
					existing=action.duplicate(true)
					break
		if existing.kind=="wait":
			var at := float(world.time)-source.time
			var first := float(next_actions[owner])
			var earliest := maxf(at+period,float(step.get("ready_at",world.time))-source.time)
			var ready := first+maxf(0.0,ceil((earliest-first-1e-9)/period))*period
			if ready>horizon: return
			existing={"kind":"wait","intent":"wait","reason":"按同一时钟检验已有计划后续","_event_at":ready}
		else:
			existing.erase("execution_continuation")
			existing.erase("execution_step")
			existing["_warm_step"]=step.duplicate(true)
		if index==0 and options.get("root_action_filter",Callable()).is_valid() and not options.root_action_filter.call(existing): return
		existing["_warm"]=true
		for action in actions:
			if _same_action(action,existing) and not existing.has("_event_at"):
				action["_warm"]=true
				action["_warm_step"]=step.duplicate(true)
				return
		actions.append(existing)

	func _matches_step(world: OffWorkState, action: Dictionary, step: Dictionary) -> bool:
		if not _open(): return false
		if action.get("kind","")!=step.get("kind",""): return false
		if action.kind=="buy": return int(action.get("offer",-1))==int(step.get("offer",-2))
		if action.kind=="wait": return false
		var group: Dictionary=step.get("group",{})
		var target := -1
		if group.has("id"):
			target=int(group.id)
		elif not group.is_empty():
			for anchor in group.get("anchors",[]):
				if world.cards.has(int(anchor.get("id",-1))): target=int(world.cards[int(anchor.id)].group);break
			if target<0: return false
		if int(action.get("group",-1))!=target: return false
		for field in ["person","tool"]:
			if not _open(): return false
			var required: Dictionary=step.get(field,{})
			if required.is_empty(): continue
			var id := int(action.get(field,-1))
			if not world.cards.has(id): return false
			if required.has("id") and int(required.id)!=id: return false
			if str(world.cards[id].type)!=str(required.get("type","")): return false
		var actual := {}
		for id in action.get("ids",[]):
			if not _open(): return false
			if not world.cards.has(id) or int(world.cards[id].owner)!=owner: return false
			var card: Dictionary=world.cards[id]
			actual[str(card.type)]=int(actual.get(str(card.type),0))+int(card.amount if card.type=="money" else 1)
		var required := {}
		for item in step.get("items",[]):
			if not _open(): return false
			if item.has("id") and not action.get("ids",[]).has(int(item.id)): return false
			var kind := str(item.get("type",""))
			required[kind]=int(required.get(kind,0))+int(item.get("count",1))
		if step.get("all_idle",false):
			return required.keys().all(func(kind):return int(actual.get(kind,0))>=int(required[kind]))
		return actual==required

	func _touches(action: Dictionary, changed: Dictionary) -> bool:
		for id in action.get("ids",[]):
			if changed.has(id): return true
		for key in ["person","tool"]:
			if changed.has(int(action.get(key,-1))): return true
		return false

	func _expand(index: int, proposal: Dictionary) -> bool:
		var parent: Dictionary=nodes[index]
		if not _materialize(index): return false
		var cursor := _cursor(parent.cursor.world,parent.cursor)
		if cursor.is_empty(): return false
		var action := proposal.duplicate(true)
		for field in ["_event_at","_causal","_enumeration","_warm","_warm_step"]: action.erase(field)
		examined+=1
		if not seed_only:
			episode_expansions+=1
			episode_peak=maxi(episode_peak,episode_expansions)
			if warm_active: warm_examined+=1
		if not _command(cursor,action):
			_discard_cursor(cursor)
			_touch_path(index,0.0)
			return _open()
		if index==0 and not options.get("root_replies",[]).is_empty():
			var response := _root_response(cursor)
			if response.is_empty():
				_discard_cursor(cursor)
				return false
			if not response.get("reuse_cursor",false): _discard_cursor(cursor)
			cursor=response.cursor
		if proposal.has("_event_at"): cursor.next=float(proposal._event_at)
		var stop := minf(horizon,float(cursor.next))
		if cursor.world.winner<0 and not _advance_shared(cursor,stop):
			if cursor.world.winner<0:
				_discard_cursor(cursor)
				return false
		var elapsed: float=cursor.world.time-source.time
		var child := _node(cursor,index,{},elapsed,int(parent.depth)+1)
		_hold(child)
		child.root_index=parent.root_index if index>0 else parent.children.size()
		child.changed=_changed(parent.cursor.world,cursor.world)
		child.pending_event=_completion_slot(parent.cursor.world,cursor.world,action,float(cursor.next))
		child.context=Execution.consumed(parent.context,{"execution_step":proposal._warm_step}) if proposal.has("_warm_step") \
			else _remaining_context(parent.cursor.world,parent.context,action)
		var plan := _plan(cursor,"legal_continuation")
		plan["evaluation_deadline"]=until-release_reserve if until>=0 else -1
		var evaluate: Callable=options.get("evaluate",Callable())
		var value: Dictionary=evaluate.call(plan) if evaluate.is_valid() else \
			evaluator.evaluate_current(cursor.world,owner,policy,int(plan.evaluation_deadline),plan.next_actions)
		if not value.get("complete",false) or not _open():
			# This transient fork is not in the retained cache yet.
			cursor.world=null
			release_reserve-=int(child.release_cost)
			return false
		child.value=value
		_refresh_opponent(cursor,value)
		child.best=_reward(value,elapsed)
		child.visits=1
		nodes.append(child)
		parent.children.append(nodes.size()-1)
		var was_warm := warm_active
		if seed_only:
			seed_only=false
			if warm_pending_root: _begin_warm(nodes.size()-1)
		else:
			child.created_episode=episodes
			child.operation=int(action.kind!="wait")
			# Ordinary traversal must keep its episode root: _episode_edge's
			# width/visit rules compare siblings there before descending again.
			# Only the saved finite queue follows its exact next child directly.
			if warm_active: episode_node=nodes.size()-1
			# Count only this path's new operations. Work spent scoring a sibling
			# cannot shorten its depth; waits still use real time and node budget.
			if not warm_active: episode_path_peak=maxi(episode_path_peak,_episode_operations(nodes.size()-1))
			if not warm_active and action.kind=="wait" and not proposal.get("_causal",false) \
				and not _wait_has_result(parent.cursor.world,cursor.world,child.changed):
				# Keep this legal, scored frontier for a later episode. If this
				# episode has tested an operation, let its existing width/visit
				# traversal compare another use before following empty waits.
				# A wholly waiting episode yields directly to another root.
				if index==episode_node or _episode_operations(index)==0: episode_active=false
				else: episode_deferred[index]=true
				empty_wait_yields+=1
			if warm_active and child.context.is_empty():
				warm_complete=true
				warm_active=false
				episode_active=false
			refined_roots[child.root_index]=true
		_touch_path(index,float(child.best))
		root_serviced[child.root_index]=true
		depth_reached=maxi(depth_reached,int(child.depth))
		plan["evaluation"]=value
		plan["growth"]={"policy":"legal_action_search","depth":child.depth,"root_index":child.root_index}
		if was_warm: plan.growth.merge({"warm_candidate":true,"warm_complete":warm_complete})
		if not plan.get("opponent_use_pending",false):
			emitted+=1
			if visitor.is_valid(): visitor.call(plan)
		_evict(nodes.size()-1)
		return _open()

	func _same_action(a: Dictionary, b: Dictionary) -> bool:
		var left: Array=a.get("ids",[]).duplicate()
		var right: Array=b.get("ids",[]).duplicate()
		left.sort()
		right.sort()
		return [a.kind,left,a.get("group",-1),a.get("person",-1),a.get("tool",-1),a.get("offer",-1)] \
			== [b.kind,right,b.get("group",-1),b.get("person",-1),b.get("tool",-1),b.get("offer",-1)]

	func _remaining_context(world: OffWorkState, context: Dictionary, action: Dictionary) -> Dictionary:
		if context.is_empty() or not _open(): return context.duplicate(true)
		if not context.get("steps",[]).is_empty() and _matches_step(world,action,context.steps[0]):
			return Execution.consumed(context,{"execution_step":context.steps[0]})
		var resolved: Dictionary=Execution.resolve(world,owner,context,until-release_reserve if until>=0 else -1)
		return Execution.consumed(resolved.context,resolved.action) if _same_action(action,resolved.action) else resolved.context

	func _touch_path(index: int, value: float) -> void:
		while index>=0:
			var node: Dictionary=nodes[index]
			node.visits+=1
			node.best=maxf(float(node.best),value)
			index=int(node.parent)

	func _changed(before: OffWorkState, after: OffWorkState) -> Dictionary:
		var result := {}
		# Currency belongs to the same produced-resource dependency graph as
		# people and ingredients; it is not part of activity_card_ids().
		var resources: Array=after.activity_card_ids(owner)+after._owner_type(owner,"money")
		for id in resources:
			if not _open(): break
			if not before.cards.has(id): result[id]=true;continue
			var old: Dictionary=before.cards[id]
			var current: Dictionary=after.cards[id]
			if old.type!=current.type or int(current.get("amount",0))>int(old.get("amount",0)):
				result[id]=true
		return result

	func _wait_has_result(before: OffWorkState, after: OffWorkState, changed: Dictionary) -> bool:
		if not changed.is_empty(): return true
		for id in before.activity_card_ids(owner):
			if not _open(): return false
			if not after.cards.has(id): continue
			# A completed task or ended restriction can release an existing
			# person without creating a new card. Mere progress is not a result.
			var prior: Dictionary=before.tasks.get(id,{})
			var current: Dictionary=after.tasks.get(id,{})
			if not prior.is_empty() and (current.is_empty() or prior.get("kind","")!=current.get("kind","")): return true
			if before.cards[id].get("status","")!=after.cards[id].get("status",""): return true
		return false

	func _completion_slot(before: OffWorkState, after: OffWorkState, action: Dictionary, at: float) -> float:
		var ids: Array=action.get("ids",[]).duplicate()
		for key in ["person","tool"]:
			if int(action.get(key,-1))>=0: ids.append(int(action[key]))
		var groups := {}
		if int(action.get("group",-1))>=0: groups[int(action.group)]=true
		var delay := INF
		for id in ids:
			if not _open(): return -1.0
			if not after.cards.has(id): continue
			groups[int(after.cards[id].group)]=true
			var task: Dictionary=after.tasks.get(id,{})
			var prior: Dictionary=before.tasks.get(id,{})
			if not task.is_empty() and (prior.is_empty() or prior.get("kind","")!=task.kind or prior.get("group",-1)!=task.group):
				var rate: float=after._task_rate(int(id))
				if rate>0.0: delay=minf(delay,maxf(0.0,1.0-after._task_progress(int(id)))/rate)
		for collection_name in ["recruitment","outsourcing","meetings","pending_strikes"]:
			var collection: Dictionary=after.get(collection_name)
			var original: Dictionary=before.get(collection_name)
			for id in collection:
				if not _open(): return -1.0
				var task: Dictionary=collection[id]
				if int(task.get("owner",owner))!=owner or (not ids.has(id) and not groups.has(int(task.get("group",-1)))): continue
				var prior: Dictionary=original.get(id,{})
				if prior.is_empty() or float(task.get("amount",0))>float(prior.get("amount",0)):
					delay=minf(delay,maxf(0.0,float(task.remaining)))
		if not is_finite(delay): return -1.0
		var first := float(next_actions[owner])
		var ready := float(after.time)-source.time+delay
		return first+maxf(0.0,ceil((maxf(at,ready)-first-1e-9)/period))*period

	func _hold(node: Dictionary) -> void:
		access_clock+=1
		node.touched=access_clock
		if int(node.release_cost)==0:
			if node.cursor.has("_release_reservation"):
				node.release_cost=int(node.cursor._release_reservation)
				node.cursor.erase("_release_reservation")
			else:
				node.release_cost=Budget.release_cost(node.cursor.world)
				release_reserve+=int(node.release_cost)

	func _evict(keep: int) -> void:
		var cached := []
		for index in nodes.size():
			if nodes[index].cursor.world!=null and index!=keep: cached.append(index)
		cached.sort_custom(func(a,b):return int(nodes[a].touched)<int(nodes[b].touched))
		while cached.size()+1>cache_limit:
			var index: int=cached.pop_front()
			var node: Dictionary=nodes[index]
			node.cursor.world=null
			release_reserve-=int(node.release_cost)
			node.release_cost=0

	func _materialize(index: int) -> bool:
		var node: Dictionary=nodes[index]
		if node.cursor.world!=null:
			_hold(node)
			return _open()
		var ancestor := int(node.parent)
		while ancestor>=0 and nodes[ancestor].cursor.world==null: ancestor=int(nodes[ancestor].parent)
		var previous: Dictionary={} if ancestor<0 else nodes[ancestor].cursor
		var cursor := _cursor(source if ancestor<0 else previous.world,previous)
		if cursor.is_empty(): return false
		var scheduled := []
		for command in node.cursor.commands.slice(cursor.commands.size()):
			scheduled.append({"at":float(command.at),"actor":owner,"action":command.action})
		for command in node.cursor.replies.slice(cursor.replies.size()):
			scheduled.append({"at":float(command.at),"actor":1-owner,"action":command.action})
		scheduled.sort_custom(func(a,b):return int(a.actor)<int(b.actor) if is_equal_approx(float(a.at),float(b.at)) else float(a.at)<float(b.at))
		var context: Dictionary=options.get("execution_context",{}).duplicate(true) if ancestor<0 else nodes[ancestor].context.duplicate(true)
		for command in scheduled:
			if not _advance(cursor,float(command.at)):
				_discard_cursor(cursor)
				return false
			if int(command.actor)==owner: context=_remaining_context(cursor.world,context,command.action)
			if not _apply(cursor,int(command.actor),command.action):
				_discard_cursor(cursor)
				return false
		cursor.next=float(node.cursor.next)
		if cursor.world.winner<0 and float(node.elapsed)>float(cursor.world.time)-source.time:
			if not _advance(cursor,float(node.elapsed)) and cursor.world.winner<0:
				_discard_cursor(cursor)
				return false
		cursor.enemy_context=node.cursor.get("enemy_context",{}).duplicate(true)
		cursor.enemy_next=float(node.cursor.get("enemy_next",next_actions[1-owner]))
		cursor.enemy_bound=node.cursor.get("enemy_bound",false)
		cursor.root_replied=node.cursor.get("root_replied",false)
		cursor.enemy_use=node.cursor.get("enemy_use",{}).duplicate(true)
		if node.seed and not cursor.root_replied and not options.get("root_replies",[]).is_empty():
			var response := _root_response(cursor,node.value)
			if response.is_empty():
				_discard_cursor(cursor)
				return false
			if not response.get("reuse_cursor",false): _discard_cursor(cursor)
			cursor=response.cursor
			node.value=response.value
			node.elapsed=float(cursor.world.time)-source.time
			node.best=_reward(node.value,float(node.elapsed))
		if node.seed: _bind_opponent(cursor,node.value,float(node.elapsed),node.seed_clock)
		node.cursor=cursor
		node.context=context
		_hold(node)
		if node.seed and cursor.root_replied and not node.seed_published \
			and not options.get("root_replies",[]).is_empty() and cursor.get("enemy_use",{}).is_empty() and _open():
			# Publish the complete common-response baseline immediately. The
			# caller must compare all roots in this model, including its incumbent,
			# before any additional friendly command changes the candidate.
			var plan := _plan(cursor,"legal_continuation")
			plan.evaluation=node.value
			plan.evaluation_deadline=until-release_reserve if until>=0 else -1
			plan.growth={"policy":"legal_action_search","depth":node.depth,"root_index":node.root_index,"root_checkpoint":true}
			node.seed_published=true
			emitted+=1
			depth_reached=maxi(depth_reached,int(node.depth))
			if visitor.is_valid(): visitor.call(plan)
		_evict(index)
		return _open()

	func _event_slot(world: OffWorkState, at: float) -> float:
		var delay := INF
		# These are the authoritative engine's clocks, not another production
		# model. This adds an optional long wait; the ordinary one-period wait
		# and every action available before the event remain in the frontier.
		if world.offers.any(func(offer):return not offer.is_empty()):
			delay=minf(delay,world.config.number("conveyor","interval_seconds")-world._conveyor_elapsed)
		for id in world.activity_card_ids():
			if not _open(): return at+period
			if world._has_timer(world.cards[id]): delay=minf(delay,maxf(0.0,float(world.cards[id].remaining)))
		for collection in [world.meetings,world.outsourcing,world.recruitment,world.pending_strikes]:
			for task in collection.values(): delay=minf(delay,maxf(0.0,float(task.remaining)))
		var groups := {}
		for id in world.tasks:
			if not _open(): return at+period
			var task: Dictionary=world.tasks[id]
			if task.kind in ["work","slack","transfer"]:
				var key := [task.kind,task.group]
				if groups.has(key): continue
				groups[key]=true
			var rate: float=world._task_rate(int(id))
			if rate>0.0: delay=minf(delay,maxf(0.0,1.0-world._task_progress(int(id)))/rate)
		if not is_finite(delay): return at+period
		var first := float(next_actions[owner])
		return first+maxf(0.0,ceil((maxf(at+period,at+delay)-first-1e-9)/period))*period

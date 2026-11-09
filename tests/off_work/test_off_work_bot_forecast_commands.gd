# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Commands = preload("res://engine/off_work_bot_forecast_commands.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
var failures: Array[String] = []
var checks := 0

func _world(money := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":2,"work":300}]
	config.rules.initial.money = money
	config.rules.conveyor.interval_seconds = 1000.0
	var world := OffWorkState.new(config)
	world.new_game(123)
	world.offers.clear()
	return world

func _initialize() -> void:
	for name in ["idle_staff","public_employee","recruit","coffee","overtime","strike"]:
		_first_command(name)
	_unavailable_commands()
	_offset_clock()
	for failure in failures: printerr("FAIL ",failure)
	print("OFF_WORK_BOT_FORECAST_COMMANDS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func _first_command(name: String) -> void:
	var world := _world(24 if name in ["public_employee","recruit"] else 0)
	var people: Array = world._owner_type(1,"employee")
	match name:
		"idle_staff": world.move_cards(people,-1)
		"public_employee": world.offers = [world._make_offer("employee")]
		"recruit": world.add_card("boss",1)
		"coffee":
			world.config.roles.grinder.work_capacity = 4
			world.add_card("coffee",1)
		"overtime": world.add_card("overtime",1)
		"strike": world.add_card("strike",1)
	var evaluator := Evaluation.new()
	var value: Dictionary = evaluator.evaluate_current(world,0,world.config.rules.bot,-1,[3.0,0.0]) if name in ["idle_staff","overtime"] \
		else evaluator.evaluate(world,0,world.config.rules.bot,-1,[3.0,0.0],false)
	_check(value.complete,name+" forecast completes")
	var forecast: Dictionary = value.detail.sides[1]
	var before := _snapshot(world)
	var command: Dictionary = Commands.next_command(world,1,world.config.rules.bot,forecast,0.0,2.99,Time.get_ticks_usec()+1000000)
	_check(command.complete and not command.get("none",false) and not command.get("unsupported",false),name+" has a matching real proposal")
	_check(_snapshot(world)==before,name+" mapping preserves the world and private RNG")
	if command.get("action",{}).is_empty(): return
	_check(is_zero_approx(float(command.at)),name+" uses the scheduled first action slot")
	_check(Actions.apply_action(world,1,command.action),name+" command executes through authoritative rules")
	if name=="recruit":
		_check(is_equal_approx(float(forecast.public_investment.at),6.0) and not world.recruitment.is_empty(),
			"recruitment replays exact scheduled at=0 instead of guessing from investment at=6")

func _unavailable_commands() -> void:
	var world := _world()
	var empty := Commands.next_command(world,1,world.config.rules.bot,{},0.0,3.0,Time.get_ticks_usec()+1000000)
	_check(empty.complete and empty.get("none",false),"no scheduled reply is explicit, not an invented wait action")
	var forecast := {"forecast_commands":[{"kind":"spend","offer":999999,"amount":1,"at":0.0}]}
	var unavailable := Commands.next_command(world,1,world.config.rules.bot,forecast,0.0,3.0,Time.get_ticks_usec()+1000000)
	_check(unavailable.complete and unavailable.get("unsupported",false) and unavailable.action.is_empty(),"missing public quote invalidates the prefix instead of substituting another purchase")
	var expired := Commands.next_command(world,1,world.config.rules.bot,forecast,0.0,3.0,Time.get_ticks_usec()-1)
	_check(not expired.complete,"expired mapping budget remains incomplete")

func _offset_clock() -> void:
	var attack := {"kind":"strike","purchase_at":0.0,"use_at":6.0,"impact_at":7.2}
	var forecast := {"eta":40.0,"public_investment":attack,"forecast_attack":attack,
		"forecast_purchases":{1:{"at":0.0,"owner":1,"price":7}},
		"forecast_commands":[{"kind":"spend","offer":1,"at":0.0}]}
	Evaluation.new()._offset_forecast(forecast,3.0)
	_check(forecast.forecast_commands[0].at==3.0 and forecast.forecast_purchases[1].at==3.0,"commands and payment clocks shift with the prefix")
	_check(forecast.public_investment.use_at==9.0 and forecast.forecast_attack.use_at==9.0,"shared attack metadata is shifted once per field")
	_check(is_equal_approx(float(forecast.forecast_attack.impact_at),10.2),"attack arrival preserves its travel time after translation")

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var values := []
	for key in OffWorkState.WORLD_FIELDS: values.append(world.get(key))
	values.append(world._rng.state)
	return var_to_bytes(values)

func _check(condition: bool, message: String) -> void:
	checks+=1
	if not condition: failures.append(message)

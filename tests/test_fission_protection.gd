# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Actions = preload("res://engine/bot_actions.gd")
const Env = preload("res://engine/bot_environment.gd")

## 裂变只补配方，不取消防御：入组即护住实际需要的一个用户，富余投料仍可攻击。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	print("=== 裂变组合的用户保护 ===")
	for owner in [GameState.PLAYER, GameState.BOT]:
		_test_immediate_protection(owner)
	_test_spare_users()
	_test_bot_candidates()
	await _test_simulator_runtime_parity()
	finish()

func _fixture(owner: String, user_count := 1, register := true) -> Dictionary:
	var s := GameState.new()
	s.set_seed(97)
	s.round_num = 4
	s.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
	for seat in [GameState.PLAYER, GameState.BOT]:
		s.add_card(seat, CardDB.unit_id(CardDB.RES_CASH))
	s.add_card(GameState.opponent(owner), CardDB.unit_id(CardDB.RES_USER))
	var core := s.add_card(owner, "shuabuting")
	var fill := s.add_card(owner, "liebian")
	var shield := s.add_card(owner, "tuisong")
	var uids: Array = [core["uid"], fill["uid"], shield["uid"]]
	var users: Array = []
	for i in user_count:
		var user := s.add_card(owner, CardDB.unit_id(CardDB.RES_USER))
		users.append(user["uid"])
		uids.append(user["uid"])
	if register:
		check(s.create_combo(owner, uids)["ok"], "%s：刷不停＋裂变＋推送弹窗编组成立" % owner)
	return {"state": s, "uids": uids, "users": users, "fill": fill["uid"], "shield": shield["uid"]}

func _target(s: GameState, owner: String, uid: int) -> Dictionary:
	for target in s.attack_targets(owner):
		if target["uids"].has(uid):
			return target
	return {}

## 按当前卡表的完整配方编组，并准备足够攻击池；配方/攻击量不是保护规则的常量。
## 连受保护用户的攻击预算也备齐，确保它留下来是因为防御，而不是攻击点不足。
func _add_attack_combos(s: GameState, owner: String, user_count := 1) -> bool:
	var attacker := GameState.opponent(owner)
	var attack_id := ""
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var ids: Array = CardDB.all_cards().keys()
	ids.sort()
	for id in ids:
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_ATTACK and d.get("attack_res") == CardDB.RES_USER \
				and int(d.get("attack_n", 0)) > 0:
			attack_id = str(id)
			break
	if not need(attack_id != "", "夹具存在提供用户攻击点数的攻击卡"):
		return false
	var def := CardDB.get_def(attack_id)
	var required_pool := user_count * per_card
	var applier := IntentApply.new(s)
	for group in ceili(float(required_pool) / float(def["attack_n"])):
		var uids: Array = [s.add_card(attacker, attack_id)["uid"]]
		for i in int(def["recipe_n"]):
			uids.append(s.add_card(attacker, CardDB.unit_id(def["recipe_res"]))["uid"])
		if not need(applier.apply(Intent.create_combo(attacker, uids), attacker)["ok"],
				"攻击方按当前卡表完整配方经真实意图编组"):
			return false
	return need(int(s.attack_pool(attacker)[CardDB.RES_USER]) >= required_pool,
		"夹具的真实攻击池足以攻击全部%d张用户（包括受保护用户）" % user_count)

## 真实编攻击组合、支付弹药并装弹，防止攻击被拒只是因为没有点数。
func _arm_attacker(s: GameState, owner: String) -> IntentApply:
	var applier := IntentApply.new(s)
	if not _add_attack_combos(s, owner):
		return applier
	var attacker := GameState.opponent(owner)
	var armed := applier.apply(Intent.arm_attacks(attacker))
	check(armed["ok"] and int(applier.pools(attacker)[CardDB.RES_USER]) >= int(CardDB.game_rules()["attack_cost_per_card"]),
		"攻击方真实装弹，持有足够用户攻击点数")
	return applier

func _test_immediate_protection(owner: String) -> void:
	var f := _fixture(owner, 1, false)
	var s: GameState = f["state"]
	var user := int(f["users"][0])
	var original_target := _target(s, owner, user)
	check(not original_target.is_empty(), "%s：编组之前散用户可被选为攻击目标" % owner)
	check(s.create_combo(owner, f["uids"])["ok"], "%s：裂变保护组合注册成功" % owner)
	var combo: Dictionary = s.combos[0]
	check(combo["eval"].get("filled_by_fission", false), "%s：唯一用户确实靠裂变补满配方" % owner)
	var protected := s.protected_uids(owner, combo, CardDB.RES_USER)
	check(s.buff_armed(owner, f["shield"]) and protected.size() == 1 and protected.has(user),
		"%s：首次编组当回合，推送弹窗立即保护裂变组唯一用户" % owner)
	check(_target(s, owner, user).is_empty(), "%s：入组后受保护用户立即退出攻击目标列表" % owner)

	var applier := _arm_attacker(s, owner)
	var attacker := GameState.opponent(owner)
	var before_pool := applier.pools(attacker).duplicate(true)
	var before_users := s.resource_count(owner, CardDB.RES_USER)
	if not original_target.is_empty():
		var attacked := applier.apply(Intent.apply_attack(attacker, original_target), attacker)
		check(not attacked["ok"] and attacked.get("code") == "no_target",
			"%s：编组前旧目标经真实攻击意图提交，当回合就被权威保护规则拒绝" % owner)
	check(not s.find_card(owner, user).is_empty() and s.resource_count(owner, CardDB.RES_USER) == before_users,
		"%s：攻击被拒后用户卡及总数保持不变" % owner)
	check(applier.pools(attacker) == before_pool, "%s：被拒的攻击不扣攻击点数" % owner)

	Settle.finalize(s)
	s.round_num += 1
	check(s.create_combo(owner, f["uids"])["ok"], "%s：下一回合重建同一组合" % owner)
	check(s.is_protected(owner, user, CardDB.RES_USER), "%s：重建后仍立即保护唯一用户" % owner)

func _test_spare_users() -> void:
	var owner := GameState.PLAYER
	var f := _fixture(owner, 3)
	var s: GameState = f["state"]
	var combo: Dictionary = s.combos[0]
	if not need(combo["eval"].get("filled_by_fission", false), "三张用户仍少于完整配方，确实走裂变补满"):
		return
	var protected := s.protected_uids(owner, combo, CardDB.RES_USER)
	check(protected.size() == 1 and protected.has(f["users"][0]), "裂变组只保护顺序第一张实际配方用户")
	for uid in f["users"].slice(1):
		var target := _target(s, owner, int(uid))
		check(not protected.has(uid) and not target.is_empty() and target.get("kind") == "spare",
			"多放的用户%d不受保护，仍是可攻击的富余卡" % int(uid))
	var applier := _arm_attacker(s, owner)
	var attacker := GameState.opponent(owner)
	var spare_uid := int(f["users"][1])
	var target := _target(s, owner, spare_uid)
	if not target.is_empty():
		var attacked := applier.apply(Intent.apply_attack(attacker, target), attacker)
		check(attacked["ok"] and s.find_card(owner, spare_uid).is_empty(), "真实攻击可移除未受保护的富余用户")
	check(s.combo_intact(owner, combo) and s.is_protected(owner, f["users"][0], CardDB.RES_USER),
		"富余用户被打掉后，裂变配方仍成立，原有用户仍受保护")

func _test_bot_candidates() -> void:
	var owner := GameState.BOT
	var f := _fixture(owner, 1, false)
	var s: GameState = f["state"]
	var profile := BOTSearch.from_model("bot", 0.0).resolved_parameters()
	profile["sales"] = 0
	var found := false
	for node in Actions.generate(s, owner, profile):
		var planned: GameState = node["state"]
		for combo in planned.combos:
			if combo["owner"] != owner or not combo["uids"].has(f["fill"]) or not combo["uids"].has(f["shield"]):
				continue
			if not combo["eval"].get("filled_by_fission", false):
				continue
			found = true
			var replay := Env.copy(s)
			check(Env.replay(replay, node["intents"]), "BOT的裂变＋推送组合候选可通过真实意图重放")
			check(replay.is_protected(owner, f["users"][0], CardDB.RES_USER), "BOT候选编组当回合立即保护唯一用户")
			break
		if found:
			break
	check(found, "BOT完整候选生成包含裂变＋推送弹窗＋唯一用户组合")

## 同一起点分别走模拟器的 Settle.run 和实战意图管道，核对整回合结果。
## 不只比摘要哈希：卡实例字段、完整战报也必须一致。
func _test_simulator_runtime_parity() -> void:
	var config := BOTSearch.from_model("bot", 0.0)
	for owner in [GameState.PLAYER, GameState.BOT]:
		for next_round in [false, true]:
			for user_count in [1, 3]:
				var fixture := _fixture(owner, user_count)
				var initial: GameState = fixture["state"]
				if not _add_attack_combos(initial, owner, user_count):
					continue
				if next_round:
					initial.round_num += 1
				var sim := Env.copy(initial)
				var live := Env.copy(initial)
				var restored := GameState.new()
				StateCodec.restore(restored, StateCodec.snapshot(initial))
				var label := "%s，跨回合=%s，用户=%d" % [owner, next_round, user_count]
				check(sim.attack_targets(owner) == initial.attack_targets(owner)
						and restored.attack_targets(owner) == initial.attack_targets(owner),
					"搜索复制和快照恢复均保留保护目标列表（%s）" % label)
				Settle.run(sim, {GameState.PLAYER: config, GameState.BOT: config})
				var pipe := LocalTransport.new(IntentApply.new(live))
				await pipe.run_round(BOTPlan.target_picker(config))
				check(StateCodec.state_hash(sim) == StateCodec.state_hash(live)
						and Env.key(sim) == Env.key(live),
					"模拟器与实战完整牌局状态一致（%s）" % label)
				check(StateCodec.canon(sim.log) == StateCodec.canon(live.log),
					"模拟器与实战战报逐条一致（%s）" % label)
				var expected_users := GameState.protect_quota(initial.combos[0]["eval"])
				check(sim.resource_count(owner, CardDB.RES_USER) == expected_users
						and live.resource_count(owner, CardDB.RES_USER) == expected_users,
					"两条路径都只保留实际受保护的用户（%s）" % label)
				var expected_cash := initial.resource_count(owner, CardDB.RES_CASH) + int(initial.combos[0]["eval"]["output_n"])
				check(sim.resource_count(owner, CardDB.RES_CASH) == expected_cash
						and live.resource_count(owner, CardDB.RES_CASH) == expected_cash,
					"入组当回合和跨回合两条路径均保护用户并正常产出（%s）" % label)
				var expected_winner := ""
				check(sim.winner == expected_winner and live.winner == expected_winner,
					"两条路径胜负结果符合保护状态（%s）" % label)

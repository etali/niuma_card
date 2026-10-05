# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 对手侧画面测试 —— 「对手做了什么」画得出来吗（scenes/main.gd 的拖拽广播与租约处理）
##
## 为什么单独立一个文件：这一整块**原先没有任何观察点**。改造前对手的每一处
## 画面都长在「驱动对手的那段代码」里（那时 scenes/main.gd 里有 _bot_buy_once /
## _bot_pawn_relief 两个函数，买完顺手 _spawn_entity、典当完顺手 _fly_out；
## 两个名字现在都不在仓里了，决策次序搬去了 engine/bot_agent.gd），
## 而没有一条判据看对手侧的画面 ——
## 实测把那几处画面调用全删掉，32 个测试文件一条不红。
## 于是「联网局对手侧一个像素都不动」这个 bug 在测试里是不可见的。
##
## 这个文件的判据全部**只经管道**驱动对手：submit 一条以服务器身份提交的意图，
## 然后看画面。它一次都不调 _foe_action / _drive_bot_action ——
## 那正是联网局的形状（对手是人，本地没有任何代码在驱动他）。
## 所以这些判据同时也是「联网时对手侧画得出来」的证明。
##
## 变异：十一条都**跑过 tools/mutate_check.py 并报了 OK**，登记在那张表的
## 「对手侧画面只能来自 pipe.applied」一段，第 5 个元素都写了这个文件
## （scenes/main.gd 在 TEST_FOR 里指向 test_arrivals.gd，省略就会去跑一个
## 根本不看对手画面的测试 —— 跑得过，等于没测）。登记前那十一条**全是 MISS**。
## 具体锚点和报警关键字看那张表，这里只记它们分别钉住了什么：
##   总闸（不连 applied）／四个 op 分支各自不画／座位过滤失效／不分客户端操作／
##   判定接反／landed 不发（BOT 内部落地又看不见）／submit 去重失效（广播两遍）／
##   阶段名不再转引 PhaseMachine
##
## T1 里另有一条「买的卡落在他那半边」，它**没有登记变异**，而且是故意的：
## 对手侧的落位是**双重决定**的 —— _render_foe_buy 先按 _unit_anchor 摆一次，
## 两行之后 _layout_bot_idle() 把对手所有牌整片重排一次。
## 实测把 _free_spot 那两个 foe_seat 换成 my_seat：z = -7.49，牌还在对手那半边
## （重排把它救回来了）；只坏重排也一样，spawn 那个位置本来就是对的。
## 单点变异破不了它，所以那一条是**端到端的回归护栏**，不是某一处实现的判据 ——
## 加它的理由仍然成立（这一节原先一条位置判据都没有，一张牌画到我这半边
## 也照样全绿），但别指望能给它配一条 MISS。理由也记在 mutate_check 那张表里
##
## 其中「座位过滤失效」那条的判据落在 is_foe_client_op 这个函数本身，
## 不落在它的副作用上：判错的后果是**在信号回调里出脚本错误**，而回调里的
## 脚本错误不会让调用方失败 —— 实测那条变异对四条行为判据全是绿的。
## 见 T6 的注释（memory: green-mutation-means-no-observer）

func _initialize() -> void:
	print("=== 对手侧画面测试 ===")
	var main: Node = await boot_main()
	await _t1_buy(main)
	# T6 要在 T5 之前：T5 的 _foe_action 会走到 _finish_actions，那里把公共区
	# 整个收走。之后 T6 的「公共区没被再摘一格」就变成 0 → 0 —— 判据还是绿的，
	# 但什么都没测（实测过：先跑 T5 时这条判据对变异是瞎的）
	await _t6_own_op_not_mirrored(main)
	await _t2_pawn(main)
	await _t3_combo(main)
	await _t4_attack(main)
	await _t5_remote_shape(main)
	_t7_phase_names()
	finish()

## 这个座位买得起的第一个货架位（-1 = 一个都买不起）。
## 判据要「留 1 块」那条护栏之内的价格：付完归零会被 buy 自己拦掉
func _affordable_slot(state: GameState, seat: String) -> int:
	var cash: int = state.resource_count(seat, CardDB.RES_CASH)
	for i in state.market.size():
		var price: int = int(CardDB.get_def(state.market[i]).get("price", -1))
		if price > 0 and cash - price > 0:
			return i
	return -1

## 对手侧实体数（画面上属于对手的卡）。按状态里的归属数，不数摆放位置：
## 位置是摆放层的事，这里问的是「这张卡在场上有实体吗」
func _foe_entity_count(main: Node) -> int:
	var n := 0
	for uid in main.entities:
		if not is_instance_valid(main.entities[uid]):
			continue
		if not main.state.find_card(main.foe_seat, uid).is_empty():
			n += 1
	return n

# ---------- T1 买卡 ----------

## 对手买一张 → 场上多一张属于对手的卡，公共区那一格被摘掉。
##
## 这条判据是**整条连接的总闸**：pipe.applied 没连、或 OP_BUY 分支不画，
## 它都红。它也是「对手是人也画得出来」的证明 —— 这里从头到尾没有
## 任何一段代码在驱动对手，只有一条 submit
func _t1_buy(main: Node) -> void:
	print("\n--- T1 对手买卡 ---")
	var state: GameState = main.state
	# 挑一张对手买得起的。市场下标 0 起，价格从卡表读
	var idx := _affordable_slot(state, main.foe_seat)
	check(idx >= 0, "公共区里有对手买得起的卡（下标 %d）" % idx)
	if idx < 0:
		return
	var def_id: String = state.market[idx]
	var before := _foe_entity_count(main)
	var market_before: int = main.market_cards.size()

	# **以服务器身份提交**（from_seat 留空）。联网局里这一步是
	# 「服务器把对方客户端发来的 buy 落地后广播给我」，本地局是 BOT 驱动 ——
	# 两条路进到 _on_intent_applied 是同一个形状
	var r: Dictionary = await main.pipe.submit(Intent.buy(main.foe_seat, idx))
	check(r["ok"], "对手的 buy 意图落地（%s）" % r.get("reason", ""))
	if not r["ok"]:
		return
	await arrivals_landed(main)

	# 净数会**掉**：买一张要付好几张现金。所以判的是准确的账，
	# 不是「变多了」—— 付 4 张买 1 张，净 -3
	var paid: int = (r.get("removed_uids", []) as Array).size()
	check(_foe_entity_count(main) == before - paid + 1,
		"对手买的卡出现在场上（%d - %d付 + 1新 = %d，实得 %d）" % [
			before, paid, before - paid + 1, _foe_entity_count(main)])
	check(main.entities.has(r["new_uid"]),
		"新卡的 uid 进了 entities（uid=%d）" % int(r["new_uid"]))
	# **落在哪一侧**。上面那几条只数个数、只查 uid 在不在 ——
	# 一张牌画到我这半边桌上，它们全绿。
	#
	# 这是端到端的护栏，**不对着某一处实现**：落位有两条路各自都能放对
	# （_render_foe_buy 的 _unit_anchor，和两行后 _layout_bot_idle 的整片重排），
	# 坏掉任一条另一条都会把牌救回来 —— 实测换掉 _free_spot 那两个 seat 参数，
	# z = -7.49，还在对手那半边。所以它没有登记变异，理由见文件头
	#
	# 判 z<0 是精确的、不是估的：_free_spot 把远侧钳在 [BOT_FAR_Z_MIN, BOT_FAR_Z_MAX]
	# = [-7.6, -1.8]，近侧钳在 [0.6, 5.2]，两段不重叠（settle_layout.gd 的 `_free_spot()`）
	if main.entities.has(r["new_uid"]):
		var pos: Vector3 = (main.entities[r["new_uid"]] as Node3D).position
		check(pos.z < 0.0,
			"对手买的卡落在**他那半边**（z=%.2f < 0）—— 大于 0 就是画到我这边来了"
				% pos.z)
	# 公共区那一格：结果里的 market_idx 是表现层唯一的依据 ——
	# 状态里那一格已经删了，光看状态认不出该摘哪个实体
	check(main.market_cards.size() == market_before - 1,
		"公共区那一格被摘掉（%d → %d）" % [market_before, main.market_cards.size()])
	check(main.market_price_labels.size() == main.market_cards.size(),
		"价签数量和卡位对齐（%d/%d）" % [
			main.market_price_labels.size(), main.market_cards.size()])
	# 付掉的现金实体也该没了
	var still_there := 0
	for u in r.get("removed_uids", []):
		if main.entities.has(u):
			still_there += 1
	check(still_there == 0, "付掉的现金实体从场上撤了（还剩 %d）" % still_there)

# ---------- T2 典当 ----------

## 对手典当 → 那几张从场上消失，换来的现金归堆。
## uids 只能从结果里来：典当掉的卡在状态里已经没了
func _t2_pawn(main: Node) -> void:
	print("\n--- T2 对手典当 ---")
	var state: GameState = main.state
	# 给对手塞一张典当行肯收的卡，确保有东西可当
	var c: Dictionary = state.add_card(main.foe_seat, CardDB.unit_id(CardDB.RES_USER))
	main._spawn_entity(c, Vector3(-6.0, 0.05, main.BOT_ZONE_Z), false)
	await settle()
	var uid: int = c["uid"]
	check(main.entities.has(uid), "待当的卡在场上（uid=%d）" % uid)

	var r: Dictionary = await main.pipe.submit(Intent.pawn(main.foe_seat, [uid]))
	check(r["ok"], "对手的 pawn 意图落地（%s）" % r.get("reason", ""))
	if not r["ok"]:
		return
	check(r.has("uids"), "pawn 的结果回传了 uids（表现层要靠它认该撤哪几张）")
	await settle()
	check(not main.entities.has(uid), "对手典当掉的卡从场上消失（uid=%d）" % uid)
	check(_foe_entity_count(main) == state.players[main.foe_seat]["cards"].size(),
		"普通典当换来的现金也全部出现在牌桌上")

# ---------- T3 编组 ----------

## 对手编成一组 → 那一组在对手区收拢成摞。
##
## 这条同时盯着 IntentApply.landed：BOT 的编组走 applier.apply（不经 submit），
## landed 不发的话表现层就看不见它 —— 所以下面第二段直接调 applier.apply
func _t3_combo(main: Node) -> void:
	print("\n--- T3 对手编组 ---")
	var state: GameState = main.state
	var uids := _make_foe_combo_cards(main)
	if uids.is_empty():
		check(false, "凑不出一组对手的组合（跳过 T3）")
		return
	await settle()

	var r: Dictionary = await main.pipe.submit(Intent.create_combo(main.foe_seat, uids))
	check(r["ok"], "对手的 create_combo 意图落地（%s）" % r.get("reason", ""))
	if not r["ok"]:
		return
	check(r.has("uids"), "create_combo 的结果回传了 uids")
	await settle()
	# 收拢成摞 = 摆放层给这几张登记了摞归属（settle_layout._bot_pile_of_uid）
	var in_pile := 0
	for u in uids:
		if str(main.layout._bot_pile_of_uid.get(u, "")) != "":
			in_pile += 1
	check(in_pile == uids.size(),
		"对手编的组收拢成摞（%d/%d 张有摞归属）" % [in_pile, uids.size()])

	# 第二段：**不经 submit**，直接让裁决器落地一条 —— 那是 BOT 走的路
	# （旧组卡器 把决策和落地交错在一个 while 里）。
	# 这一段能画出来，靠的是 IntentApply.landed
	var uids2 := _make_foe_combo_cards(main)
	if uids2.is_empty():
		return
	await settle()
	var r2: Dictionary = main.pipe.applier().apply(Intent.create_combo(main.foe_seat, uids2))
	check(r2["ok"], "第二组直接经 applier 落地（%s）" % r2.get("reason", ""))
	if not r2["ok"]:
		return
	await settle()
	var in_pile2 := 0
	for u in uids2:
		if str(main.layout._bot_pile_of_uid.get(u, "")) != "":
			in_pile2 += 1
	check(in_pile2 == uids2.size(),
		"BOT 内部直接落地的编组也画得出来（%d/%d 张有摞归属）" % [in_pile2, uids2.size()])

## 给对手凑一组能成立的组合（一张核心 + 它要的单位卡），返回 uids。
## 凑不出返回空数组
func _make_foe_combo_cards(main: Node) -> Array:
	var state: GameState = main.state
	var prod: Dictionary = state.add_card(main.foe_seat, "shuabuting")
	main._spawn_entity(prod, Vector3(1.0, 0.05, main.BOT_ZONE_Z), false)
	var uids: Array = [prod["uid"]]
	var need := 7
	for i in need:
		var u: Dictionary = state.add_card(main.foe_seat, CardDB.unit_id(CardDB.RES_USER))
		main._spawn_entity(u, Vector3(2.0 + float(i) * 0.4, 0.05, main.BOT_ZONE_Z), false)
		uids.append(u["uid"])
	var cards: Array = []
	for u in uids:
		cards.append(state.find_card(main.foe_seat, u))
	if not ComboRules.evaluate(cards)["valid"]:
		return []
	return uids

# ---------- T4 对手攻击 ----------

## 对手打掉我一张 → 那张从场上消失。
## 装弹走测试后门（seed_pool_for_test）：正常路径的 arm 要真扣配方现金，
## 为了这条判据凑一套能装弹的阵型不值当（见 IntentApply.seed_pool_for_test）
func _t4_attack(main: Node) -> void:
	print("\n--- T4 对手攻击 ---")
	var state: GameState = main.state
	main.pipe.applier().seed_pool_for_test(main.foe_seat, 30, 30)
	var targets: Array = state.attack_targets(main.my_seat)
	var target := {}
	for t in targets:
		var all_on_table := true
		for u in t["uids"]:
			if not main.entities.has(u):
				all_on_table = false
				break
		if all_on_table and GameState.target_affordable(
				t, main.pipe.applier().pools(main.foe_seat)):
			target = t
			break
	check(not target.is_empty(), "我这边有对手点得起、且在场上的靶")
	if target.is_empty():
		return
	var victims: Array = (target["uids"] as Array).duplicate()

	var r: Dictionary = await main.pipe.submit(
		Intent.apply_attack(main.foe_seat, Intent.target_ref(target)))
	check(r["ok"], "对手的 apply_attack 意图落地（%s）" % r.get("reason", ""))
	if not r["ok"]:
		return
	await settle()
	var gone := 0
	for u in r.get("removed", []):
		if not main.entities.has(u):
			gone += 1
	check(gone == (r["removed"] as Array).size() and gone > 0,
		"对手打掉的卡从场上消失（%d/%d）" % [gone, (r["removed"] as Array).size()])
	check(victims.size() > 0, "靶子里确实有卡（%d 张）" % victims.size())

# ---------- T5 联网形状 ----------

## 对手是远端的人时：本地不驱动他，画面照样来自落地的意图。
##
## 这条判的是**分人机的那一处**（_foe_is_bot）。set_foe_remote(true) 之后
## _foe_action 不再调 BOT，而是等一条 action_done —— 那条意图由「服务器」发来
func _t5_remote_shape(main: Node) -> void:
	print("\n--- T5 联网形状（对手是人） ---")
	main.set_foe_remote(true)
	check(not main._foe_is_bot(), "置远端之后不再把对手当电脑")

	# 先确认「等对手」真的在等：起一条 _foe_action 但不喂 action_done，
	# 它必须停在那儿不往下走（不往下走 = 没进 _finish_actions，phase 还是行动阶段）
	main.phase = PhaseMachine.ACTION
	main._foe_action()
	for i in 12:
		await physics_frame
	check(main.phase == PhaseMachine.ACTION,
		"没收到 action_done 时停在行动阶段等着（phase=%s）" % main.phase)

	# 喂一条 action_done —— 联网局里这是服务器广播过来的
	var before := _foe_entity_count(main)
	var r: Dictionary = await main.pipe.submit(Intent.action_done(main.foe_seat))
	check(r["ok"], "对手的 action_done 落地（%s）" % r.get("reason", ""))
	for i in 6:
		await physics_frame
	# 对手是人：本地一次都没调 BOT —— 场上不该凭空多出对手的卡
	check(_foe_entity_count(main) == before,
		"远端对手不由本地驱动（对手侧卡数没变：%d）" % before)
	main.set_foe_remote(false)

# ---------- T6 座位过滤 ----------

## 我自己的操作不该被当成对手的画出来。
##
## 前两条直接问判定本身（main.is_foe_client_op）。为什么非要这么问：
## 判错的后果是**在信号回调里出脚本错误**（拿我的 uid 去 find_card(foe_seat, …)
## 得到空字典，_spawn_entity 在 state_card["uid"] 上崩），而回调里的脚本错误
## 不会让调用方失败。实测把那个判定改成恒真，下面那两条行为判据**都还是绿的** ——
## 崩在渲染函数第一行，有观察点的副作用一个都没发生。
## 所以判定必须自己有读者，这就是那个读者（memory: green-mutation-means-no-observer）
func _t6_own_op_not_mirrored(main: Node) -> void:
	print("\n--- T6 我自己的操作不镜像到对手区 ---")
	var state: GameState = main.state
	check(main.is_foe_client_op({ "op": Intent.OP_BUY, "seat": main.foe_seat }),
		"对手的 buy 归对手侧渲染管")
	check(not main.is_foe_client_op({ "op": Intent.OP_BUY, "seat": main.my_seat }),
		"我自己的 buy **不**归对手侧渲染管")
	check(not main.is_foe_client_op({ "op": Intent.OP_PRODUCE, "seat": main.foe_seat }),
		"produce 不归对手侧渲染管（seat 是组合主人，但那是结算阶段在演）")
	check(not main.is_foe_client_op({ "op": Intent.OP_ARM, "seat": main.foe_seat }),
		"arm 不归对手侧渲染管（服务器推进的阶段，不是对手的操作）")
	var idx := _affordable_slot(state, main.my_seat)
	if idx < 0:
		check(false, "公共区里没有我买得起的卡（跳过 T6）")
		return
	var foe_before := _foe_entity_count(main)
	var market_before: int = main.market_cards.size()
	var r: Dictionary = await main.pipe.submit(
		Intent.buy(main.my_seat, idx), main.my_seat)
	check(r["ok"], "我的 buy 意图落地（%s）" % r.get("reason", ""))
	if not r["ok"]:
		return
	await settle()
	check(_foe_entity_count(main) == foe_before,
		"我自己买卡不会在对手区多出一张（%d → %d）" % [
			foe_before, _foe_entity_count(main)])
	# 公共区只该被摘一次（玩家侧那条路自己摘；这里没走玩家侧输入回调，
	# 所以一次都不该摘 —— 摘了就是被当成对手的画了）
	check(main.market_cards.size() == market_before,
		"我的买卡没被对手侧的渲染再摘一格（%d → %d）" % [
			market_before, main.market_cards.size()])

# ---------- T7 阶段名 ----------

## main.gd 的阶段名是**转引** PhaseMachine 的，不是各写一套字面量。
## 联网之后阶段名要过网线（Protocol.PHASE），一边改成 "attacking"
## 另一边还认 "attack" 的后果是界面永远等不到自己的回合，而且不报错
func _t7_phase_names() -> void:
	print("\n--- T7 阶段名一份 ---")
	var main_script: Variant = load("res://scenes/main.gd")
	check(main_script.PHASE_ACTION == PhaseMachine.ACTION,
		"PHASE_ACTION 和 PhaseMachine.ACTION 是同一个值（%s / %s）" % [
			main_script.PHASE_ACTION, PhaseMachine.ACTION])
	check(main_script.PHASE_ATTACK == PhaseMachine.ATTACK,
		"PHASE_ATTACK 和 PhaseMachine.ATTACK 是同一个值（%s / %s）" % [
			main_script.PHASE_ATTACK, PhaseMachine.ATTACK])
	check(main_script.PHASE_SETTLING == PhaseMachine.SETTLING,
		"PHASE_SETTLING 和 PhaseMachine.SETTLING 是同一个值（%s / %s）" % [
			main_script.PHASE_SETTLING, PhaseMachine.SETTLING])
	check(main_script.PHASE_OVER == PhaseMachine.OVER,
		"PHASE_OVER 和 PhaseMachine.OVER 是同一个值（%s / %s）" % [
			main_script.PHASE_OVER, PhaseMachine.OVER])

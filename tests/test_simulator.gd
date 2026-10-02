# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 无头模拟器 + 外置配置测试
## 运行：godot --headless -s tests/test_simulator.gd


## 独立读三份配置，组合成引擎现有结构；不经过任何配置加载器。
## 两边都问加载器就是自己比自己，不能发现段名或覆盖路径错误。
func _raw_config() -> Dictionary:
	var cards := _raw_json(CardDB.BUILTIN_PATH)
	var ui := _raw_json("res://data/ui.json")
	var ai := _raw_json("res://data/ai.json")
	cards["_game"]["res_labels"] = ui.get("resource_labels", {})
	cards["_sfx"] = ui.get("sfx", {})
	cards["_sim"] = ai.get("simulation", {})
	return cards

func _raw_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	check(file != null, "打得开内置配置 %s" % path)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	check(parsed is Dictionary, "内置配置能解析成字典：%s" % path)
	return parsed if parsed is Dictionary else {}


## 某段配置里的所有真键（滤掉 `_note` 这类元数据键）
func _real_keys(section: Dictionary) -> Array:
	var out: Array = []
	for k in section:
		if not str(k).begins_with("_"):
			out.append(str(k))
	out.sort()
	return out


## 配置段和读它的代码**双向**对齐：
##   - 配置里有、没人读 → 闲置旋钮。调了毫无反应，比硬编码更难查
##     （「配置里明摆着一个 attack_keep_p，改了却什么都没变」）
##   - 代码里读、配置里没有 → 读出 null 再静默变成 0。
##     AI 的门槛全变 0 就是「什么都买」，而一条错都不报
##
## 嵌套字典（buff_mult / res_labels）只判外层键：
## 里层的键是 buff_type / 资源名，各有自己的判据盯着（protect_key 那条、
## CardDB.KNOWN_BUFF_TYPES 那条）
func _check_section_coverage(raw: Dictionary, section: String, srcs: Array) -> void:
	var cfg: Dictionary = raw.get(section, {})
	check(not cfg.is_empty(), "组合后的配置有 %s 段" % section)
	var text := ""
	for p in srcs:
		var s := FileAccess.get_file_as_string(p)
		check(s != "", "读到了 %s" % p)
		# 掐掉注释：注释里提到键名不算「有人读」。
		# 不掐的话这条会被自己的说明文档喂饱 —— card_db.gd 的文档注释里
		# 就写着 `ai["score_floor"]`，谁把真正的读取删了它照样绿
		for line in s.split("\n"):
			text += line.split("#")[0] + "\n"
	var unread: Array = []
	for k in _real_keys(cfg):
		if not ('"%s"' % k) in text:
			unread.append(k)
	check(unread.is_empty(), "%s 段的每个键都有人读（%s）" % [section,
		"无闲置旋钮" if unread.is_empty() else "没人读：" + ", ".join(unread)])


## 反向：代码里 `xxx_rules()["k"]` 取的每个键，配置里都得真有。
##
## 少一个键读出来是 null，`int(null)` / `float(null)` 静默给 0 ——
## 门槛变 0 是「什么都买」，上限变 0 是「一回合都不跑」，两种都不报错。
## 拼错键名和删掉键名是同一个形态，所以这条连打错字一起接住
func _check_keys_exist(raw: Dictionary) -> void:
	var accessors := {
		"game_rules": "_game",
		"sim_rules": "_sim",
	}
	var re := RegEx.new()
	# 只认字面量下标：`ai["score_floor"]` 这种。变量下标（`ai[k]`）判不了，
	# 也没必要 —— 那种写法的键名本来就来自配置自己
	re.compile('(game_rules|sim_rules)\\(\\)\\["([a-z0-9_]+)"\\]')
	var alias := RegEx.new()
	# `var ai := CardDB.game_rules()` 之后再 `ai["k"]`：先认出局部名，再收它的下标
	alias.compile('var ([a-z_]+) *:?= *CardDB\\.(game_rules|sim_rules)\\(\\)')
	var missing: Array = []
	for p in _config_readers():
		var src := FileAccess.get_file_as_string(p)
		var local := {}   # 局部变量名 -> 段名
		for m in alias.search_all(src):
			local[m.get_string(1)] = accessors[m.get_string(2)]
		for m in re.search_all(src):
			var sec: String = accessors[m.get_string(1)]
			if not raw.get(sec, {}).has(m.get_string(2)):
				missing.append("%s 读 %s.%s" % [p.get_file(), sec, m.get_string(2)])
		for nm in local:
			var sub := RegEx.new()
			sub.compile('\\b%s\\["([a-z0-9_]+)"\\]' % nm)
			for m in sub.search_all(src):
				if not raw.get(local[nm], {}).has(m.get_string(1)):
					missing.append("%s 读 %s.%s" % [p.get_file(), local[nm], m.get_string(1)])
	missing.sort()
	check(missing.is_empty(), "代码取的每个配置键都真实存在（%s）" % (
		"无缺键" if missing.is_empty() else ", ".join(missing)))


## 会读 _game / _sim 的文件。加了新的消费方要挂进来 ——
## 漏挂的后果只是这条判据看不到它，不会假绿：它自己那份键还是得在配置里
func _config_readers() -> Array:
	return [
		# card_db.gd 自己也算消费方：buff_mult / res_labels
		# 这几个嵌套表是它的取值函数在读，别的文件只调函数、不写键名
		"res://engine/card_db.gd",
		"res://engine/game_state.gd",
		"res://engine/combo_rules.gd",
		"res://engine/match_simulator.gd",
		"res://engine/settle.gd",
		"res://scenes/main.gd",
		"res://scenes/board.gd",
		"res://tools/balance_report.gd",
	]

func _initialize() -> void:
	print("=== 配置化与无头模拟器测试 ===\n")

	# --- 内置配置加载 ---
	# 加载器哨兵：全部拿 raw 比 CardDB，一个字面量都不写。
	# 数值的唯一一份在各自的 JSON 里，判据照抄一遍等于第二份拷贝 ——
	# 而这里要判的**不是数值本身**，是「CardDB 端到端读出来的和文件里躺着的一样」。
	# raw 不经过 CardDB（见 _raw_config），所以这不是自己比自己
	CardDB.ensure_loaded()
	var raw := _raw_config()
	var raw_cards: Array = []
	for k in raw:
		if not str(k).begins_with("_"):
			raw_cards.append(str(k))
	check(CardDB.all_cards().size() == raw_cards.size(),
		"卡牌张数与 cards.json 一致（%d 张，来自 %s）" % [
			CardDB.all_cards().size(), CardDB.loaded_from])
	# 逐卡逐字段比：光比张数漏得掉「张数没变、字段读错」。
	# 尤其接得住「量没变、币种变了」这种（attack_res 从 cash 翻成 user）
	var field_drift: Array = []
	for def_id in raw_cards:
		var want: Dictionary = raw[def_id]
		var got: Dictionary = CardDB.get_def(def_id)
		for f in want:
			if str(f).begins_with("_"):
				continue
			if str(got.get(f, "<缺>")) != str(want[f]):
				field_drift.append("%s.%s：文件 %s ≠ CardDB %s" % [
					def_id, f, want[f], got.get(f, "<缺>")])
	check(field_drift.is_empty(), "每张卡的每个字段都和 cards.json 逐字一致（%s）" % (
		"无偏差" if field_drift.is_empty() else ", ".join(field_drift.slice(0, 5))))
	# 转义哨兵：上面那圈 raw 和 CardDB 用的是同一个 JSON 解析器，
	# 转义处理错了两边会一起错、差异为零。所以另判一条**性质**：
	# 卡表里有条 flavor 带着 \" 转义，解析对了字符串里就该真有个引号
	var quoted := false
	for def_id in CardDB.all_cards():
		if str(CardDB.all_cards()[def_id].get("flavor", "")).contains('"'):
			quoted = true
			break
	check(quoted, "带 \\\" 转义的 flavor 解析后真的含引号（转义没被吃掉）")
	var rules: Dictionary = CardDB.game_rules()
	var raw_game: Dictionary = raw.get("_game", {})
	var rule_drift: Array = []
	for k in _real_keys(raw_game):
		if str(rules.get(k, "<缺>")) != str(raw_game[k]):
			rule_drift.append("%s：文件 %s ≠ CardDB %s" % [k, raw_game[k], rules.get(k, "<缺>")])
	check(rule_drift.is_empty(), "_game 段每个键都和 cards.json 逐字一致（%s）" % (
		"无偏差" if rule_drift.is_empty() else ", ".join(rule_drift)))

	# 卡表可以允许首回合清零；回归检查实际倍率/成本与伤害一致，不冻结平衡设计。
	_test_attack_damage_from_rules()

	# 唯一一份：card_db.gd 里不许再躺着一份字面量拷贝的默认值。
	#
	# 这里判的是**结构**而不是数值。原先那道判据比的是「代码里的 DEFAULT_GAME
	# 和配置一致」—— 它能证明两份一样，但拦不住第二份存在，
	# 而调平衡的人改的是配置那一份。现在兜底直接读 BUILTIN_PATH，
	# 谁把字面量默认值加回来，这条报红
	var db_src := FileAccess.get_file_as_string("res://engine/card_db.gd")
	check(db_src != "", "读到了 card_db.gd")
	var relit := RegEx.new()
	# `const DEFAULT_X := {` / `static var DEFAULT_X := {`：字面量默认值表的形态
	relit.compile('(const|static +var) +DEFAULT_[A-Z_]+ *:?= *\\{')
	check(relit.search(db_src) == null,
		"card_db.gd 里没有字面量默认值表 —— 兜底要读 BUILTIN_PATH，"
		+ "不许再有第二份写死的数值（第二份是静默漂移的，调平衡的人不会改它）")

	# 三段旋钮双向对齐：配置里的键都有人读，代码取的键都真实存在
	_check_section_coverage(raw, "_game", _config_readers())
	_check_section_coverage(raw, "_sim", _config_readers())
	_check_keys_exist(raw)

	# protect_key 是拼出来的（"protect_" + res），和卡表里真实的 buff_type 是隐式契约。
	# 拼错/改了资源名就会静默找不到防御卡：保护失效但没有任何报错
	var buff_types := {}
	for def_id in CardDB.all_cards():
		var bt: String = str(CardDB.all_cards()[def_id].get("buff_type", ""))
		if bt != "":
			buff_types[bt] = def_id
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var key: String = CardDB.protect_key(res)
		check(buff_types.has(key), "protect_key(%s)=%s 对得上卡表里的 buff_type（%s）" % [
			res, key, buff_types.get(key, "无此 buff_type")])

	# --- 外置配置覆盖（热替换 → 复原） ---
	# 张数取自 fixture 自己（那是测试夹具的内容，不是游戏数值）
	var tiny_path := "res://tests/fixtures/cards_tiny.json"
	var tiny: Variant = JSON.parse_string(FileAccess.get_file_as_string(tiny_path))
	var tiny_n := 0
	for k in tiny:
		if not str(k).begins_with("_"):
			tiny_n += 1
	check(CardDB.load_from(tiny_path), "外置配置可加载")
	check(CardDB.all_cards().size() == tiny_n and CardDB.card_name("cash") == "测试现金",
		"外置配置生效（%d 张，现金名=%s）" % [tiny_n, CardDB.card_name("cash")])
	# 缺 _game 段就整段按内置配置兜底 —— 兜底值也从 raw 取，
	# 判据这一侧不留第二份 8。
	# 用 .get() 而不是 [] 取键：兜底真坏掉的时候这一段是**空字典**，
	# 方括号会当场抛运行时错误、`_initialize` 半路中断 —— 于是走不到 finish()，
	# Godot 主循环永远转下去（变异脚本那边表现成挂死，不是失败）。
	# .get() 让同一个故障落成一条正常的红断言，报出来的是「兜底没生效」这件事本身
	var fallback_size: Variant = CardDB.game_rules().get("market_size")
	check(fallback_size == raw_game["market_size"],
		"无 _game 段的配置整段回退内置配置（market_size=%s，该是 %s）" % [
			fallback_size, raw_game["market_size"]])
	# 嵌套字典逐键补、不整块覆盖：外置配置只改 buff_mult 里的一档时，
	# 另一档得留在内置那份的值上。整块覆盖的话另一档直接消失 ——
	# 而 buff_mult() 对认不出的档静默回落到 ×1，于是「只调了产出翻倍」
	# 顺带让攻击翻倍失效，一条错都不报。
	# 上面那三段旋钮对齐的判据抓不到这件事：它们扫的是**源码里有没有键名**
	# （静态文本），而这里坏的是运行时怎么合并 —— 不在一条路上。
	# 夹具是运行时拼的，不另存一个文件：这份 JSON 唯一的作用就是「只给一档」，
	# 存成夹具反倒又多一处要跟着卡表改的地方
	var one_mult := "user://mut_nested.json"
	var nested_probe: Dictionary = {
		"cash": { "name": "测试现金", "kind": "res" },
		# 只覆盖 output_x2，故意不写 attack_x2
		"_game": { "buff_mult": { "output_x2": 7 } },
	}
	var wf := FileAccess.open(one_mult, FileAccess.WRITE)
	check(wf != null, "写得出嵌套合并的临时配置")
	wf.store_string(JSON.stringify(nested_probe))
	wf.close()
	check(CardDB.load_from(one_mult), "只带一档 buff_mult 的配置可加载")
	check(CardDB.buff_mult("output_x2") == 7,
		"外置配置那一档生效（output_x2=%d，该是 7）" % CardDB.buff_mult("output_x2"))
	# 这一条才是判「没整块覆盖」的：没写的那档必须还在内置那份的值上
	check(CardDB.buff_mult("attack_x2") == int(raw_game["buff_mult"]["attack_x2"]),
		"没写的那档从内置配置逐键补齐（attack_x2=%d，该是 %d；整块覆盖会掉到 ×1）" % [
			CardDB.buff_mult("attack_x2"), int(raw_game["buff_mult"]["attack_x2"])])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(one_mult))

	CardDB.reset()
	CardDB.ensure_loaded()
	check(CardDB.all_cards().size() == raw_cards.size() and CardDB.card_name("cash") == "现金",
		"reset 后回到内置配置")

	# --- 无头模拟：10 局不同种子，至少 6 局在回合上限内分出胜负（镜像 AI 允许僵持） ---
	# 局数和「≥6 局」是这条判据自己的尺度（要多少样本、放多宽），不是游戏数值，
	# 所以写在这里。回合上限是游戏侧的旋钮，走 _sim.max_rounds
	var wins := { "player": 0, "ai": 0 }
	var rounds_total := 0
	var finished := 0
	for i in 10:
		var r: Dictionary = MatchSimulator.run_game(
			MatchSimulator.ROUNDS_FROM_CONFIG, 1000 + i * 77)
		if r["timeout"] or r["winner"] == "":
			print("  [..] 第 %d 局僵持到上限（平衡性信号）" % i)
		else:
			wins[r["winner"]] += 1
			finished += 1
		rounds_total += r["rounds"]
	check(finished >= 6, "10 局模拟 ≥6 局分出胜负（实际 %d 局）" % finished)
	print("       战况：玩家胜 %d / AI 胜 %d / 僵持 %d，平均 %.1f 回合" % [
		wins["player"], wins["ai"], 10 - finished, rounds_total / 10.0])
	check(rounds_total >= 20, "对局不是秒结束（平均回合 %.1f ≥ 2）" % (rounds_total / 10.0))

	# --- 同一种子可复现 ---
	var ra: Dictionary = MatchSimulator.run_game(MatchSimulator.ROUNDS_FROM_CONFIG, 5555)
	var rb: Dictionary = MatchSimulator.run_game(MatchSimulator.ROUNDS_FROM_CONFIG, 5555)
	check(ra["winner"] == rb["winner"] and ra["rounds"] == rb["rounds"],
		"同种子模拟结果可复现（%s / %d 回合）" % [ra["winner"], ra["rounds"]])

	_t_no_pipeline_bypass()
	finish()


## 真实规则驱动的攻击结算：倍率先乘攻击点，再按单卡成本取整。
## 对手始终留一张被打资源，避免胜负提前截断；不用旧卡表的首回合斩登记例外。
func _test_attack_damage_from_rules() -> void:
	var saved_game := CardDB.GAME
	CardDB.GAME = saved_game.duplicate(true)
	var buff := ""
	for id in CardDB.all_cards():
		if CardDB.get_def(id).get("buff_type") == "attack_x2":
			buff = str(id)
	if not need(buff != "", "卡表中有攻击倍率 Buff，覆盖增强后的实际结算"):
		CardDB.GAME = saved_game
		return
	var costs: Array = [int(saved_game["attack_cost_per_card"])]
	if not costs.has(3):
		costs.append(3)
	for per_card in costs:
		CardDB.GAME["attack_cost_per_card"] = per_card
		for id in CardDB.all_cards():
			var d := CardDB.get_def(id)
			if d.get("kind") != CardDB.KIND_ATTACK:
				continue
			for enhanced in [false, true]:
				var multiplier := CardDB.buff_mult("attack_x2") if enhanced else 1
				var points := int(d["attack_n"]) * multiplier
				var removed: int = points / int(per_card)
				CardDB.GAME["win_cash"] = maxi(int(saved_game["win_cash"]), maxi(removed, int(d["recipe_n"])) + 10)
				var state := GameState.new()
				state.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
				for res in [CardDB.RES_CASH, CardDB.RES_USER]:
					state.add_card(GameState.PLAYER, CardDB.unit_id(res))
					var count := removed + 1 if res == d["attack_res"] else 1
					for _i in count:
						state.add_card(GameState.AI, CardDB.unit_id(res))
				var uids: Array = [state.add_card(GameState.PLAYER, str(id))["uid"]]
				for _i in int(d["recipe_n"]):
					uids.append(state.add_card(GameState.PLAYER, CardDB.unit_id(str(d["recipe_res"])))["uid"])
				if enhanced:
					uids.append(state.add_card(GameState.PLAYER, buff)["uid"])
				var label := "%s / 倍率 %d / 每卡 %d 点" % [id, multiplier, per_card]
				if not need(state.create_combo(GameState.PLAYER, uids)["ok"], label + " 合法编组"):
					continue
				check(int(state.attack_pool(GameState.PLAYER)[d["attack_res"]]) == points,
					label + " 攻击池等于配置点数乘倍率")
				# 此处只测规则，固定从合法目标中取第一张，不依赖 AI 强度或偏好。
				Settle.attack_phase(state, GameState.PLAYER,
					func(_s: GameState, _who: String, targets: Array, _pools: Dictionary) -> Dictionary: return targets[0])
				check(state.resource_count(GameState.AI, str(d["attack_res"])) == 1,
					label + " 实际移除 %d 张，余点不足一张不继续攻击" % removed)
	CardDB.GAME = saved_game


## 模拟器不许绕开意图管道（README.md §「3. 文件目录结构」）。
##
## 这是一条**静态**检查，理由和 test_seat_map 那条一样：行为判据证明它现在是对的，
## 静态检查保证它不会被改回去。而这里尤其需要后者 ——
## 绕开管道**不会让任何判据变红**：`state.buy` 和 `IntentApply` 的 buy 分支
## 今天行为一致（实测 12 局终局哈希逐字相同），所以退回去是静默的。
## 它的代价在将来：谁在 IntentApply 里加一道买卡的判断，
## 模拟器就开始量另一个游戏，而平衡报表照旧出数、一条错都不报。
##
## 白名单是空的：模拟器里**没有**哪一步该直接改状态。
## 结算那半边（Settle.run）不在这条检查里 —— 它本来就是两条路共用的那一层。
##
## 查两个文件：`match_simulator.gd` 起头，`ai_agent.gd` 落地。
## 行动阶段的三步搬去 AIAgent 之后，只查模拟器那个文件的话这条禁令就空转了 ——
## 它查的那些字眼已经不在被查的文件里，而绕开管道的新地方没人看着
func _t_no_pipeline_bypass() -> void:
	var paths := ["res://engine/match_simulator.gd", "res://engine/ai_agent.gd"]
	# 直接改状态的入口。`state.buy(` 这种带括号的写法才算，
	# 免得把注释里提到的函数名也算进去（注释里就有好几处，是故意留的说明）
	#
	# 两种拿到状态的写法都要禁：模拟器那边状态是局部变量（`state.buy(`），
	# AIAgent 那边是取值函数（`state().buy(`）。只禁前一种的话，
	# 在 ai_agent.gd 里写 `state().buy(_seat, idx)` 这条禁令一个字都不说 ——
	# 实跑变异撞到过：它是被隔壁那条正面判据（「买卡走的是 apply」）拦下的，
	# 而那条只盯买卡一个入口，典当和编组退回去就没人管了
	var banned: Array = []
	for f in ["buy(", "pawn(", "create_combo(", "add_card(", "remove_card("]:
		banned.append("state." + f)
		banned.append("state()." + f)
	for path in paths:
		var src := FileAccess.get_file_as_string(path)
		check(src != "", "读到了 %s" % path)
		var short: String = String(path).get_file()
		var lines := src.split("\n")
		for i in lines.size():
			var line: String = lines[i]
			var code: String = line.split("#")[0]  # 掐掉行内注释
			for b in banned:
				check(not code.contains(b),
					"%s:%d 直接调了 %s —— 三步都得走 apply(Intent.x)，"
						% [short, i + 1, b]
					+ "不然平衡数字量的是另一条路上的游戏（README.md §「3. 文件目录结构」）")
	# 反过来也要判：管道**真的**在用。上面那圈全是「没有 X」，
	# 把整个行动阶段删空它也全绿（memory: green-mutation-means-no-observer）
	var agent_src := FileAccess.get_file_as_string("res://engine/ai_agent.gd")
	check(agent_src.contains("applier().apply(intent)"),
		"方案意图逐条交给 applier().apply(intent) —— 上面禁令是「没有 X」型判据，"
		+ "少了这一条的话把行动阶段整个删空它照样绿")
	check(FileAccess.get_file_as_string("res://engine/match_simulator.gd")
			.contains("IntentApply.new("),
		"action_phase 自己开了一个 applier")
	# 模拟器**必须**把行动阶段交给 AIAgent。少这一条的话，
	# 谁把那两行改回「自己调 旧的三个策略入口」就没人看着了 ——
	# 而那正是「两个 AI」的老形状，且改回去一条判据都不红
	check(FileAccess.get_file_as_string("res://engine/match_simulator.gd")
			.contains("AIAgent.new("),
		"action_phase 把决策次序交给 AIAgent（次序只有那一份）")

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 卡牌逻辑和配乐必须**整份住在配置里**：代码只读，不许自己另存一份
##
## 这一份钉的是两段刚从代码里搬出来的东西：
##   `_upgrade.routes` —— 一堆同名卡该拿哪个键、按什么折算率去查 upgrade_from。
##       原先是 upgrade_target 里一段写死的阶梯（tier 判断 + `n / 2` + DUP_T2），
##       卡表上只有「每档几张」那一半，另一半在代码里。
##   `_sfx` —— 音效名→wav、游戏动作→音效+响度+音高。
##       原先音效表在 sfx.gd 里，而响度散在三十来处调用点上（`play("deny", -4.0)`）。
##
## **为什么单独立一份判据，而不是靠已有的那些**：test_dup_upgrade 验的是
## 「阶梯算得对」，test_arrivals T11 验的是「产出响几声」—— 两边都从行为那头看，
## 而配置化坏掉的典型形态是**行为一模一样、事实来源变回两份**：
## 有人给某张卡在代码里补一条 if、或者给某处 play 直接写个 db。
## 那种改动行为上全绿（他补的那条就是对的），坏的是「改一处全生效」这个性质本身。
## 所以这里换个方向验：**读代码文本**，确认那几种写法一处都没有。
##
## 变异提示（都实跑确认过红，登记进 tools/mutate_check.py）：
##   1. `_sfx.actions` 里删掉 `combo_complete` 那一项
##      → T3「代码里用到的动作名配置里全都有」红（少一条会静默沉默）
##   2. combo_rules 的 `var want_n: int = n / per` 改成 `= n`
##      → T2「各档都对上 dup_key 侧同一张」红（配置写了 per、代码不听）
##   3. sfx.gd 的 `play` 里 `float(spec.get("db", 0.0))` 改成写死 `-4.0`
##      → T4「响度真的从配置那一档读」红
##
## **实跑查出来一条假提示**（原先写的是「把 T1 那条路线的 per 改成 3 → T2 红」）：
## 它是绿的，而且必然绿 —— T2 算「该得哪张」用的是配置里的 per，
## 被测的 upgrade_target 读的也是同一个 per，两边一起动。
## 改 per 本来就是合法调档（`_upgrade.routes` 里的 `per`，配置说了算），
## 该跟着变的东西全跟着变了才对。所以这一节能守的是**代码不听配置**那一侧，
## 守不住「配置本身被调了」—— 后者由 test_dup_upgrade 从具体张数那头兜
## （实测 per 2→3 那边红 75 条）。这就是 memory 里那两种空判的第一种：
## 期望值和实际值同源，判据长得像在验，其实只是把配置抄了一遍

func _initialize() -> void:
	print("=== 配置完备性：升级路线表 + 音效表 ===")
	_t1_routes_wellformed()
	_t2_t1_ladder_follows_per()
	_t3_action_names_match_both_ways()
	await _t4_db_comes_from_config()
	_t5_no_second_copy_in_code()
	finish()

# ---------- T1 路线表本身立得住 ----------

## 路线表是「按次序试、先中先返回」，所以它的每一项都得能被代码解释。
## 空表 / 键写错 / per 为 0 这三种都会让传说卡整片合不出来，而**一条错都不报**
## （CardDB 的 _check_upgrade_routes 就是为这个加的，这里验它拦得住的那些形态
## 在真配置上确实不出现）
func _t1_routes_wellformed() -> void:
	print("\n--- T1 路线表立得住 ---")
	var rules: Dictionary = CardDB.upgrade_rules()
	check(not rules.is_empty(), "配置里有 _upgrade 段")
	var routes: Array = rules.get("routes", [])
	check(routes.size() >= 2,
		"路线表至少两条（T2 直查 + T1 折算，实 %d 条）" % routes.size())
	# dup_key 是 upgrade_from 里那个占位符。它和卡表必须对得上，
	# 否则「拿这个键去查」一条都查不到 —— 症状是传说卡突然全都合不出来
	var dup_key := CardDB.dup_key()
	check(dup_key != "", "配置里写了 dup_key（实 %s）" % dup_key)
	var users := 0
	for def_id in CardDB.all_cards():
		if str(CardDB.all_cards()[def_id].get("upgrade_from", "")) == dup_key:
			users += 1
	check(users >= 1, "卡表里真有卡认这个占位符（%s，实 %d 张）" % [dup_key, users])
	var bad: Array = []
	for i in routes.size():
		var r: Variant = routes[i]
		if typeof(r) != TYPE_DICTIONARY:
			bad.append("#%d 不是字典" % i)
			continue
		var key := str(r.get("key", ""))
		if key != "self" and key != "dup_key":
			bad.append("#%d key=%s（只认 self/dup_key）" % [i, key])
		if int(r.get("per", 1)) <= 0:
			bad.append("#%d per=%s（要正数，0 会崩在整数除法上）" % [i, r.get("per")])
	check(bad.is_empty(), "每条路线的 key/per 代码都解释得了（坏的：%s）" % [
		"无" if bad.is_empty() else ", ".join(bad)])
	# 兜底那条（kind/tier 都省）必须在最后：它谁都对得上，
	# 排前面会把后面几条全遮住 —— 而遮住之后低档照旧能合，只有传说卡那几档静默消失
	var catch_all := -1
	for i in routes.size():
		if typeof(routes[i]) == TYPE_DICTIONARY \
			and not routes[i].has("kind") and not routes[i].has("tier"):
			catch_all = i
			break
	if catch_all >= 0:
		check(catch_all == routes.size() - 1,
			"不限定 kind/tier 的兜底路线排在最后（实第 %d 条 / 共 %d 条）" % [
				catch_all + 1, routes.size()])

# ---------- T2 T1 认的档位跟着折算率走 ----------

## 这一节不钉具体张数（那是 test_dup_upgrade 的事），钉的是那个**等式**：
##   T1 认的档 = dup_key 各档的 upgrade_dup_n × 那条路线的 per
## 改 per 或改 upgrade_dup_n，两边必须一起变。
## 原先这个 ×2 在六处各写一份（代码四处、判据两处），漏一处的形态是
## 「最高那档试不出来」，而它不报错，只是清单上少一行
func _t2_t1_ladder_follows_per() -> void:
	print("\n--- T2 T1 那几档 = T2 各档 × per ---")
	var dup_key := CardDB.dup_key()
	# T1 走的是哪条路线：认 dup_key、且限定 tier 1 的那条
	var per := 0
	for r in CardDB.upgrade_rules().get("routes", []):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		if str(r.get("key", "")) == "dup_key" and int(r.get("tier", 0)) == 1:
			per = int(r.get("per", 1))
			break
	if not need(per > 0, "配置里有 T1→dup_key 那条路线"):
		return
	# dup_key 侧的档位 = 那几张传说卡各自的 upgrade_dup_n
	var t2_ns: Array = []
	var target_of: Dictionary = {}
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.all_cards()[def_id]
		if str(def.get("upgrade_from", "")) == dup_key:
			var n := int(def.get("upgrade_dup_n", 0))
			t2_ns.append(n)
			target_of[n] = def_id
	t2_ns.sort()
	check(t2_ns.size() >= 2, "dup_key 侧至少两档（实 %d 档）" % t2_ns.size())
	# 挑一张有 T2 的 T1 来问：它认的档必须正好是上面那几档 ×per
	var t1_id := ""
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.all_cards()[def_id]
		if def.get("kind", "") == CardDB.KIND_PRODUCT and int(def.get("tier", 0)) == 1:
			t1_id = def_id
			break
	if not need(t1_id != "", "卡表里有 T1 产品卡"):
		return
	var bad: Array = []
	for n in t2_ns:
		var want: String = target_of[n]
		var got := ComboRules.upgrade_target(t1_id, n * per)
		if got != want:
			bad.append("×%d 应得 %s，实得 %s" % [n * per, want, "空" if got == "" else got])
	check(bad.is_empty(), "%s 的 ×%s 各档都对上 dup_key 侧同一张（坏的：%s）" % [
		CardDB.card_name(t1_id),
		"/".join(t2_ns.map(func(n): return str(n * per))),
		"无" if bad.is_empty() else ", ".join(bad)])
	# 上界得等于最长那条路线，否则最高那档「试」不出来。
	# 这个数只许有一处出处（CardDB.max_upgrade_n），这里验它算得对
	check(CardDB.max_upgrade_n() == CardDB.max_upgrade_dup_n() * CardDB.max_upgrade_per(),
		"搜索上界 = 最高档 × 最大折算率（%d = %d × %d）" % [
			CardDB.max_upgrade_n(), CardDB.max_upgrade_dup_n(), CardDB.max_upgrade_per()])
	check(CardDB.max_upgrade_per() >= per,
		"max_upgrade_per 覆盖得住 T1 那条路线的 per（%d >= %d）" % [
			CardDB.max_upgrade_per(), per])

# ---------- T3 动作名两头都要对得上 ----------

## 两个方向都验，因为两种漏法的症状完全不同：
##   代码用了、配置没有 → 那一声**静默不响**（play 里 push_error，但游戏照跑）
##   配置有了、代码没用 → 表上一条死项，调它音量没有任何效果
## 后者不算 bug，但它是「音效表和代码飘开了」最早的迹象，所以只警告不判红
func _t3_action_names_match_both_ways() -> void:
	print("\n--- T3 动作名：代码用的 ⊆ 配置有的 ---")
	var actions: Dictionary = CardDB.sfx_rules().get("actions", {})
	var sounds: Dictionary = Sfx.sounds()
	# 数的时候撇掉 _note_actions 之类的说明字段：那不是动作，
	# 算进去的话「配置里有几个动作」和「代码里用到几个」永远差一个，
	# 看着像少了一个没人用的动作
	var n_actions := 0
	for name in actions:
		if not str(name).begins_with("_"):
			n_actions += 1
	check(n_actions > 0, "配置里有 _sfx.actions（实 %d 个动作）" % n_actions)
	check(not sounds.is_empty(), "配置里有 _sfx.sounds（实 %d 个音效）" % sounds.size())
	# 每个动作指的 wav 都得在 sounds 里，且文件真的存在 ——
	# 名字对而文件不在，play 里 _streams 那一格是 null，照样静默不响
	var bad: Array = []
	for name in actions:
		if str(name).begins_with("_"):
			continue          # _note_actions 之类的说明字段
		var spec: Variant = actions[name]
		if typeof(spec) != TYPE_DICTIONARY:
			bad.append("%s 不是字典" % name)
			continue
		var snd := str(spec.get("sound", ""))
		if not sounds.has(snd):
			bad.append("%s→%s（sounds 里没有）" % [name, snd])
		elif not ResourceLoader.exists(str(sounds[snd])):
			bad.append("%s→%s 文件不在（%s）" % [name, snd, sounds[snd]])
	check(bad.is_empty(), "每个动作都指着一个真的 wav（坏的：%s）" % [
		"无" if bad.is_empty() else ", ".join(bad)])
	# 代码里实际播的那些名字：从源码里扒 play("...")，
	# 这样加一处新调用而忘了加配置，这条会红
	var used := _action_names_in_code()
	check(used.size() >= 10, "从源码里扒到了播放调用（实 %d 个动作名）" % used.size())
	# 扒取范围自己也要有人看：漏掉 scenes/ 下任何一份，
	# 那个文件里拼错的动作名就成了「不响、且全绿」（见 _scanned 的说明）
	var want_files := _scene_scripts()
	var not_scanned: Array = []
	for rel in want_files:
		if not _scanned.has(rel):
			not_scanned.append(rel.get_file())
	check(not_scanned.is_empty(),
		"scenes/ 下每一份 .gd 都扒过了（实 %d 份，漏的：%s）" % [
			_scanned.size(), "无" if not_scanned.is_empty()
			else ", ".join(not_scanned)])
	var missing: Array = []
	for name in used:
		if not actions.has(name):
			missing.append(name)
	missing.sort()
	check(missing.is_empty(),
		"代码里用到的动作名配置里全都有（缺的：%s）" % [
			"无" if missing.is_empty() else ", ".join(missing)])
	# 反方向只提示：配置里挂着没人用的动作
	var unused: Array = []
	for name in actions:
		if not str(name).begins_with("_") and not used.has(name):
			unused.append(str(name))
	unused.sort()
	if not unused.is_empty():
		print("    提示：_sfx.actions 里这些没人用：%s（不判红，但可能是飘开了）"
			% ", ".join(unused))

## 扒 `play("xxx")` 和 `_delayed_sfx("xxx")` 里的动作名。
## 只扒 scenes/：engine/ 不出声（无头模拟器也得跑得动）
##
## **整个目录扒，不列文件名。** 原先写死三份（main/board/card），
## 而眼下只有 main.gd 真在播 —— 那份名单是防着以后的，可它防不住
## 「以后」落在名单外：在 join_panel.gd 里加一句 sfx.play 拼错了名字，
## 这条判据看不见，而 Sfx.action() 那句 push_error 也接不住 ——
## 它印的是 `ERROR:`，run_tests.sh 只把 `SCRIPT ERROR` 当失败（实测过）。
## 两道防线在同一处一起失效，症状是「那一声不响」，全套照旧全绿
func _action_names_in_code() -> Dictionary:
	var out: Dictionary = {}
	var re := RegEx.new()
	re.compile('(?:sfx\\.play|_delayed_sfx)\\("([a-z_]+)"')
	_scanned = []
	for rel in _scene_scripts():
		var src := FileAccess.open(rel, FileAccess.READ).get_as_text()
		_scanned.append(rel)
		for m in re.search_all(src):
			out[m.get_string(1)] = true
	return out

## 上一次扒取真读过的文件。T3 拿它和目录列表对，为的是让**扒取范围自己**
## 也有判据：把上面那行 `for rel in _scene_scripts()` 换成写死的名单，
## 里面的 check 一条都不再执行 —— 少一条断言不等于红，实测是 28/0 全绿
## （变异 48b）。范围记在这儿、在外面比，那种掏空才有人看得见
var _scanned: Array = []

## scenes/ 下所有 .gd 的 res:// 路径。列不出来就判红：
## 空数组会让 T3 的「扒到了播放调用」和「用到的名字配置里都有」
## 一起变成真空绿（没扒到东西 ⇒ 没有缺的名字）
func _scene_scripts() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("res://scenes")
	check(dir != null, "打得开 res://scenes（扒播放调用的前提）")
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".gd"):
			out.append("res://scenes/".path_join(f))
	out.sort()
	return out

# ---------- T4 响度真的是从配置那一档读的 ----------

## 换掉配置里的一档，播出来就得跟着变 —— 这一节是「代码只读配置」的
## 唯一直接判据。为什么不能光看源码里没有字面量：`play` 里写死一个 db
## 也能让全表绿（响度不进任何断言），坏的形态是「配置那一档调了没反应」。
##
## **用真的 Sfx，不用替身**：替身的 play 是照配置自己算一遍，
## 那验的是「我这份判据会不会读配置」，不是「production 的 play 会不会」——
## 把 sfx.gd 里那句 `float(spec.get("db", 0.0))` 换成写死的数，替身照旧全绿。
## 所以这一节起真场景，读那 10 个 AudioStreamPlayer 上真被写进去的值。
## headless 下 wav 是真加载得上的（实测 12 个流一个都不为 null），
## 只是听不见 —— 这一节量的是写进去的数，跟出不出声无关
func _t4_db_comes_from_config() -> void:
	print("\n--- T4 响度跟着配置那一档走（真 Sfx） ---")
	var main: Node = await boot_main()
	var s: Sfx = main.sfx
	if not need(s != null and not s._players.is_empty(), "真 Sfx 起来了、池子建好了"):
		return
	# 流加载不上的话下面全是空判：play 第一关就 return，池子上还是上一次的值
	var nulls: Array = []
	for k in s._streams:
		if s._streams[k] == null:
			nulls.append(str(k))
	check(nulls.is_empty(), "12 个 wav 都加载上了（空的：%s）" % [
		"无" if nulls.is_empty() else ", ".join(nulls)])
	var actions: Dictionary = CardDB.sfx_rules().get("actions", {})
	var pick := ""
	for name in actions:
		if typeof(actions[name]) == TYPE_DICTIONARY and actions[name].has("db"):
			pick = str(name)
			break
	if not need(pick != "", "配置里有带 db 的动作"):
		return
	# 轮转池：下一声落在 _next 那一格，播完 _next 已经挪走了，
	# 所以先记下要看哪一格
	var slot: int = s._next
	var want := float(actions[pick]["db"])
	s.play(pick)
	check(absf(s._players[slot].volume_db - want) < 0.001,
		"%s 播出来是配置那一档 %.1f dB（实 %.3f）" % [
			pick, want, s._players[slot].volume_db])
	# 音高同理：省略就该是 1.0，写了就得照写的来
	var pitched := ""
	for name in actions:
		if typeof(actions[name]) == TYPE_DICTIONARY and actions[name].has("pitch"):
			pitched = str(name)
			break
	if pitched != "":
		slot = s._next
		s.play(pitched)
		var want_p := float(actions[pitched]["pitch"])
		# play 里叠了 ±4% 随机（重复不机械），所以比区间不比等号
		var got_p: float = s._players[slot].pitch_scale
		check(absf(got_p - want_p) <= want_p * 0.05,
			"%s 的音高在配置那档 %.2f 的 ±4%% 内（实 %.3f）" % [pitched, want_p, got_p])
	# 配置里没有的动作名：必须响不出来，而且不许静默 ——
	# 打错一个字母的形态就是「这一声没了」，而游戏照跑
	slot = s._next
	s.play("这个动作不存在")
	check(s._next == slot, "配置里没有的动作名不占池子（也就是根本没播）")

# ---------- T5 代码里没有第二份 ----------

## 配置化真正要防的东西：**行为对了，但事实来源变回两份**。
## 三种写法各自的症状：
##   `play("x", -4.0)`  → 那一处的响度不听配置，调表没反应
##   `volume_db = <数>`  → 同上，而且更难找（不在 play 那一行上）
##   路线表里的键在 combo_rules 里被硬编        → 加一条路线得改代码
## 这几种都不会让任何行为判据变红，所以只能读文本
func _t5_no_second_copy_in_code() -> void:
	print("\n--- T5 代码里没有第二份 ---")
	var main_src := FileAccess.open("res://scenes/main.gd", FileAccess.READ).get_as_text()
	# play("动作名", 数字) —— 响度从调用点传进去的老写法
	var re_db := RegEx.new()
	re_db.compile('play\\("[a-z_]+", *-?[0-9]')
	check(re_db.search(main_src) == null,
		"main.gd 里没有 play(动作名, 响度) 这种写法（响度只许在配置里）")
	# sfx.gd 里也不许再有音效名→文件的表，或者写死的 db
	var sfx_src := FileAccess.open("res://scenes/sfx.gd", FileAccess.READ).get_as_text()
	check(not sfx_src.contains("res://assets/sfx/"),
		"sfx.gd 里没有 wav 路径（音效名→文件只在配置里对一次）")
	var re_vol := RegEx.new()
	re_vol.compile('volume_db *= *-?[0-9]')
	check(re_vol.search(sfx_src) == null,
		"sfx.gd 里没有写死的 volume_db（只许从 spec 读）")
	# 升级路线：DUP_T2 那个常量只许在「和配置对账」的地方出现。
	# combo_rules 拿它当真值用，就等于路线表在代码里还有一份。
	# **只看代码行**：注释里提一句「upgrade_from 写那个占位符」是说明，不是第二份数据 ——
	# 连注释一起禁的话，这条判据会逼着人把话说不清楚
	var cr_code := _code_lines("res://engine/combo_rules.gd")
	check(not cr_code.contains("CardDB.DUP_T2"),
		"combo_rules.gd 的代码不直接用 DUP_T2 常量（占位符从 CardDB.dup_key() 走配置）")
	# 折算率：`/ 2` 这类写死的折算不许再有
	check(not cr_code.contains("n / 2"),
		"combo_rules.gd 里没有写死的折算（per 从路线上读）")

## 去掉整行注释之后的源码。行尾注释不去 —— 去它得判断 # 在不在字符串里，
## 而这几条查的东西（`CardDB.DUP_T2`、`n / 2`）没有一个会出现在行尾注释里
func _code_lines(path: String) -> String:
	var out: PackedStringArray = []
	for line in FileAccess.open(path, FileAccess.READ).get_as_text().split("\n"):
		if not line.strip_edges().begins_with("#"):
			out.append(line)
	return "\n".join(out)

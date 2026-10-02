# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name CardDB
extends RefCounted

## 卡牌数据库：全部卡面参数外置在 JSON 配置里（效果/文案/价格/配方一处改）
## 加载优先级（找到即止）：
##   1. 可执行文件旁的 cards.json        —— 发布版：不重新打包即可改配置
##   2. 可执行文件上三级目录的 cards.json —— macOS .app 旁边的 cards.json
##   3. 项目根目录 cards.json（开发期）   —— 编辑器/源码运行：改完直接重跑
##   4. res://data/cards.json            —— 打包进游戏的内置默认配置（兜底）
## kind: unit / product / attack / buff / legend

const KIND_UNIT := "unit"
const KIND_PRODUCT := "product"
const KIND_ATTACK := "attack"
const KIND_BUFF := "buff"
const KIND_LEGEND := "legend"

const RES_CASH := "cash"
const RES_USER := "user"

## 代码认得的全部 buff_type。三处消费方都按字符串匹配：
## ComboRules.evaluate（真效果）、Card._add_kind_badge（C 位记号）、
## Board.describe_def（悬停说明）—— 谁都不认的值会**静默**变成
## 「没效果 + 记号写×2 + 说明只剩典当」，一声不响地错三处。
## 实测过：拿 V1.0 的表（裂变鬼才 buff_type=user_x2）配现在的脚本跑，
## 三条症状一次全中，零报错。所以这份清单要在加载时就核，见 _check_buff_types
const KNOWN_BUFF_TYPES := [
	"user_fill",      # 裂变鬼才：核心配方吃用户时，组里有 ≥1 张即视为补满
	"output_x2",      # 组内产出翻倍
	"attack_x2",      # 组内攻击翻倍
	"protect_user",   # 组内用户不可被移除
	"protect_cash",   # 组内现金不可被移除
]

## upgrade_from 的历史占位键：任意同档生产卡的传说路线，T1/T2 各自按 per 折算。
## 真值在配置的 _upgrade.dup_key 上，这里只是给代码一个名字用；
## 两处不一致时 dup_key() 会 push_error 点名（见那个函数）
const DUP_T2 := "dup_t2"

const BUILTIN_PATH := "res://data/cards.json"
const EXTERNAL_FILE := "cards.json"

## 运行时段名保留旧格式，供引擎、旧录像和旧外置 cards.json 兼容使用。
## 配置中的唯一来源：cards.json 的 _game / _upgrade；ui.json 的 sfx /
## resource_labels；ai.json 的 simulation。缺键从各自内置文件补齐。
const SECTION_GAME := "_game"
const SECTION_UPGRADE := "_upgrade"
const SECTION_SFX := "_sfx"
const SECTION_SIM := "_sim"

static var CARDS: Dictionary = {}
static var GAME: Dictionary = {}
static var UPGRADE: Dictionary = {}
static var SFX: Dictionary = {}
static var SIM: Dictionary = {}
static var UNITS: Dictionary = {}   # res -> 资源卡 def_id，随 CARDS 一起建
static var loaded_from := ""

## 打包进游戏那份配置的解析结果，兜底用。独立于 CARDS 缓存：
## reset() 清的是「当前加载了哪份配置」，内置那份是只读的事实，清了也还是它
static var _builtin: Dictionary = {}

## 每张卡的定义字段见 data/cards.json 顶部 _comment

static func load_default() -> bool:
	return load_from(BUILTIN_PATH)

static func ensure_loaded() -> void:
	if not CARDS.is_empty():
		return
	for path in _config_candidates():
		if load_from(path):
			return
	push_error("CardDB: 找不到卡牌配置 cards.json（内置 %s 也缺失）" % BUILTIN_PATH)

## 从指定 JSON 文件加载卡面配置；成功返回 true
static func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or parsed.is_empty():
		push_error("CardDB: 配置解析失败 %s" % path)
		return false
	var table: Dictionary = {}
	for def_id in parsed:
		if str(def_id).begins_with("_"):
			continue  # _comment 等元字段
		var def: Variant = parsed[def_id]
		if typeof(def) == TYPE_DICTIONARY and def.has("name") and def.has("kind"):
			table[def_id] = def
	if table.is_empty():
		push_error("CardDB: 配置里没有有效卡牌 %s" % path)
		return false
	CARDS = table
	UNITS = {}
	for def_id in table:
		if table[def_id].get("kind") == KIND_UNIT:
			UNITS[str(table[def_id].get("res", ""))] = def_id
	# 将独立配置投影到既有运行时结构；旧版 cards.json 的显式覆盖仍然有效。
	var sections := _runtime_sections(parsed)
	GAME = _merge_section(sections, SECTION_GAME, path)
	UPGRADE = _merge_section(sections, SECTION_UPGRADE, path)
	SFX = _merge_section(sections, SECTION_SFX, path)
	SIM = _merge_section(sections, SECTION_SIM, path)
	_check_buff_types(path)
	_check_upgrade_routes(path)
	_check_sfx_actions(path)
	loaded_from = path
	return true

## 兼容旧配置，不再要求新 cards.json 重复保存展示或 AI 参数。
static func _runtime_sections(parsed: Dictionary) -> Dictionary:
	var sections := parsed.duplicate(true)
	sections[SECTION_SFX] = _overlay_section(UIConfig.read_section("sfx"), parsed.get(SECTION_SFX))
	sections[SECTION_SIM] = _overlay_section(AIConfig.read_section("simulation"), parsed.get(SECTION_SIM))
	var game := _overlay_section({}, parsed.get(SECTION_GAME))
	game["res_labels"] = _overlay_section(UIConfig.read_section("resource_labels"), game.get("res_labels"))
	sections[SECTION_GAME] = game
	return sections

static func _overlay_section(base: Dictionary, over: Variant) -> Dictionary:
	var result := base.duplicate(true)
	if over is Dictionary:
		for key in over:
			var value: Variant = over[key]
			if value is Dictionary and result.get(key) is Dictionary:
				result[key] = _overlay_section(result[key], value)
			else:
				result[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	return result

## 内置配置的某一段，作为外置配置缺键时的兜底来源。
##
## 规则缺段必须报告，不能把缺失数值静默当作零。
static func _builtin_section(key: String) -> Dictionary:
	if key == SECTION_SFX:
		return UIConfig.builtin_section("sfx")
	if key == SECTION_SIM:
		return AIConfig.builtin_section("simulation")
	if _builtin.is_empty():
		var f := FileAccess.open(BUILTIN_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY:
				_builtin = parsed
	var sec: Variant = _builtin.get(key, {})
	if typeof(sec) != TYPE_DICTIONARY or sec.is_empty():
		push_error(("CardDB: 内置配置 %s 缺少 %s 段 —— " % [BUILTIN_PATH, key])
			+ "全部数值旋钮的唯一一份就在那里，缺了会让读到的每个阈值静默变成 0")
		return {}
	if key == SECTION_GAME:
		var game: Dictionary = sec.duplicate(true)
		game["res_labels"] = UIConfig.builtin_section("resource_labels")
		return game
	return sec

## Buff 卡的 buff_type 必须是代码认得的那几个，否则点名警告。
## 为什么值得单独核一遍：这是唯一「数据写了、代码没接住」还能一路装作正常的字段。
## kind 写错会立刻炸在配方/产出上，buff_type 写错的卡照样能买、能进组、能典当，
## 只是永远不生效 —— 而 C 位那个 `_:` 兜底还会把它标成「×2」，等于反过来骗人。
## 不 return false：一张 Buff 认不出来不该开不了局（其余 30 张都是好的），
## 但必须响，而且要把名字和取值都打出来 —— 这条错的典型来源是旧版本的
## cards.json 落在可执行文件旁边（_config_candidates 优先 exe_dir），
## 光看「游戏能开」根本不会怀疑到数据上
static func _check_buff_types(path: String) -> void:
	var bad: Array = []
	for def_id in CARDS:
		var def: Dictionary = CARDS[def_id]
		if def.get("kind", "") != KIND_BUFF:
			continue
		var bt := str(def.get("buff_type", ""))
		if not KNOWN_BUFF_TYPES.has(bt):
			bad.append("%s(%s)=%s" % [def_id, str(def.get("name", "")), bt if bt != "" else "缺该字段"])
	if not bad.is_empty():
		bad.sort()
		push_warning(
			("CardDB: %s 里这些 Buff 卡的 buff_type 代码不认识：%s。" % [path, ", ".join(bad)])
			+ "它们买得到但不会生效（记号和说明也会错）。认得的是：%s。" % ", ".join(KNOWN_BUFF_TYPES)
			+ "常见原因：旧版 cards.json 落在可执行文件旁边，优先级高于仓库里那份")

## 升级路线表的自检。三条都是「配置写了、代码接不住」还能装作正常的形态：
##
## 1. dup_key 和代码里的 DUP_T2 对不上 —— 卡表里那几张传说卡的 upgrade_from
##    还写着 dup_t2，路线拿另一个键去查，一条都对不上，
##    症状是「传说卡突然全都合不出来」而不报错；
## 2. 路线的 key 不是 self/dup_key —— 那条路线永远查不到东西，静默少一条路；
## 3. per <= 0 —— 折算要做除法，0 会当场崩在整数除法上，负数更荒唐。
##
## 不 return false：路线表坏了不该开不了局（配方/产出那些还是好的），
## 但必须响，而且要点名是哪一条 —— 「合不出传说卡」这种症状从表面上
## 完全看不出问题在配置的哪一行
static func _check_upgrade_routes(path: String) -> void:
	var key: String = str(UPGRADE.get("dup_key", ""))
	if key != DUP_T2:
		push_error(("CardDB: %s 的 %s.dup_key 是「%s」，代码认的是「%s」。" % [
			path, SECTION_UPGRADE, key, DUP_T2])
			+ "卡表里传说卡的 upgrade_from 写的是后者，"
			+ "两边对不上会让全部传说升级静默查不到产物")
	var bad: Array = []
	var routes: Array = UPGRADE.get("routes", [])
	for i in routes.size():
		var r: Variant = routes[i]
		if typeof(r) != TYPE_DICTIONARY:
			bad.append("#%d 不是字典" % i)
			continue
		var k := str(r.get("key", ""))
		if not k in ["self", "dup_key"]:
			bad.append("#%d key=%s（只认 self/dup_key）" % [i, k if k != "" else "缺该字段"])
		if int(r.get("per", 0)) <= 0:
			bad.append("#%d per=%s（要 ≥1）" % [i, str(r.get("per", "缺该字段"))])
	if not bad.is_empty():
		push_error("CardDB: %s 的 %s.routes 有问题：%s。这几条路线不会生效" % [
			path, SECTION_UPGRADE, "，".join(bad)])

## 音效表的自检：动作指着一个不存在的音效名。
##
## 这条特别值得核 —— 音效缺失在 headless 下**本来就是静默的**（Sfx.play 找不到
## 流就直接 return，测试里数不出来），而有声的那一端只是「少响一声」，
## 谁都不会怀疑到配置上。所以指着空气的动作要在加载时就点名
static func _check_sfx_actions(path: String) -> void:
	var sounds: Dictionary = SFX.get("sounds", {})
	var actions: Dictionary = SFX.get("actions", {})
	var bad: Array = []
	for a in actions:
		if str(a).begins_with("_"):
			continue
		var spec: Variant = actions[a]
		if typeof(spec) != TYPE_DICTIONARY:
			bad.append("%s（不是字典）" % a)
			continue
		var s := str(spec.get("sound", ""))
		if not sounds.has(s):
			bad.append("%s→%s" % [a, s if s != "" else "缺 sound 字段"])
	if not bad.is_empty():
		bad.sort()
		push_error(("CardDB: %s 的 %s.actions 里这些动作指着不存在的音效：%s。" % [
			path, SECTION_SFX, ", ".join(bad)])
			+ "认得的音效是：%s" % ", ".join(sounds.keys()))

## 读一个配置段，缺的键从内置配置那份补齐，并把缺了哪些点名警告。
## 兜底值照用（改坏一个字段就开不了局太脆），但不能不响：
## 这些是开局资源、胜利线、AI 阈值，静默按另一套数值开局比直接崩更难查 ——
## 玩家只会觉得「这版怎么变难了」
##
## 嵌套字典（buff_mult / buff_value / res_labels）逐键补，不整块覆盖：
## 外置配置只想改 buff_value 里的一档时，整块覆盖会把其余几档一起抹掉，
## 于是「只调了热搜的估价」顺带让防御膜的估价掉到兜底档 —— 而它不报错
static func _merge_section(parsed: Dictionary, key: String, path: String) -> Dictionary:
	var defaults := _builtin_section(key)
	# 深拷贝：res_labels 这类嵌套字典浅拷贝会和内置那份共用同一个
	var out: Dictionary = defaults.duplicate(true)
	var meta: Variant = parsed.get(key, {})
	if typeof(meta) != TYPE_DICTIONARY:
		meta = {}
	var missing: Array = []
	for k in meta:
		if str(k).begins_with("_"):
			continue
		if typeof(meta[k]) == TYPE_DICTIONARY and typeof(out.get(k)) == TYPE_DICTIONARY:
			var sub: Dictionary = out[k]
			for sk in meta[k]:
				sub[sk] = meta[k][sk]
			for sk in defaults[k]:
				if not meta[k].has(sk):
					missing.append("%s.%s" % [k, sk])
			continue
		out[k] = meta[k]
	for k in defaults:
		if str(k).begins_with("_"):
			continue
		if not meta.has(k):
			missing.append(str(k))
	# 加载内置配置本身时 meta 就是 defaults，missing 天然为空
	if not missing.is_empty():
		missing.sort()
		push_warning("CardDB: %s 的 %s 段缺少 %s，这几项按内置配置（%s）" % [
			path, key, ", ".join(missing), BUILTIN_PATH])
	return out

## 清空当前逻辑表及配置来源缓存（测试 / 热重载用）。
static func reset() -> void:
	UIConfig.reset_cache()
	AIConfig.reset_cache()
	CARDS = {}
	GAME = {}
	UPGRADE = {}
	SFX = {}
	SIM = {}
	UNITS = {}
	loaded_from = ""

## 全局规则数值（键见 data/cards.json 的 _game 段 _note）
static func game_rules() -> Dictionary:
	ensure_loaded()
	return GAME

## 无头模拟器的旋钮（键见 data/ai.json 的 simulation 段 _note）
static func sim_rules() -> Dictionary:
	ensure_loaded()
	return SIM

## 某个 buff_type 的倍率（output_x2 / attack_x2）。认不出的返回 1 = 不生效。
##
## ComboRules 的两处（effect_multipliers 报给卡面、evaluate 算真产出）和
## 卡面记号都从这里取。原先三处各写一个字面量 2，改倍率要同时改三处 ——
## 漏一处的形态是「卡面写 ×2、结算发一份」，两边各自都自洽
static func buff_mult(buff_type: String) -> int:
	ensure_loaded()
	return int(GAME.get("buff_mult", {}).get(buff_type, 1))

## 典当折价的除数（`_game.pawn_rate`）。
##
## 不写死：pawn_value 里要用两次（标价那一路、T2 递归那一路），
## 而 tools/check_card_table.py 和 check_balance_numbers.py 各自复刻了一份公式 ——
## 写死的话这个数就有四份，改一处的形态是「卡表上的回收价和游戏里发的钱不一样」
static func pawn_rate() -> float:
	ensure_loaded()
	return float(GAME.get("pawn_rate", 2.0))

## 一张用户卡当掉给几块（`_game.pawn_user`）
static func pawn_user() -> int:
	ensure_loaded()
	return int(GAME.get("pawn_user", 1))

## 升级路线表（键见 data/cards.json 的 _upgrade 段 _note）
static func upgrade_rules() -> Dictionary:
	ensure_loaded()
	return UPGRADE

## 音效表（键见 data/ui.json 的 sfx 段 _note）
static func sfx_rules() -> Dictionary:
	ensure_loaded()
	return SFX

## upgrade_from 里代表传说材料的历史占位符（现在允许同档异名）。取自配置：
## 常量只是代码内部的名字，配置改了名字而代码没跟上时由 _check_upgrade_routes 点名
static func dup_key() -> String:
	ensure_loaded()
	return str(UPGRADE.get("dup_key", DUP_T2))

## 最长升级路线的来源张数（卡表里 upgrade_dup_n 的最大值）。
##
## 不写死：卡表调了那三档张数，这里跟着变。两处要用 ——
## ComboRules 报「这张卡认哪些张数」的搜索上界、AI 判「同名 T1 攒到几张算富余」
static func max_upgrade_dup_n() -> int:
	ensure_loaded()
	var mx := 2
	for def_id in CARDS:
		mx = maxi(mx, int(CARDS[def_id].get("upgrade_dup_n", 0)))
	return mx

## 折算率最大的那条升级路线折几张（_upgrade.routes 里 per 的最大值）。
##
## 「这张卡认哪些张数」的搜索上界 = max_upgrade_dup_n() × 这个数：T1 侧认的档
## 是 dup_key 各档张数乘以折算率（只用于档位查询，实际组合不允许混入 T1/T2）。
##
## 单独开一个函数是因为这个 2 原先散在六处（combo_rules 的搜索上界、board 的
## 升级清单上界、AI 的富余判定、三个测试的堆量），改折算率要同时改六处 ——
## 漏一处的形态是「最高那档试不出来」，而它不报错，只是清单上少一行
static func max_upgrade_per() -> int:
	ensure_loaded()
	var mx := 1
	for r in UPGRADE.get("routes", []):
		if typeof(r) == TYPE_DICTIONARY:
			mx = maxi(mx, int(r.get("per", 1)))
	return mx

## 「这张卡认哪些张数」的搜索上界（含）。两个上界只有这一个出处
static func max_upgrade_n() -> int:
	return max_upgrade_dup_n() * max_upgrade_per()

static func all_cards() -> Dictionary:
	ensure_loaded()
	return CARDS

static func get_def(def_id: String) -> Dictionary:
	ensure_loaded()
	return CARDS.get(def_id, {})

static func card_name(def_id: String) -> String:
	return get_def(def_id).get("name", def_id)

## res（cash/user）对应的资源卡 def_id。
## 现在两者同名，但「资源」和「卡」是两件事：发一张现金写 unit_id(RES_CASH)，
## 不写字面量 "cash"，改卡表里的资源卡 id 时不用回来翻散落各处的字符串
static func unit_id(res: String) -> String:
	ensure_loaded()
	return UNITS.get(res, res)

## 资源的**计量**名：资金 / 用户。
## 用在「产出 资金+N」「你的公司 · 资金 N」「资金 ≥ `_game.win_cash` 获胜」
## 这类说资源总量的地方
static func res_label(res: String) -> String:
	ensure_loaded()
	return str(GAME.get("res_labels", {}).get(res, res))

## 该资源对应的防御 Buff 的 buff_type（protect_cash / protect_user）。
## 四个地方要用（引擎的保护额度、AI 的两处选牌、场景的盾牌标记），
## 各写一遍 `"protect_cash" if res == RES_CASH else "protect_user"` 就是四份同样的推导
static func protect_key(res: String) -> String:
	return "protect_%s" % res

## 资源的**卡**名：现金 / 用户。
## 用在「支付现金×6」「移除对方现金×3」「配方：现金×4」这类说具体卡的地方 ——
## 卡名与资源计量名分开读取（「现金 = 1 份资金」），
## 配方里躺的是现金卡、破百看的是资金总量，混用会让同一个配方
## 在悬停里叫「资金×4」、在报错里叫「现金×4」
static func card_label(res: String) -> String:
	return card_name(unit_id(res))

## 公共区卡池（权重 > 0 的卡）
static func market_pool() -> Array:
	ensure_loaded()
	var pool: Array = []
	for def_id in CARDS:
		var w: int = CARDS[def_id].get("weight", 0)
		if w > 0:
			pool.append({ "def_id": def_id, "weight": w })
	return pool

static func total_weight() -> int:
	var t := 0
	for e in market_pool():
		t += e["weight"]
	return t

## 典当回收价（现金卡不可典当，返回 0）
## 用户卡 `_game.pawn_user`；可购组合卡 = 标价 ÷ `_game.pawn_rate`（四舍五入）；
## 配方升级卡（T2）= 配方卡价值之和 ÷ 同一个折价率
## （递归：同名下级卡×upgrade_dup_n 的回收价，升级不吃资源）；
## 传说卡不走公式，直接以卡表各自的 pawn 字段为准（三张的数看卡表）
##
## 折价率和用户卡价钱都读配置，不写字面量：这里要用两次，
## 而两个 python 检查各复刻了一份公式，写死就是四份（见 pawn_rate 的说明）
static func pawn_value(def_id: String) -> int:
	var def: Dictionary = get_def(def_id)
	if def.is_empty():
		return 0
	if def.has("pawn"):
		return int(def["pawn"])
	if def.get("kind") == KIND_UNIT:
		return pawn_user() if def.get("res") == RES_USER else 0
	var price: int = def.get("price", -1)
	if price > 0:
		return maxi(1, roundi(price / pawn_rate()))
	var from_id: String = def.get("upgrade_from", "")
	if from_id != "" and CARDS.has(from_id):
		# 递归：升级配方 = 同名下级卡×upgrade_dup_n（纯卡面，不吃资源）
		var dup_n: int = maxi(2, int(def.get("upgrade_dup_n", 2)))
		return maxi(1, roundi(pawn_value(from_id) * dup_n / pawn_rate()))
	return 0

static func _config_candidates() -> Array:
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	return [
		exe_dir.path_join(EXTERNAL_FILE),
		exe_dir.path_join("../../../" + EXTERNAL_FILE),   # macOS .app 旁边
		"res://" + EXTERNAL_FILE,
		BUILTIN_PATH,
	]

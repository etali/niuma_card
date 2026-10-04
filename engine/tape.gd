# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Tape
extends RefCounted

## 牌局录像 —— 随时可存，存下来能重放，重放能指出「从第几步开始不对」。
##
## 规则操作逐条录意图；桌面操作记录分组、卡位与拖动轨迹；联网两端逐条录已采纳的
## 服务器结果和快照。配置随录像保存，加载前校验卡牌规则。保存不会中断录制。
## 底层不合并同回合的多个操作：每次购买、典当、每一下攻击和每组产出都保留独立步骤。
## 回放层可把同一组合连续攻击的原子步骤显示为一个行动，但不丢逐击状态。
##
## ## 为什么每一步都存哈希
##
## 重放对不上的时候，「末态不一致」这句话没有排查价值：分叉可能发生在
## 三百步之前。存了每步的哈希，重放就能报出**第一个**不一致的步号和那条
## 意图的摘要 —— 那一步就是要读的代码。这也是这个文件与
## tests/test_net_replay.gd 的分工：那边判「一致不一致」，这边答「哪儿开始不一致」。
##
## 哈希**验不出 int/float 走样**（StateCodec 的 canon 把整值 float 印成整数，
## 那是故意的）。所以「重放全绿」不等于「过一趟 JSON 也全绿」——
## 落盘再读回来那条路要单独判（tests/test_tape.gd）
##
## ## 池子为什么要单独存
##
## 攻击点数池在裁决器身上（`IntentApply._pools`），不在 GameState 上，
## 因此既不在 StateCodec.snapshot 里也不在 state_hash 里。存档要是漏了它，
## 从攻击阶段中途存的那份重放时 `pool_empty()` 一上来就为真 ——
## 攻击段被整段跳过，一条错都不报（联网那边踩过同一个坑，见
## IntentApply.pools_snapshot 的说明）

## 存档格式版本。**读到不认识的版本要拒**，不要「尽力解析」：
## 一份格式对不上的录像重放出来的分叉是假的，比读不出来更费时间
const VERSION := 2
const RecordingConfig = preload("res://engine/recording_config.gd")
const JsonStore = preload("res://engine/json_store.gd")

## 录像存哪儿：**家目录下的 `~/.niumapai_record`**（用户指定）。
##
## 不走 `user://`：那个前缀落在哪儿是引擎定的（macOS 上
## `~/Library/Application Support/…`），改不到家目录来 ——
## `use_custom_user_dir` 只能换掉最后那一层目录名，换不掉上面那几层。
## 所以这里存的是**绝对路径**，`FileAccess` / `DirAccess` 都直接吃。
##
## `~` 得自己展开：Godot 不展开它，照原样传下去会得到一个真叫 `~` 的目录
## （落在进程的工作目录底下，而那是仓库根 —— 录像存进仓库里去了，
## 而且这个坏法在屏幕上看不出来，路径照样报得出来）。
## 见 `_home_dir()`
const DIR_NAME := ".niumapai_record"

## 家目录拿不到时的退路。走到这一支说明环境变量被清过（沙箱、某些 CI），
## 此时**宁可回 `user://`** 也不要把录像撒在工作目录里
const PATH_DIR_FALLBACK := "user://replays"

## 进程内目录覆盖；测试可指向隔离的 user://，空串保持产品默认目录。
## 不读取或修改 HOME，也不持久化为玩家偏好。
static var directory_override := ""

## 家目录。macOS/Linux 是 `HOME`，Windows 是 `USERPROFILE`。
## 两个都没有就返回空串，让 path_dir() 走退路
static func _home_dir() -> String:
	for key in ["HOME", "USERPROFILE"]:
		var v := OS.get_environment(key)
		if v != "":
			return v
	return ""

## 录像目录的绝对路径。每次解析覆盖值，允许测试在独立沙箱内验证首次保存。
static func path_dir() -> String:
	if not directory_override.is_empty():
		return ProjectSettings.globalize_path(directory_override)
	if OS.has_feature("android") or OS.has_feature("ios"):
		return ProjectSettings.globalize_path(PATH_DIR_FALLBACK)
	var home := _home_dir()
	if home == "":
		return ProjectSettings.globalize_path(PATH_DIR_FALLBACK)
	return home.path_join(DIR_NAME)

## 开局那一刻（= 开始录的那一刻）的全量状态。StateCodec.snapshot 的形状
var head: Dictionary = {}

## 开局那一刻的攻击点数池（IntentApply.pools_snapshot 的形状）
var head_pools: Dictionary = {}

## 意图流，逐条 { intent, from, hash }：
##   intent  规范化后的意图（Intent.from_dict 的输出）
##   from    来路座位，阶段推进那几条是空串 —— 重放必须照原样传回去
##   hash    这条落地**之后**的 state_hash，重放时逐步比它
var steps: Array = []

## 卡表指纹（StateCodec.table_hash）。改过 data/cards.json 再重放老录像，
## 分叉是必然的而且和引擎无关 —— 提前报出来，别让人去查引擎
var table: String = ""

## 人看的：什么时候录的、录的是哪一局。不参与重放
var meta: Dictionary = {}

var configuration: Dictionary = {}
var head_view: Dictionary = {}
var view_provider := Callable()
var _remote: NetTransport
var _applier: IntentApply = null
var _last_view: Dictionary = {}
var _gesture: Dictionary = {}


# ---------- 录制 ----------

## 从**现在这一刻**开始录。head 就是此刻的状态，所以中途开始录也是完整的一份。
##
## 同一个 Tape 再 start 一次 = 丢掉前面录的重新开始（重开一局走这条）。
## 忘了先断开旧 applier 的信号会导致两份意图流交织在一条磁带上，
## 那种磁带重放必然在第二条上就落不了地 —— 所以先 stop
func start(applier: IntentApply, note := "") -> void:
	stop()
	_applier = applier
	configuration = RecordingConfig.dump()
	head_view = {}
	_last_view = {}
	_gesture = {}
	head = StateCodec.snapshot(applier.state)
	head_pools = applier.pools_snapshot()
	steps = []
	table = StateCodec.table_hash()
	meta = {
		"note": note,
		"at": Time.get_datetime_string_from_system(true),
		"round": int(applier.state.round_num),
		"rng": applier.state.rng_snapshot(),
	}
	applier.landed_intent.connect(_on_landed_intent)

## 停止录制。断开信号 —— 已经录下的那些留着，还能存、还能重放
func stop() -> void:
	if _applier != null and _applier.landed_intent.is_connected(_on_landed_intent):
		_applier.landed_intent.disconnect(_on_landed_intent)
	_applier = null
	if _remote != null and _remote.recorded_step.is_connected(_on_remote_step):
		_remote.recorded_step.disconnect(_on_remote_step)
	_remote = null

func recording() -> bool:
	return _applier != null or _remote != null

## 一条意图落地了。哈希在这里就算：此刻的状态正是「这条刚落地之后」，
## 而 IntentApply 是同步发信号的，中间插不进别的意图
func _on_landed_intent(intent: Dictionary, result: Dictionary, from_seat: String) -> void:
	_seal_previous_view()
	steps.append({
		"kind": "intent", "intent": intent.duplicate(true), "result": result.duplicate(true), "from": from_seat,
		"hash": StateCodec.state_hash(_applier.state), "at_ms": Time.get_ticks_msec(),
		"before_view": _capture_view(), "gesture": _take_gesture(),
	})

func size() -> int:
	return steps.size()

## 附加诊断不进入规则意图流，保留搜索时实际使用的强度，支持中局调参溯源。
func record_ai_decision(state: GameState, who: String, decision: Dictionary) -> void:
	if not recording(): return
	if not meta.has("ai_decisions"): meta["ai_decisions"] = []
	var entry := decision.duplicate(true)
	entry.merge({"before_step":steps.size()+1,"round":state.round_num,"seat":who,
		"state_hash":StateCodec.state_hash(state),"rng":state.rng_snapshot()},true)
	meta["ai_decisions"].append(entry)

# ---------- 落盘 ----------

func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"table": table,
		"meta": meta,
		"head": head,
		"head_pools": head_pools,
		"configuration": configuration,
		"head_view": head_view,
		"steps": steps,
	}

## 存到 `~/.niumapai_record/<name>.json`。返回落地的路径，失败返回空串。
##
## 为什么不写 res://：导出的游戏包里 res:// 是只读的，而这个功能正是要给
## 「玩到一半发现不对」的人用 —— 那时他手里是导出包，不是仓库
func save(file_name := "") -> String:
	var dir: String = path_dir()
	var fn: String = file_name if file_name != "" else default_name()
	if fn.get_file() != fn or fn in [".", ".."]:
		return ""
	var path: String = dir.path_join(fn)
	return path if JsonStore.save(path, to_dict(), false) else ""

## 时间和步数便于辨认；每次保存使用独立随机后缀，多窗口同秒保存也不会重名。
func default_name() -> String:
	var t := Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "")
	return "%s_%d步_%s.json" % [t.replace("T", "_"), steps.size(), Crypto.new().generate_random_bytes(16).hex_encode()]

## 读一份录像。返回 { ok, tape } 或 { ok=false, reason }。
##
## 实例版 JSON 而不是 JSON.parse_string()：后者解不开时自己打一条引擎 ERROR
## 加一屏回溯，而这里的入参是磁盘上的文件（可能是别人手改过的）
static func load_from(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return { "ok": false, "reason": "没有这个文件：%s" % path }
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return { "ok": false, "reason": "打不开：%s" % path }
	var text := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(text) != OK:
		return { "ok": false, "reason": "不是合法 JSON（第 %d 行：%s）" % [
			j.get_error_line(), j.get_error_message()] }
	if not (j.data is Dictionary):
		return { "ok": false, "reason": "录像不是一个 JSON 对象" }
	return from_dict(j.data)

static func from_dict(d: Dictionary) -> Dictionary:
	if not Intent.valid_integer(d.get("version", -1)):
		return {"ok": false, "reason": "录像版本格式不正确"}
	var v := int(d.get("version", -1))
	if v not in [1, VERSION]:
		return { "ok": false, "reason": "录像版本是 %d，这个版本只认 %d" % [v, VERSION] }
	if not (d.get("head") is Dictionary):
		return { "ok": false, "reason": "录像里没有开局快照" }
	if not d.get("meta", {}) is Dictionary or not d.get("head_pools", {}) is Dictionary or not d.get("steps", []) is Array:
		return {"ok": false, "reason": "录像的步骤或附加信息格式不正确"}
	var t := Tape.new()
	t.table = str(d.get("table", ""))
	t.meta = (d.get("meta", {}) as Dictionary).duplicate(true)
	t.head = (d["head"] as Dictionary).duplicate(true)
	t.head_pools = (d.get("head_pools", {}) as Dictionary).duplicate(true)
	t.configuration = d.get("configuration", {}).duplicate(true) if d.get("configuration", {}) is Dictionary else {}
	t.head_view = d.get("head_view", {}).duplicate(true) if d.get("head_view", {}) is Dictionary else {}
	if v == VERSION and not t.configuration.get("rules") is Dictionary:
		return {"ok": false, "reason": "录像缺少卡牌规则配置，不能载入"}
	# 旧 v2 的指纹未包含升级表；只在录像自己保存的完整规则也一致时迁移。
	if t.table == StateCodec.legacy_table_hash() and RecordingConfig.matches(t.configuration):
		t.table = StateCodec.table_hash()
	var snapshot_error := StateCodec.snapshot_issue(t.head)
	if snapshot_error == "": snapshot_error = StateCodec.pools_issue(t.head_pools)
	if snapshot_error != "": return {"ok": false, "reason": snapshot_error}
	t.steps = []
	for e in d.get("steps", []):
		if e is Dictionary and e.get("kind", "") in ["layout", "snapshot"]:
			if not e.get("view", {}) is Dictionary or not e.get("intent", {}) is Dictionary or not e.get("intent", {}).get("op") is String:
				return {"ok": false, "reason": "录像的操作信息格式错误"}
			if e["kind"] == "snapshot" and (not e.get("snapshot") is Dictionary or not e.get("result") is Dictionary):
				return {"ok": false, "reason": "录像缺少服务器操作结果"}
			if e["kind"] == "layout" and e["intent"]["op"] != "layout":
				return {"ok": false, "reason": "录像桌面操作格式错误"}
			if e["kind"] == "snapshot" and StateCodec.snapshot_issue(e["snapshot"]) != "":
				return {"ok": false, "reason": "录像服务器快照损坏"}
			if e["kind"] == "snapshot" and not _valid_result(e["result"]):
				return {"ok": false, "reason": "录像服务器操作结果损坏"}
			if e["kind"] == "snapshot" and e["intent"]["op"] != e["result"]["op"]:
				return {"ok": false, "reason": "录像快照的操作标记不一致"}
			var entry: Dictionary = e.duplicate(true)
			if e["kind"] == "snapshot":
				entry["result"] = Protocol.restore_uids(entry["result"])
			t.steps.append(entry)
			continue
		if not (e is Dictionary) or not ((e as Dictionary).get("intent") is Dictionary):
			return { "ok": false, "reason": "第 %d 步不是一条意图" % t.steps.size() }
		# 每条意图都过一遍 Intent.from_dict，两个理由：
		#   1. JSON 里没有整数 —— uid 数组读回来全是 double。照抄的话磁带在内存里
		#      带着一堆 3.0，谁拿 steps 去比 uid 都会静默不相等
		#      （重放本身不会错：apply 内部还要再规范化一次。错的是所有**读磁带**
		#      的代码 —— 目录、按 uid 找那一步、界面上标出「哪张卡出问题」）
		#   2. 形状错在**读的时候**就报得出步号。留到重放再报的话，
		#      一份手改坏的磁带会先跑两百步再说「第 217 步落不了地」，
		#      而真正的毛病是第 217 步那行 JSON 少了个字段
		var raw: Dictionary = e["intent"]
		var dec: Dictionary = Intent.from_dict(raw)
		if not dec["ok"]:
			return { "ok": false, "reason": "第 %d 步的意图形状不对：%s" % [
				t.steps.size(), str(dec.get("reason", dec.get("code", ""))) ] }
		var entry: Dictionary = e.duplicate(true)
		entry["intent"] = dec["intent"]
		if e.has("result"):
			if not e["result"] is Dictionary or not _valid_result(e["result"]):
				return {"ok": false, "reason": "第 %d 步的裁决结果格式不正确" % t.steps.size()}
			entry["result"] = Protocol.restore_uids(e["result"])
		entry["from"] = str(e.get("from", ""))
		entry["hash"] = str(e.get("hash", ""))
		t.steps.append(entry)
	return { "ok": true, "tape": t }

# ---------- 重放 ----------

## 重放到一个**裸引擎**上（只有 GameState + IntentApply，没有房间、
## 没有次序机、没有场景层），跑到第 upto 步为止（-1 = 跑完）。
##
## 返回 {
##   ok        没有落不了地的意图，也没有哈希对不上的步
##   state     重放出来的那份 GameState（跑到 upto 为止）
##   applier   它的裁决器（点数池要从这儿看）
##   played    实际跑了几步
##   fault     第一处不对：{ step, op, brief, kind, want, got } —— 没有则 {}
##   notes     人读的行，包括卡表指纹不符这种「和引擎无关」的提醒
## }
##
## `fault` 只报**第一处**：后面那些几乎必然是它的连锁（分叉之后哪张卡在谁手上
## 全变了）。报一屏连锁反而盖掉真正要看的那一行
##
## kind 两种：
##   "rejected"  这一步没落地 —— 录的时候它落地了，现在拒了
##   "diverged"  落地了但状态和录的时候不一样 —— 引擎读到了第三个输入
## on_step 仅在该步裁决与哈希都通过后调用，供回放建立行动索引；原文件不作修改。
static func replay(t: Tape, upto := -1, on_step := Callable()) -> Dictionary:
	var s := GameState.new()
	StateCodec.restore(s, t.head)
	var ap := IntentApply.new(s)
	ap.pools_restore(t.head_pools)
	var notes: Array = []
	if t.table != "" and t.table != StateCodec.table_hash():
		notes.append("卡表和录这份录像时不一样（data/cards.json 改过）——"
			+ "分叉多半来自卡表，不是引擎")
	var n: int = t.steps.size() if upto < 0 else mini(upto, t.steps.size())
	for i in n:
		var e: Dictionary = t.steps[i]
		var it: Dictionary = e["intent"]
		var r: Dictionary = apply_entry(ap, e)
		if not r.get("ok", false):
			return _fault(s, ap, i, it, "rejected",
				str(r.get("reason", r.get("code", ""))), "落地", notes)
		var want := str(e.get("hash", ""))
		var got := StateCodec.state_hash(s)
		if want != "" and want != got:
			return _fault(s, ap, i, it, "diverged",
				want.substr(0, 8), got.substr(0, 8), notes)
		if on_step.is_valid():
			on_step.call(i, r)
	return { "ok": true, "state": s, "applier": ap, "played": n,
		"fault": {}, "notes": notes }

static func _fault(s: GameState, ap: IntentApply, i: int, it: Dictionary,
		kind: String, want: String, got: String, notes: Array) -> Dictionary:
	return {
		"ok": false, "state": s, "applier": ap, "played": i,
		"fault": { "step": i, "op": str(it.get("op", "?")),
			"brief": Intent.brief(it), "kind": kind, "want": want, "got": got },
		"notes": notes,
	}

## 一行人读的重放结论。给命令行工具和 HUD 共用 —— 措辞只有一处
static func verdict(rp: Dictionary) -> String:
	if bool(rp.get("ok", false)):
		return "重放 %d 步全部一致" % int(rp.get("played", 0))
	var f: Dictionary = rp.get("fault", {})
	if str(f.get("kind", "")) == "rejected":
		return "第 %d 步落不了地：%s（%s）" % [int(f.get("step", -1)),
			str(f.get("brief", "")), str(f.get("want", ""))]
	return "第 %d 步状态就不对了：%s（录的时候 %s，重放成了 %s）" % [
		int(f.get("step", -1)), str(f.get("brief", "")),
		str(f.get("want", "")), str(f.get("got", ""))]

## 磁带的目录：每步一行「步号 来路 摘要」。出了 bug 先拿它扫一遍
func outline(from_step := 0, count := 40) -> Array:
	var out: Array = []
	for i in range(maxi(from_step, 0), mini(from_step + count, steps.size())):
		var e: Dictionary = steps[i]
		var who := str(e.get("from", ""))
		out.append("%4d %-8s %s" % [i, who if who != "" else "(服务器)",
			Intent.brief(e["intent"])])
	return out

static func apply_entry(ap: IntentApply, entry: Dictionary) -> Dictionary:
	match str(entry.get("kind", "intent")):
		"layout":
			return {"ok": true, "op": "layout", "seat": entry.get("from", "")}
		"snapshot":
			StateCodec.restore(ap.state, entry["snapshot"])
			ap.pools_restore(entry["snapshot"].get("pools", {}))
			return entry["result"].duplicate(true)
	return ap.apply(entry["intent"], str(entry.get("from", "")))

func start_remote(net: NetTransport, note := "联网客户端") -> void:
	stop()
	_remote = net
	head = StateCodec.snapshot(net.state())
	head_pools = net.applier().pools_snapshot()
	steps.clear()
	head_view = {}
	_last_view = {}
	_gesture = {}
	configuration = RecordingConfig.dump()
	table = StateCodec.table_hash()
	meta = {"note": note, "at": Time.get_datetime_string_from_system(true), "round": net.state().round_num, "rng":net.state().rng_snapshot()}
	net.recorded_step.connect(_on_remote_step)

func _on_remote_step(result: Dictionary, snapshot: Dictionary) -> void:
	_seal_previous_view()
	steps.append({"kind": "snapshot", "intent": {"op": str(result.get("op", "")), "seat": str(result.get("seat", ""))},
		"from": str(result.get("seat", "")), "result": result.duplicate(true), "snapshot": snapshot.duplicate(true),
		"before_view": _capture_view(), "gesture": _take_gesture(), "at_ms": Time.get_ticks_msec(), "hash": StateCodec.state_hash(_remote.state())})

func _capture_view() -> Dictionary:
	return view_provider.call() if view_provider.is_valid() else {}

func update_view() -> void:
	if not recording() or not view_provider.is_valid():
		return
	var view := _capture_view()
	_last_view = view.duplicate(true)
	if steps.is_empty():
		head_view = view
	else:
		steps[-1]["view"] = view

func record_layout(seat: String) -> void:
	if not recording() or not view_provider.is_valid():
		return
	var view := _capture_view()
	if _gesture.is_empty() and StateCodec.canon_hash(view) == StateCodec.canon_hash(_last_view):
		return
	var s := _applier.state if _applier != null else _remote.state()
	steps.append({"kind": "layout", "intent": {"op": "layout", "seat": seat}, "from": seat,
		"before_view": _last_view.duplicate(true), "gesture": _take_gesture(), "view": view, "hash": StateCodec.state_hash(s), "at_ms": Time.get_ticks_msec()})
	_last_view = view.duplicate(true)

func record_drag(seat: String, phase: String, uids: Array, at: Vector3) -> void:
	if not recording():
		return
	if phase == Protocol.DRAG_PICKUP:
		_gesture = {"seat": seat, "uids": uids.duplicate(), "points": [], "started_ms": Time.get_ticks_msec()}
	if _gesture.is_empty() or phase == Protocol.DRAG_CANCEL:
		return
	var points: Array = _gesture["points"]
	var point := {"at": [at.x, at.y, at.z], "ms": Time.get_ticks_msec() - int(_gesture["started_ms"])}
	# 保存实际鼠标路径，固定持牌不重复写几十个相同位置。
	if points.is_empty() or points[-1]["at"] != point["at"]:
		points.append(point)

func _take_gesture() -> Dictionary:
	var gesture := _gesture
	_gesture = {}
	return gesture

func _seal_previous_view() -> void:
	if not steps.is_empty() and view_provider.is_valid():
		steps[-1]["view"] = _capture_view()

static func _valid_result(result: Dictionary) -> bool:
	return Protocol.result_issue(result) == ""

func rebind_remote(net: NetTransport) -> void:
	if head.is_empty():
		start_remote(net)
		return
	# 主机易位仍是同一局，切换录制来源不能清掉已经录下的前半局。
	stop()
	_remote = net
	net.recorded_step.connect(_on_remote_step)

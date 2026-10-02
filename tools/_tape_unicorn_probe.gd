# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree
## 手工探针：逐步重放一份录像，数两边手里的独角兽。
##
## 用法（录像路径当参数，`--` 后面）：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless -s tools/_tape_unicorn_probe.gd -- <录像.json>
##
## 要分开的三种可能（「合了 2 张，下回合只看到 1 张」）：
##   a. 引擎真丢了一张 —— 张数会掉，掉在哪一步那一步就是元凶
##   b. 引擎有 2 张、画面只画 1 张 —— 张数一路是 2，问题在 scenes/
##   c. 压根没合出 2 张 —— 张数从没到过 2，问题在升级判定
##
## 不用 `Tape.replay`：那个只给终局和第一处分叉，中间每一步的张数看不见。
##
## 哈希对不上**不停**，只记一笔：这份录像在 `arm_attacks` 那步就分叉了，
## 而独角兽是在结算（`Settle._resolve_combo` 的 upgrade 分支）里才落地的，
## 停在分叉处等于永远看不到要看的那一段。分叉之后的读数标成「已污染」
const CARD := "dujiaoshou"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("要一个录像路径当参数")
		quit()
		return
	var path := String(args[0])
	var d := Tape.load_from(path)
	if not bool(d.get("ok", false)):
		print("读不了：%s" % str(d.get("reason", "?")))
		quit()
		return
	var t: Tape = d["tape"]
	var same := "一致" if str(t.table) == StateCodec.table_hash() else "不一致"
	print("录像 %s：%d 步，卡表 %s" % [path, t.steps.size(), same])

	var s := GameState.new()
	StateCodec.restore(s, t.head)
	var ap := IntentApply.new(s)
	ap.pools_restore(t.head_pools)

	var prev := _pair(s)
	print("起点：玩家 %d 张 / AI %d 张（第 %d 回合）" % [prev[0], prev[1], s.round_num])

	var dirty := 0        # 第一处哈希分叉的步号（1 基），0 = 还没分叉
	var peak := prev.duplicate()
	for i in t.steps.size():
		var e: Dictionary = t.steps[i]
		var it: Dictionary = e["intent"]
		var no := i + 1
		var tag := str(e["from"]) + " " + str(it.get("op", "?"))

		# 升级组合建起来的那一刻先记一笔：真正落卡在结算，这里只是登记配方
		if str(it.get("op", "")) == "create_combo":
			_note_upgrade(s, no, tag, it)

		var r: Dictionary = ap.apply(it, str(e["from"]))
		if not r.get("ok", false):
			print("第 %d 步被拒：%s —— %s" % [no, tag, str(r.get("reason", "?"))])
			break
		var want := str(e.get("hash", ""))
		if want != "" and want != StateCodec.state_hash(s) and dirty == 0:
			dirty = no
			print("第 %d 步哈希分叉：%s —— 往下的读数带「污」字，另案查" % [no, tag])

		var now := _pair(s)
		if now != prev:
			print("第 %d 步%s：玩家 %d 张 / AI %d 张 ← %s" % [
				no, "（污）" if dirty > 0 else "", now[0], now[1], tag])
			prev = now
		peak[0] = maxi(peak[0], now[0])
		peak[1] = maxi(peak[1], now[1])
		if str(it.get("op", "")) == "next_round":
			print("  ↳ 进第 %d 回合，此刻 玩家 %d / AI %d" % [s.round_num, now[0], now[1]])

	print("")
	print("峰值：玩家 %d 张 / AI %d 张" % [peak[0], peak[1]])
	print("终局：玩家 %d 张 / AI %d 张（第 %d 回合）" % [prev[0], prev[1], s.round_num])
	if dirty > 0:
		print("注意：第 %d 步起哈希就和录像对不上了" % dirty)
	quit()

## 这个 create_combo 是不是升级配方，产物是什么。
## 念的是 ComboRules 的判定，和引擎结算走同一条，不另写一份张数规则
func _note_upgrade(s: GameState, no: int, tag: String, it: Dictionary) -> void:
	var seat := str(it.get("seat", ""))
	if not s.players.has(seat):
		return
	var uids: Array = it.get("uids", [])
	var names: Array = []
	var cards: Array = []
	for u in uids:
		var c := s.find_card(seat, int(u))
		if c.is_empty():
			names.append("?")
			continue
		names.append(str(c.get("def_id", "?")))
		cards.append(c)
	var ev := ComboRules.evaluate(cards)
	if str(ev.get("type", "")) != "upgrade":
		return
	print("第 %d 步 %s：升级配方 %s → 「%s」（产物要到结算才落卡）" % [
		no, tag, str(names), str(ev.get("output_card", "?"))])

func _pair(s: GameState) -> Array:
	return [_count(s, GameState.PLAYER), _count(s, GameState.AI)]

func _count(s: GameState, who: String) -> int:
	var n := 0
	for c in s.players[who]["cards"]:
		if str(c.get("def_id", "")) == CARD:
			n += 1
	return n

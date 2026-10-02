# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Transport
extends RefCounted

## 意图传输的抽象接口（net/protocol.gd）
##
## 场景层只认这四样东西，不认底下是本地还是 WebSocket：
##   await transport.submit(intent, from_seat) -> Dictionary
##   transport.applied  / transport.rejected   信号
##   transport.applier                         裁决器（本地局直接持有；联网时客户端侧为空）
##
## **submit 一定是 coroutine**，哪怕本地实现根本不需要等：
## 远程要走一趟往返，接口如果做成同步返回，联网时每个调用点都得改一次 await
## —— 那就又分叉成两条执行路径了，正是 README.md §「3. 文件目录结构」要避免的那件事。
## 所以下面的 _await_gate() 里留着一个 await：它在本地实现下不真的挂起，
## 但足以让 GDScript 把 submit 标成 coroutine，调用点写 await 不会报
## 「redundant await」，将来换成真往返也不用动调用点

signal applied(result: Dictionary)
signal rejected(result: Dictionary)

## 已落地的意图序号。联网时用来丢弃过期包，本地留着给测试和回放对齐
var seq := 0

## 子类置 true 表示 submit 要真的挂起等对端回话
var _remote := false

## 提交一个意图。
## from_seat 传空 = 以「服务器自己」的身份提交（阶段推进走这条）；
## 传座位 = 以某个客户端的身份发包，会过冒充 / 阶段推进那两道校验
func submit(_intent, _from_seat := "") -> Dictionary:
	push_error("Transport.submit 未实现")
	await _await_gate()
	return Intent.err("no_transport", "没有可用的传输层")

## 见文件头：这个 await 的作用是让子类的 submit 保持 coroutine 身份。
## 本地实现下 _remote 为 false，一次也不挂起
func _await_gate() -> void:
	if _remote:
		await applied

## 结果广播。落地结果不只返回给调用方 —— 联网时对手的意图也会到这里，
## 那时候没有「调用方」可以返回给（net/protocol.gd的 foe_* 消息）
func _publish(r: Dictionary) -> Dictionary:
	if r.get("ok", false):
		seq += 1
		r["seq"] = seq
		applied.emit(r)
	else:
		rejected.emit(r)
	return r

# ---------- 阶段推进的快捷入口 ----------
## 写成方法而不是让调用方拼 Intent.xxx()：「谁能推进阶段」将来要收到服务器侧，
## 调用点集中在这几个名字上比散在各处好改

func arm(seat: String) -> Dictionary:
	return await submit(Intent.arm_attacks(seat))

func attack_done(seat: String) -> Dictionary:
	return await submit(Intent.attack_done(seat))

func produce(combo_idx: int) -> Dictionary:
	return await submit(Intent.produce(combo_idx))

func finalize() -> Dictionary:
	return await submit(Intent.finalize())

func next_round() -> Dictionary:
	return await submit(Intent.next_round())

# ---------- 阶段驱动 ----------
## 同一编排供无头与牌桌使用；牌桌通过 RoundFlow 的回调插入演出与玩家输入。
const RoundFlow = preload("res://engine/round_flow.gd")

func round_flow() -> RefCounted:
	return RoundFlow.new(func(): return self)

func run_attack_phase(seat: String, picker: Callable = Callable()) -> void:
	var flow := round_flow()
	await flow.run_attack_turn(seat, Callable(), picker)

func run_settle() -> void:
	var flow := round_flow()
	await flow.run_settle()

func run_round(picker: Callable = Callable()) -> void:
	var flow := round_flow()
	await flow.run_round(picker)

## 子类给出裁决器与状态。客户端侧的 NetTransport 没有本地裁决器，
## 那时这两个驱动方法用不上（阶段推进由服务器发）—— 所以基类只 push_error
func applier() -> IntentApply:
	push_error("Transport.applier 未实现")
	return null

func state() -> GameState:
	push_error("Transport.state 未实现")
	return null

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name LocalTransport
extends Transport

## 本地传输 —— 「服务器就在同一个进程里」的那一种。
## 单机局用它；联网时换成 NetTransport，场景层一行都不用改（见 Transport）
##
## **落地即广播**：这里连着 applier 的 landed 信号，所以经过这个裁决器的每条
## 意图都会发一遍 applied —— 包括没走 submit() 的那些（BOT 内部直接 apply 的
## 编组和典当，见 IntentApply.landed 的说明）。联网侧的 NetTransport 早就是
## 这个语义了（服务器给每条落地结果广播一遍 applied），本地侧原先不是：
## 于是「对手做了什么」在单机局只有驱动 BOT 的那段代码知道，联网局却要靠信号 ——
## 两条路径的表现层代码没法是同一份。补齐这一侧就不用分叉了

var _applier: IntentApply

func _init(a: IntentApply) -> void:
	_applier = a
	_remote = false
	_applier.landed.connect(_on_landed)

func applier() -> IntentApply:
	return _applier

func state() -> GameState:
	return _applier.state

## 落地了就广播。这一条也是 submit() 成功时唯一的发布点 ——
## 见下面 submit 里的说明
func _on_landed(r: Dictionary) -> void:
	_publish(r)

func submit(intent, from_seat := "") -> Dictionary:
	var r: Dictionary = _applier.apply(intent, from_seat)
	await _await_gate()   # 本地不挂起，见 Transport 文件头
	# 成功的那条已经被 _on_landed 发过了（landed 是同步发的，所以
	# 走到这里时 _publish 早就跑完，seq 也已经盖在 r 上了）。
	# 判据用 has("seq") 而不是一个 _announced 标志位：engine/transport.gd 的
	# _publish 是全仓唯一往结果里写 seq 的地方，所以「盖过章」就是「广播过」——
	# 无状态的判据不会因为回调里再落地一条意图而错乱。
	# 被拒的意图不发 landed，落到下面这行去发 rejected（seq 不涨，
	# 那是 tests/test_intent.gd「被拒的意图不涨 seq」在比的东西）
	if r.has("seq"):
		return r
	return _publish(r)

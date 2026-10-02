# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 单机牌桌与无头驱动共用的回合编排。传输负责裁决；回调只插入输入/演出。
## provider 每步读取当前传输，允许同一对局接管主机；cancelled 终止已被替换的会话。
var provider: Callable
var cancelled: Callable

func _init(transport_provider: Callable, cancellation: Callable = Callable()) -> void:
	provider = transport_provider
	cancelled = cancellation

func active() -> bool:
	return not cancelled.is_valid() or not cancelled.call()

func _cancelled_result() -> Dictionary:
	return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}

func run_attacks(body: Callable = Callable(), picker: Callable = Callable()) -> Dictionary:
	if not active():
		return _cancelled_result()
	var order: Array = provider.call().state().action_order()
	for seat in order:
		if not active():
			return _cancelled_result()
		if provider.call().state().winner != "":
			break
		var result := await run_attack_turn(seat, body, picker)
		if not result.get("ok", false):
			return result
	return {"ok": true}

func run_attack_turn(seat: String, body: Callable = Callable(), picker: Callable = Callable()) -> Dictionary:
	if not active():
		return _cancelled_result()
	var result: Dictionary = await provider.call().arm(seat)
	if not active():
		return _cancelled_result()
	if not result.get("ok", false) or result.get("empty", true):
		return result
	var pools: Dictionary = provider.call().applier().pools(seat)
	if body.is_valid():
		result = await body.call(seat, pools)
	else:
		result = await run_automatic_attack(seat, picker)
	return result if active() else _cancelled_result()

## AI 与无头使用同一选靶/余点/逐张扣牌循环；表现层可按同一摞插入瞄准和收尾。
func run_automatic_attack(seat: String, picker: Callable = Callable(),
		before_batch: Callable = Callable(), after_batch: Callable = Callable(),
		exhausted: Callable = Callable()) -> Dictionary:
	if picker.is_null():
		picker = AIPlan.target_picker()
	while active():
		var transport = provider.call()
		var state: GameState = transport.state()
		var applier: IntentApply = transport.applier()
		if state.winner != "" or applier.pool_empty(seat):
			return {"ok": true}
		var affordable: Array = applier.affordable_targets(seat)
		if affordable.is_empty():
			if exhausted.is_valid():
				exhausted.call()
			return await transport.submit(Intent.attack_done(seat, Intent.DONE_EXHAUSTED))
		var target: Dictionary = await picker.call(state, seat, affordable, applier.pools(seat))
		if not active():
			return _cancelled_result()
		if target.is_empty():
			return await provider.call().submit(Intent.attack_done(seat, Intent.DONE_FORFEIT))
		var batch := GameState.target_batch(target)
		if before_batch.is_valid():
			await before_batch.call(target)
		if not active():
			return _cancelled_result()
		while active():
			var result: Dictionary = await provider.call().submit(Intent.apply_attack(seat, target))
			if not active():
				return _cancelled_result()
			if not result.get("ok", false):
				return result
			transport = provider.call()
			applier = transport.applier()
			if transport.state().winner != "" or batch == "" or applier.pool_empty(seat):
				break
			var same: Array = applier.affordable_targets(seat).filter(func(candidate): return GameState.target_batch(candidate) == batch)
			if same.is_empty():
				break
			target = await picker.call(transport.state(), seat, same, applier.pools(seat))
			if not active():
				return _cancelled_result()
			if target.is_empty():
				break
		if after_batch.is_valid():
			await after_batch.call(target)
	return _cancelled_result()

## presenter(index, resolve) 可以在 resolve() 前后演出；真实 produce 仍只有一个入口。
func run_settle(presenter: Callable = Callable()) -> Dictionary:
	if not active():
		return _cancelled_result()
	var count: int = provider.call().applier().production_count()
	for index in count:
		var result: Dictionary = await presenter.call(index, produce.bind(index)) if presenter.is_valid() else await produce(index)
		if not active():
			return _cancelled_result()
		if not result.get("ok", false):
			return result
	return await finalize()

func produce(index: int) -> Dictionary:
	if not active():
		return _cancelled_result()
	return await provider.call().produce(index)

func finalize() -> Dictionary:
	if not active():
		return _cancelled_result()
	return await provider.call().finalize()

func run_round(picker: Callable = Callable()) -> Dictionary:
	var result := await run_attacks(Callable(), picker)
	if not active():
		return _cancelled_result()
	if not result.get("ok", false):
		return result
	if provider.call().state().winner == "":
		return await run_settle()
	return await finalize()

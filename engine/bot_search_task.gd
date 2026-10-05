# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 协作式任务：线程只保存调用栈，不并行计算。调度器一次只唤醒一个任务。
## 暂停发生在真实扣费前；恢复继续原调用栈，既不重算，也不丢掉局部进度。
var thread := Thread.new()
var resume := Semaphore.new()
var yielded := Semaphore.new()
var allowance := 0
var aborted := false
var done := false
var result: Dictionary = {}
var progress: Dictionary = {}
var meter: RefCounted
var work := 0
var turns := 0
var kind := ""
var node: Dictionary = {}
var run: Callable

func start(callback: Callable, ledger: RefCounted) -> void:
	run = callback
	meter = ledger
	var error := thread.start(_execute)
	if error != OK:
		result = {"thread_error":error}
		done = true
		yielded.post()

func _execute() -> void:
	resume.wait()
	result = run.call(self) if not aborted else {}
	done = true
	yielded.post()

func charge(amount: int, category: String, at: Dictionary) -> bool:
	while allowance < amount and not aborted:
		yielded.post()
		resume.wait()
	if aborted: return false
	if not meter.spend(amount,category,at):
		aborted = true
		return false
	allowance -= amount
	work += amount
	return true

func advance(quantum: int) -> void:
	allowance += quantum
	turns += 1
	resume.post()
	yielded.wait()

func stop() -> void:
	if not done:
		aborted = true
		resume.post()
	if thread.is_started(): thread.wait_to_finish()
	# Callable可能捕获本任务；释放后避免环。
	run = Callable()

func cancelled() -> bool:
	return aborted

func publish_future(value: Dictionary) -> void:
	progress = value.duplicate()

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 主线程请求停止；工作线程只读这个令牌，不调用场景树。
var _mutex := Mutex.new()
var _cancelled := false

func request() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func is_cancelled() -> bool:
	_mutex.lock()
	var result := _cancelled
	_mutex.unlock()
	return result

static func requested(parameters: Dictionary) -> bool:
	if parameters.has("_compute") and parameters["_compute"].stopped(): return true
	if not parameters.has("_cancelled"): return false
	return probe_requested(parameters["_cancelled"])

static func probe_requested(probe: Callable) -> bool:
	return probe.is_valid() and bool(probe.call())

static func checker(parameters: Dictionary) -> Callable:
	return func() -> bool: return requested(parameters)

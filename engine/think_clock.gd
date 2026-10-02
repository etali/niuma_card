# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name ThinkClock
extends RefCounted

## 「对手想了多久」的秒表。**量的是墙钟，不是估的**。
##
## 面板显示当前搜索的实时耗时、上次耗时及累计平均值。
## 不使用固定档位耗时表，避免把其他机器上的测量值当成本机结果。
##
## ---
##
## **为什么要它，而不是让 `AIThink` 自己计时。**
##
## 联网局那一路压根不经过 `AIThink`：对手在他自己那台机器上想，
## 这边只是在 `scenes/main.gd::_await_foe_action` 里等一条 action_done。
## 也就是说「思考耗时」有两个来源，只有一个在工作线程上 ——
## 秒表必须待在两条路都够得着的地方。
##
## 而这两条路都在 `scenes/main.gd` 里，读它的却是 `scenes/ai_panel.gd`：
## 面板不连任何信号到主场景（见 main.gd 建面板那段注释）。
## 静态状态是这两者之间唯一现成的通道 —— `AISearch` 的玩家偏好、
## `Palette` 的配色走的都是这条路，同一个形状。
##
## ---
##
## 用法：
##     ThinkClock.start(ThinkClock.SRC_AI)   # 开始想
##     …
##     ThinkClock.stop()                     # 想完了，这一趟计入统计
## 面板每帧问 `running()` / `elapsed_ms()`（在跑）或 `last_ms()`（跑完了）。


## 谁在想。分开记是因为屏幕上要念不同的话：
## 本地 AI 那一路念「AI」，联网局念「对手」——
## 联网局里对面是个人，管他叫 AI 是错的
const SRC_AI := "ai"
const SRC_FOE := "foe"

## 现在在跑的话，是谁在跑；空串 = 没人在想
static var _src := ""

## 这一趟的起点（`Time.get_ticks_msec()`）。只在 `_src` 非空时有意义
static var _t0 := 0

## 最近一趟的耗时和来源。跑完之后面板念的是这两个
static var _last_ms := -1
static var _last_src := ""

## 统计：趟数和总毫秒。平均值现算（`avg_ms`）而不是滚动更新 ——
## 滚动的平均要自己处理「除零」和精度漂移，存两个整数没这些事
static var _count := 0
static var _total_ms := 0


## 开始计时。**重复 start 以最后一次为准**：前一趟不计入统计。
##
## 为什么不报错也不累加：这个类是屏幕上一行字的数据源，
## 它的错处理只能是「显示的数字不对」，不该反过来影响对局。
## 而真会撞上这条的是「上一趟没 stop 就换局了」—— 那一趟的数确实不该要
static func start(src: String) -> void:
	_src = src
	_t0 = Time.get_ticks_msec()


## 停表，这一趟计入统计。没在跑就什么也不做（幂等）。
##
## 幂等是必须的：`main.gd` 的 stop 在 `await` 之后，
## 而换局 / 掉线会让那个 await 之后的代码走不到 —— 下一次 `start` 会盖掉，
## 但中间可能已经有人调过 `stop`
static func stop() -> void:
	if _src == "":
		return
	var ms := Time.get_ticks_msec() - _t0
	_last_ms = ms
	_last_src = _src
	_count += 1
	_total_ms += ms
	_src = ""


## 有人正在想吗
static func running() -> bool:
	return _src != ""


## 谁在想（在跑）。没人在想时返回空串
static func source() -> String:
	return _src


## 这一趟到此刻走了多少毫秒。没在跑返回 0 ——
## 面板那边靠 `running()` 分支，不靠这个数判有无
static func elapsed_ms() -> int:
	if _src == "":
		return 0
	return Time.get_ticks_msec() - _t0


## 最近一趟花了多少毫秒。**从没跑过是 -1**，不是 0：
## 0 是个合法读数（快到不足一毫秒），拿它当「没有」会念出「上次 0 毫秒」
static func last_ms() -> int:
	return _last_ms


## 最近一趟是谁。空串 = 从没跑过
static func last_source() -> String:
	return _last_src


## 一共跑过几趟
static func count() -> int:
	return _count


## 平均每趟多少毫秒。没跑过返回 -1（同 `last_ms` 的理由）
static func avg_ms() -> int:
	if _count <= 0:
		return -1
	return int(round(float(_total_ms) / float(_count)))


## 清空。换局时调 —— 上一局的平均值挂在新一局的面板上是假话。
##
## 也给单测用：静态状态跨测试文件不重置的话，
## 前一个文件跑出来的趟数会漏到后一个的判据里
static func reset() -> void:
	_src = ""
	_t0 = 0
	_last_ms = -1
	_last_src = ""
	_count = 0
	_total_ms = 0

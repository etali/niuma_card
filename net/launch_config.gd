# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name LaunchConfig
extends RefCounted

## 从启动参数读取房间、联机角色和指定的试玩卡表。
const MODE_SOLO := "solo"     ## 什么都没指定 → 照旧单机开局，玩家自己点「联网对战」
const MODE_HOST := "host"     ## 自己开服务器等人连进来（桌面版才做得到）
const MODE_JOIN := "join"     ## 连一个已经在跑的服务器

## 认得的参数名。长短两种都收 —— 网址是要手打/贴到聊天窗口里的，
## `?s=...&r=...` 比 `?server=...&room=...` 短一半
const KEYS_SERVER := ["server", "s"]
const KEYS_ROOM := ["room", "r"]
const KEYS_HOST := ["host", "h"]
const KEYS_PORT := ["port", "p"]

## 启动器可以将参数放在 Godot 的 -- 分隔符之前或之后。
const FLAG_PREFIXES := ["--server=", "--room=", "--port=", "--host", "--off-work-playtest", "--cards-config=", "--cards-config"]

## Release builds buffer stdout when launched by the workbench. stderr is
## flushed immediately and joins the same launch log, so readiness must use it.
static func report_playtest_ready(marker: String) -> void:
	printerr(marker)

# ---------- 解析 ----------

## 把一份 { 参数名: 值 } 解析成启动配置。
##
## 返回 { mode, url, room, port }；指定卡表时另带 cards_config。room 已经归一化过（Protocol.normalize_room），
## 非法的房间码会**退回 solo** 而不是带着一个连不上的码去连 ——
## 带着去连的症状是「网页打开就报房号不合法」，玩家不知道错在链接里
static func parse(params: Dictionary) -> Dictionary:
	var out := { "mode": MODE_SOLO, "url": "", "room": "", "port": 0 }
	# 保留“显式传了空路径”和“没传”的区别，前者应报错，不能悄悄试玩默认卡表。
	if params.has("cards-config"):
		out["cards_config"] = str(params["cards-config"])
	var raw_server := _pick(params, KEYS_SERVER)
	var raw_room := _pick(params, KEYS_ROOM)
	var raw_port := _pick(params, KEYS_PORT)
	var raw_host := _pick(params, KEYS_HOST)

	if raw_port != "":
		out["port"] = int(raw_port)
	var room := Protocol.normalize_room(raw_room)
	if room != "" and Protocol.valid_room(room):
		out["room"] = room

	# --host / ?host=1：自己开服务器等人。房间码没写就让界面现生一个
	if _truthy(raw_host):
		out["mode"] = MODE_HOST
		return out

	var url := normalize_url(raw_server, out["port"])
	if url == "":
		return out
	out["url"] = url
	# 有地址、没房间码 → 还是要玩家填一个（进哪一间是两人之间的约定，猜不出来）。
	# 但地址要**填好放在输入框里**，所以 url 照样带回去
	if out["room"] == "":
		return out
	out["mode"] = MODE_JOIN
	return out

## 把玩家/链接里各种写法补成一个完整的 ws:// 地址。
##
##   ""                     → ""（没写）
##   "ws://1.2.3.4:8910"    → 原样
##   "wss://x.com/pvp"      → 原样（远程服务的 TLS 地址，保留显式协议与路径）
##   "1.2.3.4"              → "ws://1.2.3.4:8910"（补协议和默认端口）
##   "1.2.3.4:9000"         → "ws://1.2.3.4:9000"
##
## 为什么要补：这个字符串来自**网址里的参数**，而网址要贴进聊天窗口。
## 逼玩家在参数里写全 `server=ws%3A%2F%2F1.2.3.4%3A8910` 的话，
## 一半的链接会因为没转义冒号斜杠而失效，而失效的形态是「打开就说连不上」
static func normalize_url(text: String, default_port := 0) -> String:
	var s := text.strip_edges()
	if s == "":
		return ""
	var p := default_port if default_port > 0 else EmbeddedHost.DEFAULT_PORT
	if s.begins_with("ws://") or s.begins_with("wss://"):
		return s
	# 带端口就用它自己那个，光主机名才补默认端口。
	# 判「有没有端口」看最后一个冒号后面是不是纯数字 —— IPv6 里冒号很多
	var colon := s.rfind(":")
	if colon > 0 and s.substr(colon + 1).is_valid_int():
		return "ws://" + s
	return "ws://%s:%d" % [s, p]

static func read_desktop() -> Dictionary:
	return parse_flags(desktop_args())

static func desktop_args() -> PackedStringArray:
	var user := OS.get_cmdline_user_args()
	if not user.is_empty():
		return user
	return pick_desktop_args(OS.get_cmdline_args())

static func pick_desktop_args(args: PackedStringArray) -> PackedStringArray:
	var picked := PackedStringArray()
	var i := 0
	while i < args.size():
		var a := args[i]
		for f in FLAG_PREFIXES:
			if a == f or (f.ends_with("=") and a.begins_with(f)):
				picked.append(a)
				if a == "--cards-config" and i + 1 < args.size() and not args[i + 1].begins_with("--"):
					i += 1
					picked.append(args[i])
				break
		i += 1
	return picked

## `--room=ABCD` → { room: "ABCD" }。参数名和 web 那边**同一套**（KEYS_*）
static func parse_flags(args) -> Dictionary:
	var out := {}
	var i := 0
	while i < args.size():
		var s := str(args[i])
		i += 1
		if not s.begins_with("--"):
			continue
		s = s.substr(2)
		var eq := s.find("=")
		if s.to_lower() == "cards-config":
			out["cards-config"] = ""
			if i < args.size() and not str(args[i]).begins_with("--"):
				out["cards-config"] = str(args[i])
				i += 1
		elif eq < 0:
			out[s.to_lower()] = "1"
		else:
			out[s.substr(0, eq).to_lower()] = s.substr(eq + 1)
	return out

# ---------- 这一次启动 ----------

## 当前进程的启动配置。**平台分歧只在这一个函数里**：
## 取参数的来源不同，往下全是同一条 parse()
static func current() -> Dictionary:
	return parse(read_desktop())

static func _pick(params: Dictionary, keys: Array) -> String:
	for k in keys:
		if params.has(k):
			return str(params[k])
	return ""

## 开关型参数的真值。`?host`、`?host=1`、`?host=true`、`?host=yes` 都算真；
## `?host=0` / `?host=false` 算假 —— 有人会照着「参数=值」的直觉写 `host=0`
## 来表示不要，而把它当真值处理的话那条链接的行为和字面意思相反
static func _truthy(text: String) -> bool:
	var s := text.strip_edges().to_lower()
	return s != "" and s != "0" and s != "false" and s != "no"

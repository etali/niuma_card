# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name LaunchConfig
extends RefCounted

## 本次启动配置：联网入口供 Web 和桌面共用，桌面另支持指定单机试玩卡表。
##
## 这个类存在的全部理由是需求 6（逻辑只有一份）。同一件事有两个入口：
##   Web    ：网址里的查询参数   index.html?server=ws://host:8910&room=ABCD
##   桌面   ：命令行参数         牛马牌.app --server=ws://host:8910 --room=ABCD
## 两者**只有取字符串那一步不同**（read_web / read_desktop），
## 解析、归一化、决定进哪种模式全在 parse() 里，一份。
##
## 反过来做会怎样：web 那一侧单独写一段「读 URL → 连服务器」的代码，
## 于是房间码归一化、默认端口、地址补 ws:// 这几件事各有一份实现，
## 而两份的分歧只在网页上才看得见（本地测不出来）—— 那正是 执行入口各自实现同一逻辑造成的静默分叉。
##
## 判据在 tests/test_launch_config.gd。parse() 是**纯函数**（传字典进去），
## 所以那条判据不需要浏览器、不需要端口，直接喂参数

## 三种模式
const MODE_SOLO := "solo"     ## 什么都没指定 → 照旧单机开局，玩家自己点「联网对战」
const MODE_HOST := "host"     ## 自己开服务器等人连进来（桌面版才做得到）
const MODE_JOIN := "join"     ## 连一个已经在跑的服务器（网页版只有这一种）

## 认得的参数名。长短两种都收 —— 网址是要手打/贴到聊天窗口里的，
## `?s=...&r=...` 比 `?server=...&room=...` 短一半
const KEYS_SERVER := ["server", "s"]
const KEYS_ROOM := ["room", "r"]
const KEYS_HOST := ["host", "h"]
const KEYS_PORT := ["port", "p"]

## 桌面命令行认的前缀。**和 web 的参数名对齐**（--server= ←→ ?server=），
## 两边记两套名字的话文档要写两遍，而写两遍必有一遍过期
const FLAG_PREFIXES := ["--server=", "--room=", "--port=", "--host", "--cards-config=", "--cards-config"]

# ---------- 解析 ----------

## 把一份 { 参数名: 值 } 解析成启动配置。
##
## page_host 是网页自己所在的主机名（web 才有，桌面传空）。它的用途只有一个：
## 只写了 ?room=ABCD 时**默认连发出这个网页的那台机器** ——
## 网页是从服务器那台机器上发出来的，那台机器十有八九也跑着专服。
## 少了这一条，最短的那条邀请链接（只带房间码）连不上任何东西。
##
## 返回 { mode, url, room, port }；指定卡表时另带 cards_config。room 已经归一化过（Protocol.normalize_room），
## 非法的房间码会**退回 solo** 而不是带着一个连不上的码去连 ——
## 带着去连的症状是「网页打开就报房号不合法」，玩家不知道错在链接里
static func parse(params: Dictionary, page_host := "") -> Dictionary:
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
	if url == "" and out["room"] != "" and page_host != "":
		# 只带房间码的短链接：连发网页的那台机器
		url = normalize_url(page_host, out["port"])
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

# ---------- 取参数：Web ----------

## 读网址里的查询串。**只有网页版会返回东西**。
##
## JavaScriptBridge 走 Engine.get_singleton 而不是直接写它的名字：
## 那个单例只在 web 导出里注册，桌面版上直接引用是**编译期**报错 ——
## 整个脚本解析失败，症状是「桌面版一启动就黑屏」，
## 而这段代码本来只在网页上才该跑
static func read_web() -> Dictionary:
	var query := web_query()
	if query == "":
		return {}
	return parse_query(query)

## 网页自己所在的主机名（桌面版是空串）
static func web_page_host() -> String:
	return _js_eval("window.location.hostname")

static func web_query() -> String:
	return _js_eval("window.location.search")

static func _js_eval(expr: String) -> String:
	if not OS.has_feature("web"):
		return ""
	if not Engine.has_singleton("JavaScriptBridge"):
		return ""
	var js: Object = Engine.get_singleton("JavaScriptBridge")
	var v: Variant = js.call("eval", expr, true)
	return "" if v == null else str(v)

## `?a=1&b=2` → { a: "1", b: "2" }。**纯函数**，判据直接喂字符串。
##
## 值要 uri_decode：地址里的 `://` 贴进聊天窗口常被转义成 `%3A%2F%2F`
static func parse_query(query: String) -> Dictionary:
	var out := {}
	var q := query
	if q.begins_with("?"):
		q = q.substr(1)
	for part in q.split("&", false):
		var eq := part.find("=")
		if eq < 0:
			# `?host` 这种没有等号的开关也要认：写 `?host=1` 才生效的话，
			# 一半的人会写 `?host` 然后以为功能坏了
			out[part.uri_decode().to_lower()] = "1"
			continue
		var k := part.substr(0, eq).uri_decode().to_lower()
		out[k] = part.substr(eq + 1).uri_decode()
	return out

# ---------- 取参数：桌面 ----------

## 读命令行。`--server=... --room=... --host --port=... --cards-config=/path/cards.json`
##
## **两条命令行都扫**：get_cmdline_user_args() 只返回 `--` 之后的东西，
## 少写那个分隔符时它是空的，于是参数被静默忽略 ——
## 照着文档写却不生效，这个坑在 tools/pvp_server.gd 上踩过一次（见那里的 _args）
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
	if OS.has_feature("web"):
		return parse(read_web(), web_page_host())
	return parse(read_desktop())

## 网页版开不了监听端口（net/embedded_host.gd 的平台限制），所以主机模式只有桌面版有。
## 界面按这个决定要不要画「开房间」那个按钮 —— 画了点不动比不画糟糕
static func can_host() -> bool:
	return not OS.has_feature("web")

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

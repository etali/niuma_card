# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 启动参数：**网页版和桌面版走同一条解析**（需求 5、6）
##
## 为什么这条判据非要有：网页那一半在测试里跑不到 ——
## 没有浏览器就没有 window.location，于是 read_web() 永远返回空。
## 如果「读 URL → 决定进哪种模式」这段逻辑长在 read_web() 里面，
## 那它就是一段**只在网页上跑、而任何测试都碰不到**的代码，
## 而它出错的形态是「链接打开就是单机局」—— 玩家不会报这种 bug，
## 他只会觉得链接没用。
##
## 所以 LaunchConfig 被切成两半：取字符串（平台相关，测不了）
## 和 parse()（纯函数，全在这里钉住）。这条判据钉的就是那道切口：
## 只要 parse 是纯的，网页和桌面就不可能在「同一个参数进哪种模式」上分叉。
##
## 变异提示（都实跑确认过红，登记进 tools/mutate_check.py）：
##   1. parse 里 `if _truthy(raw_host)` 改成 `if false`
##      → T3「?host=1 进主机模式」红（网页/命令行要求开房被静默当成单机）
##   2. normalize_url 里去掉补默认端口那一行（`return "ws://" + s`）
##      → T2「光主机名补上了默认端口」红（连 ws://1.2.3.4 直接失败）
##   3. parse 里 `if room != "" and Protocol.valid_room(room)` 去掉后半段
##      → T4「非法房号退回单机」红（带着连不上的房号去连，报的是服务器的话）
##   4. parse_query 里 `if eq < 0` 那一支直接 continue
##      → T1「没有等号的开关也认」红（`?host` 静默失效）
##   5. parse 里 page_host 那一支去掉
##      → T5「只带房间码的短链接连发页面的那台机器」红

func _initialize() -> void:
	print("=== 启动参数测试 ===")
	_t1_query_parse()
	_t2_url_normalize()
	_t3_modes()
	_t4_bad_room()
	_t5_short_link()
	_t6_flags()
	_t7_same_path()
	finish()

# ---------- T1 查询串 ----------

func _t1_query_parse() -> void:
	print("\n--- T1 查询串 ---")
	var q := LaunchConfig.parse_query("?server=ws://1.2.3.4:8910&room=abcd")
	check(str(q.get("server", "")) == "ws://1.2.3.4:8910",
		"server 读出来了（实为 %s）" % str(q.get("server", "")))
	check(str(q.get("room", "")) == "abcd", "room 读出来了")
	check(LaunchConfig.parse_query("server=x").get("server", "") == "x",
		"没有前导问号也能读")
	# 贴进聊天窗口的链接常被转义。不解码的话地址里是 %3A%2F%2F，
	# connect_to_url 失败，而报出来的是「连不上」—— 玩家去查网络，错在链接里
	check(LaunchConfig.parse_query("?s=ws%3A%2F%2Fa.com%3A9000").get("s", "")
			== "ws://a.com:9000",
		"值做了 uri_decode —— 转义过的地址也要能用")
	# `?host` 这种没有等号的开关：写 `?host=1` 才生效的话，
	# 一半的人会写 `?host` 然后以为功能坏了。
	#
	# 这里必须走 .get 而不是 ["host"]：键不存在时下标是**运行时错误**，
	# 它把 _t1 整个中断掉，后面两条断言压根不跑 —— 而 run_tests.sh
	# 只数结果行、只 grep [FAIL]，于是「少跑了两条」在摘要里看不出来。
	# 实测：把 parse_query 无等号那一支改成 continue，下标写法是
	# 「49 通过 / 0 失败」（绿），.get 写法才是这条断言变红
	check(str(LaunchConfig.parse_query("?host").get("host", "")) == "1",
		"没有等号的开关也认（?host）")
	check(LaunchConfig.parse_query("").is_empty(), "空查询串什么都不产")

# ---------- T2 地址补全 ----------

func _t2_url_normalize() -> void:
	print("\n--- T2 地址补全 ---")
	check(LaunchConfig.normalize_url("") == "", "没写就是没写")
	check(LaunchConfig.normalize_url("ws://a:1") == "ws://a:1", "写全了原样不动")
	check(LaunchConfig.normalize_url("wss://x.com/pvp") == "wss://x.com/pvp",
		"wss 原样不动 —— 远程那一档带 TLS")
	# 光主机名要补协议和端口：邀请链接里写全 `ws%3A%2F%2F…` 的话，
	# 一半会因为没转义而失效
	check(LaunchConfig.normalize_url("1.2.3.4")
			== "ws://1.2.3.4:%d" % EmbeddedHost.DEFAULT_PORT,
		"光主机名补上了协议和默认端口（实为 %s）"
			% LaunchConfig.normalize_url("1.2.3.4"))
	check(LaunchConfig.normalize_url("1.2.3.4:9000") == "ws://1.2.3.4:9000",
		"自带端口就用它自己那个（实为 %s）"
			% LaunchConfig.normalize_url("1.2.3.4:9000"))
	check(LaunchConfig.normalize_url("a.com", 7000) == "ws://a.com:7000",
		"?port= 指定的端口用得上")
	# 默认端口和无头专服**同一个数**：两处各写一份的话，玩家在
	# 「自己开房」和「连别人的专服」之间换的时候要改地址，而症状是连不上
	check(EmbeddedHost.DEFAULT_PORT == 8910,
		"默认端口是 8910 —— 和 tools/pvp_server.gd 同一个数")

# ---------- T3 三种模式 ----------

func _t3_modes() -> void:
	print("\n--- T3 模式 ---")
	var solo: Dictionary = LaunchConfig.parse({})
	check(str(solo["mode"]) == LaunchConfig.MODE_SOLO,
		"什么都没指定 → 单机（绝大多数启动走这一支，不该被联网面板挡住）")

	var join: Dictionary = LaunchConfig.parse(
		{ "server": "ws://1.2.3.4:8910", "room": "abcd" })
	check(str(join["mode"]) == LaunchConfig.MODE_JOIN, "地址 + 房号 → 加入")
	check(str(join["url"]) == "ws://1.2.3.4:8910", "地址带过去了")
	check(str(join["room"]) == "ABCD",
		"房号归一化成大写 —— 链接里是小写的，两边要进同一间（实为 %s）"
			% str(join["room"]))

	var host: Dictionary = LaunchConfig.parse({ "host": "1" })
	check(str(host["mode"]) == LaunchConfig.MODE_HOST, "?host=1 → 主机模式")
	check(str(LaunchConfig.parse({ "host": "1" })["room"]) == "",
		"主机模式不写房号也行 —— 界面会现生一个")
	check(str(LaunchConfig.parse({ "h": "1", "room": "myroom" })["room"])
			== "MYROOM", "主机模式也能指定房号（短名 h 也认）")
	# host=0 要当假：有人会照「参数=值」的直觉写它来表示不要，
	# 当真处理的话链接的行为和字面意思相反
	for falsy in ["0", "false", "no"]:
		check(str(LaunchConfig.parse({ "host": falsy })["mode"])
				!= LaunchConfig.MODE_HOST,
			"host=%s 不算真 —— 字面意思是不要" % falsy)

	# 只有地址没房号：**不是 join**（进哪间是两人的约定，猜不出来），
	# 但地址要带回去填在输入框里
	var half: Dictionary = LaunchConfig.parse({ "server": "1.2.3.4" })
	check(str(half["mode"]) == LaunchConfig.MODE_SOLO, "只有地址没房号 → 不自动连")
	check(str(half["url"]) == "ws://1.2.3.4:%d" % EmbeddedHost.DEFAULT_PORT,
		"但地址还是带回去了（填进输入框，玩家补个房号就能连）")

# ---------- T4 坏房号 ----------

func _t4_bad_room() -> void:
	print("\n--- T4 坏房号 ---")
	# 房间码现在只限字母数字（不分大小写），所以「坏」只剩两种：
	# 归一化之后是空的、或者超长
	var empty: Dictionary = LaunchConfig.parse(
		{ "server": "1.2.3.4", "room": "---" })
	check(str(empty["room"]) == "",
		"全是分隔符的房号归一化成空（实为 %s）" % str(empty["room"]))
	check(str(empty["mode"]) != LaunchConfig.MODE_JOIN,
		"空房号不自动连 —— 带着一个连不上的码去连，玩家看到的是服务器报错，"
		+ "而错在链接里")
	var long := ""
	for i in Protocol.ROOM_MAX_LEN + 5:
		long += "A"
	check(str(LaunchConfig.parse({ "server": "1.2.3.4", "room": long })["room"])
			== "", "超长房号被挡在客户端 —— 服务器那道 valid_room 也会踢，"
		+ "但那要先连上再读关闭帧")
	# 反过来：以前会被挡的那些现在要放过去（需求 2）
	for code in ["lili", "room1", "ok"]:
		var r: Dictionary = LaunchConfig.parse(
			{ "server": "1.2.3.4", "room": code })
		check(str(r["mode"]) == LaunchConfig.MODE_JOIN,
			"房号 %s 现在能用 —— 原先的字母表会把它丢成空串" % code)

# ---------- T5 最短的邀请链接 ----------

func _t5_short_link() -> void:
	print("\n--- T5 短链接 ---")
	# 网页是从服务器那台机器上发出来的，那台机器十有八九也跑着专服。
	# 少了这一条，`index.html?room=ABCD` 这种最短的邀请链接连不上任何东西
	var r: Dictionary = LaunchConfig.parse({ "room": "abcd" }, "10.0.0.7")
	check(str(r["mode"]) == LaunchConfig.MODE_JOIN,
		"只带房间码 → 连发出这个网页的那台机器")
	check(str(r["url"]) == "ws://10.0.0.7:%d" % EmbeddedHost.DEFAULT_PORT,
		"地址就是页面的主机名 + 默认端口（实为 %s）" % str(r["url"]))
	# 桌面版没有「页面主机名」这回事，所以同一份参数在那边只能是单机
	check(str(LaunchConfig.parse({ "room": "abcd" })["mode"])
			== LaunchConfig.MODE_SOLO,
		"桌面版没有页面主机名 → 只有房号猜不出连谁")
	check(str(LaunchConfig.parse({ "room": "abcd", "port": "9100" },
			"10.0.0.7")["url"]) == "ws://10.0.0.7:9100",
		"短链接也能指定端口")

# ---------- T6 命令行 ----------

func _t6_flags() -> void:
	print("\n--- T6 命令行 ---")
	var f: Dictionary = LaunchConfig.parse_flags(
		["--server=ws://1.2.3.4:8910", "--room=abcd", "--host"])
	check(str(f.get("server", "")) == "ws://1.2.3.4:8910", "--server= 读出来了")
	check(str(f.get("room", "")) == "abcd", "--room= 读出来了")
	check(str(f.get("host", "")) == "1", "--host 这种没有等号的开关也认")
	check(LaunchConfig.parse_flags(["--headless", "-s", "x.gd"]).has("headless"),
		"不认得的长参数只是被读进字典，不影响解析（parse 只挑它认的键）")
	var cards_path := "/tmp/测试 配置/cards.json"
	var cards_equal := LaunchConfig.parse(LaunchConfig.parse_flags(["--cards-config=" + cards_path]))
	var cards_space := LaunchConfig.parse(LaunchConfig.parse_flags(["--cards-config", cards_path]))
	check(cards_equal.get("cards_config") == cards_path and cards_space.get("cards_config") == cards_path,
		"卡表参数同时支持等号和空格，中文及路径空格原样保留")
	var picked := LaunchConfig.pick_desktop_args(PackedStringArray(["--path", "/tmp/project", "--cards-config", cards_path, "--room=abcd"]))
	check(LaunchConfig.parse(LaunchConfig.parse_flags(picked)).get("cards_config") == cards_path,
		"没有 -- 分隔符时仍保留卡表路径参数")
	check(not LaunchConfig.parse({}).has("cards_config"), "无卡表启动参数时不制造覆盖")
	for args in [["--cards-config"], ["--cards-config="], ["--cards-config", "--host"]]:
		var missing := LaunchConfig.parse(LaunchConfig.parse_flags(args))
		check(missing.has("cards_config") and missing["cards_config"] == "", "空卡表参数保留显式失败语义")
	# 参数名和网页那边**同一套**：两边记两套名字的话文档要写两遍，
	# 而写两遍必有一遍过期
	for k in LaunchConfig.KEYS_SERVER + LaunchConfig.KEYS_ROOM:
		check(("--%s=" % k) != "", "参数名 %s 两边共用" % k)

# ---------- T7 同一条路 ----------

func _t7_same_path() -> void:
	print("\n--- T7 网页和桌面同一条解析 ---")
	# 需求 6 的判据：同一份参数，不管从查询串来还是从命令行来，
	# parse() 的结果必须**逐字段相同**。
	# 这两条取值路径是唯一的平台分歧，往下只有一份代码
	var from_web: Dictionary = LaunchConfig.parse(
		LaunchConfig.parse_query("?server=ws://1.2.3.4:8910&room=abcd"))
	var from_cli: Dictionary = LaunchConfig.parse(
		LaunchConfig.parse_flags(["--server=ws://1.2.3.4:8910", "--room=abcd"]))
	for k in ["mode", "url", "room", "port"]:
		check(str(from_web[k]) == str(from_cli[k]),
			"网页和命令行解析出同一个 %s（%s / %s）"
				% [k, str(from_web[k]), str(from_cli[k])])
	# 无头跑测试时 current() 必须是单机 —— 不是的话每个测试进程都会试着连网
	var cur: Dictionary = LaunchConfig.current()
	check(str(cur["mode"]) == LaunchConfig.MODE_SOLO,
		"测试进程自己的启动配置是单机（实为 %s）" % str(cur["mode"]))
	check(LaunchConfig.can_host(),
		"桌面版能开房 —— 网页版这一项为假，界面据此少画一个按钮")
	# 网页那两个读取函数在非网页环境下要**安静地返回空**，不能报错：
	# 它们走 Engine.get_singleton 而不是直接写 JavaScriptBridge 的名字，
	# 后者在桌面版上是编译期报错（整个脚本解析失败 → 一启动就黑屏）
	check(LaunchConfig.web_query() == "", "非网页环境下读查询串返回空，不报错")
	check(LaunchConfig.web_page_host() == "", "非网页环境下读页面主机名返回空")

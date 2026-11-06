# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	print("=== 启动参数测试 ===")
	_t2_url_normalize()
	_t3_modes()
	_t4_bad_room()
	_t6_flags()
	check(LaunchConfig.current()["mode"] == LaunchConfig.MODE_SOLO, "无启动参数时进入单机")
	finish()

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

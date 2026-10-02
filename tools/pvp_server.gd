# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 本地专用服务器的入口；启动命令见 README.md §「4.4 联机专服」。
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless -s tools/pvp_server.gd --port=8910
##   参数：--port=8910  --seed=12345（固定牌序，调试用）  --verbose-net
##
## 这个文件只做两件事：读命令行、每帧 poll。
## 服务器逻辑全在 net/server.gd —— 拆出去的理由写在那个文件头：
## 一个测试自己就是 SceneTree，装不下第二个，于是真开端口的判据没法写。
## 现在 tests/test_net_socket.gd 在同一个进程里起 NetServer + 两个 NetTransport

## 端口的默认值和游戏内自开房用的是**同一个数**（net/embedded_host.gd）：
## 玩家在两种形态之间换（连别人的专服 / 自己开房）时填的地址不该变
const DEFAULT_PORT := EmbeddedHost.DEFAULT_PORT

## 服务器的壳也和游戏内自开房共用一份（NetServer + 端口顺延 + 报地址）。
## 这个文件剩下的活只有「读命令行」和「每帧 poll」
var _host: EmbeddedHost

## 认得的参数前缀。**两条命令行都扫**，见 _args 的说明
const FLAG_PORT := "--port="
const FLAG_SEED := "--seed="
const FLAG_VERBOSE := "--verbose-net"

## 本脚本的参数，**不管有没有写 `--` 分隔符都能读到**。
##
## get_cmdline_user_args() 只返回 `--` **之后**的东西。少写那个分隔符时它是空的，
## 于是 --port= 被静默忽略、服务器照默认端口开 —— 报错信息里那句
## 「换 --port= 试试」按字面照做**不起作用**，这个坑踩过一次。
##
## 所以拿不到 user_args 时退回整条命令行，只挑认得的那三个前缀：
## 全盘接受会把 Godot 自己的开关（--headless、-s、脚本路径）也读进来
func _args() -> PackedStringArray:
	var user := OS.get_cmdline_user_args()
	if not user.is_empty():
		return user
	var picked := PackedStringArray()
	for a in OS.get_cmdline_args():
		if a.begins_with(FLAG_PORT) or a.begins_with(FLAG_SEED) or a == FLAG_VERBOSE:
			picked.append(a)
	return picked

func _initialize() -> void:
	var port := DEFAULT_PORT
	var fixed_seed := 0
	var verbose := false
	for a in _args():
		if a.begins_with(FLAG_PORT):
			port = int(a.split("=")[1])
		elif a.begins_with(FLAG_SEED):
			fixed_seed = int(a.split("=")[1])
		elif a == FLAG_VERBOSE:
			verbose = true

	_host = EmbeddedHost.new(fixed_seed, verbose)
	# tries = 1：**不顺延**。写了 --port= 的人要把那个端口告诉对面，
	# 悄悄换一个的话对面照着填连不上，而服务器日志显示一切正常
	var r: Dictionary = _host.start(port, 1)
	if not r["ok"]:
		printerr("%s（换 --port=<别的端口> 试试）" % r["reason"])
		quit(1)
		return
	print("牛马牌 专服已启动 —— 端口 %d，协议 v%d，卡表 %s" % [
		port, Protocol.VERSION, _host.server.table_hash().substr(0, 8)])
	_print_urls(port)
	print("客户端填房间码就能进；房间不存在就现开一个")
	if fixed_seed != 0:
		print("固定牌序 seed=%d" % fixed_seed)

## 把客户端该填的地址打出来，**照抄就能用**。
##
## 分两类是因为适用范围不同，而填错的症状都是「服务器没让我入座」：
## 本机那行只在同一台机器上有效，局域网那些是给另一台机器填的。
## 地址从 EmbeddedHost 来 —— 游戏内自开房报的是同一套（那边界面上也要显示），
## 两处各算一份的话「哪些网卡该报出来」会分叉
func _print_urls(port: int) -> void:
	print("  本机双开填：ws://127.0.0.1:%d" % port)
	for u in EmbeddedHost.lan_urls(port):
		print("  同局域网另一台机器填：%s" % u)
	# 网页版直接把地址塞进链接里就能进（README.md §「4.4 联机专服」）——
	# 打出来省得玩家自己拼参数
	print("  网页版可以直接开：index.html?server=ws://127.0.0.1:%d&room=<房间码>" % port)

## SceneTree 的每帧回调。返回 true 会退出主循环
func _process(_dt: float) -> bool:
	_host.poll()
	return false

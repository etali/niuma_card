# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name EmbeddedHost
extends RefCounted

## 游戏进程内的专服；独立启动方式见 README.md §「4.4 联机专服」。
##
## 为什么它能存在：NetServer 是 RefCounted（见那个文件头），
## 「开端口 + 每帧 poll」而已 —— 谁来 poll 都行。
## 于是桌面版可以在自己进程里起一个服务器，再用一条 ws://127.0.0.1 连回来。
## 这一层**没有第二套逻辑**：主机侧和客户端侧走的是同一条 NetTransport → net/server.gd
## → net/room.gd → engine/ 的路，权威照旧在服务器手里。
##
## 它替掉的是「先开一个无头专服进程，再开游戏，再填地址」这三步 ——
## 那三步以前由一个 shell 脚本代劳（本地双人对战.command），
## 而脚本里那个端口和客户端默认地址是**两份写死的数**：脚本顺延端口时
## 客户端不跟着改，症状是「服务器开着，游戏说连不上」。
## 现在端口由这一层决定，地址由它**报出来**给界面用 —— 一份数。
##
## Web 版**用不到这个类**：浏览器开不了监听端口（net/embedded_host.gd 的平台限制），
## 网页那一侧只能当客户端。逻辑同一份、入口按平台少一个按钮，
## 而不是两份代码（scenes/join_panel.gd 里那句 can_host）

## 默认端口。和 tools/pvp_server.gd 的 DEFAULT_PORT 是同一个数 ——
## 玩家在两种形态之间换（自己开房 / 连别人的专服）时填的地址不用变
const DEFAULT_PORT := 8910

## 端口被占就往上顺延几次。
##
## 顺延这件事以前在 shell 脚本里做，而**脚本改不了客户端那个写死的地址** ——
## 于是顺延成功反而更糟：服务器在 8911 上开着，游戏还在敲 8910。
## 放到这里就没这个问题：url() 报的是真开成的那个端口
const PORT_TRIES := 12

var server: NetServer = null
var port := 0

var _seed := 0
var _verbose := false

func _init(seed_value := 0, verbose_net := false) -> void:
	_seed = seed_value
	_verbose = verbose_net

## 开端口。返回 { ok: true, port } 或 { ok: false, code, reason }。
##
## tries = 1 表示「就这个端口，占了就报错」—— 无头专服显式写了 --port= 时走这一支
## （顺延会让人以为自己指定的端口生效了，而对面照着填连不上）
func start(listen_port := DEFAULT_PORT, tries := PORT_TRIES) -> Dictionary:
	stop()
	var last: Dictionary = {}
	for i in maxi(tries, 1):
		var s := NetServer.new(_seed, _verbose)
		var r: Dictionary = s.start(listen_port + i)
		if r["ok"]:
			server = s
			port = int(r["port"])
			return { "ok": true, "port": port }
		last = r
	if tries <= 1:
		return last
	return Protocol.err("listen_failed", "%d..%d 都开不了端口" % [
		listen_port, listen_port + tries - 1])

## 主机易位时开房：**先试默认端口，占了才退到随机**（见本文件 start_takeover）。
##
## 为什么默认端口优先 —— 因为随机端口那一版有个**没人念得出来的地址**的毛病：
## 主机那个进程走了之后，回来的那位手里只有房间码，端口号只长在
## 接管方的屏幕上。他要么打电话问，要么连不上（用户原话：
## 「输入相同的密码还是连不上」）。而默认端口是**两边都已经知道的那个数** ——
## 面板默认地址就是它（JoinPanel.DEFAULT_URL）：
##   同机双开 —— 原主机进程真的没了，8910 就空着，回来那位地址一栏
##               什么都不用改，填原来那个房间码就进来了
##   两台机器 —— 他要换的只有 IP 那一段，端口和房间码都是老样子
##
## 那么原先避开默认端口的理由呢：对面那个进程可能**没退、只是网络断了**，
## 还占着 8910。这条理由没消失，只是降级成了「退路」而不是「先手」：
## 8910 真被占着的时候 start 会失败（tries=1，不顺延 —— 顺延出来的 8911
## 又变成一个念不出来的数），这时才挑随机端口，而那种情形下地址反正得念，
## 挂在牌子上（main._show_foe_offline_notice）
##
## 只试**一次**默认端口而不是顺延一段：顺延成功比失败更糟 ——
## 8911 既不是那个「两边都知道的数」，也不像随机端口那样一眼看出「得问」，
## 玩家会照着默认地址填 8910，撞在对面那个半死的房上
func start_takeover() -> Dictionary:
	var r := start(DEFAULT_PORT, 1)
	if r["ok"]:
		return r
	return start_random()

## 随机端口那一档的范围。**避开 DEFAULT_PORT 那一段**（8910 + PORT_TRIES）：
## 走到这一档说明默认端口开不了，而开不了的头号原因就是对面那个刚死的进程
## 还占着它（他只是掉线了不是退了）。从 8910 往上顺延的话，
## 最糟的情况是**顺回到那个半死的房上** —— 同一个端口号、不同的进程
const RANDOM_PORT_LO := 21000
const RANDOM_PORT_HI := 60000

## 随便找个能用的端口开（用户那句「端口随机一个可用的」）。
##
## 为什么是「随机一个起点 + 顺延」而不是「问系统要 0 号端口」：
## Godot 的 WebSocketMultiplayerPeer.create_server 收 0 会真的开在随机端口上，
## 但**报不出开在哪** —— port 字段留着的是我们传进去的 0，
## 而这个端口号是要念给对手听的（url() / lan_urls() 全靠它）。
## 所以自己挑：挑中的那个开成了就知道是几号
func start_random() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var lo := rng.randi_range(RANDOM_PORT_LO, RANDOM_PORT_HI - PORT_TRIES)
	return start(lo, PORT_TRIES)

func running() -> bool:
	return server != null

## 每帧调一次 —— WebSocketMultiplayerPeer 是轮询式的（见 NetServer.poll）。
## 桌面版由 scenes/main.gd 的 _process 调，无头专服由 SceneTree 调
func poll() -> void:
	if server != null:
		server.poll()

func stop() -> void:
	if server != null:
		server.stop()
		server = null
	port = 0

## 自己连自己填的地址。回环写死，不从网卡里找 ——
## 回环不受网卡状态影响，而「同机双开」是最常走的一条路
func url() -> String:
	return "ws://127.0.0.1:%d" % port

## 给对手报的地址们。**可能是空的**（没连网），也可能是好几个
## （Wi-Fi + 有线 + 虚拟机网卡），所以全给出去让人挑。
##
## 从 tools/pvp_server.gd 搬过来的（那边现在调这里）：两处各写一份的话，
## 「哪些地址该报给对面」这件事会在无头专服和自开房之间分叉
static func lan_urls(p: int) -> Array[String]:
	var out: Array[String] = []
	for ip in lan_ips():
		out.append("ws://%s:%d" % [ip, p])
	return out

## 本机在局域网里的 IPv4，优先物理网卡，VPN / 虚拟网卡留作备选。
## 系统枚举可能先返回 utun：直接取首项会把仅 VPN 可达的地址报给同一 Wi-Fi
## 的对手。依据网卡信息排序，不按 10.* / 192.168.* 猜测真实局域网。
## 参数用于覆盖多网卡顺序；生产侧直接读取 Godot 的网卡枚举。
static func lan_ips(interfaces: Array = IP.get_local_interfaces()) -> Array[String]:
	var local: Array[String] = []
	var virtual: Array[String] = []
	for interface in interfaces:
		var target := virtual if _is_virtual_interface(interface) else local
		for address in interface.get("addresses", []):
			var ip := str(address)
			if not ip.is_valid_ip_address() or ip.contains(":") \
				or ip.begins_with("127.") or ip.begins_with("169.254."):
				continue
			if not target.has(ip):
				target.append(ip)
	for ip in virtual:
		if not local.has(ip):
			local.append(ip)
	return local

static func _is_virtual_interface(interface: Dictionary) -> bool:
	var name := str(interface.get("name", "")).to_lower()
	var friendly := str(interface.get("friendly", "")).to_lower()
	for prefix in ["utun", "tun", "tap", "ppp", "ipsec", "wg", "tailscale",
		"zt", "docker", "veth", "virbr", "vmnet", "vboxnet"]:
		if name.begins_with(prefix) or friendly.begins_with(prefix):
			return true
	for marker in ["vpn", "virtual", "vmware", "virtualbox", "hyper-v", "vethernet",
		"wireguard", "tailscale", "zerotier", "tunnel"]:
		if name.contains(marker) or friendly.contains(marker):
			return true
	return false

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name JoinPanel
extends CanvasLayer

const UI_FONT_BODY := 17
const UI_FONT_TITLE := 22
const UI_BUTTON_MIN := Vector2(132, 44)
const UI_RADIUS := 10

func _style(fill: Color, margin := 10, border := 2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = Palette.get_color("card", "frame")
	style.set_border_width_all(border)
	style.set_corner_radius_all(UI_RADIUS)
	style.set_content_margin_all(margin)
	return style

## 联网对战的入口界面（房间码校验见 net/protocol.gd 的 valid_room）
##
## 为什么这个文件必须存在：在它之前，联网这条路**在成品里根本走不到** ——
## NetTransport / NetRoom / NetServer 全都写好了、测试全绿，
## 而没有任何一处生产代码调 attach_net。也就是说「联网功能」当时的实际状态是
## 「测试里能跑，玩家点不到」。这是 共享执行路径缺少场景接线时最难发现的一种分叉：
## 每个零件都对，只是没接上，而测试恰好把每个零件都单独接过一次。
##
## 三件事，一件都不能省：
##   1. 填服务器地址 + 房间码 → 连上去（房间不存在就现开一个，见 net/server.gd）
##   2. 等双方到齐发牌 —— 单人入座继续保留当前 AI 对局，取消后仍可继续
##   3. **把拒连的理由说出来**。这一条最容易被当成锦上添花：
##      版本不符 / 卡表不一致 / 房间满了，三种拒连在关闭帧里各有各的原因
##      （Protocol.CLOSE_CODES），不显示的话玩家看到的都是同一句「连不上」——
##      而这三种要做的事完全不同（换版本 / 同步 cards.json / 换房间码）

## 默认地址。填的是「本机自己开的那个服务器」——
## 端口从 EmbeddedHost 取，不写死一个数：以前这里是 `ws://127.0.0.1:8910` 常量，
## 而开服务器那一侧（当时是个 shell 脚本）端口被占会顺延到 8911，
## 这个常量不跟着变 —— 症状是「服务器开着，游戏说连不上」。
## 现在服务器由游戏自己开（见 _on_host），地址由它**报**出来
const DEFAULT_URL := "ws://127.0.0.1:%d" % EmbeddedHost.DEFAULT_PORT

## 连上之后多久还没 seated 就认为不对（对手还没进来不算 —— 那是正常等待，
## 服务器会先发 seated 再等人满）。取值比 NetTransport.TIMEOUT_SEC 宽一点：
## 那个是「一次往返」，这个是「握手 + 入座」
const SEAT_TIMEOUT_SEC := 10.0

## 输入框里预填的地址。**优先真实局域网地址**，回环只作兜底。
##
## 预填 127.0.0.1 的话，两台机器那一侧照着默认值按下去连的是自己 ——
## 而这个数是猜得出来的：EmbeddedHost.lan_ips() 就在报它，
## 底下那句分享提示（_share_hint）一直用的就是这个。
## 没插网线 / 只有回环时 lan_ips() 返回空，那时候预填回环是对的：
## 同机双开确实只能连回环。
##
## 地址表**从参数进来**（默认现取），为的是让空表那一支判得到：
## 开发机上 lan_ips() 从来不空，那一支平时一次都跑不到 ——
## 变异掉它整套测试全绿（实测「退出码 0、失败 0 条」）
static func default_url(ips: Array[String] = EmbeddedHost.lan_ips()) -> String:
	if ips.is_empty():
		return DEFAULT_URL
	return "ws://%s:%d" % [ips[0], EmbeddedHost.DEFAULT_PORT]


## 双方已发牌且可以切换了。参数就是那条连接，由 main.begin_net_game 接管。
signal joined(net: NetTransport)

var _main: Node = null
## 这一次打开面板只是来看/抄地址的（打开时这一局还活着，见 bind）。
## 两颗连接按钮禁掉、桌面不锁 —— 理由分别在 _ready 和 bind 里
var _read_only := false
var _net: NetTransport = null
var _url_edit: LineEdit
var _room_edit: LineEdit
var _btn: Button
var _host_btn: Button = null       ## 网页版没有这一个（浏览器开不了监听端口）
var _status: Label
## 「对手该填我这边哪个地址」那一块（标题 + 只读输入框 + 复制）。
##
## 为什么非要有这么一块：这个地址原先**只出现在两个抄不走的地方** ——
## _status 那句话（Label，选不中）和 stdout（成品里没有终端）。
## 而它恰恰是要念给另一台机器的人听、或者粘到聊天窗口里发过去的东西。
## 断线接管之后更要紧：那时候地址**变了**（端口可能顺延，见
## EmbeddedHost.start_takeover），玩家手上那个老地址已经不对，
## 而新的那个只在一条 2 秒后淡出的提示里闪过（用户原话
## 「断网后提示对方连接的IP和端口要在『局域网对战』tab中可见，并且，可以选中复制」）
var _share_row: VBoxContainer
var _share_label: Label
var _share_edit: LineEdit
var _share_copy: Button
var _waiting := false
var _wait_t := 0.0
## 这一次是「自己开房」还是「连别人的」。决定提示语和分享地址 ——
## 连接本身两条路完全一样（都是一条 NetTransport 连一个 ws:// 地址）
var _hosting := false
## 只收掉本次等待新开的服务器；查看已有房间或重连不拥有它。
var _owned_host: EmbeddedHost = null
var _panel: PanelContainer
var _body: VBoxContainer
var _title: Label
var _intro: Label
var _form: VBoxContainer
var _cancel_btn: Button
var _url_copy: Button
var _room_copy: Button
var _address_menu: MenuButton
var _available_addresses: Array[String] = []

func _init() -> void:
	layer = 20      # 压在终局面板（layer 10）之上：连上之后要盖住上一局的残留

## 联机设置是非模态工具面板：查看地址/房间码时继续操作牌桌。
## 双方发牌前只持有候选连接，不换主场景的 state / pipe / 录像 / 牌桌。
func bind(main_node: Node) -> void:
	_main = main_node
	_read_only = _main != null and _main.has_method("net_live") and bool(_main.net_live())

func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.custom_minimum_size = Vector2(560, 360)
	_panel.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), 18))
	center.add_child(_panel)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 16)
	_panel.add_child(_body)
	_title = _label("局域网对战", 34, Color(1.0, 0.85, 0.4))
	_title.set_meta("drawer_font_base", 21)
	_body.add_child(_title)
	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 12)
	_body.add_child(_form)

	# 输入、等待与失败复用同一套控件；两行提示预留空间，不随文案重排外框。
	_intro = _fixed_notice(_form)
	_set_intro(false)
	_form.add_child(_label("连接地址（IP 与端口）", 18, Color(0.85, 0.85, 0.9)))
	var url_row := HBoxContainer.new()
	url_row.add_theme_constant_override("separation", 8)
	_form.add_child(url_row)
	_url_edit = _edit(default_url())
	_url_edit.custom_minimum_size = Vector2(320, 42)
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(_url_edit)
	# 地址切换入口也预先占位，多网卡时原位选择，不再新增地址行撑大弹窗。
	_address_menu = _button("▾", Callable(), true) as MenuButton
	_address_menu.custom_minimum_size = Vector2(32, 42)
	_address_menu.tooltip_text = "选择本机其他连接地址"
	_address_menu.disabled = true
	_address_menu.get_popup().id_pressed.connect(_select_address)
	url_row.add_child(_address_menu)
	_url_copy = _copy_button(_url_edit)
	url_row.add_child(_url_copy)

	_form.add_child(_label("房间码", 18, Color(0.85, 0.85, 0.9)))
	var room_row := HBoxContainer.new()
	room_row.add_theme_constant_override("separation", 8)
	_form.add_child(room_row)
	_room_edit = _edit("")
	_room_edit.custom_minimum_size = Vector2(320, 42)
	_room_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_edit.placeholder_text = "比如 %s，或者自己起一个" % _sample_room()
	room_row.add_child(_room_edit)
	_room_copy = _copy_button(_room_edit)
	room_row.add_child(_room_copy)

	_status = _fixed_notice(_form)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	_form.add_child(row)
	if LaunchConfig.can_host():
		_host_btn = _button("等待对局", _on_host)
		_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(_host_btn)
	_btn = _button("加入对局", _on_connect)
	_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_btn)
	_cancel_btn = _button("关掉" if _read_only else "单机继续", _on_cancel)
	_cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_cancel_btn)
	if _read_only:
		_btn.disabled = true
		_btn.tooltip_text = "这一局还在打 —— 要换对手先退出房间"
		if _host_btn:
			_host_btn.disabled = true
			_host_btn.tooltip_text = _btn.tooltip_text

	# 已有联网局的重连地址仍可查看；普通开房直接更新上方地址，不另插一块内容。
	_share_row = VBoxContainer.new()
	_share_row.add_theme_constant_override("separation", 4)
	_share_row.hide()
	_body.add_child(_share_row)
	_share_label = _label("", 18, Color(0.75, 0.95, 0.8))
	_share_row.add_child(_share_label)
	var share_line := HBoxContainer.new()
	share_line.add_theme_constant_override("separation", 8)
	_share_row.add_child(share_line)
	_share_edit = _edit("")
	_share_edit.editable = false
	_share_edit.selecting_enabled = true
	_share_edit.shortcut_keys_enabled = true
	_share_edit.caret_blink = false
	_share_edit.custom_minimum_size = Vector2(300, 42)
	_share_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_share_edit.tooltip_text = "把这一行念给对手 —— 选中可复制"
	share_line.add_child(_share_edit)
	_share_copy = _button("复制", _on_copy_share)
	_share_copy.custom_minimum_size = Vector2(112, 42)
	share_line.add_child(_share_copy)

func _fixed_notice(parent: VBoxContainer) -> Label:
	var label := _label("", UI_FONT_BODY, Palette.get_color("card", "body"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = 2
	label.clip_text = true
	label.custom_minimum_size = Vector2(460, 56)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(label)
	return label

func _copy_button(edit: LineEdit) -> Button:
	var copy := _button("复制", func(): DisplayServer.clipboard_set(edit.text))
	# 回执「已复制 ✓」也在这份宽度里，不能推挤旁边的输入框。
	copy.custom_minimum_size = Vector2(112, 42)
	copy.pressed.connect(func(): copy.text = "已复制 ✓")
	edit.text_changed.connect(func(_value: String): copy.text = "复制")
	return copy

func _set_intro(waiting: bool) -> void:
	if waiting:
		_intro.text = "等待对手加入同一房间。\n取消后继续当前对局。"
	else:
		_intro.text = "等待对局：把地址和房间码发给对手。\n加入对局：填写对方提供的地址和房间码。" if LaunchConfig.can_host() \
			else "填写对方提供的地址和房间码。\n网页版只能加入对局。"

func _select_address(index: int) -> void:
	if index >= 0 and index < _available_addresses.size():
		_url_edit.text = _available_addresses[index]
		_url_copy.text = "复制"

func _show_waiting(url: String, room: String) -> void:
	_set_intro(true)
	_available_addresses.clear()
	if _hosting:
		_available_addresses = EmbeddedHost.lan_urls(_main.local_host_port())
	if _available_addresses.is_empty():
		_available_addresses.append(url)
	_url_edit.text = _available_addresses[0]
	_room_edit.text = room
	_url_edit.editable = false
	_room_edit.editable = false
	var popup := _address_menu.get_popup()
	popup.clear()
	for index in _available_addresses.size():
		popup.add_item(_available_addresses[index], index)
	_address_menu.disabled = _available_addresses.size() < 2
	_url_copy.text = "复制"
	_room_copy.text = "复制"
	_cancel_btn.text = "取消"
	if _hosting:
		_host_btn.text = "等待中…"
	else:
		_btn.text = "连接中…"
	_refresh_theme()

func _show_form() -> void:
	_set_intro(false)
	_url_edit.editable = true
	_room_edit.editable = true
	_address_menu.disabled = true
	_cancel_btn.text = "关掉" if _read_only else "单机继续"
	_btn.text = "加入对局"
	if _host_btn:
		_host_btn.text = "等待对局"
	_refresh_theme()

func _refresh_theme() -> void:
	if _main != null and _main.drawer_presentation != null:
		_main.drawer_presentation._theme_external_panel(self)

func has_pending_connection() -> bool:
	return _waiting and _net != null and not is_queued_for_deletion()

func _button(text: String, cb: Callable, menu := false) -> Button:
	var b: Button = MenuButton.new() if menu else Button.new()
	b.text = text
	b.add_theme_font_override("font", Fonts.zh_bold())
	b.add_theme_font_size_override("font_size", UI_FONT_BODY)
	b.add_theme_color_override("font_color", Palette.semantic("ink", Palette.get_color("card", "body")))
	b.add_theme_color_override("font_hover_color", Palette.semantic("ink", Palette.get_color("card", "body")))
	b.add_theme_color_override("font_pressed_color", Palette.semantic("ink", Palette.get_color("card", "body")))
	b.add_theme_stylebox_override("normal", _style(Palette.get_color("world", "table_frame"), 9))
	b.add_theme_stylebox_override("hover", _style(Palette.plate_color("plate_cash", "face"), 9))
	b.add_theme_stylebox_override("pressed", _style(Palette.plate_color("plate_cash", "band"), 9))
	b.add_theme_stylebox_override("focus", _style(Palette.plate_color("plate_cash", "face"), 9))
	b.custom_minimum_size = UI_BUTTON_MIN
	if cb.is_valid():
		b.pressed.connect(cb)
	return b

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Fonts.zh_bold())
	var actual := UI_FONT_TITLE if size >= 30 else UI_FONT_BODY
	l.add_theme_font_size_override("font_size", actual)
	l.add_theme_color_override("font_color", Palette.get_color("card", "body") if size < 30 else Palette.plate_color("plate_cash", "ink"))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _edit(text: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.add_theme_font_override("font", Fonts.zh_bold())
	e.add_theme_font_size_override("font_size", UI_FONT_BODY)
	e.add_theme_color_override("font_color", Palette.semantic("ink", Palette.get_color("card", "body")))
	e.add_theme_stylebox_override("normal", _style(Palette.get_color("world", "background"), 9, 1))
	e.add_theme_stylebox_override("focus", _style(Palette.plate_color("plate_cash", "face"), 9, 2))
	e.custom_minimum_size = Vector2(420, 42)
	return e

# ---------- 开房间（本机当服务器）----------

## 在**这个进程里**起一个服务器，然后照常连自己（使用 net/embedded_host.gd）。
##
## 「开房间」和「加入房间」在连接那一步是同一条路 —— 都是一条 NetTransport
## 连一个 ws:// 地址、走同一个 net/server.gd。差别只有「那个服务器是谁开的」。
## 所以这里不是第二条实现，是 _connect 前面多一步 start_local_host。
##
## 服务器的所有权在 main 手里（它每帧要 poll，见 main._process）——
## 这个面板在正式开局后就 queue_free 了，服务器不能跟着一起没
## `want_port > 0`：`--host --port=N` 指定了端口。它一路传到 EmbeddedHost，
## 并且**关掉顺延** —— 指定端口的意思就是「对手会照这个数来连」
## （启动脚本开多份时第二份就是这么找到第一份的），换个地方开等于连不上
func _on_host(want_port := 0) -> void:
	if _waiting or _read_only or is_queued_for_deletion():
		return
	if _main == null or not _main.has_method("start_local_host"):
		_say("这个版本开不了房间 —— 请让对手按「等待对局」，你填他的地址",
			Color(1.0, 0.6, 0.5))
		return
	# 房间码没填就现生一个：自己开房时房号是**给对面报**的，
	# 逼玩家先想一个只是多一步（而且想出来的多半是 "1234" 这种撞号的）
	var room := Protocol.normalize_room(_room_edit.text)
	if room == "":
		room = _sample_room(true)
		_room_edit.text = room
	if not Protocol.valid_room(room):
		_say(Protocol.room_rule_text(), Color(1.0, 0.6, 0.5))
		return
	var previous_host: EmbeddedHost = _main._host
	var r: Dictionary = _main.start_local_host(want_port)
	if not r["ok"]:
		_mascot("danger")
		_say(str(r["reason"]), Color(1.0, 0.5, 0.45))
		return
	if _main._host != previous_host:
		_owned_host = _main._host
	_url_edit.text = str(r["url"])
	_hosting = true
	_connect(str(r["url"]), room)

# ---------- 加入房间 ----------

func _on_connect() -> void:
	if _waiting or _read_only or is_queued_for_deletion():
		return
	var room := _room_edit.text.strip_edges()
	if room == "":
		_say("房间码不能空 —— 两边要填同一个才会进同一局", Color(1.0, 0.6, 0.5))
		return
	# **在本地判一次**，别让服务器代劳。服务器那道 valid_room 会踢，
	# 但那要先连上、握手、再读关闭帧 —— 对一个明显填错的房号来说，
	# 那条路上任何一环出问题（专服没开、端口不对）都会显示成另一句话，
	# 玩家于是去查网络，而错在输入框里。
	# 判的是**归一化之后**的：大小写和分隔符本来就该收下（normalize 会处理）
	room = Protocol.normalize_room(room)
	if not Protocol.valid_room(room):
		_say(Protocol.room_rule_text(), Color(1.0, 0.6, 0.5))
		return
	# 地址也过一遍归一化：玩家（和邀请链接）会只写 `192.168.1.7`，
	# 补不上 ws:// 和端口的话 connect_to_url 直接失败，而报的是「连不上」
	var typed := LaunchConfig.normalize_url(_url_edit.text)
	if typed == "":
		_say("服务器地址不能空 —— 填对手报出来的那个 ws:// 地址", Color(1.0, 0.6, 0.5))
		return
	_url_edit.text = typed
	# **别让他连上自己那间房**。这一条只在「我原来是主机、网断了、回来重连」
	# 那条路上出现，而它是用户报的那半个坑里最难看的一种：
	#
	# 主机那一侧的连接走的是**回环**，网断了它照样活着，我自己那个服务器
	# 也照样在进程里跑着。于是玩家照旧填自己那个老地址 —— 连上了、坐下了
	# （令牌还在，seat_for_token 认得他），然后 main._on_net_joined 里那句
	# _clear_old_session_for_reconnect 把 stop_local_host 跑了，
	# 也就是**把他刚连上的那个服务器关掉**。屏幕上是「连上了又断了」，
	# 一条错都没有 —— 而他会说「密码是对的啊」。
	#
	# 判在这儿而不是等连上：和上面那条判房间码同一个道理，
	# 明显填错的东西不该走一趟网络再回来报一句意思不同的话
	if _is_my_own_host(typed):
		_say("这是**你自己**那间房的地址 —— 对手不在里面。\n"
			+ "他那间房在他自己那台机器上，去问他屏幕上报的那一行地址",
			Color(1.0, 0.6, 0.5))
		return
	_connect(typed, room)

## 这个地址指的是不是我自己正开着的那个服务器。
##
## 两个条件**都要**成立：端口撞上，而且主机名指的是本机。
##
## 光比端口不行 —— 接管开的是**默认端口**（EmbeddedHost.start_takeover），
## 于是「我开着 8910」和「对手也开着 8910」是常态而不是巧合：
## 只比端口的话对手报来的 `ws://192.168.1.9:8910` 会被当成我自己那间房拦掉，
## 而那正是他唯一能连的地址 —— 拦错的代价比漏拦更大。
## （端口随机那一版没这个问题，纯属两个随机数不会撞；改成默认端口就现形了）
##
## 主机名那一栏也不能只认字符串「127.0.0.1」：玩家可能写 localhost、
## 也可能写自己那台机器的局域网 IP，三种都通到同一个进程
func _is_my_own_host(url: String) -> bool:
	if _main == null or not _main.has_method("local_host_port"):
		return false
	var mine: int = _main.local_host_port()
	if mine <= 0:
		return false
	return _port_of(url) == mine and _is_local_host_name(_host_of(url))

## 这个主机名指的是不是本机。三类都算：回环写法、localhost、
## 以及本机自己那些局域网 IP（EmbeddedHost.lan_ips —— 报给对手的就是这些，
## 玩家很可能把自己那一行抄回到自己的输入框里）
func _is_local_host_name(host: String) -> bool:
	if host == "":
		return false
	if host == "localhost" or host.begins_with("127."):
		return true
	return host in EmbeddedHost.lan_ips()

## 从 ws:// 地址里抠主机名（不含端口），抠不出来返回 ""。
##
## 手写而不用 URL 解析：Godot 没有现成的 ws:// 解析器，而这里要认的形状很窄 ——
## `ws://主机:端口` 后面可能跟一个路径。IPv6 那种 `ws://[::1]:8910`
## 不在这条路上（lan_ips 把带冒号的全滤掉了，报出去的地址不会长那样）
func _host_of(url: String) -> String:
	var s := url
	var sep := s.find("://")
	if sep >= 0:
		s = s.substr(sep + 3)
	var slash := s.find("/")
	if slash >= 0:
		s = s.substr(0, slash)
	var colon := s.rfind(":")
	return s.substr(0, colon) if colon >= 0 else s

## 从 ws:// 地址里抠端口，抠不出来返回 0。
##
## **不能拿 ends_with(":端口") 顶替**：normalize_url 对已经带 ws:// 的地址
## 原样返回，于是玩家粘进来的可能是 `ws://127.0.0.1:8910/` —— 尾巴上那个斜杠
## 让字符串比法漏掉，而它指的确实是自己那间房
func _port_of(url: String) -> int:
	var colon := url.rfind(":")
	if colon < 0:
		return 0
	var digits := ""
	for i in range(colon + 1, url.length()):
		if url[i].is_valid_int():
			digits += url[i]
		else:
			break
	return int(digits) if digits != "" else 0

## 真正把连接开出去。两条入口（开房间 / 加入房间）在这里合并
func _connect(url: String, room: String) -> void:
	if _main != null and _main.has_method("prepare_network_cards"):
		var cards_result: Dictionary = _main.prepare_network_cards()
		if not cards_result.get("ok", false):
			_say(str(cards_result.get("reason", "默认 cards.json 加载失败")), Color(1.0, 0.5, 0.45))
			return
	_mascot("connecting")
	_net = NetTransport.new(url, room)
	_net.defer_scene_events()
	# 三条信号都要接。**disconnected 是这个界面存在的主要理由**：
	# 不接的话三种拒连（版本 / 卡表 / 房间满）在玩家眼里都是「按了没反应」
	_net.connected.connect(_on_seated)
	_net.disconnected.connect(_on_down)
	var r: Dictionary = _net.connect_to_server()
	if not r["ok"]:
		_mascot("danger")
		_say(str(r["reason"]), Color(1.0, 0.5, 0.45))
		_net = null
		_stop_owned_host()
		return
	_waiting = true
	_wait_t = 0.0
	_show_waiting(url, room)
	_btn.disabled = true
	if _host_btn:
		_host_btn.disabled = true
	_say("正在连接房间…", Palette.get_color("card", "body"))

## 报给对手的地址。局域网那几个优先（对手多半在另一台机器上），
## 一个都没有（没连网）就只能报回环 —— 那时只有同机双开走得通
func _share_hint() -> String:
	var urls := EmbeddedHost.lan_urls(_main.local_host_port() if _main
		and _main.has_method("local_host_port") else EmbeddedHost.DEFAULT_PORT)
	if urls.is_empty():
		return _url_edit.text + "（没找到局域网地址，只能同机双开）"
	return " 或 ".join(urls)

# ---------- 启动参数直接进 ----------

## 照 LaunchConfig 给的配置**自己动手**（需求 5）：
## 网址里带了 server/room 的话玩家不该还要点一次按钮 —— 链接的意思就是「进去」。
##
## 三种模式对应三件事，而**没有一件是新逻辑**：填输入框、按「等待对局」、按「加入对局」。
## 这一条是需求 6 的落点：网页版走的不是一条专用代码路径，
## 它就是替玩家点了那个按钮
func apply_launch(cfg: Dictionary) -> void:
	var url := str(cfg.get("url", ""))
	var room := str(cfg.get("room", ""))
	if url != "":
		_url_edit.text = url
	if room != "":
		_room_edit.text = room
	match str(cfg.get("mode", LaunchConfig.MODE_SOLO)):
		LaunchConfig.MODE_HOST:
			if LaunchConfig.can_host():
				# --port= 传下去：不传的话它在 8910 开，而启动脚本
				# 已经把那个数当成「第二份该去连的地方」报出去了
				_on_host(int(cfg.get("port", 0)))
			else:
				# 网页版被要求开房间：**说清楚做不到**，别静默退回加入模式 ——
				# 那样两边都在等对方开房，而画面上什么都不说
				_say("网页版开不了房间（浏览器不能监听端口）——\n请对手按「等待对局」，然后把地址填在上面",
					Color(1.0, 0.75, 0.4))
		LaunchConfig.MODE_JOIN:
			_on_connect()
		_:
			if url != "" and room == "":
				_say("链接里只有地址，还差房间码 —— 两边填同一个就能进同一局",
					Color(1.0, 0.85, 0.5))

## 把输入框填好并说一句话（断线之后回来重连用，见 main._offer_reconnect）。
##
## 房间码**照旧那个填**：服务器那间房还在（net/room.gd 的 drop_peer 只把座位
## 置 0，房间留着等重连），接管出来的那间房也刻意沿用同一个码
## （NetServer.adopt_room —— 用户那句「保持密码不变」）。
##
## 地址那一栏**不动**，因为断线前用的那个地址就是要重连的那个 ——
## 覆盖成默认值反而会把「对手的地址」冲掉。接管开的也是默认端口
## （EmbeddedHost.start_takeover），端口这一段本来就对得上。
## 至于建面板时预填哪个 IP，见 default_url()：那个数是猜得出来的
## `share`：本机此刻开着房的话，「对手该填哪个地址」那一行。断线接管之后
## （scenes/main.gd 的 _take_over_host）这个数**变了** —— 端口可能已经不是原来那个，
## 而玩家手上那个老地址连不上任何东西。空串表示本机没开房，那一块就不立
func prefill(room: String, hint: String, share := "") -> void:
	if room != "":
		_room_edit.text = room
	if hint != "":
		_say(hint, Color(1.0, 0.85, 0.5))
	show_share(share, room)

## 候选连接由面板轮询，正式发牌后才交给 main；等对手不算握手超时。
func _process(dt: float) -> void:
	if not has_pending_connection():
		return
	_net.poll()
	# poll 会同步触发入座、断线或交接，不能再用调用前的连接引用。
	if not has_pending_connection():
		return
	if _try_start_match():
		return
	if _net.my_seat != "":
		return
	_wait_t += dt
	if _wait_t >= SEAT_TIMEOUT_SEC:
		_mascot("danger")
		_drop_pending_connection()
		_stop_owned_host()
		_show_form()
		_say("服务器没让我入座（%.0f 秒）—— 地址和端口对吗？对面开着房间吗？"
			% SEAT_TIMEOUT_SEC, Color(1.0, 0.5, 0.45))

## 第一份 seated 可能只有空房；保留单机牌桌直到两个座位都有正式卡牌。
func _on_seated(_mine: String, _foe: String) -> void:
	if not has_pending_connection():
		return
	if not _try_start_match():
		if not _net.has_dealt_state():
			_mascot("waiting")
			if not _hosting:
				_btn.text = "等待中…"
			_say("等待对手加入…", Palette.get_color("card", "body"))

func _try_start_match() -> bool:
	if not has_pending_connection() or not _net.has_dealt_state():
		return false
	# 不把正在执行的 AI / 攻击协程接到另一局；当前动作完成后再切换。
	if _main != null and not _main.can_start_pending_net_game():
		_say("对手已就绪，完成当前行动后进入联机对局。", Palette.get_color("card", "body"))
		return false
	_waiting = false
	var net := _net
	_net = null
	_owned_host = null # 房间交给正式联网局，面板释放不再关闭它。
	if net.connected.is_connected(_on_seated):
		net.connected.disconnect(_on_seated)
	if net.disconnected.is_connected(_on_down):
		net.disconnected.disconnect(_on_down)
	joined.emit(net)
	queue_free()
	return true

## 拒连原因留在表单，可重新填写地址；当前对局从未被替换。
func _on_down(code: String, reason: String) -> void:
	_mascot("danger")
	_drop_pending_connection()
	_stop_owned_host()
	_show_form()
	_say("%s（%s）" % [reason, code], Color(1.0, 0.5, 0.45))

func _drop_pending_connection() -> void:
	_waiting = false
	var pending := _net
	_net = null
	if pending != null:
		if pending.connected.is_connected(_on_seated):
			pending.connected.disconnect(_on_seated)
		if pending.disconnected.is_connected(_on_down):
			pending.disconnected.disconnect(_on_down)
		pending.close()
	_btn.disabled = _read_only
	if _host_btn:
		_host_btn.disabled = _read_only

func _stop_owned_host() -> void:
	if _owned_host != null:
		if _main != null and _main._host == _owned_host:
			_main.stop_local_host()
		else:
			_owned_host.stop()
		show_share("")
	_owned_host = null
	_hosting = false

func _on_cancel() -> void:
	_mascot("idle")
	if is_queued_for_deletion():
		return
	_drop_pending_connection()
	_stop_owned_host()
	if _main != null and _main._join_panel == self:
		_main._join_panel = null
	queue_free()

## 把「对手该填的地址」立到面板上，选得中、复制得了。
##
## 空串 = 收起这一块（本机没开房时没有这么一个地址，
## 摆一个空框在那儿比不摆更难懂）。
##
## room 不为空时连房间码一起写进去：那两样是**一起念给对手的**，
## 分两处放的话玩家复制完地址还要回头找房号
func show_share(addr: String, room := "") -> void:
	if addr == "":
		_share_row.visible = false
		return
	_share_label.text = "对手填这个地址连你" if room == "" \
		else "对手填这个地址连你（房间码 %s）" % room
	_share_edit.text = addr
	_share_copy.text = "复制"
	_share_copy.disabled = false
	_share_row.visible = true

## 这一块此刻立着没有（测试和 main 都要问得到）
func share_visible() -> bool:
	return _share_row != null and _share_row.visible

## 面板上此刻写着的那个分享地址
func share_text() -> String:
	return _share_edit.text if _share_edit != null else ""

## 复制到系统剪贴板。改按钮文案是**回执** —— 剪贴板看不见，
## 不给回执玩家会连按几次然后怀疑按钮坏了
func _on_copy_share() -> void:
	DisplayServer.clipboard_set(_share_edit.text)
	_share_copy.text = "已复制 ✓"

## 网络状态同步到抽屉角色；面板关闭后角色不会遗留连接中。
func _mascot(value: String) -> void:
	if _main != null and _main.has_method("_set_connection_mascot_state"):
		_main._set_connection_mascot_state(value)

func _say(text: String, color: Color) -> void:
	if color.r > color.g + 0.15:
		_mascot("danger")
	_status.text = text
	_status.add_theme_color_override("font_color", Palette.get_color("card", "body") if _waiting else color)
	_status.tooltip_text = text

## 提示语里那个例子 / 现生一个房间码。
##
## **现算**而不是写死一串字母：生成用的字母表以后要是改了（见
## Protocol.ROOM_GEN_ALPHABET），写死的那个例子可能变成非法输入，
## 而它长得完全正常 —— 和原先那个「比如 1234」是同一个坑。
##
## random = false 时用固定种子：占位符每次开面板看到同一个例子，不然像是在闪。
## 真要开房时必须随机 —— 固定种子的话所有人第一次开房都用同一个房号，
## 两拨互不相识的人会撞进同一间（局域网上真会发生）
func _sample_room(random := false) -> String:
	var rng := RandomNumberGenerator.new()
	if random:
		rng.randomize()
	else:
		rng.seed = 20260826
	return Protocol.make_room_code(rng)

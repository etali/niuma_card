# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 从玩家使用的选项菜单和鼠标按钮起房，客户端连实际报出的局域网地址。
## 独立网络测试常走回环，无法发现 VPN 被误选成默认分享地址。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 局域网菜单与分享地址回归 ===")
	_check_interface_order()
	await _menu_to_lan_match()
	await _menu_to_lan_join()
	finish()

func _check_interface_order() -> void:
	var interfaces := [
		{"name": "utun4", "friendly": "utun4", "addresses": ["10.254.182.140"]},
		{"name": "lo0", "friendly": "lo0", "addresses": ["127.0.0.1", "::1"]},
		{"name": "en0", "friendly": "en0", "addresses": ["fe80::1234", "192.168.0.101"]},
		{"name": "en1", "friendly": "en1", "addresses": ["169.254.0.2"]},
	]
	var addresses := EmbeddedHost.lan_ips(interfaces)
	check(addresses == ["192.168.0.101", "10.254.182.140"],
		"系统先枚举VPN时仍先报Wi-Fi地址，VPN保留作备选")
	check(JoinPanel.default_url(addresses) == "ws://192.168.0.101:%d" % EmbeddedHost.DEFAULT_PORT,
		"面板默认填写排序后的真实局域网地址")
	check(EmbeddedHost.lan_ips([
		{"name": "wg0", "addresses": ["192.168.200.2"]},
		{"name": "eth0", "addresses": ["10.1.2.3"]},
	]) == ["10.1.2.3", "192.168.200.2"],
		"10开头的物理局域网优先于192.168开头的VPN，不靠IP前缀误判")
	check(EmbeddedHost.lan_ips([
		{"name": "adapter-a", "friendly": "vEthernet (Default Switch)", "addresses": ["172.25.1.1"]},
		{"name": "adapter-b", "friendly": "Wi-Fi", "addresses": ["192.168.1.8", "192.168.1.8"]},
	]) == ["192.168.1.8", "172.25.1.1"],
		"Windows虚拟交换机排在Wi-Fi后，重复地址只显示一次")
	check(EmbeddedHost.lan_ips([
		{"name": "tun0", "addresses": ["10.1.0.2"]},
	]) == ["10.1.0.2"], "只有VPN可用时仍保留连接地址")
	check(EmbeddedHost.lan_ips([]).is_empty(), "没有网卡时返回空表，交给面板回环兜底")

func _menu_to_lan_match() -> void:
	var main := await _boot_drawer()
	var popup: PopupMenu = main.drawer_presentation._menu.get_popup()
	var network_id := -1
	for i in popup.item_count:
		if popup.get_item_text(i) == "局域网对战":
			network_id = popup.get_item_id(i)
	if not need(network_id >= 0, "选项菜单包含可选的局域网对战入口"):
		main.queue_free()
		return
	popup.id_pressed.emit(network_id)
	await process_frame
	var panel: JoinPanel = main._join_panel
	if not need(is_instance_valid(panel) and panel.visible, "真实菜单信号打开可见联网面板"):
		main.queue_free()
		return
	for i in 4:
		await process_frame
	panel._room_edit.text = "MENU1"
	await _click(panel._host_btn)
	if not need(main._host != null and main._host.running(), "鼠标点击等待对局真正启动监听服务器"):
		panel._on_cancel()
		main.queue_free()
		return
	var host_ready := await _until(func(): return panel._net != null and panel._net.my_seat != "")
	check(host_ready, "主机通过场景每帧轮询完成真实WebSocket握手")
	var shared_url := panel._url_edit.text
	var available := EmbeddedHost.lan_urls(main.local_host_port())
	check(shared_url == (available[0] if not available.is_empty() else main._host.url()),
		"等待界面报出的地址与真实监听端口、网卡优先级一致：%s" % shared_url)
	var foe := NetTransport.new(shared_url, panel._room_edit.text.to_lower())
	foe.connect_to_server()
	var started := await _until(func():
		foe.poll()
		return main._net != null and main._net_table_drawn and foe.has_dealt_state())
	check(started, "对手按界面展示的局域网地址连入，同房间双方发牌并进入联网局")
	if started:
		check(main._net.my_seat != foe.my_seat and main._host.server.room_count() == 1,
			"菜单入口到开局使用同一房间，双方座位不同")
	foe.close()
	main._reset_session_flags()
	main.queue_free()
	await process_frame
	await process_frame

func _menu_to_lan_join() -> void:
	var main := await _boot_drawer()
	if not net_boot(48400, 42):
		main.queue_free()
		return
	var remote := net_client("MENU2")
	if not need(await net_until([remote], func(): return remote.my_seat != ""),
		"加入路径的远端主机先通过真实socket入座"):
		remote.close()
		net_stop()
		main.queue_free()
		return
	var popup: PopupMenu = main.drawer_presentation._menu.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i) == "局域网对战":
			popup.id_pressed.emit(popup.get_item_id(i))
	var panel: JoinPanel = main._join_panel
	for i in 4:
		await process_frame
	var urls := EmbeddedHost.lan_urls(int(_srv.port))
	panel._url_edit.text = urls[0] if not urls.is_empty() else remote.url
	panel._room_edit.text = remote.room
	await _click(panel._btn)
	check(panel._waiting, "鼠标点击加入对局启动候选连接，未被其他工具页遮挡")
	var started := await net_until([remote], func(): return main._net != null and main._net_table_drawn)
	check(started and main.my_seat != remote.my_seat,
		"菜单中的加入按钮连入真实LAN地址并接管当前牌桌")
	check(main._host == null, "加入对局使用对方服务器，不另外创建本机房间")
	remote.close()
	main._reset_session_flags()
	net_stop()
	main.queue_free()
	await process_frame
	await process_frame

func _boot_drawer() -> Node:
	paused = false
	root.size = Vector2i(1280, 800)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.sfx.set_muted(true)
	main.drawer_presentation.relayout()
	for i in 4:
		await process_frame
	return main

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = point
		click.pressed = pressed
		root.push_input(click)
		await process_frame

func _until(condition: Callable, ms := 5000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return condition.call()

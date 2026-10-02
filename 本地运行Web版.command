#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 牛马牌 · 本地运行浏览器版
#
#   ./本地运行Web版.command       开一个标签（单机）
#   ./本地运行Web版.command 2     起专服 + 开两个标签，**直接进同一个房间**
#                                 （试联机：网址里带 server/room，打开就在等对手）
#
# Web 版不能直接双击 index.html（浏览器安全限制），必须走本地 HTTP。
# 停止：在本窗口按 Ctrl+C 或直接关窗口
#
# 联机那一支为什么要起专服：浏览器**开不了监听端口**（见 net/embedded_host.gd 的平台限制），
# 网页那一侧只能当客户端。所以两个标签都要连一个真正在监听的东西 ——
# 要么是这里起的无头专服，要么是另一台机器上桌面版点的「开房间」。
# 网址里的参数由 net/launch_config.gd 解析，**和桌面版同一份代码**

set -eu
cd "$(dirname "$0")"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PORT=8100          # 网页
WS_PORT=8910       # 专服（和 net/embedded_host.gd 的 DEFAULT_PORT 同一个数）
ROOM=WEB1          # 两个标签约定的房间码；字母数字都行（见 net/protocol.gd）

COUNT="${1:-1}"
# 先验一眼：不是数字的话下面 `[ "$COUNT" -gt 1 ]` 会甩出一句
# `integer expression expected`，而这脚本是给双击的人用的
case "$COUNT" in
	''|*[!0-9]*)
		echo "参数得是个数字（开几个标签）：./本地运行Web版.command 2" >&2
		exit 2 ;;
esac

if [ ! -f build/web/index.html ]; then
	echo "==> 未找到 build/web/，先执行一次发布打包"
	./打包发布.command || exit 1
fi

# 端口被占用则顺延
while lsof -i ":$PORT" > /dev/null 2>&1; do
	PORT=$((PORT + 1))
done

SERVER_PID=""
HTTP_PID=""
OPENER_PID=""
cleanup() {
	local status=$?
	trap - EXIT INT TERM HUP
	for pid in "$OPENER_PID" "$HTTP_PID" "$SERVER_PID"; do
		[ -n "$pid" ] || continue
		kill "$pid" 2>/dev/null || true
	done
	# 子进程可能正在处理信号；给它短暂收尾时间，再强制回收拒绝退出的进程。
	for attempt in {1..40}; do
		local alive=0
		for pid in "$HTTP_PID" "$SERVER_PID"; do
			[ -n "$pid" ] || continue
			kill -0 "$pid" 2>/dev/null && alive=1
		done
		[ "$alive" -eq 1 ] || break
		sleep 0.05
	done
	for pid in "$OPENER_PID" "$HTTP_PID" "$SERVER_PID"; do
		[ -n "$pid" ] || continue
		kill -KILL "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

URLS=()
if [ "$COUNT" -gt 1 ]; then
	# 专服的端口**不顺延**：网址里那个 server= 参数要和它对上。
	# 顺延的话两个标签连一个没人听的端口，症状是「打开就说连不上」——
	# 所以这里先自己看一眼，占着就报出来让人处理
	if lsof -i ":$WS_PORT" > /dev/null 2>&1; then
		echo "端口 $WS_PORT 被占着（多半是上次跑剩的专服）。先关掉它：" >&2
		echo "  pkill -f pvp_server.gd" >&2
		exit 1
	fi
	echo "==> 起专服（ws://127.0.0.1:${WS_PORT}）"
	"$GODOT" --headless -s tools/pvp_server.gd --port="$WS_PORT" &
	SERVER_PID=$!
	sleep 2
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "专服启动失败。" >&2
		wait "$SERVER_PID" || exit $?
		exit 1
	fi
	# 两个标签的网址一模一样 —— 谁先打开谁先入座，第二个进来就开局。
	# 参数是 net/launch_config.gd 解析的，桌面版的 --server=/--room= 是同一套名字
	for i in 1 2; do
		URLS+=("http://localhost:$PORT/?server=ws://127.0.0.1:$WS_PORT&room=$ROOM")
	done
else
	URLS+=("http://localhost:$PORT")
fi

echo "=========================================="
echo " 牛马牌 Web 版本地运行中"
for u in "${URLS[@]}"; do
	echo " 地址：$u"
done
if [ "$COUNT" -gt 1 ]; then
	echo " 两个标签都会**直接进房间 $ROOM**，不用点任何按钮"
fi
echo " 停止：Ctrl+C"
echo "=========================================="

(
	sleep 1
	for u in "${URLS[@]}"; do
		open "$u"
		sleep 1
	done
) &
OPENER_PID=$!

cd build/web
python3 -m http.server "$PORT" &
HTTP_PID=$!
wait "$HTTP_PID"

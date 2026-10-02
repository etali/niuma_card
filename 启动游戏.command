#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 牛马牌 · 双击启动（跑**构建好的** App，不是用编辑器打开项目）
#
#   ./启动游戏.command            开一个窗口
#   ./启动游戏.command 2          开两个窗口（试联机：一边开房，一边加入）
#   ./启动游戏.command 2 --room=TEST
#                                 两个窗口都带上参数（见 net/launch_config.gd）
#   ./启动游戏.command --rebuild  先重新构建一次再开
#   ./启动游戏.command --cards-config="/绝对路径/cards.json"
#                                 本次单机试玩优先使用指定卡表
#
# 为什么跑 App 而不是 `Godot project.godot`：那条路要装着 Godot 才能玩，
# 而且跑的是**源码**——导出设置、资源导入、渲染后端上的差异全绕过去了，
# 于是「我这儿好的」和「发出去的包」是两个东西。
#
# 构建这件事**不在这个脚本里做**：它调 ./构建游戏.command（那里是唯一一份导出逻辑）。
# 抄一份 --export-release 过来的话，两处的预设名/输出路径早晚分叉，
# 而分叉的症状是「构建脚本出的包和启动脚本找的包不是同一个」

set -u
cd "$(dirname "$0")"

APP_NAME="牛马牌.app"
APP="$PWD/build/$APP_NAME"
BIN="$APP/Contents/MacOS"

COUNT=1
REBUILD=0
ROOM=""
# 剩下的参数原样透给 App（--server= / --room= / --host，见 net/launch_config.gd）
PASS=()

EXPLICIT=0        # 自己写了 --server= / --host / --port= 就别替他配对
for a in "$@"; do
	case "$a" in
		--rebuild) REBUILD=1 ;;
		# 房间码单独接住：开多份时要靠它把第一份和后面几份配起来（见下面）
		--room=*|-r=*) ROOM="${a#*=}" ;;
		--server=*|-s=*|--host|--port=*|-p=*) EXPLICIT=1; PASS+=("$a") ;;
		# 纯数字 = 开几份。挡住 --port=2 / -p=2 的**不是**这条的位置，而是
		# [0-9]* 要求首字符就是数字（'-' 不是）—— 换到最前面判也一样。
		# 这行为由 tools/check_launch_script.py 钉着（"--port=2 不算份数"）
		[0-9]*) COUNT="$a" ;;
		*) PASS+=("$a") ;;
	esac
done

# 开多份 + 给了房间码 = 「两个人进同一局」。这时**不能把同样的参数发给每一份**：
#   - 光给房间码：桌面版没有「网页那台机器」可以默认连，两份各起一局单机，
#     房间码只是填在了输入框里 —— 看着像联机没生效
#   - 都给 --host：第一份占住 8910，第二份顺延到 8911 自己开一间，
#     两个人各在自己那间房里等对方
# 所以第一份开房（端口钉死，不顺延），后面几份连它。
# 自己写了地址（要连别人的专服 / 要自己开）时**一个字都不改**：
# 那种情况下配对是错的 —— 会给他的 --server= 上面再叠一个 --host，
# 两个 --server 打架，而症状是「我明明填了地址」
PORT=8910
PAIR=0
HOST_ARGS=()
JOIN_ARGS=()
if [ -n "$ROOM" ]; then
	if [ "$EXPLICIT" = "0" ] && [ "$COUNT" -gt 1 ]; then
		PAIR=1
		HOST_ARGS=(--host "--room=$ROOM" "--port=$PORT")
		JOIN_ARGS=("--server=ws://127.0.0.1:$PORT" "--room=$ROOM")
	else
		# 只开一份、或者他自己写了地址：房间码填进去，别的不动
		HOST_ARGS=("--room=$ROOM")
		JOIN_ARGS=("--room=$ROOM")
	fi
fi

if [ "$REBUILD" = "1" ] || [ ! -d "$APP" ]; then
	if [ "$REBUILD" = "1" ]; then
		echo "==> 按要求重新构建"
	else
		# ${} 不能省：变量后面紧跟全角字符时 bash 3.2（macOS 自带那个）
		# 会把「）」的首字节吃进变量名，set -u 下直接 unbound variable ——
		# 而这一支正是「还没构建过」那条路，脚本会死在第一次用的时候
		echo "==> 还没构建过（找不到 build/${APP_NAME}），先构建一次"
	fi
	./构建游戏.command || exit 1
	echo ""
fi

if [ ! -d "$APP" ]; then
	echo "构建完了还是找不到 build/$APP_NAME —— 看上面构建那一段的报错" >&2
	exit 1
fi

echo "=========================================="
echo " 牛马牌 · 启动 $COUNT 个窗口"
if [ ${#PASS[@]} -gt 0 ]; then
	echo " 启动参数：${PASS[*]}"
fi
if [ "$PAIR" = "1" ]; then
	echo " 房间 ${ROOM}：第 1 份开房（ws://127.0.0.1:${PORT}），"
	echo " 其余 $((COUNT - 1)) 份自动连上去 —— 两边都不用点按钮"
else
	echo " 联机：一边点「开房间」（本机当服务器），把它报出来的地址和"
	echo "       房间码给另一边，另一边点「加入房间」"
fi
echo "=========================================="
echo ""

# 双击 .app 两次是**开不出第二个窗口**的：macOS 的默认行为是
# 「同一个 app 再次双击 = 激活已经在跑的那个」，看着像没反应。
# 绕开的办法是 open 的 -n（新实例）+ -a（按路径指定 app），
# 而 -a 必须给**绝对路径** —— 相对路径会被当成 app 名去 /Applications 里找。
#
# `--args` 之后的东西进 OS.get_cmdline_args()。Godot 的
# get_cmdline_user_args() 只认 `--` 之后的，所以 LaunchConfig.desktop_args()
# 两条命令行都扫（见那个函数的说明）
for i in $(seq 1 "$COUNT"); do
	# 第一份拿 HOST_ARGS，后面几份拿 JOIN_ARGS（没给房间码时两个都是空的）
	ARGS=()
	if [ "$i" = "1" ]; then
		[ ${#HOST_ARGS[@]} -gt 0 ] && ARGS+=("${HOST_ARGS[@]}")
	else
		[ ${#JOIN_ARGS[@]} -gt 0 ] && ARGS+=("${JOIN_ARGS[@]}")
	fi
	[ ${#PASS[@]} -gt 0 ] && ARGS+=("${PASS[@]}")
	if [ ${#ARGS[@]} -gt 0 ]; then
		open -na "$APP" --args "${ARGS[@]}"
	else
		open -na "$APP"
	fi
	# 隔一下再开下一个。两个原因，都实打实撞过：
	#   - 同时启动两个实例，两边的资源导入抢同一份 .godot 缓存，偶发起不来
	#   - 开房那份要先把 8910 监听起来，后面几份才连得上（连太早是「连不上」）
	[ "$i" -lt "$COUNT" ] && sleep 2
done

echo "已启动。窗口是独立进程，关掉这个终端不影响它们。"
echo "全部关掉： pkill -f '$APP_NAME/Contents/MacOS'"
# BIN 只用来打这一句提示，故意不 exec 进去 —— open 起的进程不归这个脚本管
: "$BIN"

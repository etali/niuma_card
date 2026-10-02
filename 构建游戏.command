#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 牛马牌 · 构建可运行 App（build/牛马牌.app）
# 首次使用已完成模板安装，之后每次运行本脚本即可出包
set -e
cd "$(dirname "$0")"

# 外层负责完整日志、退出码和可见失败提示；工作进程保留原有字体恢复 trap。
# 精简模式中的 exec / 编译失败也会回到外层，不会直接让终端窗口消失。
if [ "${CARD_BUILD_WORKER:-0}" != "1" ]; then
	case "${1:-}" in
		-h|--help) CARD_BUILD_WORKER=1 /bin/bash "$0" "$@"; exit $? ;;
	esac
	if ! mkdir -p build/logs; then
		echo "构建失败：无法创建日志目录 build/logs" >&2
		exit 1
	fi
	# export_presets的exclude_filter只影响导出，不能阻止编辑器扫描引擎源码。
	# 在任何Godot进程启动之前隔离build；用户清空build后也会自动重建。
	if ! touch build/.gdignore; then
		echo "构建失败：无法创建Godot导入隔离标记 build/.gdignore" >&2
		exit 1
	fi
	BUILD_LOG="build/logs/build-$(date +%Y%m%d-%H%M%S)-$$.log"
	echo "构建日志：$BUILD_LOG"
	set +e
	CARD_BUILD_WORKER=1 PYTHONUNBUFFERED=1 /bin/bash "$0" "$@" 2>&1 | python3 -u tools/project_paths.py | tee "$BUILD_LOG"
	BUILD_CODES=("${PIPESTATUS[@]}")
	set -e
	BUILD_STATUS=${BUILD_CODES[0]}
	# 部分 Godot 导入/导出错误仍返回0，最终结果必须按实际报错判定。
	if [ "$BUILD_STATUS" -eq 0 ] && grep -Eq '^(SCRIPT ERROR|ERROR):' "$BUILD_LOG"; then
		BUILD_STATUS=1
		echo "构建进程返回0，但日志含有引擎错误，按失败处理。" >&2
	fi
	# 脱敏或日志写入失败同样不能报告成功；优先保留构建的真实退出码。
	for BUILD_CODE in "${BUILD_CODES[1]}" "${BUILD_CODES[2]}"; do
		if [ "$BUILD_STATUS" -eq 0 ] && [ "$BUILD_CODE" -ne 0 ]; then
			BUILD_STATUS=$BUILD_CODE
		fi
	done
	if [ "$BUILD_STATUS" -ne 0 ]; then
		{
			echo ""
			echo "========== 构建失败（退出码：${BUILD_STATUS}） =========="
			echo "首个错误及上下文："
			awk '/^(SCRIPT ERROR|ERROR):|精简构建失败：|error:|Traceback/ { if (!found) { found=1; left=10 } } found && left-- > 0 { print }' "$BUILD_LOG" || true
			echo "错误摘要（日志末尾）："
			tail -n 12 "$BUILD_LOG" || true
			echo ""
			echo "本次构建未完成。完整日志：$BUILD_LOG"
		} >&2
		if [ -t 0 ] && [ -t 1 ] && [ "${CARD_BUILD_NO_PAUSE:-0}" != "1" ] && [ -z "${CI:-}" ]; then
			printf '\n请先查看以上错误。按回车键退出…' >&2
			read -r _build_reply || true
		fi
	fi
	exit "$BUILD_STATUS"
fi
unset CARD_BUILD_WORKER

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# 不带参数继续使用已安装的完整模板；精简模式由独立工具准备专用模板后调用原流程。
if [ "$#" -gt 0 ]; then
	case "$1" in
		--slim-engine|--slim|--engine-plan)
			exec python3 tools/slim_engine.py --godot "$GODOT" "$@"
			;;
		--android|--apk|--android-debug|--aab)
			ANDROID_ARGS=()
			[ "$1" = "--android-debug" ] && ANDROID_ARGS+=(--debug)
			[ "$1" = "--aab" ] && ANDROID_ARGS+=(--aab)
			exec python3 tools/android_build.py --godot "$GODOT" "${ANDROID_ARGS[@]}"
			;;
		-h|--help)
			cat <<'HELP'
用法：
  ./构建游戏.command                         标准构建
  ./构建游戏.command --engine-plan           扫描当前功能并查看裁剪计划，不下载、不编译
  ./构建游戏.command --slim-engine           编译精简模板后构建 App（首次较慢，之后使用缓存）
  ./安装安卓构建环境.command                   安装 Android SDK/JDK/导出模板
  ./安装安卓构建环境.command --dry-run         只显示安装计划
  ./构建游戏.command --android-debug         导出横屏 Android debug APK
  ./构建游戏.command --android               导出横屏 Android release APK
  ./构建游戏.command --aab                   导出 Google Play 使用的 AAB
  ./构建游戏.command --slim-engine --arch arm64 --jobs 8

Android release 首次未配置签名时自动生成 .android-signing/，后续复用；请备份此目录。
精简选项：--source /path/to/godot 指定匹配版本源码；--rebuild-engine 强制重新构建模板。
精简默认：--optimize size --lto full --class-trim safe；--keep-class 类名 可保留动态使用的类。
可选：--optimize size_extra 更小但可能变慢；--lto thin --class-trim none 恢复旧优化方式。
默认架构沿用 macOS 导出预设。详细选项：python3 tools/slim_engine.py --help
失败时显示错误摘要并保存 build/logs/；交互终端按回车退出，自动化可设 CARD_BUILD_NO_PAUSE=1。
HELP
			exit 0
			;;
		*) echo "未知参数：${1}（使用 --help 查看用法）" >&2; exit 2 ;;
	esac
fi
FONT="assets/fonts/NotoSansSC.ttf"

# ---------- 字体子集化与完整导入状态恢复 ----------
source tools/font_subset.sh
font_transaction_begin

# ---------- 应用图标闸门 ----------
# 原始桌宠图保留在素材包；两个入口共用同一规范化函数，输出仓库内的标准方图。
ensure_app_icon() {
	python3 tools/ensure_app_icon.py
}

echo "[1/4] 应用图标..."
ensure_app_icon || exit 1
# 构建前校验仓库素材；可选桌面素材只告警，必需素材缺失直接中止。
python3 tools/check_art_assets.py

echo "[2/4] 字体子集化..."
subset_font

echo "[3/4] 导入资源..."
font_import_resources

echo "[4/4] 导出 macOS App..."
build_stage
godot_checked --headless --export-release "macOS" "$_BUILD_STAGE/牛马牌.app"

restore_font
python3 tools/release_bundle.py "$_BUILD_STAGE" build --app-only

echo ""
echo "构建完成：build/牛马牌.app"
echo "双击即可运行（首次如提示未验证开发者：右键 → 打开）"

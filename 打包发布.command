#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 牛马牌 · 一键发布打包（itch.io）
# 产出：
#   build/牛马牌_web.zip  —— 浏览器版（itch.io HTML5 直接上传，index.html 在根目录）
#   build/牛马牌_mac.zip  —— macOS 桌面版（itch.io 可下载文件）
# 首次运行会自动下载 Godot Web 导出模板（约 1GB，仅一次）

cd "$(dirname "$0")"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
FONT="assets/fonts/NotoSansSC.ttf"
TPL_DIR="${TPL_DIR:-$HOME/Library/Application Support/Godot/export_templates/4.7.1.stable}"
TPZ_URL="https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz"

set -e

# 打印人类可读的**逻辑**大小。不用 du：du 报块占用，压不动的文件会显示成「压完变大」
bytes_h() {
	local n
	n=$(stat -f%z "$1")
	if [ "$n" -ge 1048576 ]; then
		printf "%.1fM" "$(echo "scale=3; $n/1048576" | bc)"
	else
		printf "%dK" "$((n / 1024))"
	fi
}

# ---------- 1. 确保 Web 导出模板就位 ----------
python3 tools/install_web_templates.py "$TPL_DIR" "$TPZ_URL"

# ---------- 字体子集化与完整导入状态恢复 ----------
source tools/font_subset.sh
font_transaction_begin

# ---------- 1.5 应用图标闸门 ----------
# 原始桌宠图保留在素材包；两个入口共用同一规范化函数，输出仓库内的标准方图。
ensure_app_icon() {
	python3 tools/ensure_app_icon.py
}

echo "==> 应用图标"
ensure_app_icon || exit 1
# 素材发布有独立入口；游戏打包只消费已安装素材，不修改版本锁或素材包。
# 构建前校验仓库素材；可选桌面素材只告警，必需素材缺失直接中止。
python3 tools/check_art_assets.py

echo "==> 字体子集化"
subset_font

# ---------- 3. 导入资源 ----------
echo "==> 导入项目资源"
font_import_resources

# ---------- 4. 导出 Web 版 ----------
echo "==> 导出 Web 版 → build/web/"
build_stage
mkdir -p "$_BUILD_STAGE/web"
godot_checked --headless --export-release "Web" "$_BUILD_STAGE/web/index.html"

# ---------- 5. 导出 macOS 版 ----------
echo "==> 导出 macOS 版 → build/牛马牌.app"
godot_checked --headless --export-release "macOS" "$_BUILD_STAGE/牛马牌.app"

restore_font

# ---------- 6. Brotli 预压缩（自建服务器用；itch.io 那包不带） ----------
# .wasm/.pck 是纯二进制大件，Brotli-11 能压到三成上下。
# 生成的 .br 留在 build/web/ 里，给 nginx 的 brotli_static / Caddy 的 precompressed 用；
# itch.io 自己会按 Accept-Encoding 现压现发，不认这种同名兄弟文件，
# 所以下面打 zip 时把 .br 排除掉 —— 塞进去只是让上传包白胖一圈
if command -v brotli > /dev/null 2>&1; then
	echo "==> Brotli 预压缩"
	for f in "$_BUILD_STAGE/web/index.wasm" "$_BUILD_STAGE/web/index.pck"; do
		[ -f "$f" ] || continue
		brotli -k -f -q 11 "$f"
		# 这里量的是 stat 逻辑字节，不是 du。du 报的是块占用（4K 向上取整），
		# index.pck 这种压不动的文件会被 du 显示成「6.1M → 6.5M」，看着像压完变大了，
		# 其实逻辑字节是 6383400 → 6162811，确实小了，只是只小 3.5%
		echo "    $(basename "$f"): $(bytes_h "$f") → $(bytes_h "$f.br")"
	done
else
	echo "==> 跳过 Brotli 预压缩（没装 brotli：brew install brotli）"
fi

# ---------- 7. 打 zip（itch.io 要求 index.html 在压缩包根目录） ----------
echo "==> 打包 zip"
cp data/cards.json "$_BUILD_STAGE/cards.json"
python3 tools/release_bundle.py "$_BUILD_STAGE" build

echo ""
echo "=========================================="
echo " 发布包就绪："
ls -lh "build/牛马牌_web.zip" "build/牛马牌_mac.zip" | awk '{print "   " $NF " (" $5 ")"}'
echo ""
echo " itch.io 上传步骤："
echo "   1. https://itch.io/game/new 建项目，Kind 选 HTML"
echo "   2. 上传 牛马牌_web.zip，勾选 'This file will be played in the browser'"
echo "   3. 视口建议 1280×720，勾选 Mobile friendly 可关"
echo "   4. 再把 牛马牌_mac.zip 作为可下载附件上传"
echo "=========================================="

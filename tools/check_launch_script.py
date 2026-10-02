#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""检查 启动游戏.command 的参数配对：真跑一遍脚本，看每个窗口收到了什么。

为什么单开一份：mutate_check.py 那套的判据是 Godot 测试的断言，只改得动 .gd，
而这段逻辑整个在 shell 里 —— 于是它是**全仓唯一一段没有任何判据的分支代码**。

而它的错法全是静默的，没有一种会报错：
  - 该配对却没配对：两份各起一局单机，房间码只是填在了输入框里 ——
    看着像「联机没生效」，而不像「启动脚本发错了参数」
  - 不该配对却配了：他自己写的 --server= 上面又叠一个 --host，
    两个地址打架，症状是「我明明填了地址」
  - 配错端口：第二份连 ws://127.0.0.1:8911，那儿没人监听，「连不上」
  - APP_NAME 和 export_presets.cfg 里的导出路径分叉：构建脚本出的包
    和启动脚本找的包不是同一个，于是每次启动都「还没构建过」重新构建一遍

判据的跑法是端到端的：把脚本抄进一个临时目录，把 open / sleep / 构建游戏.command
全换成会记账的假货，然后真的 bash 它一遍，读那本账。
不解析 shell、不复述实现 —— 换个写法只要行为不变就照样绿。

用法：
    python3 tools/check_launch_script.py         # 跑判据（tools/run_tests.sh 会调）
    python3 tools/check_launch_script.py --self  # 再把脚本逐条改坏，确认判据真会红
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "启动游戏.command"
PRESETS = ROOT / "export_presets.cfg"

OPEN_STUB = """#!/bin/bash
# 假 open：把每次调用的参数记一行，不真的开窗口
printf '%s\\t' "$@" >> "$WINLOG"
printf '\\n' >> "$WINLOG"
"""

SLEEP_STUB = """#!/bin/bash
echo "$@" >> "$SLEEPLOG"
"""

BUILD_STUB = """#!/bin/bash
# 假构建脚本：记一笔，并把 App 目录建出来（真脚本的可观察结果就是这个）
echo "build" >> "$BUILDLOG"
mkdir -p "$(dirname "$0")/build/$BUILD_APP"
"""


class Result:
	def __init__(self, code: int, out: str, windows: list, builds: int,
			sleeps: int):
		self.code = code
		self.out = out
		self.windows = windows   # [[arg, ...], ...] 按启动顺序
		self.builds = builds     # 调了几次 构建游戏.command
		self.sleeps = sleeps

	def args_of(self, i: int) -> list:
		"""第 i 个窗口 --args 之后的东西（没有 --args 就是空）"""
		w = self.windows[i]
		return w[w.index("--args") + 1:] if "--args" in w else []


def app_name(src: str) -> str:
	"""从脚本里读 APP_NAME —— 不写死，免得改了名字这份检查自己先过时"""
	m = re.search(r'^APP_NAME="([^"]+)"', src, re.M)
	if not m:
		raise SystemExit("启动游戏.command 里找不到 APP_NAME=\"...\"")
	return m.group(1)


def run(argv: list, src: str, *, prebuilt: bool = True) -> Result:
	"""把 src 当成 启动游戏.command 跑一遍，返回它干了什么。

	prebuilt=False 模拟「还没构建过」：不预先建 build/<App>，
	于是脚本该自己去调构建。
	"""
	app = app_name(src)
	with tempfile.TemporaryDirectory() as d:
		box = pathlib.Path(d)
		(box / "启动游戏.command").write_text(src, encoding="utf-8")
		(box / "构建游戏.command").write_text(BUILD_STUB, encoding="utf-8")
		os.chmod(box / "构建游戏.command", 0o755)
		if prebuilt:
			(box / "build" / app).mkdir(parents=True)

		# 假 open / 假 sleep 塞在 PATH 最前面。构建脚本是按 ./ 相对路径调的，
		# 拦不住也不用拦 —— 上面那份假货就在同一个目录里
		bin_dir = box / "_bin"
		bin_dir.mkdir()
		(bin_dir / "open").write_text(OPEN_STUB, encoding="utf-8")
		(bin_dir / "sleep").write_text(SLEEP_STUB, encoding="utf-8")
		for n in ("open", "sleep"):
			os.chmod(bin_dir / n, 0o755)

		env = dict(os.environ)
		env["PATH"] = "%s:%s" % (bin_dir, env.get("PATH", ""))
		env["WINLOG"] = str(box / "win.log")
		env["SLEEPLOG"] = str(box / "sleep.log")
		env["BUILDLOG"] = str(box / "build.log")
		env["BUILD_APP"] = app

		p = subprocess.run(["bash", str(box / "启动游戏.command")] + argv,
			capture_output=True, text=True, env=env, cwd=str(box))

		def lines(name):
			f = box / name
			return f.read_text(encoding="utf-8").splitlines() if f.exists() \
				else []

		windows = [[a for a in ln.split("\t") if a != ""]
			for ln in lines("win.log")]
		return Result(p.returncode, p.stdout + p.stderr, windows,
			len(lines("build.log")), len(lines("sleep.log")))


def presets_app() -> str:
	"""export_presets.cfg 里 macOS 预设导出到哪个 .app"""
	m = re.search(r'^export_path="build/([^"]+)"', PRESETS.read_text(
		encoding="utf-8"), re.M)
	return m.group(1) if m else ""


def cases(src: str) -> list:
	"""跑全部判据，返回 [(名字, 过没过, 说明), ...]"""
	out = []

	def ck(name, cond, detail=""):
		out.append((name, bool(cond), detail))

	# —— 开两份 + 房间码：第一份开房、第二份连它 ——
	r = run(["2", "--room=TEST"], src)
	ck("配对：开两份带房间码 → 正好两个窗口", len(r.windows) == 2,
		"实际 %d 个" % len(r.windows))
	if len(r.windows) == 2:
		a0, a1 = r.args_of(0), r.args_of(1)
		ck("配对：第 1 份开房（--host + 钉死端口）",
			"--host" in a0 and "--port=8910" in a0, "第 1 份收到 %s" % a0)
		ck("配对：第 2 份连第 1 份，不再自己开房",
			"--server=ws://127.0.0.1:8910" in a1 and "--host" not in a1,
			"第 2 份收到 %s" % a1)
		ck("配对：房间码两份都要有（少一边就是各在自己那间房）",
			"--room=TEST" in a0 and "--room=TEST" in a1,
			"第 1 份 %s / 第 2 份 %s" % (a0, a1))

	# 短写 -r= 走的是同一条路，别只认长的
	r = run(["2", "-r=TEST"], src)
	ck("配对：-r= 短写也认",
		len(r.windows) == 2 and "--host" in r.args_of(0)
		and "--server=ws://127.0.0.1:8910" in r.args_of(1),
		"第 1 份 %s" % (r.args_of(0) if r.windows else []))

	# —— 自己写了地址：一个字都不许改 ——
	r = run(["2", "--room=TEST", "--server=ws://1.2.3.4:9000"], src)
	both = [r.args_of(i) for i in range(len(r.windows))]
	ck("显式地址：不给他叠 --host（两个地址会打架）",
		len(both) == 2 and all("--host" not in a for a in both),
		"实际 %s" % both)
	ck("显式地址：他写的地址两份都照原样带上",
		len(both) == 2
		and all("--server=ws://1.2.3.4:9000" in a for a in both),
		"实际 %s" % both)
	ck("显式地址：不塞本机端口",
		all("--port=8910" not in a for a in both), "实际 %s" % both)

	return out + cases_more(src)


def cases_more(src: str) -> list:
	out = []

	def ck(name, cond, detail=""):
		out.append((name, bool(cond), detail))

	# —— 只开一份：没有「另一份」可以配对，别自作主张开房 ——
	r = run(["--room=TEST"], src)
	a = r.args_of(0) if r.windows else []
	ck("单份：只带房间码，不给 --host、不给端口",
		len(r.windows) == 1 and a == ["--room=TEST"], "实际 %s" % a)

	# —— --port=2 是端口，不是「开 2 份」——
	r = run(["--room=TEST", "--port=2"], src)
	ck("--port=2 不算份数（只开一个窗口）", len(r.windows) == 1,
		"实际 %d 个" % len(r.windows))
	ck("--port=2 算「自己写了地址」，于是不配对",
		len(r.windows) == 1 and "--host" not in r.args_of(0),
		"实际 %s" % (r.args_of(0) if r.windows else []))

	# —— 没参数：干净起一个，不带 --args ——
	r = run([], src)
	ck("没参数：一个窗口、不带 --args",
		len(r.windows) == 1 and "--args" not in r.windows[0],
		"实际 %s" % (r.windows[0] if r.windows else []))
	ck("open 用 -n 开新实例、-a 给绝对路径（相对路径会被当成 app 名去 /Applications 找）",
		len(r.windows) == 1 and r.windows[0][0] in ("-na", "-an")
		and r.windows[0][1].startswith("/"),
		"实际 %s" % (r.windows[0][:2] if r.windows else []))

	# —— 构建：没构建过要自己去构建，--rebuild 要强制再来一次 ——
	r = run([], src, prebuilt=False)
	ck("还没构建过 → 自己调一次构建，然后照样把窗口开出来",
		r.builds == 1 and len(r.windows) == 1,
		"构建 %d 次 / 窗口 %d 个" % (r.builds, len(r.windows)))
	r = run([], src)
	ck("已经构建过 → 不重复构建", r.builds == 0, "构建 %d 次" % r.builds)
	r = run(["--rebuild"], src)
	ck("--rebuild → 强制再构建一次", r.builds == 1, "构建 %d 次" % r.builds)
	ck("--rebuild 不当成透传参数塞给 App",
		"--rebuild" not in r.args_of(0) if r.windows else False,
		"实际 %s" % (r.args_of(0) if r.windows else []))

	# —— 两份之间要隔一下：同时起两个实例会抢同一份 .godot 缓存，
	#    而且开房那份得先把端口监听起来 ——
	r = run(["2", "--room=TEST"], src)
	ck("开多份时窗口之间有间隔（抢缓存 / 连太早）", r.sleeps >= 1,
		"sleep %d 次" % r.sleeps)

	# —— APP_NAME 和导出预设必须是同一个包 ——
	ck("APP_NAME 和 export_presets.cfg 的导出路径一致",
		app_name(src) == presets_app(),
		"启动脚本找 %s，导出预设出 %s" % (app_name(src), presets_app()))

	return out


# 逐条改坏脚本，确认上面那些判据真的会红（--self）。
# (说明, 原文, 改成) —— 原文必须在脚本里**只出现一次**，否则算 SKIP
MUTATIONS = [
	("不再区分「他自己写了地址」，一律配对",
	 '\t\t--server=*|-s=*|--host|--port=*|-p=*) EXPLICIT=1; PASS+=("$a") ;;',
	 '\t\t--server=*|-s=*|--host|--port=*|-p=*) PASS+=("$a") ;;'),
	("配对条件里不看份数（只开一份也给 --host）",
	 '\tif [ "$EXPLICIT" = "0" ] && [ "$COUNT" -gt 1 ]; then',
	 '\tif [ "$EXPLICIT" = "0" ]; then'),
	("第一份不开房（光给房间码）",
	 '\t\tHOST_ARGS=(--host "--room=$ROOM" "--port=$PORT")',
	 '\t\tHOST_ARGS=("--room=$ROOM")'),
	("第一份开房但不钉端口（顺延后第二份连了个没人监听的端口）",
	 '\t\tHOST_ARGS=(--host "--room=$ROOM" "--port=$PORT")',
	 '\t\tHOST_ARGS=(--host "--room=$ROOM")'),
	("后面几份也给 --host（各在自己那间房里等对方）",
	 '\t\tJOIN_ARGS=("--server=ws://127.0.0.1:$PORT" "--room=$ROOM")',
	 '\t\tJOIN_ARGS=(--host "--room=$ROOM")'),
	("第二份不带房间码",
	 '\t\tJOIN_ARGS=("--server=ws://127.0.0.1:$PORT" "--room=$ROOM")',
	 '\t\tJOIN_ARGS=("--server=ws://127.0.0.1:$PORT")'),
	("开房那份和连接那份对调",
	 '\tif [ "$i" = "1" ]; then',
	 '\tif [ "$i" != "1" ]; then'),
	("纯数字不再当份数（开两份变成开一份）",
	 '\t\t[0-9]*) COUNT="$a" ;;',
	 '\t\t[0-9]*) PASS+=("$a") ;;'),
	("没构建过也不构建（然后卡在「找不到包」上）",
	 'if [ "$REBUILD" = "1" ] || [ ! -d "$APP" ]; then',
	 'if [ "$REBUILD" = "1" ]; then'),
	("--rebuild 不再触发构建",
	 '\t\t--rebuild) REBUILD=1 ;;',
	 '\t\t--rebuild) : ;;'),
	("窗口之间不隔（抢 .godot 缓存 / 连太早）",
	 '\t[ "$i" -lt "$COUNT" ] && sleep 2',
	 '\t:'),
	("APP_NAME 和导出预设分叉",
	 'APP_NAME="%s"' % app_name(SCRIPT.read_text(encoding="utf-8")),
	 'APP_NAME="别的名字.app"'),
]


def self_check() -> int:
	src = SCRIPT.read_text(encoding="utf-8")
	base = cases(src)
	bad_base = [c for c in base if not c[1]]
	if bad_base:
		print("原样就有判据不过，先修那个再谈变异：")
		for name, _, detail in bad_base:
			print("  ✗ %s —— %s" % (name, detail))
		return 1

	miss = 0
	for note, old, new in MUTATIONS:
		if src.count(old) != 1:
			print("  SKIP %-42s 锚点命中 %d 次（≠1）" % (note, src.count(old)))
			miss += 1
			continue
		red = [c[0] for c in cases(src.replace(old, new, 1)) if not c[1]]
		if red:
			print("  ✓ %-42s → 红 %d 条：%s" % (note, len(red), red[0]))
		else:
			print("  MISS %-42s → 一条都没红" % note)
			miss += 1
	print()
	print("变异 %d 条，%d 条没被抓住" % (len(MUTATIONS), miss))
	return 1 if miss else 0


def main() -> int:
	if "--self" in sys.argv:
		return self_check()
	if shutil.which("bash") is None:
		print("跳过：找不到 bash")
		return 0
	res = cases(SCRIPT.read_text(encoding="utf-8"))
	bad = [c for c in res if not c[1]]
	if bad:
		print("启动游戏.command 参数配对检查失败：")
		for name, _, detail in bad:
			print("  ✗ %s" % name)
			if detail:
				print("      %s" % detail)
		return 1
	print("启动脚本检查：%d 条判据，0 失败" % len(res))
	return 0


if __name__ == "__main__":
	sys.exit(main())

# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 探针：真的从命令行传参数进来时，LaunchConfig 读到的是什么。
##
## 为什么要有这个：`LaunchConfig.parse()` 是纯函数，测试钉得死；
## 而 `desktop_args()`（从 OS 那两个 cmdline 里捞参数）**在测试里造不出来** ——
## 测试进程自己的命令行是 `-s tests/test_x.gd`，没法让它假装带了 `--room=`。
## 所以这一段只能靠人手跑一次看一眼，而它坏掉的形态是
## 「`启动游戏.command --room=X` 静默失效」，没有任何报错。
##
## 用法（三种传法都要试，因为 Godot 对 `--` 的处理不一样）：
##     Godot --headless -s tools/_cmdline_probe.gd --room=LILI
##     Godot --headless -s tools/_cmdline_probe.gd -- --room=LILI
##     Godot --headless -s tools/_cmdline_probe.gd

func _initialize() -> void:
	print("get_cmdline_args      = %s" % str(OS.get_cmdline_args()))
	print("get_cmdline_user_args = %s" % str(OS.get_cmdline_user_args()))
	print("desktop_args          = %s" % str(LaunchConfig.desktop_args()))
	print("current               = %s" % str(LaunchConfig.current()))
	quit(0)

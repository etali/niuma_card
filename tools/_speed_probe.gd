# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 手工探针：各档搜索的**单次行动阶段耗时**。
##
## 「把最强档设成默认」要先知道它卡不卡：屏幕上的对手每回合要等这么久。
## `ai.md` §「节点预算与诊断」给单机意图管道定的是最小档位预算，
## 高档位必然超，问题是超到什么量级 —— 几十毫秒没人察觉，几秒就是卡住。
##
## 量的是 MatchSimulator.action_phase 一次调用的墙钟时间，取真对局中的局面
## （先跑 3 个回合让场面长出东西，空场的行动阶段没有代表性）。
##
## 不进 tests/：耗时依赖机器，做判据会在别的机器上乱红。结论进 ai.md
func _initialize() -> void:
	CardDB.ensure_loaded()
	print("%-10s %10s %10s %10s   %s" % ["档位", "平均ms", "最慢ms", "总计ms", "旋钮"])
	# min 是 strength=0 的梯子最底档，
	# 它们的差就是不同强度 profile 的预算代价
	for tier in ["min", "low", "mid", "high", "max"]:
		var cfg := AISearch.from_tier(tier)
		var total := 0.0
		var worst := 0.0
		var n := 0
		for seed_i in range(1, 9):
			var st := GameState.new()
			st.set_seed(seed_i)
			st.new_game()
			# 先按当前默认低档推进 3 个回合，让双方场上有卡有组合
			for _r in range(3):
				if st.winner != "":
					break
				for who in st.action_order():
					MatchSimulator.action_phase(st, who)
				Settle.run(st)
				if st.winner == "":
					st.end_round()
					st.start_round()
			if st.winner != "":
				continue
			# 只给 AI 座位用这一档，量它这一次的耗时
			var t0 := Time.get_ticks_usec()
			MatchSimulator.action_phase(st, GameState.AI, cfg)
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			total += ms
			worst = maxf(worst, ms)
			n += 1
		print("%-10s %10.1f %10.1f %10.1f   %s"
			% [tier, total / maxi(1, n), worst, total, cfg.describe()])
	quit()

#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""变异检查：把被测代码逐条改坏，确认测试真的会报警。

判据写在注释里不算数 —— 没实跑过的「改坏它这条就报」可能根本没被测到。

用法：
    python3 tools/mutate_check.py              # 全表，约 20 分钟
    python3 tools/mutate_check.py test_foe_drag # 只跑某个测试/文件/关键字那几条

**必须独占跑**：并发两份会互相还原变异，症状是成片的假 MISS。

报出 MISS 的三种原因，修法互不相同：
  1. 判据太松 —— 断言宽到容得下改坏后的结果。收紧断言。
  2. 没有观察点 —— 那个量根本没人读，或者测试自己替被测代码算了一遍。
     这时候收紧断言没用，要先让被测的东西有读者。
  3. 变异没打在想改的地方 —— 锚点撞了名，replace 改的是另一处（下面 SKIP
     那一关会挡住），或者重构之后锚点失配（tools/check_mut_residue.py 管这个）。

判据不限于 .gd：run_tests.sh 里那五个 python 检查（check_card_table 那些）
也能当裁判，按扩展名分派，见 _cmd_for。它们盯的是「文档和配置飘了」这一类
**没有任何 .gd 判据会红**的坏法 —— 那种变异下全套测试照旧全绿。
"""
import os
import re
import subprocess
import sys
import pathlib

GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
ROOT = pathlib.Path(__file__).resolve().parent.parent

# 时间加速，同 tools/run_tests.sh（实现在 tests/harness.gd 的 _init）。
# 这一关要跑 len(MUTATIONS) 次测试，慢档下是几十分钟的差别。
# setdefault 而不是直接赋值：出了怪事要能 TEST_SPEED=1 跑同一份变异表对照
os.environ.setdefault("TEST_SPEED", "5")

# (文件, 原文, 改成, 期望报警的断言关键字[, 指定跑哪个测试])
# 第 5 项省略时按 TEST_FOR 取该文件的默认测试
MUTATIONS = [
    ("engine/game_state.gd",
     'if resource_count(who, CardDB.RES_CASH) - price <= 0:',
     'if false:',
     "付完会归零"),
    ("engine/game_state.gd",
     'if resource_count(who, CardDB.RES_CASH) - price <= 0:',
     'if resource_count(who, CardDB.RES_CASH) - price < 0:',
     "付完会归零"),
    ("engine/game_state.gd",
     '\t\t\t\treturn { "ok": false, "code": "not_cash", "reason": "请用现金卡支付" }',
     '\t\t\t\tpass',
     "not_cash"),
    ("engine/game_state.gd",
     '\tvar removed: Array = pay.slice(0, price)',
     '\tvar removed: Array = pay',
     "多付的 2 张不吃"),
    # 唯一一份：兜底改成读 BUILTIN_PATH 之后，字面量默认值表不许再回来。
    # 原先这里钉的是「代码兜底值偏离 cards.json」（18/8 vs 20/10 那种静默偏移），
    # 但那道判据只能证明两份一样、拦不住第二份存在 —— 而调平衡的人改的是配置那份。
    # 现在钉结构：把字面量表加回来就报红
    ("engine/card_db.gd",
     'const SECTION_GAME := "_game"',
     'const DEFAULT_GAME := {"start_cash": 18}\nconst SECTION_GAME := "_game"',
     "没有字面量默认值表"),
    # 兜底不从内置配置补：外置配置缺一个键就读出 null → 静默变 0
    ("engine/card_db.gd",
     '\tvar defaults := _builtin_section(key)',
     '\tvar defaults := {}',
     "整段回退内置配置"),
    # 嵌套字典整块覆盖：外置配置只改 buff_mult 一档，其余几档被抹掉。
    # 关键词盯的是 test_simulator 里那条**跑合并**的判据（「逐键补齐」）。
    # 原先写的是「每个键都有人读」—— 那条判据扫的是源码里有没有键名（静态文本），
    # 跟运行时怎么合并不在一条路上，所以这条变异一直报 MISS 且失败 0 条：
    # 不是判据太松，是压根没有观察点（2026-09-01 补上判据后才真的红）
    ("engine/card_db.gd",
     '\t\tif typeof(meta[k]) == TYPE_DICTIONARY and typeof(out.get(k)) == TYPE_DICTIONARY:',
     '\t\tif false:',
     "逐键补齐"),
    # 闲置旋钮：配置里摆着但没人读。往 _game 段塞一个谁都不认的键
    ("data/cards.json",
     '"start_cash": 20,',
     '"start_cash": 20, "win_user": 999,',
     "_game 段的每个键都有人读"),
    # 可调 attack_n 不受旧卡表的首回合斩上限约束。改合法配置不应报错；
    # 要破坏的是引擎是否正确应用倍率和单卡成本，判据走真实攻击池/结算。
    # 无 Buff 也翻倍：覆盖「倍率只作用于带攻击 Buff 的组合」这半边。
    ("engine/combo_rules.gd",
     '\t\t\tresult["attack_n"] = ldef["attack_n"] * (CardDB.buff_mult("attack_x2") if attack_x2 else 1)',
     '\t\t\tresult["attack_n"] = ldef["attack_n"] * CardDB.buff_mult("attack_x2")',
     "攻击池等于配置点数乘倍率", "tests/test_simulator.gd"),
    # 单卡成本退回写死 1：成本为 3 的夹具会多打牌，真实移除数量必须报错。
    ("engine/game_state.gd",
     '\tvar per_card := int(CardDB.game_rules()["attack_cost_per_card"])',
     '\tvar per_card := 1',
     "余点不足一张不继续攻击", "tests/test_simulator.gd"),
    # 回合上限退回写死：模拟器从此量的不是配置里那个回合数
    ("engine/match_simulator.gd",
     '\t\tmax_rounds = int(CardDB.sim_rules()["max_rounds"])',
     '\t\tmax_rounds = 80',
     "_sim 段的每个键都有人读"),
    # 防御膜的 res 从 buff_type 反解：反解错了两张卡会说同一种资源
    ("scenes/board.gd",
     'CardDB.card_label(bt.trim_prefix("protect_"))',
     'CardDB.card_label(CardDB.RES_USER)',
     "降价补贴说的是现金", "tests/test_hover_desc.gd"),
    # 计量名/卡名分工：把配方段换回计量名，悬停就又和报错不同词了
    ("scenes/board.gd",
     'CardDB.card_label(def["recipe_res"]), int(def["recipe_n"]),\n\t\t\t\tCardDB.res_label(def["output_res"])',
     'CardDB.res_label(def["recipe_res"]), int(def["recipe_n"]),\n\t\t\t\tCardDB.res_label(def["output_res"])',
     "生产卡配方段用卡名"),
    ("scenes/board.gd",
     '\t\t\t\tCardDB.res_label(def["output_res"]), int(def["output_n"]),',
     '\t\t\t\tCardDB.card_label(def["output_res"]), int(def["output_n"]),',
     "每回合产出段用计量名"),
    # 摞位求解器：判据一律不读被测常量，所以改小余量/删掉判定都该报
    ("engine/pile_solver.gd",
     'const PILE_TAKE_CLEAR_Z := 2.3',
     'const PILE_TAKE_CLEAR_Z := 1.8',
     "一摞实际占地"),
    ("engine/pile_solver.gd",
     'const PILE_CLEAR_X := 1.3',
     'const PILE_CLEAR_X := 1.0',
     "卡宽"),
    # 硬避让那一轮没了：新摞会落在旧摞的坐标上，10 层逐层撞死
    ("engine/pile_solver.gd",
     '\t\t\t\tif hard and pile_overlaps(desk, spot, taken):',
     '\t\t\t\tif false:',
     "摞外的格子更贵也不压在摞上"),
    # 压深退回真假量：筛不出「最不坏的那一格」
    ("engine/pile_solver.gd",
     '\t\tdepth += (1.0 - dx / PILE_CLEAR_X) * (1.0 - dz / reach)',
     '\t\tdepth += 1.0',
     "越靠摞心压得越深"),
    # 玩家的摊开组不再加倍计价
    ("engine/pile_solver.gd",
     '\t\tdepth += 2.0 * (1.0 - d1 / PILE_CLEAR_X) * (1.0 - d2 / PILE_TAKE_CLEAR_Z)',
     '\t\tdepth += 1.0 * (1.0 - d1 / PILE_CLEAR_X) * (1.0 - d2 / PILE_TAKE_CLEAR_Z)',
     "压玩家的摊开组比压摞贵一倍"),
    # 撞车判定没了：散牌落在同一格，屏幕上看着就是少了几张
    ("engine/pile_solver.gd",
     '\t\t\t\t\tif absf(u.x - spot3.x) < 0.01 and absf(u.z - spot3.z) < floor_step:',
     '\t\t\t\t\tif false:',
     "同列两张的间距"),
    # 余量按 PILE_CHUNK 估而不按实际最长的摞：并成 20 的那一摞尾巴漏在余量外
    ("engine/pile_solver.gd",
     '\t\tn = maxi(n, int(p["count"]))',
     '\t\tn = n',
     "并成 20 的那一摞"),
    # 定高度不限序：两摞占地互相重叠就互相往上顶，反复算发散到 y=509
    ("engine/pile_solver.gd",
     '\t\tif limit >= 0 and int(pile["gi"]) >= limit:',
     '\t\tif false:',
     "十趟结算高度不变"),
    # 抬升不含台阶：摞顶那张和落上去那张撞在同一层（穿模）
    ("engine/pile_solver.gd",
     '\t\t\ttop = maxf(top, origin.y + desk.pile_step_y * float(n - 1) + desk.ladder1)',
     '\t\t\ttop = maxf(top, origin.y + desk.pile_step_y * float(n - 1))',
     "抬到身下那摞的顶 + 一级台阶"),
    # 高度成了摆放历史的残留：身下的结构撤了还悬空着
    ("engine/pile_solver.gd",
     '\treturn maxf(desk.table_y, top)',
     '\treturn maxf(desk.table_y, maxf(top, 0.5))',
     "身下空了就落回桌面"),

    # ---- 摆放那一层（scenes/settle_layout.gd，从 main.gd 切出来的）----
    # 「只管刚出现的这几张」的判据没了：整片玩家的卡都被当成新到货重排一遍
    ("scenes/settle_layout.gd",
     '\t\tif known.has(c["uid"]) or not entities.has(c["uid"]):',
     '\t\tif not entities.has(c["uid"]):',
     "结算前后玩家自己那一摞没挪窝"),
    # 两批摞不共用 taken：用户那批的摞位进不了 taken，后面排余数时看不见它们。
    # 报出来的是余数叠死（不是摞叠死）—— 摞与摞之间另有 _spot_cost 兜着。
    #
    # 关键词盯「散牌都没压在摞上」那条（余数落点和摞的矩形有交集）。
    # 原先写的是「卡面不穿模」，那条一直不响 —— 它判的是「重叠的两张 y 差**不足**
    # FACE_SPAN_Y」= 穿模，而这条变异把余数垫到了摞的**上方**（实测 y=1.83
    # 对清单 0.479），y 差远超阈值，于是它天然看不到这种坏法。
    # 不是判据太松，是那条判的根本是另一件事（2026-09-01 查明）
    ("scenes/settle_layout.gd",
     '\tvar user_rest: Array = _stack_piles_only(user_pool, SETTLE_USER_ANCHOR,\n\t\tSETTLE_USER_COLS, taken, mine)',
     '\tvar user_rest: Array = _stack_piles_only(user_pool, SETTLE_USER_ANCHOR,\n\t\tSETTLE_USER_COLS, [], mine)',
     "都没压在摞上"),
    # mine 那一条判据在求解器里，由 test_pile_solver 的 T7 直接盯着：
    # 场景层去掉它只体现成「余数多散一张」，越不过「不重叠/不出界」那几条
    ("engine/pile_solver.gd",
     '\t\tif mine.has(s["uid"]):\n\t\t\tcontinue',
     '\t\tif false:\n\t\t\tcontinue',
     "自己正站着的那一格算空的"),
    # ---- AI 区分行：分行看「是什么」不看「第几个」 ----
    # 退回按序号分行 —— 开局零组合，两堆闲置卡被排进靠购牌区的前排、挤在中间
    ("scenes/settle_layout.gd",
     '\t\tif is_front_pile(p["key"]):',
     '\t\tif true:',
     "离购牌区不比玩家近", "tests/test_ai_pile.gd"),
    # 闲置摞的席位不再镜像玩家侧：现金摞跑到杂项那个位置，两边对不上
    ("scenes/settle_layout.gd",
     '\t\tif key.begins_with("ai_cash"):\n\t\t\tx = _ai_resource_anchor(CardDB.RES_CASH).x',
     '\t\tif false:\n\t\t\tx = _ai_resource_anchor(CardDB.RES_CASH).x',
     "摞对着玩家的", "tests/test_ai_pile.gd"),
    # 侧边清单的高度回去扫实时坐标：开局那批牌正从头顶飞过，清单被顶到半空
    ("scenes/board.gd",
     '\tvar y: float = floor_y if pin_y else overlay_y(\n\t\tVector3(left + SIDE_W / 2.0, 0.0, at.z), Vector2(SIDE_W, col_h), floor_y)',
     '\tvar y: float = overlay_y(\n\t\tVector3(left + SIDE_W / 2.0, 0.0, at.z), Vector2(SIDE_W, col_h), floor_y)',
     "没飘在半空", "tests/test_ai_pile.gd"),
    # 后行不按张数往北退：摞沿 +z 长出去，伸进前行压着组合
    ("scenes/settle_layout.gd",
     '\tvar span: float = Board.capped_offset(n, 0, back_pile_cap()).z\n'
     '\treturn maxf(AI_ROW_Z[1] - span, AI_BACK_Z_MIN)',
     '\treturn AI_ROW_Z[1]',
     # 关键字对着「封顶封在席位真正的容量上」那条，不是「没有伸进前行」那条：
     # 后者量的是这一局真实那几摞，摞到那一刻还没满级、南缘离前行还有余量，
     # 不按张数往北退也没顶到人。真看得见这件事的是满级那一条
     "封顶封在席位真正的容量上", "tests/test_ai_pile.gd"),
    # ---- 重开一局：连接不许活过重开 ----
    # 连接活过重开 —— 新局第一个对手回合停在 _await_foe_action 里等一条
    # 永远不来的 action_done。不报错、不崩，就是再也不动了
    ("scenes/main.gd",
     '\tif _net != null:\n\t\t# 先摘信号再 close',
     '\tif false:\n\t\t# 先摘信号再 close',
     "不再往上一局那条连接上发", "tests/test_restart_bugs.gd"),
    # 只清连接、忘了把「对手是人」置回去：本地 AI 不接手，新局第一个对手回合
    # 停在 _await_foe_action 里等一条永远不来的 action_done
    # 锚点只取 set_foe_remote 那一行（文件里唯一一处）：它上面那几行会变 ——
    # 后来插进来的 stop_local_host() 和它的注释就把带 `_net = null` 的旧锚点弄失配了，
    # 而失配的表现是这条变异静默不打（check_mut_residue.py 的「原文不在」管这个）
    ("scenes/main.gd",
     '\tset_foe_remote(false)',
     '\tpass',
     "重开退回单机局", "tests/test_restart_bugs.gd"),
    # 只清 _net、忘了摘信号：上一局那条连接还能往新局的桌面上塞拖拽帧，
    # 新局的牌会被一个「这一局根本没拖过牌的对手」租走
    ("scenes/main.gd",
     '\tif net.foe_drag.is_connected(on_foe_drag):\n'
     '\t\tnet.foe_drag.disconnect(on_foe_drag)',
     '\tpass',
     "摘掉了", "tests/test_restart_bugs.gd"),
    # ---- 组合分列：一列摊不开就横着借地方（治「组合牌全摞在一块儿看不清」）----
    # 不再分列，一律一列：一列最多摊得开 combo_per_col()=4 张，而 21 个配方里
    # 17 个是 5 张以上 —— 于是绝大多数组合退回收拢，正是报上来的那个症状
    ("scenes/settle_layout.gd",
     '\treturn maxi(1, ceili(float(n) / float(per)))',
     '\treturn 1',
     "组合是摊开的", "tests/test_ai_pile.gd"),
    # ---- 前行按「最宽那组 + 空当」定节距（治「每次 AI 理完牌，组合卡都叠在一起」）----
    # 这四条守的是同一件事的四个零件。原先这儿有一条「分列不看 room」的，
    # 那个 room 参数已经没了 —— 整行的宽度成了定值，三个调用方传的是同一个数，
    # 掐列数那一步再也没掐着过。「一行摆不下」现在归下面的降列那一段
    #
    # 空当归零：节距退回「最宽那组的宽度」本身，相邻两组边挨边、
    # 中间一丝空当都没有 —— 正是报上来的那个样子
    ("scenes/settle_layout.gd",
     '\tvar pitch: float = lead + trail + COMBO_ROW_GAP',
     '\tvar pitch: float = lead + trail',
     "兑现了声明的空当", "tests/test_ai_pile.gd"),
    # 节距只看第一组有多宽（不取整行最宽的那个）：最宽的那组在中间时，
    # 它自己的两边就压上邻居
    ("scenes/settle_layout.gd",
     '\tvar lead: float = _row_lead(out)\n'
     '\tvar trail: float = _row_trail(out)',
     '\tvar lead: float = combo_reach(int(out[0]["n"]), int(out[0]["cols"]),\n'
     '\t\tbool(out[0]["compact"])).x\n'
     '\tvar trail: float = combo_reach(int(out[0]["n"]), int(out[0]["cols"]),\n'
     '\t\tbool(out[0]["compact"])).y',
     "没有牌压牌", "tests/test_ai_pile.gd"),
    # 摆不下也不降列：整行按最宽那组的节距摊开，宽到把一个组合挤下前行
    # （前行放不下就落到后排，和闲置摞混在一起 —— 判据数的就是前后排各几摞）
    ("scenes/settle_layout.gd",
     '\twhile _row_span(out, lead + trail) > avail:',
     '\twhile false:',
     "都在前排", "tests/test_ai_pile.gd"),
    # 降列的闸门按「带着空当摆得下吗」问，而不是「空当挤到 0 摆得下吗」：
    # 只差一点空当就触发降列，而降列是有损的（一列摊不开 5 张以上只好收拢）。
    # 症状是组合一多就整行崩成收拢，每个组合只剩一张牌 —— 正是报上来的
    # 「AI 整理后的组合牌摞在一块儿看不清」。7 个组合时露馅
    ("scenes/settle_layout.gd",
     '\twhile _row_span(out, lead + trail) > avail:',
     '\twhile _row_span(out, lead + trail + COMBO_ROW_GAP) > avail:',
     "空当还挤得动就不降列", "tests/test_ai_pile.gd"),
    # 一行空得慌时不把节距撑开：节距按最宽那组的伸出算，组合小的时候只有 1.80,
    # 比原先的固定网格（2.5）还挤 —— 不重叠，但白空着大半个前行
    ("scenes/settle_layout.gd",
     '\tif k > 1 and pitch < AI_SLOT_PITCH:',
     '\tif false:',
     "节距撑开到 AI_SLOT_PITCH", "tests/test_ai_pile.gd"),
    # 降到一列还是摆不下时不再压节距：出桌。
    # 判的是 _check_plan_row_stress 那一节 —— 压节距只在 12 个组合以上才启用，
    # 摆真牌那一节（8 个）碰不到
    ("scenes/settle_layout.gd",
     '\tif k > 1 and _row_span(out, pitch) > avail:',
     '\tif false:',
     "卡宽放得下的组合数都没出桌", "tests/test_ai_pile.gd"),
    # 压节距不留卡宽这条底线：压到相邻两张牌互相盖上去 —— 牌压牌看不见
    # （长得像「本来就这么多牌」），比出桌更糟。同样只有 20 个组合以上才压到底
    ("scenes/settle_layout.gd",
     '\t\tpitch = maxf(pitch - over / float(k - 1), CardEntity.CARD_SIZE.x)',
     '\t\tpitch = pitch - over / float(k - 1)',
     "没有牌压牌", "tests/test_ai_pile.gd"),
    # 清单只往右长这件事不算进占地：按卡心居中，整片就往右偏出一个清单宽
    ("scenes/settle_layout.gd",
     '\t\t\tright = half + Board.SIDE_GAP + Board.SIDE_W',
     '\t\t\tright = half',
     "以 x=0 居中", "tests/test_ai_pile.gd"),
    # 按卡心居中（不按真实占地）：同上，右边那截清单出桌
    ("scenes/settle_layout.gd",
     '\tvar ext: Vector2 = _row_extent(out)\n'
     '\tvar shift: float = -(ext.x + ext.y) / 2.0',
     '\tvar shift: float = -float(out[out.size() - 1]["x"]) / 2.0',
     "以 x=0 居中", "tests/test_ai_pile.gd"),
    # 一列几张退回按整组张数算（分列之前的算法）：5 张以上一律 0 步长，
    # 分了列也白分 —— 判据是「张数多的组合也摊得开」那条前提
    ("scenes/settle_layout.gd",
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\treturn 1 + int(floor(budget / combo_band_step() + 0.0001))',
     '\treturn 1',
     "组合是摊开的", "tests/test_ai_pile.gd"),
    # 分列了但列与列不错开 x：所有列落在同一个 x 上，几列牌完全重合 ——
    # 比不分列更糟（看不出是几张，还每张都压着别人的占地）
    ("scenes/settle_layout.gd",
     '\t\tvar dx: float = (float(col) - float(cols - 1) / 2.0) * COMBO_COL_PITCH',
     '\t\tvar dx: float = 0.0',
     "每摞的高度差都对得上它声明的形态", "tests/test_ai_pile.gd"),
    # ---- 后行的资源摞：占地不随张数长（治「资源牌多的时候也不怎么摞」）----
    # 台阶不再封顶：40 张就压进前行，100 张（胜利线，一局真能走到）摞到 y=4.5、
    # 南缘盖在货架牌上。判据是「三个张数下占地逐位相同」那条
    ("scenes/board.gd",
     '\tvar rungs: int = mini(n, maxi(cap, 1))',
     '\tvar rungs: int = n',
     "张时摞的占地逐位相同", "tests/test_ai_pile.gd"),
    # 封顶封在 12 级（式子里纵深减两次 —— 那正是这段注释记着的坑）：
    # 摞更矮更紧，「不随张数长」照旧成立，可它把「不碰前行」偷偷换成一条更严的、
    # 没人说出口的规矩。判据是「满级的摞南缘正好顶在前行北缘上」那条
    ("scenes/settle_layout.gd",
     '\tvar budget: float = AI_ROW_Z[0] - AI_BACK_Z_MIN - CardEntity.CARD_SIZE.z',
     '\tvar budget: float = AI_ROW_Z[0] - AI_BACK_Z_MIN'
     ' - CardEntity.CARD_SIZE.z * 2.0',
     "正好顶在前行北缘", "tests/test_ai_pile.gd"),
    # 摊开那一片不再限宽：现金能摊到 7 列 56 张、横着占掉大半个 AI 区，
    # 一眼看不出是几张 —— 报上来的「资源牌多的时候也不怎么摞」的另一半
    #
    # 关键词盯**新开那一局**那一节（_check_spread_width），不是镜像那一节：
    # 开局 AI 恰好 20 张现金 = 3 列 = spread_max_cols(cash)，闸门正好不吃紧，
    # 拆了和不拆一模一样；而其余几节桌上都有组合，_spread_ai_res 第一条
    # 先返回 false，闸门走不到。2026-09-01 这条一开始是 MISS，为它补了那一节
    ("scenes/settle_layout.gd",
     '\t\tif cols > spread_max_cols(res):\n\t\t\treturn false',
     '\t\tif false:\n\t\t\treturn false',
     "张时这一片改收拢了", "tests/test_ai_pile.gd"),
    # 侧边清单的核心卡闸门退回数「种」而不是数「张」：同名两张只有 1 种，
    # 核心一行都不出。这正是报上来的「AI 合成了 2 张独角兽，下一回合只看到 1 张」——
    # 备牌摞按 def_id 分摞（两张必然同摞）、收拢只露摞顶那张，清单又不提，
    # 屏幕上和「只合出一张」逐像素相同。
    #
    # 判据只有 _check_same_core_twice 那一节抓得住：备牌那几节补的 12/29 种卡
    # **各不相同**，种类数恒等于张数，两种写法给同一个答案
    ("scenes/board.gd",
     '\tif core_total >= 2:',
     '\tif cores.size() >= 2:',
     "清单里有一行「×2」", "tests/test_ai_pile.gd"),
    # ---- 前行的组合：张数少就摊开 ----
    # 摊开这条路整个不走了，一律收拢 —— 3 张的组合明明摊得下，却收成
    # 一坨只露核心卡。判据是「有组合摊开了」那条前提
    ("scenes/settle_layout.gd",
     '\t\tvar step: float = combo_spread_step(ceili(float(n) / float(maxi(cols, 1))))',
     '\t\tvar step: float = 0.0',
     "有组合摊开了", "tests/test_ai_pile.gd"),
    # 摊开时座次不翻过来：核心卡落到最北那个座、被它后面每一张压掉，
    # 屏幕上露的是随便一张用户卡。收拢那条路（compact_offset 自己翻）不受影响，
    # 所以上面那节 8 张组合的「摞顶是核心卡」照样过 —— 只有摊开这一节报
    ("scenes/settle_layout.gd",
     '\t\tvar seat: int = per - 1 - (j % per)',
     '\t\tvar seat: int = j % per',
     "每个组合的形态都完整可读", "tests/test_ai_pile.gd"),
    # 南界退回读 AI 托盘那条线（AI_COMBO_MAX_Z 是卡心限制，不管货架牌的占地）：
    # 预算从 0.80 涨到 2.10，3 张的组合按 0.52 摊开，南缘钻到货架牌底下
    ("scenes/settle_layout.gd",
     '\treturn _main.MARKET_Z - CardEntity.CARD_SIZE.z',
     '\treturn AI_COMBO_MAX_Z',
     "每个组合的形态都完整可读", "tests/test_ai_pile.gd"),
    # 挤到看不出张数也照摊：7～8 张的组合按 0.11~0.13 摊开 —— 露不出标题带，
    # 又因为 compact=false 没有侧边清单顶上，那几张彻底读不出来。
    #
    # 锚点必须带上 `var budget := ...` 那行：combo_spread_step 和 declared_spread_step
    # 的**最后两行逐字相同**，只写尾行会撞两处、整条被 SKIP 掉。
    # 这两个函数和这两条变异同在提交 9166689 里进来 —— 也就是说加进表那天就是死的，
    # 一直到 2026-09-01 才查出来。两者唯一的区别就在预算怎么取
    #（这边「行线往南到南界」，那边「行线往北到后排退让线」）
    ("scenes/settle_layout.gd",
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\tvar step: float = minf(Board.STACK_GAP.z, budget / float(per_col - 1))\n'
     '\treturn step if step >= combo_band_step() - 0.0001 else 0.0',
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\tvar step: float = minf(Board.STACK_GAP.z, budget / float(per_col - 1))\n'
     '\treturn step',
     "张数多的组合仍然收拢", "tests/test_ai_pile.gd"),
    # 不再限制「别比玩家侧摊得更开」：预算摊得下就一路撑开。
    # 桌上量不出来（卡表最小的组合 3 张，那一档预算本来就收紧），
    # 判据是那条走遍张数域的 —— n=2 时步长会从 0.52 变成 0.80。
    # 锚点同样得带预算那行才唯一（见上一条）
    ("scenes/settle_layout.gd",
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\tvar step: float = minf(Board.STACK_GAP.z, budget / float(per_col - 1))',
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\tvar step: float = budget / float(per_col - 1)',
     "比玩家侧", "tests/test_ai_pile.gd"),
    # 台阶朝北长：北端不再钉在行线上，整组退进后排、核心卡也跑到最北那头
    ("scenes/settle_layout.gd",
     '\t\t_ai_move(e, at + Vector3(dx, Board.ladder_y(seat), step * float(seat)))',
     '\t\t_ai_move(e, at + Vector3(dx, Board.ladder_y(seat), -step * float(seat)))',
     "每个组合的形态都完整可读", "tests/test_ai_pile.gd"),
    # ---- 理牌航迹：飞行途中也要守住「占地重叠 → y 差 > FACE_SPAN_Y」----
    # 抬升改成**每张各自算**（抬到同一个高度）而不是整趟共用一个 Δy：
    # 一整摞平移时底下那张抬得多、上面那张抬得少，整摞在半途压成一个平面。
    #
    # 变异下在 _flush_ai_moves 而不是 _ai_arc 里那句 `+ lift * sin(...)`：
    # 后者试过，MISS —— 同摞两张牌的 from.y/at.y 一起偏移，那句里怎么改
    # 两张都一样地改，y 差原样保住，是一条近似等价的变异。
    # 「共用一个 Δy」这个决定本来就在 _flush_ai_moves，判据该盯的是那儿
    #
    # 变异要**连登记表一起改**（"lift": lift → 各自那个）：判据现在按 _ai_flight
    # 里登记的计划密采（见 test_tidy.gd 第 3 节，2026-09-01 从「按物理帧采」改的）。
    # 只改 _ai_fly 那一句的话，登记的还是整趟共用的那个 lift，判据采到的是
    # **没被改坏的**那条航迹 —— 屏幕上压成平面，判据却全绿
    ("scenes/settle_layout.gd",
     '\tvar lift: float = maxf(0.0, _lift_ceiling() - low)\n'
     '\tfor m in moves:\n'
     '\t\tvar e: CardEntity = m[0]\n'
     '\t\t_ai_flight[e.uid] = {"from": e.position, "at": m[1] as Vector3, "lift": lift}\n'
     '\t\t_ai_fly(e, m[1], lift)',
     '\tvar ceil2: float = _lift_ceiling()\n'
     '\tfor m in moves:\n'
     '\t\tvar e: CardEntity = m[0]\n'
     '\t\tvar lift: float = maxf(0.0, ceil2 - e.position.y)\n'
     '\t\t_ai_flight[e.uid] = {"from": e.position, "at": m[1] as Vector3, "lift": lift}\n'
     '\t\t_ai_fly(e, m[1], lift)',
     "一趟理牌里同摞、占地重叠的牌 y 差都", "tests/test_tidy.gd"),
    # 出发那片占地上不再冻住 y：从厚摞顶起飞的那张，头几帧就被 lerp
    # 拽到原摞同伴的高度上。
    #
    # 判据是「没有跳变」那条：闸门一常假，w = (u-t0)/(t1-t0) 就跑到 [0,1] 之外，
    # sin 翻号，牌一出发先跳到落点下面去（实测 y 1.5 → -0.496）。
    # 「y 差」那条量不出来 —— 400 个采样点正好跨过跳变的那一瞬
    ("scenes/settle_layout.gd",
     '\tif u <= t0:\n\t\t# 还压在出发那片占地上：y **一点不许动**。',
     '\tif false:\n\t\t# 还压在出发那片占地上：y **一点不许动**。',
     "航迹上没有跳变", "tests/test_tidy.gd"),
    # 进了落点那片占地还在动 y：滑进座位的最后一段边降边挪，扎进邻座里
    # （同上，现形成跳变）
    ("scenes/settle_layout.gd",
     '\tif u >= t1:\n\t\t# 已经进了落点那片占地：y 已经落到位，平着滑进座位',
     '\tif false:\n\t\t# 已经进了落点那片占地：y 已经落到位，平着滑进座位',
     "航迹上没有跳变", "tests/test_tidy.gd"),
    # 「脱开出发那片占地」的闸门归零：于是牌一起飞就开始升 y、一路升到落点，
    # 出摞和进摞都变成竖着穿过去 —— 正是要修的那个穿模
    #
    # 不变异 `gate >= 0.5` 那个短程分支（试过，MISS）：短程时 gate 本来就 > 0.5，
    # t0 > t1，下面 `u <= t0` 那一支把整个开窗都遮住了，
    # 拆掉这个分支和留着它算出来的航迹一样 —— 那是一条近似等价的变异
    #
    # 判据是第 1 节（实跑那一趟）和第 3 节（密采计划）两条一起：
    # 第 1 节自己按定义算闸门（_gate_of），压根不读这个函数 —— 那是故意的，
    # 判据不该跟着被改坏的实现一起走；第 3 节反过来读生产侧的，
    # 量的是「这一趟的计划干不干净」（两节各自的注释里写了这个分工）
    ("scenes/settle_layout.gd",
     '\tvar fx: float = CardEntity.CARD_SIZE.x / dx if dx > 0.0 else INF\n'
     '\tvar fz: float = CardEntity.CARD_SIZE.z / dz if dz > 0.0 else INF\n'
     '\treturn minf(fx, fz)',
     '\treturn 0.0',
     "一趟理牌里同摞、占地重叠的牌 y 差都", "tests/test_tidy.gd"),
    # 闸门按圆算（退回 2026-09-01 之前那个 _foot_radius）：横着飞的牌多滑 0.88
    # 才肯落 y，那一段贴着落点高度从邻摞头上擦过去 —— 跨摞掠过从 7 对涨到 14 对。
    # 判据是第 3 节钉的那个上限（≤7），它正是为这条改动立的
    ("scenes/settle_layout.gd",
     '\tvar dx: float = absf(at.x - from.x)\n\tvar dz: float = absf(at.z - from.z)',
     '\tvar span: float = Vector2(at.x - from.x, at.z - from.z).length()\n'
     '\tif span <= 0.0:\n\t\treturn INF\n'
     '\treturn Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z).length() / span\n'
     '\tvar dx: float = absf(at.x - from.x)\n\tvar dz: float = absf(at.z - from.z)',
     "闸门就是占地最早分开的那一刻", "tests/test_tidy.gd"),
    # 两头不再逐位返回端点：lerp(from, at, 1.0) 差一个 ulp，
    # 落点正好压在分桶边界上时（x=6.25 按 0.1 分列）一摞被记成跨两列
    ("scenes/settle_layout.gd",
     '\tif f >= 1.0:\n\t\treturn at\n\tif f <= 0.0:\n\t\treturn from',
     '\tif f >= 2.0:\n\t\treturn at\n\tif f <= -1.0:\n\t\treturn from',
     "航迹两头逐位等于", "tests/test_tidy.gd"),
    # 落点等于原位的牌也发补间：理牌一趟里绝大多数牌都是原地不动，
    # 全发进去 = 全被抬到航线高度，同一摞里每一对都共面
    #
    # 判据是「落点没变的那一趟不发补间」，**不是**穿模那条：原地不动的牌
    # span=0，进 _ai_arc 也走短程平飞那一支，y 一动不动。这一句守的是
    # ai_moving() 那个同步条件，不是穿模（memory: vacuous-mutation-two-flavors）
    ("scenes/settle_layout.gd",
     '\tif e.position.distance_to(at) < AI_STILL_EPS:',
     '\tif false:',
     "落点没变的那一趟不发补间", "tests/test_tidy.gd"),
    # ---- 备牌那一片：不同的卡各占一摞（问题 2 的修复）----
    # 备牌不按卡面分摞，全塞进一摞 —— 那正是报上来的样子：几种互不相同的
    # 核心卡收成一摞，只露得出最上面那一张。实测 6 种落在同一个 x 上、
    # z 只铺开 0.25 而牌纵深 1.7，85% 互相盖住
    ("scenes/settle_layout.gd",
     '\t\t\tvar d: String = e.def_id\n',
     '\t\t\tvar d: String = "ai_bench_all"\n',
     "两张不同的卡分成了两摞", "tests/test_dblclick_pile.gd"),
    # 分了摞却不给席位：全落回 AI_PILE_BENCH_X，分摞白分（就是分摞之前的样子）
    ("scenes/settle_layout.gd",
     '\t\telif bench_x.has(key):\n\t\t\tx = float(bench_x[key])\n',
     '\t\telif false:\n\t\t\tx = float(bench_x[key])\n',
     "两摞备牌横向不互相盖住", "tests/test_dblclick_pile.gd"),
    # 席位节距不受窗口约束（退回只按 PLAYER_PILE_COL_PITCH 排）：
    # 摞数一多整片撑出窗口，压在摊开的现金片上
    ("scenes/settle_layout.gd",
     '\tvar pitch: float = minf(PLAYER_PILE_COL_PITCH,\n\t\t(hi - lo) / float(k - 1))\n',
     '\tvar pitch: float = PLAYER_PILE_COL_PITCH\n',
     "备牌跟别的摞不互相盖住", "tests/test_ai_pile.gd"),
    # 整片不平移回窗口内：这是我改这一版时真踩出来的那次穿模 ——
    # 节距从窗口宽反解、居中却按 BENCH_X 算，两个基准不是一个数，
    # 6 摞时最左那摞落在 -5.00，摊开的现金片右缘 -4.80，相差 0.20 而牌宽 1.2
    ("scenes/settle_layout.gd",
     '\tx0 = clampf(x0, lo, hi - span)\n',
     '\tx0 = x0\n',
     "备牌跟别的摞不互相盖住", "tests/test_ai_pile.gd"),
    # 窗口不看资源摊开没摊开（一律按收拢那一版的宽度算）：
    # 开局那一趟资源是摊开的，现金片往右长，备牌就压在它上头
    ("scenes/settle_layout.gd",
     '\tif spread:\n\t\tfor p in idles:\n',
     '\tif false:\n\t\tfor p in idles:\n',
     "备牌跟别的摞不互相盖住", "tests/test_ai_pile.gd"),
    # 席位数不封顶：摆不下也照摆，整片撑出窗口。实测 26 种时最外那摞落到
    # x=±15.00（AI_SPREAD_MAX_X 是 12.4，直接出桌），比不分摞还糟
    #
    # 变异的是 cap 的**算式**而不是 _merge_bench_overflow 的调用：
    # 调用拆了的话 cap 照旧算得出来，判据「摞数 ≤ cap」反而会红在别的地方
    ("scenes/settle_layout.gd",
     '\treturn maxi(1, floori((hi - lo) / CardEntity.CARD_SIZE.x) + 1)',
     '\treturn 99',
     "备牌都在桌上", "tests/test_ai_pile.gd"),
    # 超出的那几摞不并：cap 白算，摞数照旧等于卡种数
    ("scenes/settle_layout.gd",
     '\tidles = _merge_bench_overflow(idles, spread)\n',
     '\tidles = idles\n',
     # 关键字里不许带那两个数：判据句子是「摞数 %d ≤ ...摆得下的 %d 个席位」，
     # 改坏之后前一个数从 5 变成 12，写「摞数 5」的话对不上红的那一行
     # （memory: keyword-must-survive-the-fail-branch）
     "这片窗口摆得下的", "tests/test_ai_pile.gd"),
    # ---- 侧边清单认核心卡（并起来那一摞唯一说得出内容的东西）----
    # 清单不列核心卡（退回只数资源和 buff）：并起来那一摞在屏幕上就是
    # 「一张牌 + 什么提示都没有」，摞里另外几种卡既看不见也没处读
    ("scenes/board.gd",
     '\tif core_total >= 2:\n',
     '\tif false:\n',
     "并起来那一摞的清单说全了卡种", "tests/test_ai_pile.gd"),
    # 清单行数不封顶：这一列以摞顶为中心上下摊开，行数一多两头一起探 ——
    # 卡表凑得出 11 行、列高 3.96，北探到 -8.48 出了 AI 区、南探到 -4.52
    # 压进前行的组合
    ("scenes/board.gd",
     '\tif out.size() > SIDE_MAX_ROWS:\n',
     '\tif false:\n',
     "清单这一列留在后行带子里", "tests/test_ai_pile.gd"),
    # ---- 结算到货窗口：产出直接落进左侧带，按每 PILE_CHUNK 张分组 ----
    # 窗口不开 = 退回老路：整批同时出生，_free_spot 对每张都判「锚点空着」，
    # 于是全落在玩家自己的现金堆锚点上、糊成一坨
    ("scenes/settle_layout.gd",
     '\tif not _arr_open:\n\t\treturn _free_spot(anchor, who)',
     '\tif true:\n\t\treturn _free_spot(anchor, who)',
     "落地就在左侧资源带里"),
    # 分组的座次不推进：每张都算第 0 张，一组一席，整批叠死在一个坐标上
    ("scenes/settle_layout.gd",
     '\tvar k: int = int(_arr_count.get(res, 0))\n\t_arr_count[res] = k + 1',
     '\tvar k: int = 0\n\t_arr_count[res] = 0',
     "落地没有两张压在同一个坐标上"),
    # 组基准不进 _arr_taken：第二组挑位置时看不见第一组，两组落一处
    ("scenes/settle_layout.gd",
     '\t\t_arr_base[ck] = base\n\t\t_arr_taken.append(base)',
     '\t\t_arr_base[ck] = base',
     "落地即按每"),
    # 左侧带里的零头不算「本轮要重排的」：新摞绕开它们落到别处，
    # 末尾统一那趟再把两边并起来 —— 整摞又搬一次，就是玩家看到的「跳一下」
    ("scenes/settle_layout.gd",
     '\t\tfor e in _mergeable_left(res):\n\t\t\t_arr_mine[e.uid] = true',
     '\t\tfor e in []:\n\t\t\t_arr_mine[e.uid] = true',
     "零头旁边"),
    # 找空位根本不避让：所有障碍都视而不见，整批全落在锚点上叠死。
    #
    # 落点选在 `_clash_at` 而不是任何一套「告诉它障碍在哪」的机制上（2026-09-01 改）。
    # 原先那条改的是 `_free_spot(anchor, who, _arr_claimed)` 的参数，报了个查无实据的
    # MISS —— 实测**全套 52 文件 3541 断言全绿**。换成去掉 main.gd 里飞入那行
    # `set_meta("dest_pos", to_pos)`，**照样全绿**。
    # 两次都绿是因为这条不变量有两道**互为冗余**的防线：
    #   - `_arr_claimed`：本次结算已许诺出去的落点（AI 那批走这条）
    #   - `dest_pos`：飞行中那批宣告的归宿，`_obstacles` 经 `_rest_pos` 读到（玩家带走这条）
    # 各去一个都还有另一个兜着，**两个一起去掉**才终于红（实测「AI 那批 5 张也各有落点
    # （重合 4 张）」）。所以这不是判据漏，是任何单点变异都到不了它。
    # `_clash_at` 是两套机制汇合的那一点：障碍怎么收集的都不管用了。
    # 顺带说明为什么原先那两条不能留着当「反正是冗余」——
    # 一条什么都验不了的变异比没有更坏：它长期报 MISS，看上去像判据有洞
    ("scenes/settle_layout.gd",
     '\tfor p in blockers:\n'
     '\t\tif absf((p as Vector3).x - spot.x) < 1.3',
     '\tfor p in []:\n'
     '\t\tif absf((p as Vector3).x - spot.x) < 1.3',
     "AI 那批", "tests/test_arrivals.gd"),
    # 【这里原先有一条 `for uid in extra_mine:` → `for uid in []:`，盯「落点不变」。
    #   2026-09-01 撤掉：它什么都验不了，而长期挂着 MISS 会被当成判据有洞。
    #
    #   test_arrivals 那条差分判据（「另一批还在飞时，现金那摞落点不变」）本身是好的
    #   —— 它记着一个真出过的 bug（最南那张 x=-13.0，屏幕上看不到自己的钱）。
    #   问题在于「半空中的牌被判成障碍」这件事在当前代码里有**三层**挡着：
    #     1. `extra_mine`：调用方告诉这一趟「另一趟那批也是本轮要重排的」
    #     2. `dest_pos`：飞行中那批宣告的归宿，`_obstacles` 经 `_rest_pos` 读到
    #     3. `board.rest_pos`：卡还被 board 的移动补间送着时直接返回补间终点
    #   四个候选落点全试过、判据一次都没响（各自实跑，测完复原）：
    #     去掉 extra_mine → 全套 52 文件 3541 断言全绿；
    #     extra_mine + 飞入的 dest_pos 一起去掉 → 「落点不变」仍 OK；
    #     `_obstacles` 里 `if ignore.has(uid)` 整道闸拆掉 → test_arrivals 94/0；
    #     `_stack_arrivals` 开头的 `_cancel_fly(c)` 去掉 → 94/0。
    #   结论：这条不变量没有单点变异到得了，不是判据太松。要给它加变异得先把三层
    #   里的两层同时拆掉，而 mutate_check 一次只改一处 —— 所以留个记录，别再加回来】
    # ---- 余数搬牌要宣告归宿（_move_to_spot / _rest_pos）----
    # 不宣告归宿：_stack_settled 一次跑两趟，第二趟读到第一趟刚送出去那几张的
    # **出发点**，把它们按半路上的坐标重新钉死 —— 一个余数组里 11 张散在
    # x=-11.7..7.3，横穿整张桌子，各自按台阶名次抬到半空
    ("scenes/settle_layout.gd",
     '\t_main._cancel_fly(c)\n\tc.set_meta("dest_pos", spot)',
     '\t_main._cancel_fly(c)',
     "每个余数组都只占一列", "tests/test_arrivals.gd"),
    # 宣告了但读的人不认：_rest_pos 退回实时坐标，等于没宣告
    ("scenes/settle_layout.gd",
     '\tif e.has_meta("dest_pos"):\n\t\treturn e.get_meta("dest_pos")\n\treturn board.rest_pos(e)',
     '\treturn e.global_position',
     "每个余数组都只占一列", "tests/test_arrivals.gd"),
    # 垫高老余数时按实时坐标取座位（_relift_remainders）。
    #
    # 判据是 T12 那条，**不是** T9 的「每个余数组都只占一列」—— 那条查不出来，
    # 而且这两件事的差别本身值得记一笔：一次结算里两趟 _relift_remainders
    # （现金/用户各一趟）都排在两趟 _lay_loose_run 前面，所以它看不见本轮自己
    # 摆的余数，上几轮的又早落定了。实测全表 30 次 _relift 调用，
    # `_rest_pos` 和 `global_position` 的差全是 0.000 —— 这句改坏了根本没人读。
    # 唯一到得了的局面：结算把余数送上 0.3s 补间的路，玩家在补间跑完前典当一张
    # （main._on_pawn 直接调 _stack_arrivals）。T12 就是照这个局面搭的，
    # 故意不 await 补间。改坏之后 4 张余数被按回各自的出发点，横跨 4 列、
    # z 全一样只靠 y 台阶错开
    #
    # 锚点带上那句注释才唯一 —— 同样的两行在 _place_loose_col 里还有一处。
    # 写成 `var at: Vector3 = ...` 而不是 `var at := ...`：c 来自 Dictionary，
    # 是 Variant，`:=` 推不出类型直接 Parse Error —— 那样改出来的是个编译不过的
    # 变异体，什么都没测到（见跑变异那头的 BROKE 分支）
    ("scenes/settle_layout.gd",
     '\t\t\t\t# 读出发点等于把它们按半路上的位置重新钉死，补间白跑\n'
     '\t\t\t\tvar at := _rest_pos(c)',
     '\t\t\t\t# 读出发点等于把它们按半路上的位置重新钉死，补间白跑\n'
     '\t\t\t\tvar at: Vector3 = c.global_position',
     "半路上被典当打断", "tests/test_arrivals.gd"),
    # 续排时把组里老牌的座位按实时坐标取（_place_loose_col）：现金那趟刚把这几张
    # 送上路，读出发点会把它们按半路上的位置重新钉死一遍
    ("scenes/settle_layout.gd",
     '\t\t\t\t# 按半路上的位置重新钉死一遍（见 _move_to_spot 的注释）\n'
     '\t\t\t\tvar at := _rest_pos(c)',
     '\t\t\t\t# 按半路上的位置重新钉死一遍（见 _move_to_spot 的注释）\n'
     '\t\t\t\tvar at: Vector3 = c.global_position',
     "每个余数组都只占一列", "tests/test_arrivals.gd"),
    # ---- 开局两边形态一致（AI 摊开，见 settle_layout.gd 的 _spread_ai_res）----
    # 永不摊开：AI 的资源又挤成一坨，玩家摊成三列、AI 一摞 —— 就是那个 bug 的原样
    ("scenes/settle_layout.gd",
     '\tif not no_combos:\n\t\treturn false',
     '\tif true:\n\t\treturn false',
     "AI 的列数和玩家一样", "tests/test_ai_pile.gd"),
    # 摊开了但台阶步长按收拢那档给：列数、每列张数全对，牌却前后叠死，
    # 看不出张数 —— 光验「分了几列」验不到这一层
    ("scenes/settle_layout.gd",
     '\treturn minf(Board.STACK_GAP.z, (south - AI_SPREAD_Z0) / float(n - 1))',
     '\treturn Board.COMPACT_GAP.z',
     "一列对一列地照玩家的排布来", "tests/test_ai_pile.gd"),
    # 换列的张数不照玩家侧：4 张就换一列，开局那点现金（`_game.start_cash`）
    # 于是比玩家侧多摊出几列 —— 玩家侧是每 PLAYER_PILE_PER_COL 张一列。
    # 每列内部照样是摊开的台阶（形态那条过），错的只是「不是同一个排布」
    ("scenes/settle_layout.gd",
     'float(i / PLAYER_PILE_PER_COL) * PLAYER_PILE_COL_PITCH',
     'float(i / 4) * PLAYER_PILE_COL_PITCH',
     "AI 的列数和玩家一样", "tests/test_ai_pile.gd"),
    # ---- 产出音效：每张牌落地各响一声 drop ----
    # 落地不响：产出就成了没有声音的事
    ("scenes/main.gd",
     '\ttw.parallel().tween_callback(func() -> void: sfx.play("produce_land")) \\\n\t\t.set_delay(stagger + SPAWN_FLY_TIME)',
     '\tpass',
     "声 drop", "tests/test_arrivals.gd"),
    # 音量和手放牌落桌不一致：同一件事响两种响度。
    # 这条现在改的是配置而不是代码 —— 响度搬进 ui.json:sfx.actions 之后，
    # 「产出和落桌不一样响」这个坏法只能从那张表上发生
    ("data/ui.json",
     '"produce_land": {\n        "sound": "drop",\n        "db": -8.0\n      }',
     '"produce_land": {\n        "sound": "drop",\n        "db": -3.0\n      }',
     "落地音量和手放牌落桌一致", "tests/test_arrivals.gd"),
    # 产出改用自己的音效：听起来不再是「牌落到桌上」，而且整组一声那套老毛病
    # 会从配置这一侧偷偷回来 —— 代码一个字都不用改
    ("data/ui.json",
     '"produce_land": {\n        "sound": "drop",\n        "db": -8.0\n      }',
     '"produce_land": {\n        "sound": "complete",\n        "db": -8.0\n      }',
     "produce_land 和 card_drop 同 wav 同响度", "tests/test_arrivals.gd"),
    # ---- 产出起飞是错开的，不是整批同时弹出去 ----
    # 错开时长归零 = 十四张一起起飞，也就是那个「整批跳过去」的老毛病
    # （T9 上面那段写了它的来历）。这条本来没人盯着：判据在，变异表里缺
    ("scenes/main.gd",
     'const SPAWN_FLY_SPREAD := 0.3',
     'const SPAWN_FLY_SPREAD := 0.0',
     "起飞是错开的", "tests/test_arrivals.gd"),
    # ---- 回合编排收口后的三个共用原语（engine/game_state.gd）----
    # 这三个没有任何测试直接点名，全靠 Settle/模拟器 间接走到。收口把 11+5+2 处
    # 重复合成一处，好处是改一处全跟着变，坏处是错一处也全跟着错 —— 所以每个都得
    # 有变异盯着，否则「就一份实现」反倒成了没人验的单点
    # 打自己：攻击该扣对方的卡
    ("engine/game_state.gd",
     'static func opponent(who: String) -> String:\n\treturn PLAYER if who == AI else AI',
     'static func opponent(who: String) -> String:\n\treturn who',
     # 关键字挑不带数字、也不带定价口径的那半句：原先写「外卖核心 4 一减到底」，
     # 后来外卖配方量从 4 改到 5，断言文案跟着变、这条就漂成 MISS 了；
     # 后来配方核心从「一减到底」改成 1 点/张，「一减到底」这半句又没了；
     # 再后来「一次只打一个组合」改了测试1 的账，「弹药没付」那半句也没了 ——
     # 三次都是变异明明被抓住、红的是同一批断言，只是关键字对不上。
     # 这次索性挑测试7 那条清零即胜：打自己的话对手一张不掉，胜负判定跟着塌，
     # 而那句文案里既没有数字也没有定价口径，改口径改配方量都碰不到它
     "立即获胜"),
    # 两方都用先手身份行动 → 后手那一方整局没动过（AI 组不出任何组合）
    ("engine/game_state.gd",
     '\tvar first := action_first()\n\treturn [first, opponent(first)]',
     '\tvar first := action_first()\n\treturn [first, first]',
     # 同上：别把「两边」写进关键字。核心改成 1 点/张之后，
     # 玩家那 5 点会先打破 AI 的攻击组合 → AI 装不上弹 → 只有一边的组作废
     "产出组合被拆散作废"),
    # 不筛点数：点不起的靶也照样报上去
    # 关键字盯测试6：余点作废那一条从测试1挪过去了（弹药规则下测试1的牌桌
    # 留不出「1 点无处可去」的局面，见 tests/test_engine.gd 的头注释）
    ("engine/game_state.gd",
     '\t\tif target_affordable(t, pools):\n\t\t\tout.append(t)',
     '\t\tout.append(t)',
     "玩家现金池一个可点目标都没有"),
    # 典当自杀护栏拆掉：能把最后一个用户当掉（=当场判负）
    ("engine/game_state.gd",
     '\tif pawn_would_zero_user(who, uids):\n\t\treturn { "ok": false, "reason": REASON_PAWN_ZERO_USER }',
     '\tpass',
     "当掉最后一个用户被引擎拦下", "tests/test_pawn.gd"),
    # 护栏改成「归零才拦」（差一错位：resource_count - lost < 0 而不是 <= 0）
    ("engine/game_state.gd",
     '\treturn resource_count(who, CardDB.RES_USER) - pawn_users_lost(who, uids) <= 0',
     '\treturn resource_count(who, CardDB.RES_USER) - pawn_users_lost(who, uids) < 0',
     "当掉最后一个用户被引擎拦下", "tests/test_pawn.gd"),
    # ---- 裂变鬼才补满（balance.md §「Buff 卡」）----
    # 门槛从 1 张抬到 2 张：大配方立刻退回旧翻倍手感
    ("engine/combo_rules.gd",
     '\tif user_n < 1:\n\t\treturn false',
     '\tif user_n < 2:\n\t\treturn false',
     "带裂变时 1 张用户就补满", "tests/test_fission_fill.gd"),
    # 不看有没有裂变：任意用户配方组自动补满（凭空产出）
    ("engine/combo_rules.gd",
     '\tif not user_fill:\n\t\treturn false',
     '\tpass',
     "不带裂变时 1 张用户凑不出", "tests/test_fission_fill.gd"),
    # 不看配方资源：裂变顺手把现金配方也补满
    ("engine/combo_rules.gd",
     '\tif ldef["recipe_res"] != CardDB.RES_USER:\n\t\treturn false',
     '\tpass',
     "现金配方里混用户卡 + 裂变 → 仍不成立", "tests/test_fission_fill.gd"),
    # 本来就够的组也标补满：balance.md §「Buff 卡」 的防御失效判定会连坐到正常凑满的组
    ("engine/combo_rules.gd",
     '\treturn user_n < int(ldef["recipe_n"])',
     '\treturn true',
     "别连坐防御 Buff 失效判定", "tests/test_fission_fill.gd"),
    # ---- 弹药自付 + 防御入组立即保护（README.md §「2.6 组合与结算」 / balance.md §「Buff 卡」）----
    # 装弹不扣款：攻击组合白拿弹药
    ("engine/game_state.gd",
     '\tfor u in pay:\n\t\tremove_card(who, u)\n\tlog_fmt("⚔ %s「%s」装弹',
     '\tfor u in pay:\n\t\tpass\n\tlog_fmt("⚔ %s「%s」装弹',
     "arm_attacks 扣掉配方那", "tests/test_ammo_arming.gd"),
    # 弹药自尽护栏放宽成「负数才拦」：掏空自己也能开一炮
    ("engine/game_state.gd",
     '\tvar suicide := resource_count(who, CardDB.RES_CASH) - need <= 0',
     '\tvar suicide := resource_count(who, CardDB.RES_CASH) - need < 0',
     "装弹被护栏拦下，0 点", "tests/test_ammo_arming.gd"),
    # 重引入装机前提：新牌不再写 armed_round，首次入组便失去即时保护。
    ("engine/game_state.gd",
     '\treturn def.get("kind") == CardDB.KIND_BUFF and str(def.get("buff_type", "")) in [',
     '\treturn c.has("armed_round") and def.get("kind") == CardDB.KIND_BUFF and str(def.get("buff_type", "")) in [',
     "编组当回合", "tests/test_ammo_arming.gd"),
    # 把持续保护改成只在第一回合有效：下一回合与重注册都丢掉保护。
    ("engine/game_state.gd",
     '\treturn def.get("kind") == CardDB.KIND_BUFF and str(def.get("buff_type", "")) in [',
     '\treturn round_num == 1 and def.get("kind") == CardDB.KIND_BUFF and str(def.get("buff_type", "")) in [',
     "下一回合仍有", "tests/test_ammo_arming.gd"),
    # 生产配方不扣款：现金配方白吃
    ("engine/settle.gd",
     '\tfor u in pay:\n\t\tstate.remove_card(owner, u)',
     '\tfor u in pay:\n\t\tpass',
     "张现金被吃掉", "tests/test_ammo_arming.gd"),
    # HUD 不挂归零预警：屏幕上只剩「资金 10（本回合待付 10）」，读起来像刚好
    # 付得起，而结算时它一分钱都产不出。**这就是报障时玩家看到的那个读数**
    ("scenes/main.gd",
     '\t\tif state.resource_count(my_seat, CardDB.RES_CASH) \\\n'
     '\t\t\t\t+ state.pending_cash_income(my_seat, piles) - due <= 0:\n'
     '\t\t\tcash_txt += "⚠ 付完归零，整组会作废"',
     '\t\tpass',
     "挂归零预警", "tests/test_consume_hud.gd"),
    # 归零护栏放宽一格：付到正好 0 也放行 —— 而现金归零就是败北条件，
    # 于是「产出到账」和「当场判负」同一次结算里一起发生
    ("engine/settle.gd",
     '\tif state.resource_count(owner, CardDB.RES_CASH) - need <= 0:',
     '\tif state.resource_count(owner, CardDB.RES_CASH) - need < 0:',
     "会让资金归零", "tests/test_recipe_pay_order.gd"),
    # 结算不分拨：进账的组合和付款的组合按编组次序混着结。
    # 同样两摞牌，只因为玩家先摞了哪一摞，一摞活一摞废 ——
    # 且**只在混摞时现形**，单摞的判据一条都不红
    ("engine/settle.gd",
     '\t\tfor pays_cash in [false, true]:\n'
     '\t\t\tfor combo in state.combos:\n'
     '\t\t\t\tif combo["owner"] != owner or combo["eval"].get("type") == "attack":\n'
     '\t\t\t\t\tcontinue\n'
     '\t\t\t\tif (int(combo["eval"].get("recipe_pay_n", 0)) > 0) == pays_cash:\n'
     '\t\t\t\t\tout.append(combo)',
     '\t\tfor combo in state.combos:\n'
     '\t\t\tif combo["owner"] != owner or combo["eval"].get("type") == "attack":\n'
     '\t\t\t\tcontinue\n'
     '\t\t\tout.append(combo)',
     "编组次序不再决定生死", "tests/test_recipe_pay_order.gd"),
    # 用户配方也填 recipe_pay_n：席位被当成成本（组里没现金 → 整组付不起）
    ("engine/combo_rules.gd",
     '\t\tif ldef["recipe_res"] == CardDB.RES_CASH:\n\t\t\tresult["recipe_pay_n"] = int(ldef["recipe_n"])',
     '\t\tresult["recipe_pay_n"] = int(ldef["recipe_n"])',
     "用户配方不该触发付款失败", "tests/test_ammo_arming.gd"),
    # 数据/代码漂移：buff_type 退回 V1.0 的 user_x2。三处消费方一处都不认，
    # 于是「卡不生效 + C 位记号错 + 悬停只剩典当+3」同时出现且**零报错** ——
    # 这是真实误报过一次的形态（旧 cards.json 落在可执行文件旁边）
    ("data/cards.json",
     '"buff_type": "user_fill"',
     '"buff_type": "user_x2"',
     "代码不认识的 buff_type", "tests/test_fission_fill.gd"),
    # 996（output_x2）翻倍 —— 全套测试原先一条都没碰过这条规则。
    # 只对现金线生效：**这正是用户报障的形状**（「996 没让用户数产出翻倍」）。
    # 产现金的核心 5 张、产用户的 4 张，实现一旦按 output_res 分岔，先坏的是用户线
    ("engine/combo_rules.gd",
     '\t\t\tresult["output_n"] = ldef["output_n"] * (CardDB.buff_mult("output_x2") if output_x2 else 1)',
     '\t\t\tresult["output_n"] = ldef["output_n"] * (CardDB.buff_mult("output_x2") if output_x2 and ldef["output_res"] == CardDB.RES_CASH else 1)',
     # 关键词停在插值之前：判据那行是「带 996 产出翻 %d 倍」，倍数取自
     # `_game.buff_mult.output_x2`。写成「产出翻倍」会跨过 %d，
     # 运行时精确子串必不命中 —— 变异明明红了 33 条却报 MISS（实测过一次）
     "带 996 产出翻", "tests/test_buff_output_x2.gd"),
    # 结算按卡面值发牌而不是按组合快照：规则层和编组层照样绿，
    # 到账张数却少一半（eval 是对的，发牌绕过了它）
    ("engine/settle.gd",
     '\t\t\tfor i in eval["output_n"]:',
     '\t\t\tfor i in CardDB.get_def(eval["leader"])["output_n"]:',
     "到账", "tests/test_buff_output_x2.gd"),
    # 卡面 C 位不跟组翻倍：玩家在结算之前读不到翻倍生效了。
    # 三条各堵一处：规则不报倍数 / Board 不推 / 离组不还原
    ("engine/combo_rules.gd",
     '\t\t\t"output_x2": out["output"] = CardDB.buff_mult(bt)',
     '\t\t\t"output_x2": pass',
     "卡面", "tests/test_effect_badge_mult.gd"),
    ("scenes/board.gd",
     '\t_push_recipe_progress(g, _group_progress(g), eval["valid"])\n\t_push_effect_mult(g)',
     '\t_push_recipe_progress(g, _group_progress(g), eval["valid"])',
     "卡面", "tests/test_effect_badge_mult.gd"),
    ("scenes/board.gd",
     '\tif c.has_effect_badge():\n\t\tc.set_effect_mult(1)',
     '\tpass',
     "退回", "tests/test_effect_badge_mult.gd"),
    # 两条乘数串台：产出卡吃 attack_x2 / 攻击卡吃 output_x2
    ("scenes/board.gd",
     '\t\telif k == CardDB.KIND_ATTACK:\n\t\t\tc.set_effect_mult(int(mult["attack"]))',
     '\t\telif k == CardDB.KIND_ATTACK:\n\t\t\tc.set_effect_mult(int(mult["output"]))',
     "攻击量", "tests/test_effect_badge_mult.gd"),
    # 卡面倍数算了但没乘上去
    ("scenes/card.gd",
     '\t_effect_label.text = _effect_mark + str(_effect_base_n * m)',
     '\t_effect_label.text = _effect_mark + str(_effect_base_n)',
     "卡面", "tests/test_effect_badge_mult.gd"),

    # ============ 联网：两条路径必须同态（README.md §「3. 文件目录结构」）============
    # 这一段的目标不是「网络能跑」，是**不分叉**：单机局和联网局走同一条意图
    # 管道，末态哈希必须相等。分叉的形态一律是静默的 —— 规则在一条路上修了，
    # 另一条上漏了，没人报错，只有一局打出来不一样。
    # 第 5 项都写全了：net/、engine/phase_machine.gd、engine/state_codec.gd
    # 都不在 TEST_FOR 里，省略就会退到 test_engine.gd（跑得过，等于没测）

    # 结算次序：finalize 提到 produce 之前。Settle.run 和 Transport.run_round
    # 都是「先产出再收尾」，房间要是反过来，产出卡就赶不上这一轮收尾
    ("net/room.gd",
     '''	if state.winner == "":
		var n: int = applier.production_count()
		for i in n:
			var r: Dictionary = applier.apply(Intent.produce(i))
			out.append(_applied(r))
	var fin: Dictionary = applier.apply(Intent.finalize())
	out.append(_applied(fin))''',
     '''	var fin: Dictionary = applier.apply(Intent.finalize())
	out.append(_applied(fin))
	if state.winner == "":
		var n: int = applier.production_count()
		for i in n:
			var r: Dictionary = applier.apply(Intent.produce(i))
			out.append(_applied(r))''',
     "含攻击+产出的一整回合", "tests/test_net_parity.gd"),
    # 房间不发 next_round：联网局卡在第一回合，而单机局进了第二回合
    ("net/room.gd",
     '''	var nr: Dictionary = applier.apply(Intent.next_round())
	out.append(_applied(nr))''',
     '''	var nr: Dictionary = { "ok": true }
	out.append(_applied(nr))''',
     "第二回合起点一致", "tests/test_net_parity.gd"),
    # 次序闸门不判「轮不轮到你」。PhaseMachine 管次序、IntentApply 管规则，
    # 这一条塌了，谁都能在对手回合里行动，而规则层看不出毛病
    ("engine/phase_machine.gd",
     '''	if seat != actor:
		return Intent.err("not_your_turn", "现在轮到 %s 行动" % actor)''',
     '''	if false:
		return Intent.err("not_your_turn", "现在轮到 %s 行动" % actor)''',
     "对方回合不能买卡", "tests/test_net_parity.gd"),
    # 落地不带 from_seat：意图里的 seat 字段就成了「谁都能填」的自述，
    # 一条连接可以替对手出牌
    ("net/room.gd",
     "	var r: Dictionary = applier.apply(it, seat)",
     "	var r: Dictionary = applier.apply(it)",
     "冒充座位被拒", "tests/test_net_parity.gd"),
    # 快照丢掉旧 armed_round：破坏历史快照字段往返；当前即时保护不依赖此字段。
    ("engine/state_codec.gd",
     '''	if c.has("armed_round"):
		out["armed_round"] = int(c["armed_round"])''',
     "	pass",
     "armed_round 跟着快照走", "tests/test_net_parity.gd"),
    # 还原不接随机流位置：重连之后两边刷出不同的公共区 —— 状态是
    # f(种子, 意图序列)，随机流的**位置**也是状态的一部分
    ("engine/game_state.gd",
     '''	if d.has("state"):
		_rng.state = int(str(d["state"]))''',
     '''	if false:
		_rng.state = int(str(d["state"]))''',
     "还原后随机流接上", "tests/test_net_parity.gd"),
    # 哈希不排键序：字典键序在 GDScript 里按插入顺序，经引擎组装的状态和
    # 经 JSON 还原的状态键序不同 —— 于是「同一个状态」永远哈希不等，
    # 整套同态判据从此只会报假分叉
    ("engine/state_codec.gd",
     '''			var keys: Array = (v as Dictionary).keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))''',
     '''			var keys: Array = (v as Dictionary).keys()''',
     "过一趟 JSON 再还原", "tests/test_net_parity.gd"),
    # 装弹不给 seq 编号：广播序号跳号，客户端没法判「我是不是漏了一条」
    # （原先这条改的是「装弹那一步不给 seq 编号」。seq 自增后来被收进 _applied，
    #  锚点改成「装弹不广播」—— 同一个后果：客户端漏掉一条，序号跟着跳）
    ("net/room.gd",
     '''	var r: Dictionary = applier.apply(Intent.arm_attacks(phase.actor))
	out.append(_applied(r))''',
     '''	var r: Dictionary = applier.apply(Intent.arm_attacks(phase.actor))''',
     # 判据不是「连号」而是「广播流里有 arm_attacks」：漏播时 seq 自增也跟着
     # 不发生（两件事都在 _applied 里），剩下那些照旧连号 —— 连号对漏播是瞎的
     "广播流里有房间自己驱动的 arm_attacks", "tests/test_net_replay.gd"),
    # 房间在转发之外偷偷动了状态：重放（裸引擎，同种子同意图）就追不上。
    # 这一条钉的是「网络层只搬意图，不改规则」
    ("net/room.gd",
     '''	var out: Array = [_applied(r)]
	out.append_array(_advance(seat, op))''',
     '''	var out: Array = [_applied(r)]
	state.add_card(seat, "cash")
	out.append_array(_advance(seat, op))''',
     "重放末态一致", "tests/test_net_replay.gd"),
    # JSON 的数字全是 double，uid 不过 ints() 就成了 float。
    # **末态哈希抓不到这条**：canon 把整值 float 印成整数（那是故意的，
    # 不然经 JSON 还原的状态永远哈希不等），GDScript 里 3 == 3.0 也是真，
    # find_card 照样找得到 —— 它要潜到「拿 uid 当字典键」的地方才炸。
    # 所以判据是 test_net_replay 的 T6，直接判 typeof == TYPE_INT
    ("engine/intent.gd",
     '''static func ints(a) -> Array:''',
     '''static func ints(a) -> Array:
	return a as Array''',
     "uids 全是 int", "tests/test_net_replay.gd"),
    ("engine/intent.gd",
     '''		out["uids"] = ints(d["uids"])''',
     '''		out["uids"] = d["uids"] as Array''',
     "pawn 的 uids 是 int", "tests/test_net_replay.gd"),
    # 哈希把数组也排序：卡序就不参与哈希了。可卡序是玩法 ——
    # 付款取 pay.slice(0, price)、护盾名额取前 N 个 uid，
    # 两台机器上卡序不同就是两局不同的牌
    ("engine/state_codec.gd",
     '''		TYPE_ARRAY:
			var items: Array = []
			for e in v:
				items.append(canon(e))
			return "[" + ",".join(items) + "]"''',
     '''		TYPE_ARRAY:
			var items: Array = []
			for e in v:
				items.append(canon(e))
			items.sort()
			return "[" + ",".join(items) + "]"''',
     "换了卡序哈希就变", "tests/test_net_replay.gd"),

    # ---------------- 真 WebSocket：net/net_transport.gd 整个文件 ----------------
    # 上面那批是**无端口**的（直接喂 NetRoom.handle_intent），碰不到传输层。
    # 这一批全由 tests/test_net_socket.gd 抓 —— 它真开一个端口。
    # 九条都实跑确认过红（mutation-hint-must-be-run）。
    # 其中两条最初是 MISS，补了观察点才红，那两处各自注明。

    # 握手不发 join：连上了但服务器不知道你要进哪个房间，永远等不到 seated
    ("net/net_transport.gd",
     '''				_send(Protocol.join(room, StateCodec.table_hash(), resume_token))''',
     '''				pass''',
     "双方都入座了", "tests/test_net_socket.gd"),
    # _next_frame 不 poll：submit 挂在这个循环上，唤醒它的回音只有 poll 才收得到。
    # 场景层忘了调 poll 时的表现是按钮全灰，看起来像网络问题。
    # **这条一开始是 MISS**：测试的 _keep_pumping 把正在 submit 的那个客户端
    # 也一起 poll 了，等于替被测代码干了活。改成只摇服务器 + 旁观那个才红
    ("net/net_transport.gd",
     '''		await (loop as SceneTree).process_frame
	poll()''',
     '''		await (loop as SceneTree).process_frame''',
     "submit 自己泵帧", "tests/test_net_socket.gd"),
    # submit 不看 _pending：两条意图同时在飞。第二次点击会在几百毫秒后
    # 突然生效，手感上像误触 —— 而且两条回音谁配谁没法认
    ("net/net_transport.gd",
     '''	if _pending:
		# 上一条还在飞。''',
     '''	if false:
		# 上一条还在飞。''',
     "上一条在飞时再发被拒", "tests/test_net_socket.gd"),
    # 收包不分流：WebSocketMultiplayerPeer 握手完先塞一个 4 字节 peer id 过来，
    # 不认它就每连一次刷一屏 push_warning，真解不开的包埋在那一屏里没人看。
    # **这条一开始也是 MISS**：peer_id 写了没人读，没有观察点。
    # T1 现在判 peer_id != 0 —— 那是这个分流唯一看得见的地方
    ("net/net_transport.gd",
     '''	if pkt.size() == 4:
		peer_id = pkt.decode_s32(0)
		return''',
     '''	if false:
		peer_id = pkt.decode_s32(0)
		return''',
     "peer id 握手包被认出来", "tests/test_net_socket.gd"),
    # _on_applied 不看座位：对手那条落地被当成自己的回音吞掉，
    # 于是自己这边照对手的结果去演 —— 两边从此画的不是同一局，且不报错
    # （这条的锚点跟着 _on_applied → _inbox/_drain/_apply 的拆分搬过一次。
    #  判的还是同一件事：回音要按座位认，不然对手那条被当成自己的吞掉）
    ("net/net_transport.gd",
     '''	if _pending and str(r.get("seat", "")) == my_seat and Intent.is_client_op(str(r.get("op", ""))):''',
     '''	if _pending:''',
     "submit 拿回来的是自己那条", "tests/test_net_socket.gd"),
    # 拒连不带原因：客户端只知道「连不上」。而「卡表不一致」和「端口写错了」
    # 要玩家做的事完全不同。原因**必须走关闭帧** —— 数据帧会随关闭一起丢
    ("net/server.gd",
     '''		p.close(int(Protocol.CLOSE_CODES.get(code, 4000)),
			Protocol.clip_reason(reason))''',
     '''		p.close()''',
     "拒连给了原因", "tests/test_net_socket.gd"),
    # 客户端消息白名单形同虚设：一个改过的客户端能给对手发假 seated，
    # 对手照着画，两边从此看到不同的牌
    ("net/protocol.gd",
     '''	return CLIENT_MSGS.has(t)''',
     '''	return true''',
     "客户端伪造 seated 被拒", "tests/test_net_socket.gd"),
    # 关闭原因不截断：超 123 字节 close() 会**静默什么都不做**，
    # 连接挂在 OPEN 上不断 —— 玩家看到的是「连上了但什么也没发生」
    ("net/protocol.gd",
     '''	if text.to_utf8_buffer().size() <= limit:
		return text''',
     '''	if true:
		return text''',
     "截过的原因塞得进关闭帧", "tests/test_net_socket.gd"),
    # 结果里的 uid 不掰回 int：JSON 的数字全是 double。60 == 60.0 为真、
    # find_card 照样找得到、末态哈希也不变 —— 它只炸在拿 uid 当字典键的地方。
    # main.gd 的 _commit_buy 是 entities.has(u)，拖拽买是 paid.has(c.uid)：
    # 联网局里付掉的现金卡不被吸走、还被当成多付的退回来，单机局完全正常
    ("net/protocol.gd",
     '''			out["result"] = restore_uids(d["result"])''',
     '''			out["result"] = d["result"]''',
     "整个结果里没有 float uid", "tests/test_net_socket.gd"),

    # ==== 联网：对手侧画面只能来自 pipe.applied（README.md §「3. 文件目录结构」）====
    # 改造前，对手侧的每一张卡都是**驱动对手的那段代码**顺手画的（_ai_buy_once 自己
    # spawn、_ai_pawn_relief 自己飞走）。联网局里对手是人，没有那段代码在跑 ——
    # 对手侧就什么都不画，而且不报错。这一段钉的是「画面只认落地结果」。
    # 登记之前这 11 条**全是 MISS**：32 个测试文件里没有一个观察对手侧的画面，
    # 把渲染整段删掉也全绿（memory: green-mutation-means-no-observer）。
    # 第 5 项都写全了：scenes/main.gd 在 TEST_FOR 里指向 test_arrivals.gd，
    # 省略就会去跑一个根本不看对手画面的测试（跑得过，等于没测）

    # 总闸：不连 applied，对手侧一张卡都不画
    ("scenes/main.gd",
     '''	pipe.applied.connect(_on_intent_applied)''',
     '''	pass''',
     "对手买的卡出现在场上", "tests/test_foe_render.gd"),
    # 买：新卡不落地、付掉的现金不撤、公共区那一格不摘
    ("scenes/main.gd",
     '''		Intent.OP_BUY:
			_render_foe_buy(r)''',
     '''		Intent.OP_BUY:
			pass''',
     "新卡的 uid 进了 entities", "tests/test_foe_render.gd"),
    # 落位这一条**没有登记变异**，理由记在这儿免得下次有人再试一遍：
    # 对手侧的落位是**双重决定**的 —— _render_foe_buy 先按 _unit_anchor 摆一次,
    # 两行之后 _layout_ai_idle() 又把对手所有牌整片重排一次。
    # 把 _free_spot 那两个 foe_seat 换成 my_seat（实测）：z = -7.49，
    # 还在对手那半边，因为重排那一下把它救回来了。
    # 反过来只坏重排、不坏 spawn 也一样：spawn 那个位置本来就是对的。
    # 两条路各自都能把牌放对，单点变异破不了 —— 于是
    # test_foe_render 里那条「落在他那半边」是端到端的回归护栏，
    # 不是某一处实现的判据。别为它编一条 MISS 挂在表上
    # 典当：卡从状态里没了，场上还摆着
    ("scenes/main.gd",
     '''		Intent.OP_PAWN:
			_render_foe_pawn(r)''',
     '''		Intent.OP_PAWN:
			pass''',
     "对手典当掉的卡从场上消失", "tests/test_foe_render.gd"),
    # 编组：对手区的卡不收拢成摞
    ("scenes/main.gd",
     '''		Intent.OP_COMBO:
			_render_foe_combo(r)''',
     '''		Intent.OP_COMBO:
			pass''',
     "对手编的组收拢成摞", "tests/test_foe_render.gd"),
    # 攻击：被打掉的卡留在场上
    ("scenes/main.gd",
     '''		Intent.OP_ATTACK:
			_render_foe_attack(r)''',
     '''		Intent.OP_ATTACK:
			pass''',
     "对手打掉的卡从场上消失", "tests/test_foe_render.gd"),
    # 座位过滤失效：我自己那条也被当对手的画。后果是**在信号回调里出脚本错误**
    # （拿我的 uid 去 find_card(foe_seat, …) 得空字典），而回调里的脚本错误不会
    # 让调用方失败 —— 所以判据落在 is_foe_client_op 本身，不落在它的副作用上
    ("scenes/main.gd",
     '''	return str(r.get("seat", "")) == foe_seat and Intent.is_client_op(str(r.get("op", "")))''',
     '''	return true''',
     "我自己的 buy **不**归对手侧渲染管", "tests/test_foe_render.gd"),
    # 不分客户端操作：produce 的 seat 就是组合主人，可能正是对手 ——
    # 结算演出（_resolve_combo_visual）已经在演了，再画一遍是双份
    ("scenes/main.gd",
     '''	return str(r.get("seat", "")) == foe_seat and Intent.is_client_op(str(r.get("op", "")))''',
     '''	return str(r.get("seat", "")) == foe_seat''',
     "produce 不归对手侧渲染管", "tests/test_foe_render.gd"),
    # 判定接反：只画自己的，对手侧全空
    ("scenes/main.gd",
     '''	if not is_foe_client_op(r):
		return''',
     '''	if is_foe_client_op(r):
		return''',
     "公共区那一格被摘掉", "tests/test_foe_render.gd"),
    # 落地不公告：旧组卡器 拿着 applier 直接 apply，不过 submit。
    # landed 是这些意图对表现层唯一的可见途径 —— 不发就退回改造前的状态：
    # 对手侧只有「驱动那段代码顺手画的」才看得见
    # （锚点只取 if 那一行：录像功能在 emit 之间插了 landed_intent，
    #   把两行连在一起锚会成孤儿。这里要判的是「成功了就公告」这件事本身）
    ("engine/intent_apply.gd",
     '''	if r.get("ok", false):''',
     '''	if false:''',
     "AI 内部直接落地的编组也画得出来", "tests/test_foe_render.gd"),
    # 去重失效：submit 成功的那条已经被 _on_landed 广播过了（landed 同步发），
    # 再 _publish 一遍表现层就收两遍 —— 公共区被摘两格、seq 也多涨一个
    ("engine/local_transport.gd",
     '''	if r.has("seq"):
		return r''',
     '''	if false:
		return r''',
     "公共区那一格被摘掉", "tests/test_foe_render.gd"),
    # 阶段名不再转引：一边 "attacking" 一边 "attack"，界面永远等不到自己的回合
    ("scenes/main.gd",
     '''const PHASE_ATTACK := PhaseMachine.ATTACK''',
     '''const PHASE_ATTACK := "attacking"''',
     "是同一个值", "tests/test_foe_render.gd"),

    # ======== 联网：拖拽广播 + 租约（scenes/main.gd 的拖拽广播与租约处理）========
    # 转发那一段（客户端 drag → 服务器 → 对手 foe_drag）test_net_socket 的 T6
    # 早就测过，但**两头都没有观察点**：没人调 send_drag，foe_drag 也没有听众。
    # 「转发通了而一张牌都不动」在改造前是全绿的。这一段钉的是两头。
    # 第 5 项都写全了：scenes/main.gd / scenes/board.gd / scenes/settle_layout.gd
    # 在 TEST_FOR 里都不指向这个文件，省略就会去跑不看拖拽的测试
    # 发送端总闸：不连 board.drag_broadcast，对手侧一帧都收不到
    ("scenes/main.gd",
     '''	board.drag_broadcast.connect(_on_drag_broadcast)''',
     '''	pass''',
     "拎起来这一下发到了 net 层", "tests/test_foe_drag.gd"),
    # attach_net 漏掉哪一件都不报错，症状各不相同（见那个函数的注释）：
    # 只设 _net → 对手看得到我拖牌，我看不到他的
    ("scenes/main.gd",
     '''	if not net.foe_drag.is_connected(on_foe_drag):
		net.foe_drag.connect(on_foe_drag)''',
     '''	pass''',
     # 判据只能是 T7 那条走信号的：T3~T5 直接调 on_foe_drag，
     # 绕过这条连接，改坏了它们照样全绿
     "net 层那个信号真的接到了 on_foe_drag 上", "tests/test_foe_drag.gd"),
    # 只连信号不设 _net → 反过来：我看得到他的，他看不到我的
    ("scenes/main.gd",
     '''func attach_net(net: NetTransport) -> void:
	_net = net''',
     '''func attach_net(net: NetTransport) -> void:
	pass''',
     "拎起来这一下发到了 net 层", "tests/test_foe_drag.gd"),
    # 忘了 set_foe_remote → 本地还在驱动 AI 替对手行动（两边各打一局）
    ("scenes/main.gd",
     '''	_net = net
	set_foe_remote(true)''',
     '''	_net = net''',
     "本地不再驱动对手", "tests/test_foe_drag.gd"),
    # 松手那一帧不往下发：对手侧的牌要等满 2 秒超时才落下
    ("scenes/main.gd",
     '''	_net.send_drag(p["phase"], p["uids"], p["u"], p["v"])''',
     '''	if p["phase"] != Protocol.DRAG_CANCEL:
		_net.send_drag(p["phase"], p["uids"], p["u"], p["v"])''',
     "松手这一下也发到了 net 层", "tests/test_foe_drag.gd"),
    # 发送端字段写反：u/v 互换。两侧都不报错，症状是对手屏幕上我的牌沿错的轴跑
    ("scenes/main.gd",
     '''	return { "phase": phase_name, "uids": uids, "u": uv.x, "v": uv.y }''',
     '''	return { "phase": phase_name, "uids": uids, "u": uv.y, "v": uv.x }''',
     "拖到左边 → u<0.5", "tests/test_foe_drag.gd"),
    # 归一化 z 用了近侧的区间：牌画到我这半边来（-0.6 那种落在购牌区上）
    ("scenes/main.gd",
     '''		lerpf(DRAG_FAR_Z.x, DRAG_FAR_Z.y, clampf(v, 0.0, 1.0)))''',
     '''		lerpf(DRAG_NEAR_Z.x, DRAG_NEAR_Z.y, clampf(v, 0.0, 1.0)))''',
     "不落在我这半边", "tests/test_foe_drag.gd"),
    # v 接反：对手往前推，我看到的是往后退
    ("scenes/main.gd",
     '''		lerpf(DRAG_FAR_Z.x, DRAG_FAR_Z.y, clampf(v, 0.0, 1.0)))''',
     '''		lerpf(DRAG_FAR_Z.y, DRAG_FAR_Z.x, clampf(v, 0.0, 1.0)))''',
     "v 越大越靠近购牌区", "tests/test_foe_drag.gd"),
    # 不钳制：拖过购牌区时发出 v<0，对手那边的牌飞出桌面
    ("scenes/main.gd",
     '''		clampf(inverse_lerp(DRAG_NEAR_Z.x, DRAG_NEAR_Z.y, at.z), 0.0, 1.0))''',
     '''		inverse_lerp(DRAG_NEAR_Z.x, DRAG_NEAR_Z.y, at.z))''',
     "v 被钳在 [0,1]", "tests/test_foe_drag.gd"),
    # 收不到 pickup：租约不建，布局照旧抢着摆牌（牌抽搐）
    ("scenes/main.gd",
     '''		Protocol.DRAG_PICKUP:
			_lease_foe_cards(msg.get("uids", []))''',
     '''		Protocol.DRAG_PICKUP:
			pass''',
     "收到 pickup 之后这张牌归网络驱动", "tests/test_foe_drag.gd"),
    # 收不到 move：牌停在拎起来那一帧的位置，对手怎么拖都不动
    ("scenes/main.gd",
     '''		Protocol.DRAG_MOVE:
			_move_foe_drag(msg)''',
     '''		Protocol.DRAG_MOVE:
			pass''',
     "第 20 帧摆到位", "tests/test_foe_drag.gd"),
    # 乱序帧不丢：晚到的旧帧把牌拽回去，看着是抽搐
    ("scenes/main.gd",
     '''	if ph == Protocol.DRAG_MOVE and seq <= _drag_lease_seq:''',
     '''	if false:''',
     "迟到的第 15 帧被丢掉了", "tests/test_foe_drag.gd"),
    # 把 cancel 也拦在 seq 判定里：seq 落后的 cancel 被丢掉，牌永远浮在半空
    ("scenes/main.gd",
     '''	if ph == Protocol.DRAG_MOVE and seq <= _drag_lease_seq:''',
     '''	if seq <= _drag_lease_seq:''',
     "seq 落后的 cancel 也收", "tests/test_foe_drag.gd"),
    # 收不到 cancel：同上
    ("scenes/main.gd",
     '''		Protocol.DRAG_CANCEL:
			_release_drag_lease()''',
     '''		Protocol.DRAG_CANCEL:
			pass''',
     "cancel 之后租约收回", "tests/test_foe_drag.gd"),
    # 松手不交还布局：牌浮在 DRAG_HEIGHT 上，谁都不摆它。
    # 锚点带上前一行 —— 'layout._layout_ai_idle()' 在 main.gd 里有 7 处，
    # 光这一行会去改第一处（见 SKIP 那一关）
    ("scenes/main.gd",
     '''	_drag_lease_t = 0.0
	# 交还给布局：牌现在浮在 DRAG_HEIGHT 上，得有人把它们摆回去。
	# 对手买/典当那几张牌可能已经不在场上了，_layout_ai_idle 只摆还在的
	layout._layout_ai_idle()''',
     '''	_drag_lease_t = 0.0''',
     "松手之后布局把牌摆回去了", "tests/test_foe_drag.gd"),
    # 倾斜不清：那几张牌斜着躺在摞里
    ("scenes/main.gd",
     '''			e.rotation_degrees = Vector3(0, e.rotation_degrees.y, 0)
	_drag_lease.clear()''',
     '''			pass
	_drag_lease.clear()''',
     "歪着拎的倾斜清掉了", "tests/test_foe_drag.gd"),
    # 超时不接：对方拖着牌掉线，牌永远浮在半空
    ("scenes/main.gd",
     '''	_tick_drag_lease(delta)''',
     '''	pass''',
     "租约自己到期", "tests/test_foe_drag.gd"),
    # 超时判反：对手拖一下牌就被抢回去
    ("scenes/main.gd",
     '''	if _drag_lease_t >= DRAG_LEASE_TIMEOUT:''',
     '''	if true:''',
     "才过 0.05s，租约还在", "tests/test_foe_drag.gd"),
    # 租约不挡布局（闲置摞那条）：_layout_ai_idle 每步都把牌摆回摞里
    ("scenes/settle_layout.gd",
     '''		if _main.is_drag_leased(int(c["uid"])):
			continue''',
     '''		if false:
			continue''',
     "布局跑过一趟之后牌还在半空", "tests/test_foe_drag.gd"),
    # 停着不动那一路的节流拆掉：坐标一样的帧也照发，不可靠通道里最吵的一路更吵
    ("scenes/board.gd",
     '''	if _bcast_t < DRAG_KEEPALIVE_DT:
		return''',
     '''	if false:
		return''',
     "停着不动那一路有节流", "tests/test_foe_drag.gd"),
    # 动了不当帧发，退回「一律等节流」：本地 60fps 拖，对手侧每 0.2s 才动一次，
    # 而收方是硬写位置的（没插值）—— 就是玩家报的那个「延迟很高」
    ("scenes/board.gd",
     '''	if _bcast_at.distance_squared_to(at) > DRAG_MOVE_EPS * DRAG_MOVE_EPS:''',
     '''	if false:''',
     "牌在动的时候每帧都发", "tests/test_foe_drag.gd"),
    # 松手不广播：对手那边的牌永远浮在半空，而本地一切正常
    ("scenes/board.gd",
     '''			drag_broadcast.emit(Protocol.DRAG_CANCEL, _bcast_uids, Vector3.ZERO)''',
     '''			pass''',
     "松手发了一帧 cancel", "tests/test_foe_drag.gd"),
    # 手上空了还继续发：空转的 dragging 帧让对手侧的租约永远不到期
    ("scenes/board.gd",
     '''			_bcast_uids = []
			_bcast_at = Vector3.INF''',
     '''			pass''',
     "手上没牌了就不再广播", "tests/test_foe_drag.gd"),
    # 拎起来那一帧被节流吃掉：对手侧晚 50ms 才抬手（pickup 是一次性事件）
    ("scenes/board.gd",
     '''	if _bcast_uids != uids:''',
     '''	if false:''',
     "拎起来发了一帧 pickup", "tests/test_foe_drag.gd"),

    # ---- 重开一局：换 state 必须一起重建管道 ----
    # 漏掉这句 → 界面读新 state（画面全对），而每一条输入都写进上一局那份
    # （上一局 winner 不为空，apply 那条「已分胜负后只放 finalize」全挡了）。
    # 症状是「第二局买不了卡」+ 结算越界崩溃，两个症状同一个根因
    ("scenes/main.gd",
     '''	# 换 state 就必须重建管道 —— 漏掉这句的后果见 _rebuild_pipe 的注释：
	# 第二局什么都做不了，而且不报错
	_rebuild_pipe()''',
     '''	pass''',
     "管道的 applier 指向新 state", "tests/test_restart_bugs.gd"),
    # 只重建管道、忘了换 state 的反向错（写成拿旧 state 建）：
    # 这次是界面和输入都指着上一局，胜负标记还在，同样一动不能动
    ("scenes/main.gd",
     '''	pipe = LocalTransport.new(IntentApply.new(state))''',
     '''	pipe = LocalTransport.new(IntentApply.new(GameState.new()))''',
     "第二局买得成", "tests/test_restart_bugs.gd"),

    # ---- 买到的牌不可见：落点搜索 ----
    # 找不到空位时返回循环出口那个坐标（原来的写法）：桌面一挤，
    # 每次调用都给同一个点，后买的精确压在先买的上面
    ("scenes/settle_layout.gd",
     '''			spot.z = _next_row(spot.z, z_dir, z_min, z_max)
	return best''',
     '''			spot.z = _next_row(spot.z, z_dir, z_min, z_max)
	return spot''',
     "挤满时两次落点不重合", "tests/test_restart_bugs.gd"),
    # 换行钳在边上、不绕回另一头：锚点上方三行铺满时就找不到下方的空行了
    ("scenes/settle_layout.gd",
     '''	if next > z_max + 0.01:
		return z_min      # 走到远边，绕回近边接着扫''',
     '''	if next > z_max + 0.01:
		return z_max''',
     "绕到了锚点", "tests/test_restart_bugs.gd"),
    # 飞行中的牌按实时坐标算（还在出发点）：那 0.35s 里同一个坑许诺两次
    ("scenes/settle_layout.gd",
     '''	if e.has_meta("dest_pos"):
		return e.get_meta("dest_pos")''',
     '''	if false:
		return e.get_meta("dest_pos")''',
     "飞起来之后那个点算占住了", "tests/test_restart_bugs.gd"),
    # 起飞时不宣告归宿：_rest_pos 那边再对也没有东西可读
    #
    # 锚点原先连着函数签名一起写（为了在 main.gd 里唯一）。bug「组合卡有时候
    # 会消失」的修复往签名和这一句之间插了 _cancel_fly(card)，锚点当场失配 ——
    # tools/check_mut_residue.py 报的就是这个。改成只锚 set_meta 那一句：
    # 它在 main.gd 里本来就只有一处，不必再靠签名凑唯一性
    ("scenes/main.gd",
     '	card.set_meta("dest_pos", target)',
     '	pass',
     "飞行中挂着 dest_pos", "tests/test_restart_bugs.gd"),
    # 落地不撤归宿：此后避让一直绕开一个其实已经有人的点，
    # 两份记录并存就有机会不一致
    ("scenes/main.gd",
     '''	tw.tween_callback(func() -> void: _clear_dest(card))''',
     '''	pass''',
     "落地之后 dest_pos 撤掉了", "tests/test_restart_bugs.gd"),

    # ---- bug 3：补间活过了它动画的那张牌 ----
    # 补间是 main 建的（create_tween 挂在调用它的节点上），动画的却是卡。
    # 不 bind_node 的话卡被 queue_free 之后补间照样跑完，回调对着空引用赋值。
    # 实测症状：`--host --port=N` + `--server=...` 两个无头进程配对，
    # 两边各刷 8 条 Lambda capture freed + 8 条 SCRIPT ERROR ——
    # 而 harness 只数断言、只 grep [FAIL]，那一跑照样「全绿」
    ("scenes/main.gd",
     '''	var tw := create_tween().bind_node(e) \\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)''',
     '''	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)''',
     "卡被收掉之后那条补间跟着失效了", "tests/test_restart_bugs.gd"),
    ("scenes/main.gd",
     '''	var tw := create_tween().bind_node(card)
	tw.tween_interval(delay)''',
     '''	var tw := create_tween()
	tw.tween_interval(delay)''',
     "拆卡那条补间也跟着失效", "tests/test_restart_bugs.gd"),

    # ---- 跨局残留量：和 bug 2 同一个形状（某个成员活过了重开）----
    # 租约记的是 uid，而 uid 跨局重用：不清的话新局有几张牌被布局绕开，
    # 直到 2 秒超时才放回去，期间还弹一句「对手那边没动静」
    ("scenes/main.gd",
     '''	_drag_lease.clear()
	_drag_lease_t = 0.0
	_foe_action_done = false''',
     '''	_foe_action_done = false''',
     "没有牌背着上一局的拖拽租约", "tests/test_restart_bugs.gd"),
    # 「对方行动完了」活到下一局 → 新局对手的第一个行动阶段一帧就过去
    ("scenes/main.gd",
     '''	_foe_action_done = false
	_foe_combo_shown = 0''',
     '''	_foe_combo_shown = 0''',
     "action_done 没活到新局", "tests/test_restart_bugs.gd"),
    # pickup 也受 seq 水位管 → 换一条新连接（seq 从 1 重发）时第一帧就被丢掉，
    # 一个租约都建不起来。水位是每次拎牌重置的，靠的就是这条豁免
    ("scenes/main.gd",
     '''	if ph == Protocol.DRAG_MOVE and seq <= _drag_lease_seq:''',
     '''	if ph in [Protocol.DRAG_MOVE, Protocol.DRAG_PICKUP] and seq <= _drag_lease_seq:''',
     "新连接的低 seq 没被上一条连接的水位丢掉", "tests/test_foe_drag.gd"),

    # ======== 联网：快照的节拍与裁决器的池子（net/protocol.gd）========
    # 上面那几段钉的是「转发通了」「画面画得出」。这一段钉的是它们之上的两件事：
    #   1. 池子不在 GameState 上（它是裁决器的成员），StateCodec 看不见它
    #   2. 每条广播都带**全量**快照，而一整段结算是一口气推完的 ——
    #      收到就合上的话客户端的状态会跑在演出前面一整段
    # 两条都只在**真联网**里出现：单机局没有快照这一步。
    # 四条都实跑确认过红（mutation-hint-must-be-run）。
    # 第 5 项都写全了：net/ 和 engine/intent_apply.gd 在 TEST_FOR 里都不指向
    # 这个文件，省略就会去跑一个根本不联网的测试（跑得过，等于没测）

    # 还原不清空：服务器 next_round 清掉的那份在客户端留着 ——
    # 下一回合客户端以为自己已经装过弹了（armed 判的就是「有没有条目」），
    # 于是那一回合的装弹被当成重复装弹拦掉，攻击阶段一个点数都没有
    ("engine/intent_apply.gd",
     '''func pools_restore(d: Dictionary) -> void:
	_pools.clear()''',
     '''func pools_restore(d: Dictionary) -> void:''',
     "next_round 之后客户端也没装弹", "tests/test_net_client.gd"),
    # 快照不带池子：状态全对、画面全对，而客户端的 pool_empty() 一上来就是真 ——
    # **攻击回合被整段跳过，一条错都不报**（_await_foe_attack 就是循环判它）
    ("net/room.gd",
     '''	snap["pools"] = applier.pools_snapshot()''',
     '''	pass''',
     "装弹后客户端的池子跟服务器一样", "tests/test_net_client.gd"),
    # 到达队列不停在服务器操作上：一整段（produce×n + finalize + next_round）
    # 在同一次 poll 里全部合上，客户端的状态在演第 0 组之前就跳到下一回合 ——
    # _resolve_combo_visual(0) 去取第 0 组时 state.combos 已被 finalize 清空，
    # 下标越界，崩在结算演出的第一行。而服务器那边一切正常
    ("net/net_transport.gd",
     '''		if not Intent.is_client_op(op):
			return
		_inbox.pop_front()''',
     '''		if not Intent.is_client_op(op):
			pass
		_inbox.pop_front()''',
     "一段结算全到齐也不会把状态推过第 0 组", "tests/test_net_client.gd"),
    # 重画桌子不把组合摆回去：board.groups 是桌面的实况，只由拖拽产生。
    # 重连之后状态里组合还在、桌上却是散牌，而且下一次 _register_player_combos
    # 会把它们当成没编过、重发 create_combo 被引擎以「卡已在别的组合里」拒掉。
    # 症状是「重连之后我的组合没了，重编也编不上」，一条错都不报
    ("scenes/main.gd",
     '''	_restore_my_combo_groups()''',
     '''	pass''',
     "重画之后我的组合还在桌上", "tests/test_net_client.gd"),

    # ---- 一个人先进房：seated 带的是空局（test_net_client T5）----
    # 这四条钉的局面在 T5 之前**一次都没被跑过**：T4 用的是「两个人都坐下之后
    # 才 begin_net_game」，于是空快照那一支永远走不到。而真人开局走的就是它 ——
    # 点连接的那一刻对面还没来。四条都实跑确认过红（mutation-hint-must-be-run）

    # 照空快照摆桌子：_respawn_all 第一行读 state.players[my_seat]，
    # 空字典上取键抛脚本错误。它跑在 joined 信号的回调里 —— 错误不让调用方失败，
    # 只把 begin_net_game 剩下的部分静默丢掉（锁输入、灰按钮、提示语全不执行）。
    # 玩家看到「点了连接，桌子空了，没有任何提示」，报上来就是「好像没连上」
    # 期望报警的是**提示语**那一条，不是「没有打断 begin_net_game」那一条 ——
    # 后者在这条变异下照样绿，而那不是判据太松：GDScript 的运行时错误
    # 只中止**出错的那个函数**，_respawn_all 抛错之后 _draw_net_table
    # 和 begin_net_game 都继续跑完了（输入照样锁上）。
    # 看得见的差别在提示语上：走错了分支，说的是「等服务器发牌」而不是「等对手」
    ("scenes/main.gd",
     '''	if not _net_dealt():''',
     '''	if false:''',
     "提示语说了在等对手", "tests/test_net_client.gd"),
    # 不接补发的那份 seated：牌是第二个人进来才发的，那一刻的真局面只在
    # 补发的 seated 里。不接的话 state 里 30 张牌、桌上 0 张，整局一张空桌
    # 原先这个 if 在 _draw_net_table 和 _swap_transport 里各有一份，锚点得多带
    # 两行注释才唯一（不唯一会 SKIP，而 SKIP 长得不像失败）。两处已合并成
    # _attach_net_state_signals，锚点因此天然唯一，且这一条同时盖住两条路
    ("scenes/main.gd",
     '''	if not net.connected.is_connected(_on_net_seated):
		net.connected.connect(_on_net_seated)''',
     '''	if false:
		net.connected.connect(_on_net_seated)''',
     "第二个人进来之后桌子补摆上了", "tests/test_net_client.gd"),
    # 进联网局不复位「桌子摆了没有」：它从单机局带着 true 进来
    # （开局 _sync_round → _respawn_all 置的），于是 _on_net_seated 一进门就返回。
    # 症状和上一条一样是空桌，但原因在**另一个文件都不用改**的一行上
    ("scenes/main.gd",
     '''	_net_table_drawn = false
	_draw_net_table()''',
     '''	_draw_net_table()''',
     "第二个人进来之后桌子补摆上了", "tests/test_net_client.gd"),
    # 等人的时候不说话：不崩了，但玩家那一侧和崩掉时**看到的是同一个画面**
    # （一张空桌 + 没有提示）。「不崩」和「说了在等人」是两条判据，
    # 少了后一条的话「静默等待」这个真症状溜过去
    ("scenes/main.gd",
     '''		_show_message("已入座（%s），等对手进同一个房间码……%s"
			% [_seat_name(my_seat), extra], Color(0.7, 0.9, 1.0))''',
     '''		pass''',
     "提示语说了在等对手", "tests/test_net_client.gd"),

    # ======== 可见度：消耗演出 / HUD 拆分（scenes/main.gd 的 _resolve_combo_visual / _update_hud）========
    # 这一段和上面每一段都不同：**规则一条没动**。动的全是「玩家看不看得见」。
    # 于是每条变异的后果都是「屏幕上那行字没了 / 写错了」，而引擎末态一模一样 ——
    # 末态哈希、资源读数、战报一个都抓不到。观察点只能是屏幕上那行字本身。
    # 每条都实跑确认过红（memory: mutation-hint-must-be-run）。
    # 牌摞级提示（「装机中」）那一层已整层撤掉，这里原先守着它的 11 条一并注销 ——
    # 留着只会次次 SKIP（锚点找不到），而 SKIP 和「测过了」在总数上分不出来。
    # 第 5 项都写全了：scenes/main.gd → test_arrivals、
    # engine/game_state.gd → test_engine，两个默认都不看这些字（跑得过，等于没测）

    # --- scenes/main.gd 的 HUD 与面板实现 HUD 拆分 ---
    # 待付按**卡面** recipe_n 取，不按 eval 的 recipe_pay_n：用户配方的摞
    # 一分钱不付（席位是永久的，README.md §「2.6 组合与结算」），而它的 recipe_n 也是 7 ——
    # 屏幕上就成了「本回合待付 7」而那一摞压根不掏钱。玩家照它留钱，留错了。
    # 现金摞的判据抓不到这个：现金配方两个数恰好相等
    # （同一个形状在 settle.gd 上也登记过一条：「按卡面值发牌而不是按组合快照」）
    #
    # 登记时先试过 `if not bool(eval["valid"]): continue` → **等价变异**：
    # evaluate 只在 valid 分支里填 recipe_pay_n，不成立时它本来就是 0
    ("engine/game_state.gd",
     '''		total += int((pe["eval"] as Dictionary).get("recipe_pay_n", 0))''',
     '''		total += int(CardDB.get_def(
		str((pe["eval"] as Dictionary)["leader"])).get("recipe_n", 0))''',
     "用户配方的摞待付 0", "tests/test_consume_hud.gd"),
    # 在岗按「摞里有几张用户」数，不按席位额度：一摞 7 张用户而配方只要 4 张时，
    # 富余那 3 张被记成在岗 —— 闲置读数把最该警报的情形算成了健康
    ("engine/game_state.gd",
     '''		on_duty += mini(seats, have)''',
     '''		on_duty += have''',
     "富余不算", "tests/test_consume_hud.gd"),
    # 待付括号永远不写：破百局面里「资金 34」有 8 块是这回合要付的，
    # 真实可用 26。少了这个括号玩家读到的是一个虚高的数
    # 锚点只取 append 那一行，不要连 `if due > 0:` 一起取：那个 if 的身子不止一行
    # （后面还嵌着「付完归零」那条 ⚠），把头两行换成外层缩进的 `pass` 会把剩下的
    # 身子孤零零留在里层缩进上，变异体直接编译不过 —— 报 BROKE，等于这条没测到
    ("scenes/main.gd",
     '''		cash_txt += "（本回合待付 %d）" % due''',
     '''		pass''',
     "HUD 写出「本回合待付", "tests/test_consume_hud.gd"),
    # 在岗/闲置括号跟着待付一起「0 就藏」：闲置 0 是这条读数唯一的好消息，
    # 藏掉的话玩家分不清「全部在岗」和「这个读数根本没算」
    ("scenes/main.gd",
     '''	user_txt += "（在岗 %d / 闲置 %d）" % [int(dep["on_duty"]), int(dep["idle"])]''',
     '''	if int(dep["on_duty"]) > 0:
		user_txt += "（在岗 %d / 闲置 %d）" % [int(dep["on_duty"]), int(dep["idle"])]''',
     "没有任何在岗时照旧写括号", "tests/test_consume_hud.gd"),
    # --- 13. 配方消耗演出 ---
    # 名单不筛现金卡：吸走的是组里前 N 张（可能是核心卡、用户卡），
    # 而引擎扣款走的是同一个函数 —— 两处一起错，动画和扣款仍然一致，
    # 于是**只有卡面看得出来**：屏幕上飞走一张核心卡
    ("engine/game_state.gd",
     '''		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == CardDB.RES_CASH:
			out.append(u)
	return out''',
     '''		out.append(u)
	return out''',
     "名单里全是这一组内的现金卡", "tests/test_consume_hud.gd"),
    # 消耗退回「固定等一个数」：该吃的牌照样吃，坏的只是节奏 ——
    # 一次付 N 张读作一团糊掉的东西，外加每组白挂的那点空场
    ("scenes/main.gd",
     '''	return TEAR_STAGGER * float(count - 1) + SUCK_TIME''',
     '''	return SUCK_TIME''',
     "张数多了要等得久一点", "tests/test_consume_hud.gd"),
    # 错开的系数和攻击那边不一致：两套演出看着就是两个快慢
    ("scenes/main.gd",
     '''	return TEAR_STAGGER * float(count - 1) + SUCK_TIME''',
     '''	return TEAR_STAGGER * float(count - 1) * 0.5 + SUCK_TIME''',
     "错开的系数和攻击一致", "tests/test_consume_hud.gd"),
    # 兜底路径把摘登记也一起延迟：牌在错开的那几十毫秒里还留在 board.cards，
    # 点得到、射线打得着、理牌还会把它排进摞 —— 而引擎里它已经不存在了
    ("scenes/main.gd",
     '''				var e: CardEntity = entities[uid]
				board.drop_card(e)
				_delayed_flyout_torn(e, Vector3(0, 0, 1.0),''',
     '''				var e: CardEntity = entities[uid]
				_delayed_flyout_torn(e, Vector3(0, 0, 1.0),''',
     "同步一回来它们就不在 board.cards 了", "tests/test_consume_hud.gd"),
    # 兜底路径不登记 _tear_until_ms：结算重画桌子不会等这一批，
    # 错开还没轮到的那几张会被连补间带卡一起清掉（见 _tears_drained）
    # 锚点改过一次：起飞时刻改成排在 _tear_slot_ms 那条公用队上之后，
    # 这里不再是「现在 + dur」而是「队尾那张起飞的时刻 + TEAR_TIME」
    ("scenes/main.gd",
     '''		_tear_slot_ms = slot
		_tear_until_ms = maxi(_tear_until_ms,
			slot - int(TEAR_STAGGER * 1000.0) + int(TEAR_TIME * 1000.0))''',
     '''		_tear_slot_ms = slot''',
     "这一批登记进了 _tear_until_ms", "tests/test_consume_hud.gd"),
    # --- 14. 再来一局（net/room.gd 的 rematch 投票与重开）---
    # 这一段每一条漏做的症状都**不报错**，所以判据全部落在「后果」上而不是字段值上。
    # 第 5 项都写明测试文件：net/ 和 engine/game_state.gd 的默认测试
    # 分别是 test_engine / test_simulator，都跑得过 —— 省略等于没测
    #
    # winner 不清：IntentApply._decide 和 PhaseMachine.check 开头那两道
    # game_over 护栏会把新局的**每一条**意图静默拒掉。
    # 桌子摆得好好的、按钮亮着、日志干净，就是一步也走不了
    ("engine/game_state.gd",
     '''	round_num = 1
	winner = ""
	win_reason = ""''',
     '''	round_num = 1
	win_reason = ""''',
     "第二局能走意图", "tests/test_rematch.gd"),
    # 组合不清：上一局的组合带着**上一局的 uid** 进新局，而 uid 是重新发号的 ——
    # 结算时按 uid 找卡，找到的是另外几张
    ("engine/game_state.gd",
     '''	combos.clear()
	market.clear()''',
     '''	market.clear()''',
     "第二局组合表是空的", "tests/test_rematch.gd"),
    # 顺手把 _uid 也清了：新局的卡和上一局撞号。撞号在联网局里是静默的错 ——
    # 拖拽租约、攻击目标、保护名单全按 uid 认卡
    ("engine/game_state.gd",
     '''	round_num = 1
	winner = ""''',
     '''	round_num = 1
	_uid = 0
	winner = ""''',
     "uid 接着发号", "tests/test_rematch.gd"),
    # 弹药池不清：它跟着 applier 活着，StateCodec 看不见它
    # （memory: adjudicator-state-not-in-codec）。新局第一次装弹撞 already_armed，
    # 那一方整个攻击阶段静默跳过
    ("net/room.gd",
     '''	applier.pools_restore({})
	state.new_game(GameState.opponent(state.draw_first))''',
     '''	state.new_game(GameState.opponent(state.draw_first))''',
     "新局双方都没装弹", "tests/test_rematch.gd"),
    # 先手不轮换：房间里先进来的人坐 PLAYER，而 draw_first 默认就是 PLAYER ——
    # 同一个人局局先抽，那是一局定终身的不对称
    ("net/room.gd",
     '''	state.new_game(GameState.opponent(state.draw_first))''',
     '''	state.new_game(state.draw_first)''',
     "先手在局间轮换", "tests/test_rematch.gd"),
    # 局中也能投票 = 任何一方随时能掀桌，而它长得像个正常操作（一条空消息）。
    # 「什么时候能投」必须由服务器判，不由客户端的按钮可见性判
    ("net/room.gd",
     '''	if state.winner == "":
		return [_to(peer, Protocol.rejected("not_over", "这一局还没结束"))]''',
     '''	if false:
		return [_to(peer, Protocol.rejected("not_over", "这一局还没结束"))]''',
     "局中不能投票", "tests/test_rematch.gd"),
    # 掉线不撤票：这一票记在座位上而不是人身上。投了票的人走掉之后，
    # 另一位一点就直接开新局 —— 而他等的那个人不在了，新局第一个对手回合
    # 停在等一条永远不来的 action_done
    ("net/room.gd",
     '''		rematch_votes.erase(s)''',
     '''		pass''',
     "掉线撤票", "tests/test_rematch.gd"),
    # 收件箱不清：里面攒着上一局的 applied（产出/收尾那一串）。新局第一次
    # await pipe.arm() 立刻拿到上一局排在队头的那条 —— 场景层按上一局的结果
    # 演新局的攻击阶段，而状态早已是新局的：演出和状态各说各话，一条错都不报
    ("net/net_transport.gd",
     '''	_inbox.clear()
	_pending = false''',
     '''	_pending = false''',
     "新局的收件箱是空的", "tests/test_rematch.gd"),
    # decode 的字段白名单漏一个分支 → 载荷被**静默丢掉**（头一版真是这么漏的：
    # REQUIRED 登记了、构造函数写了、房间那几节全绿，而收方拿到的 msg 里
    # 连 votes 这个键都不存在）。观察点是 T4 那条「转成了信号」——
    # 它喂的是 JSON 文本，过的是 _on_text → decode 这条真路径
    #
    # 锚点要带下一行：裸的 `REMATCH_STATE:` 在这个文件里有两处
    # （from_dict 的分支和 brief 的分支），改的会是第一处 —— 那是第三种 MISS
    # （memory: mutation-anchor-must-be-unique）
    ("net/protocol.gd",
     '''		REMATCH_STATE:
			# 名单里的座位名逐个 str()''',
     '''		"__never__":
			# 名单里的座位名逐个 str()''',
     "rematch_state 转成了信号", "tests/test_rematch.gd"),
    # 同一个白名单，另一个分支：漏了它，rematch_start 到达时 my_seat 这个键
    # 不存在 —— 收方在 msg["my_seat"] 上抛脚本错误，而那是在信号回调里，
    # 调用方不失败（memory: callback-script-error-doesnt-fail-test）。
    # 所以判据要落在**后果**上：座位没换成服务器给的那个
    ("net/protocol.gd",
     '''		REMATCH_START:
			out["version"] = int(d.get("version", 0))''',
     '''		"__never__":
			out["version"] = int(d.get("version", 0))''',
     "座位按服务器给的换了", "tests/test_rematch.gd"),

    # --- 15. 协议信封本身（net/protocol.gd）---
    # 这一节和上面两条的分工：上面那两条钉的是**具体字段**（votes/my_seat），
    # 这里钉的是**校验本身还在不在**。形状校验塌掉的症状不是「某个功能坏了」，
    # 而是「坏包从这里一路走进引擎」——  服务器上收到读不懂的包是家常事
    ("net/protocol.gd",
     '''	for f in REQUIRED[t]:
		if not d.has(f):''',
     '''	for f in []:
		if not d.has(f):''',
     "少了必填字段", "tests/test_protocol.gd"),
    ("net/protocol.gd",
     "	if not REQUIRED.has(t):",
     "	if false:",
     "未知类型要拒", "tests/test_protocol.gd"),
    # 这一条要**手术式**地改：把 `if j.parse(text) != OK:` 整句换成 `if false:`
    # 等于连 parse 都不跑了，于是**每一条**消息都解不开（实测红 28 条）——
    # 那不是「坏 JSON 的拦没了」，是把整个 decode 拆了，测不出这道拦的价值。
    # 保留 parse、只忽略它的返回值：这时 j.data 是 null，
    # 下一道 `is Dictionary` 照样会拒 —— 所以观察点**只能**是 reason 那句话
    # （少了解析位置，手搓包排查得再抓一次包）
    ("net/protocol.gd",
     "	if j.parse(text) != OK:",
     "	if j.parse(text) == 999999:",
     "坏 JSON 的原因里带了解析器给的位置", "tests/test_protocol.gd"),
    # uid 掰回 int 的那两圈：漏了的话 60.0 当字典键一律查不中，
    # 症状是联网局白拿一张牌而单机局全对（memory: json-turns-uids-into-float-keys）
    ("net/protocol.gd",
     "	for f in UID_LIST_FIELDS:",
     "	for f in []:",
     "uids 掰回了 int", "tests/test_protocol.gd"),
    ("net/protocol.gd",
     "	return CLIENT_MSGS.has(t)",
     "	return true",
     "服务器消息不许客户端发", "tests/test_protocol.gd"),

    # --- 17. 启动参数：网页和桌面同一条解析（net/launch_config.gd）---
    # 这一节的共同症状是**静默退回单机局**：链接里带了服务器和房间码，
    # 游戏照样起一局单机的，什么都不报。玩家不会把这当 bug 报，
    # 他只会说「你那个链接没用」—— 所以每一条都得有测试盯着
    ("net/launch_config.gd",
     "	if _truthy(raw_host):",
     "	if false:",
     "?host=1 → 主机模式", "tests/test_launch_config.gd"),
    # 非法房号要退回单机，不能带着它去连：带过去的话服务器踢人，
    # 而玩家看到的是服务器那句话，会去查服务器
    ("net/launch_config.gd",
     '	if room != "" and Protocol.valid_room(room):',
     '	if room != "":',
     "超长房号被挡在客户端", "tests/test_launch_config.gd"),
    # 光主机名不补协议和端口：connect_to_url("1.2.3.4") 直接失败，报「连不上」
    ("net/launch_config.gd",
     '	return "ws://%s:%d" % [s, p]',
     '	return "ws://" + s',
     "光主机名补上了协议和默认端口", "tests/test_launch_config.gd"),
    # 短邀请链接那一支：只带房间码时该连**发出这个网页的那台机器**。
    # 没了它，?room=ABCD 打开就是单机局
    ("net/launch_config.gd",
     '	if url == "" and out["room"] != "" and page_host != "":',
     "	if false:",
     "只带房间码", "tests/test_launch_config.gd"),
    # `?host` 这种没有等号的开关。判据那条必须走 .get 不能走 ["host"]：
    # 键不存在时下标是运行时错误，它中断整个测试函数，后面的断言压根不跑，
    # 而 run_tests.sh 只数结果行、只 grep [FAIL] —— 于是这条变异会假绿
    ("net/launch_config.gd",
     '			out[part.uri_decode().to_lower()] = "1"\n			continue',
     "			continue",
     "没有等号的开关也认", "tests/test_launch_config.gd"),

    # --- 18. 本机开房（net/embedded_host.gd + scenes/）---
    # url() 报的必须是**真开在那个端口**上，不是 DEFAULT_PORT。
    # 这一条是旧脚本的原病：脚本顺延了端口，客户端那个硬编码地址没跟着走,
    # 症状是「服务器开着，游戏说连不上」
    ("net/embedded_host.gd",
     '	return "ws://127.0.0.1:%d" % port',
     '	return "ws://127.0.0.1:%d" % DEFAULT_PORT',
     "报的是真开成的那个端口", "tests/test_embedded_host.gd"),
    # start() 开头不 stop()：旧的 server 还占着端口，重开顺延到下一个,
    # 而玩家还在照上一次报出来的地址叫人连
    ("net/embedded_host.gd",
     "	stop()\n	var last: Dictionary = {}",
     "	var last: Dictionary = {}",
     "重开落在同一个端口", "tests/test_embedded_host.gd"),
    # main._process 不 poll 本机服务器：对手 socket 连上了、握手完不成，
    # 他那边说「服务器没让我入座」，而**我这边一切正常** —— 最难查的一类
    ("scenes/main.gd",
     "	if _host != null:\n		_host.poll()",
     "	if false:\n		_host.poll()",
     "对手连进来入座了", "tests/test_join_panel.gd"),
    # 退回单机不收服务器：它占着端口，下次开房顺延，报出的地址就变了
    ("scenes/main.gd",
     "	stop_local_host()\n	set_foe_remote(false)",
     "	set_foe_remote(false)",
     "退回单机局把服务器也收了", "tests/test_join_panel.gd"),
    # 锚点带上 want_port —— 那个参数是后来加的（指定端口那一支），
    # 不跟着改的话这条变异静默不打（check_mut_residue.py 的「原文不在」管这个）
    ("scenes/join_panel.gd",
     "	var r: Dictionary = _main.start_local_host(want_port)",
     '	var r: Dictionary = { "ok": true, "url": DEFAULT_URL, "port": EmbeddedHost.DEFAULT_PORT }',
     "开房间之后本机服务器在跑", "tests/test_join_panel.gd"),
    # 房间码空着不现生一个：按下「开房间」什么也没发生（校验把空码拒了）
    ("scenes/join_panel.gd",
     "		room = _sample_room(true)",
     "		pass",
     "房间码空着也开得起来", "tests/test_join_panel.gd"),
    # 启动参数里带了房间码却不自动连：网页链接打开停在面板上等人点按钮,
    # 而需求 5 要的就是「直接进等待对手」
    ("scenes/join_panel.gd",
     "		LaunchConfig.MODE_JOIN:\n			_on_connect()",
     "		LaunchConfig.MODE_JOIN:\n			pass",
     "就自己连上并入座了", "tests/test_join_panel.gd"),

    # --- 19. 指定端口那一支：报出去的数 = 真监听的数 ---
    # 启动脚本开两份游戏时，第一份 `--host --port=N`、第二份 `--server=...:N` ——
    # N 是脚本报出去的。下面三条各断一环，症状全是同一句：
    # 第一份写着「等对手进来」，第二份连不上，两边都不报错
    #
    # 无视 want_port：在 DEFAULT_PORT 上开
    ("scenes/main.gd",
     "		want_port if want_port > 0 else EmbeddedHost.DEFAULT_PORT,",
     "		EmbeddedHost.DEFAULT_PORT,",
     "开在**要的那个端口**上", "tests/test_join_panel.gd"),
    # 指定端口也顺延：占用时「成功」开在 N+1，而对手手里那个数是 N
    ("scenes/main.gd",
     "		1 if want_port > 0 else EmbeddedHost.PORT_TRIES)",
     "		EmbeddedHost.PORT_TRIES)",
     "端口被占就当场报错", "tests/test_join_panel.gd"),
    # apply_launch 不把 cfg["port"] 传下去：--port= 在最后一步丢掉
    ("scenes/join_panel.gd",
     '				_on_host(int(cfg.get("port", 0)))',
     "				_on_host()",
     "--port= 一路传到了服务器", "tests/test_join_panel.gd"),

    # --- 20. 攻击阶段换手：点数花光那一支也得报 attack_done ---
    # 联机时换手只认 attack_done（net/room.gd::_advance），可「该谁攻」是场景那一层
    # 算出来的。三个出口里少报一个，服务器就一直停在「等我点选」，两边一起卡到超时 ——
    # 这一条断的正是当初卡死的那个出口
    ("scenes/main.gd",
     "		await pipe.submit(Intent.attack_done(my_seat), my_seat)\n		attack_turn_finished.emit()",
     "		attack_turn_finished.emit()",
     "服务器不再停在 A 的攻击回合上", "tests/test_net_attack_flow.gd"),

    # --- 21. 摞牌那条转发channel：我摞的牌对手看得见 ---
    # 摞只活在 board.groups 里，对手区是收方**照自己的 state 重搭**的。
    # 这四条各断一环，症状全是同一句：我摞了半天，对面看见的是牌被拖过去、
    # 然后弹回资源摞
    #
    # 指纹永远相等：摞完不发，对手那边一直是开局那份
    ("scenes/main.gd",
     "	var fp := _piles_fingerprint(groups)\n	if fp == _piles_fp:",
     "	var fp := _piles_fingerprint(groups)\n	if true:",
     "开局那份分组先发了出去", "tests/test_net_piles.gd"),
    # uid 不掰成 int：JSON 那头全是 double，{60: x}.has(60.0) 是 false，
    # 于是名单收到了却一张也对不上
    ("net/protocol.gd",
     '			uids = Intent.ints(d.get("uids", []))',
     '			uids = d.get("uids", [])',
     "收到的 uid 都是 int 而不是 float", "tests/test_net_piles.gd"),
    # 声明摞不从资源摞里摘出去：同一张牌摆两回，后摆的赢 —— 就是「弹回资源堆」
    ("scenes/settle_layout.gd",
     "	var grouped := {}\n	for u in extra_grouped:",
     "	var grouped := {}\n	for u in []:",
     "那几张不再躺在资源摞里", "tests/test_net_piles.gd"),
    # 声明摞不算前行：摞塌到后行席位上，等它变成真组合时又跳回前行
    ("scenes/settle_layout.gd",
     '	return key.begins_with("ai_combo_") or key.begins_with("ai_group_")',
     '	return key.begins_with("ai_combo_")',
     "声明摞算前行", "tests/test_net_piles.gd"),

    # --- 21b. 收拢/摊开这一位：双击摞起来和摊开，对手要看得出区别 ---
    # 这五条各断一环，症状都是「我这边摞起来了/摊开了，对面纹丝不动」
    #
    # 指纹不看 compact：收拢/摊开只翻 g["compact"]，uid 名单一个字节不变。
    # 判据是**直接问指纹**的那一条（T6 开头），不是「收拢之后发了一条」——
    # 后者遮得住：位置也在同一条指纹里，而收拢会顺带把中点挪了，
    # 于是这一位漏了照旧发得出去，只是发的理由错了
    ("scenes/main.gd",
     '			"c" if bool((g as Dictionary).get("compact", false)) else "s",',
     '			"s",',
     "指纹看得见收拢这一位", "tests/test_net_piles.gd"),
    # 发出去的那份不带 compact：对手只知道哪几张一摞，不知道摞成什么样。
    # 连指纹一起废掉 —— 指纹是拿 my_pile_lists() 的输出算的（_push_piles），
    # 这里把 compact 钉死，指纹也就永远看不见那一位
    ("scenes/main.gd",
     '		var rec := { "uids": uids, "compact": bool(g.get("compact", false)) }',
     '		var rec := { "uids": uids, "compact": false }',
     "广播里那一摞报的是收拢", "tests/test_net_piles.gd"),

    # --- 21c. 位置这两个字段：对手把摞挪到哪，我这边就该摆在哪 ---
    # 这五条各断一环，症状都是同一句：对手无论把组合拖到哪儿，
    # 我这边看到的都是同一个格子（落点由收方按「共几摞」现算成整行居中）
    #
    # 发送端不带位置：收方没有位置可用，只能退回现算格子。
    # 报的是 _until 超时那条（广播里始终等不到带位置的那一摞）
    ("scenes/main.gd",
     '			rec["u"] = uv.x\n			rec["v"] = uv.y',
     '			pass',
     "摞好之后广播里带上了位置", "tests/test_net_piles.gd"),
    # 指纹不看位置：整摞搬到别处时名单和形态都没变，指纹和上一份相同 ——
    # 一条都不发。和 compact 那条是同一个形状的漏（挪了对面看不见）
    ("scenes/main.gd",
     '			_uv_bucket(g as Dictionary),',
     '			"-",',
     "挪到右边之后又播了一条", "tests/test_net_piles.gd"),
    # 转发时把位置抹掉：服务器这一跳丢字段，两端都不报错 ——
    # 这正是 Protocol.VERSION 升到 3 的那个坑（v2 的 pile_lists 只挑
    # uids/compact 两个字段重排）
    ("net/protocol.gd",
     '			if d.has("u") and d.has("v"):',
     '			if false:',
     "u/v 两个键都留着", "tests/test_protocol.gd"),
    # 缺位置时补成 (0,0)：老形状的包、单机局的摞会全被当成「在桌子左后角」，
    # 一屏的摞挤到一个点上。判据在协议那一层（没说就不出这两个键）
    ("net/protocol.gd",
     '		if uv != null:\n			rec["u"] = (uv as Vector2).x',
     '		if true:\n			uv = Vector2.ZERO if uv == null else uv\n			rec["u"] = (uv as Vector2).x',
     "没说位置就不出 u/v 键", "tests/test_protocol.gd"),
    # 收方不看对手说的位置，退回现算格子：这一条是玩家看得见的那一面
    ("scenes/settle_layout.gd",
     '		if uv is Vector2:\n			at = _pile_anchor_at(uv, _pile_z_span(per_col, step))',
     '		if false:\n			at = _pile_anchor_at(uv, _pile_z_span(per_col, step))',
     "他把摞挪到别处，我这边也跟着挪", "tests/test_net_piles.gd"),
    # 拿摞的一端当锚点（不退半个跨度）：同一个位置换个形态，那一摞会平移
    # 半个摞长 —— 而双击收拢是原地的动作
    ("scenes/settle_layout.gd",
     '	p.z -= span / 2.0',
     '	pass',
     "收拢和摊开摆在同一个中点", "tests/test_net_piles.gd"),
    # 转发时把 compact 抹平：服务器这一跳丢字段，两端都不报错
    ("net/protocol.gd",
     '			compact = bool(d.get("compact", false))',
     '			compact = false',
     "广播里那一摞报的是收拢", "tests/test_net_piles.gd"),
    # 收方不看对手明说的那一位，退回「按几何猜」：前行那份预算摊不开，
    # 于是摞多少张都被压成收拢 —— 摊开和收拢长得一模一样
    # （这段规则从 _layout_ai_zone 搬到了 plan_combo_row —— 缩进跟着少一层。
    #   搬家不改判据：摊开/收拢那一位仍然只写在一处，
    #   memory: doc-migration-moves-anchors）
    ("scenes/settle_layout.gd",
     '''		var declared_spread := false
		if want is bool:''',
     '''		var declared_spread := false
		if false:''',
     "摊开确实比收拢长", "tests/test_net_piles.gd"),
    # 明说摊开却按前行那份窄预算摊：5 张就已经摊不开（见 T6 第一条），
    # step 归 0 落进收拢分支 —— 和上一条同一个症状，另一个根因
    #
    # 锚点得带上下一行：back_pile_cap 的预算那行以这一行**开头**
    #（那边多减一个卡纵深），只写这一行会撞 2 处、整条被 SKIP 掉
    ("scenes/settle_layout.gd",
     '\tvar budget: float = AI_ROW_Z[0] - AI_BACK_Z_MIN\n'
     '\tvar step: float = minf(Board.STACK_GAP.z, budget / float(n - 1))',
     '\tvar budget: float = combo_south_limit() - AI_ROW_Z[0]\n'
     '\tvar step: float = minf(Board.STACK_GAP.z, budget / float(n - 1))',
     "他说摊开，我这边就摆成摊开", "tests/test_net_piles.gd"),

    # --- 21d. 攻击回执里那串 uid：受击的卡要当场撕 ---
    # `removed` 名字里没有 uid 字样，装的却是一串 uid。白名单和
    # test_net_socket 的扫描器都按字段名织网 —— 同一个字眼一次漏两道。
    # 漏了不是「找不着卡」（60 == 60.0 为真），是 entities.has(u) 查不中：
    # 不撕、返回 0.0，那几张挂到结算才被 _sync_entities 的兜底路径收走
    ("net/protocol.gd",
     '"empty_uids", "removed"]',
     '"empty_uids"]',
     "attack 的 removed 也掰了", "tests/test_protocol.gd"),

    # --- 21e. 摞里的次序：对手怎么排的，我这边就怎么摆 ---
    # 收方无条件提核心卡（改动之前的行为）。发方的规矩是「只有收拢才提」，
    # 两侧不一致有两个症状：摊开的摞次序在两个视角里不同；
    # 而且队首会跟着变 —— 重排是在「剔掉租约之后」的子集上算的
    ("scenes/settle_layout.gd",
     '''	if declared is bool and not bool(declared):
		return cards
	return Board.core_first_order(cards)''',
     '''	return Board.core_first_order(cards)''',
     "摊开的摞照他说的次序摆", "tests/test_net_piles.gd"),
    # 反过来：一律照原样，收拢态也不提核心卡 —— 摞顶露出来的是随便一张单位卡，
    # 这摞牌看不出在做什么
    ("scenes/settle_layout.gd",
     '''	if declared is bool and not bool(declared):
		return cards
	return Board.core_first_order(cards)''',
     '''	return cards''',
     "收拢态核心卡在摞顶", "tests/test_net_piles.gd"),

    # --- 22. 对手掉线：提示要挂得上、摘得下，掉线期间打不到他的牌 ---
    # 22a. 服务器不发「他回来了」。这条最难查：掉线提示**永久挂在**对手牌区，
    # 而对手明明已经回来了、每一步也都在动 ——
    # 「提示不消失」和「对手真的没回来」在屏幕上一模一样
    ("net/server.gd",
     "	var refilled := room.started() and room.full()",
     "	var refilled := false",
     "他回来之后提示摘掉了", "tests/test_foe_offline.gd"),
    # 22b. REQUIRED 里漏登记 foe_back。那张表是类型白名单，
    # 漏了不是「字段丢了」而是**整条被拒**（from_dict 返回 bad_type，
    # 客户端 push_warning 一句就算完）—— 症状同 22a
    ("net/protocol.gd",
     "	FOE_BACK: [],\n",
     "",
     "他回来之后提示摘掉了", "tests/test_foe_offline.gd"),
    # 22c. 掉线期间照样能打他的牌。服务器会照常裁决 ——
    # 他回来时拿的是结果快照，牌少了一批，中间那段演出一眼没看见
    ("scenes/main.gd",
     '''	if _foe_gone():
		_foe_offline_block("打他的牌")
		return''',
     '''	if false:
		_foe_offline_block("打他的牌")
		return''',
     "掉线期间点他的牌一张都没掉", "tests/test_foe_offline.gd"),
    # 22d. 掉线了但不挂提示（这条改动之前的行为：只收租约，不说话）。
    # 玩家看到的是「对手忽然不动了」，而这和「他在想」「网卡了」
    # 「程序崩了」在屏幕上是同一个样子。
    #
    # 锚点带上 `_show_message("对手断开`：那两行在 `_on_foe_left_drag` 和
    # 主机接管（24h 那条改的地方）各有一份，只写两行会撞两处、整条被 SKIP。
    # 24h 靠第三行 `_show_waiting_as_host` 区分，这条靠 _show_message 区分
    ("scenes/main.gd",
     '	_foe_online = false\n	_show_foe_offline_notice(true)\n'
     '	_show_message("对手断开',
     '	_foe_online = false\n	_show_message("对手断开',
     "对手掉线之后牌区挂出了提示", "tests/test_foe_offline.gd"),

    # --- 23. 认输：胜负要两边都算数 ---
    # 23a. CLIENT_OPS 漏登记。那张表决定「客户端发得动这条吗」，
    # 漏了服务器按 not_client_op 拒掉 —— 而我这边的面板是自己弹的，
    # 症状是「我看到我认输了，他那边还在等我行动」，两边各看一局
    ("engine/intent.gd",
     "	OP_ACTION_DONE, OP_RESIGN]",
     "	OP_ACTION_DONE]",
     "认输是客户端操作", "tests/test_resign.gd"),
    # 23b. 判成认输的那个赢。点了认输反而赢了 —— 这按钮就成了必胜键
    ("engine/game_state.gd",
     "	winner = opponent(who)\n	# 这里**故意**没写成",
     "	winner = who\n	# 这里**故意**没写成",
     "认输的是**输**的那个", "tests/test_resign.gd"),
    # 23c. 去掉 PhaseMachine 那道豁免。认输就成了「一种行动」：
    # 只在我的行动阶段、只在我还没收手时认得了。对手行动时（最想认的时候）
    # 撞 not_your_turn。这条是实跑才发现的 —— 光看 CLIENT_OPS 是通的
    ("engine/phase_machine.gd",
     "	if op == Intent.OP_RESIGN:\n		return {}",
     "	if false:\n		return {}",
     "他那条认输走通了", "tests/test_resign.gd"),
    # 23d. 第一下就认。认输没有撤回，而这按钮和联网入口同在左下角、
    # 同样 150×44 —— 手滑一次整局没了
    ("scenes/main.gd",
     "	if not _resign_armed:\n		_resign_armed = true",
     "	if false:\n		_resign_armed = true",
     "第一下不认输", "tests/test_resign.gd"),
    # 23e. 对手侧那个分支没了。他认输、服务器落地、我这份快照也跟着变成终局，
    # 但屏幕上什么都不发生：输入还开着，而我发出去的每条意图都被 game_over 拒掉。
    # 玩家看到的是「牌能拖，但一步也走不了，也没人告诉我为什么」
    ("scenes/main.gd",
     "		Intent.OP_RESIGN:\n			_render_foe_resign()",
     "		Intent.OP_RESIGN:\n			pass",
     "他认输之后我这边的结算界面自己弹出来了", "tests/test_resign.gd"),
    # 23f. 战报硬编成一句话（不带座位参数）。认输不动任何资源，
    # 前后两行之间看不出发生过什么 —— 这一行是复盘时唯一的线索，
    # 而硬编的话认输的人自己看到的也是「对手认输了」
    ("engine/game_state.gd",
     '	log_fmt("🏳 %s 认输了", [seat_arg(who)])',
     '	log_msg("🏳 对手认输了")',
     "那一行带着座位参数", "tests/test_resign.gd"),
    # 23g. win_reason 写成带视角的。它是裸字符串，state_codec 原样传给对端
    # （state_codec.gd 的 `snapshot()` 存、`restore()` 读，两边都只是搬），
    # 谁都不会再翻译它一次 ——
    # 赢的那位在终局面板上读到的是「你认输了」
    ("engine/game_state.gd",
     '	win_reason = "这局是认输结束的。',
     '	win_reason = "你认输了。这局是认输结束的。',
     "win_reason 视角中立", "tests/test_resign.gd"),

    # --- 24. 主机易位：开房那一位走了，剩下的这位接管（scenes/main.gd 的 _take_over_host） ---
    # 24a. adopt 不推 `_done`。`_done` 不在快照里（它是从 (phase, actor) 推的），
    # 不推的话接管出来的房认为「谁都还没收手」——
    # 症状是先手在同一个行动阶段里又能动一次
    ("engine/phase_machine.gd",
     "		if order.size() == 2 and who == str(order[1]):\n			_done[str(order[0])] = true",
     "		if false:\n			_done[str(order[0])] = true",
     "先手那格标着收过手了", "tests/test_host_takeover.gd"),
    # 24a2. 同一处的**后果面**：`_done` 空着的话后手收手时 mark_done 回 false
    # 并且把 actor 拨回先手 —— 玩家看到的是「接管之后先手在同一个行动阶段里
    # 又动了一次」。和 24a 同一个改动、不同的判据：前者判「标记对不对」，
    # 这一条判「错了会怎样」，而后者才是玩家真正看到的东西
    ("engine/phase_machine.gd",
     "	if (p == ACTION or p == ATTACK) and who != \"\":",
     "	if false:",
     "后手一收手这个行动阶段就结束了", "tests/test_host_takeover.gd"),
    # 24b. 池子没搬。pools 挂在 IntentApply 上而不是 GameState 上，
    # 所以它不在 StateCodec.snapshot 的覆盖范围里，得单独搬一次。
    # 漏了不报错：接管出来的房池子是空的，整段攻击当场跳过
    ("net/room.gd",
     '	applier.pools_restore(snap.get("pools", {}))',
     "	pass",
     "池子搬过来了", "tests/test_host_takeover.gd"),
    # 24c. 建了 PhaseMachine 就用（构造那一下会 reset_for_round）。
    # 打到一半的攻击回合退回行动阶段从头再来，而弹药已经花掉了
    ("net/room.gd",
     "	phase = PhaseMachine.new(state)\n	phase.adopt(phase_name, actor_seat)",
     "	phase = PhaseMachine.new(state)",
     "阶段按住在真实那一步上", "tests/test_host_takeover.gd"),
    # 24c2. PhaseMachine.adopt 自己走 reset_for_round 那条路（看着像是
    # 「初始化一个阶段机」该做的事）。走了的话不管传什么进来都会回到
    # 「行动阶段 + 先手先动」—— 打到一半的攻击回合从头再打一遍，
    # 而弹药已经花掉了。这一条钉的是 T1 的 p5，和 24c 不在同一层
    ("engine/phase_machine.gd",
     "func adopt(p: String, who: String) -> void:\n	phase = p\n	actor = who",
     "func adopt(p: String, who: String) -> void:\n	reset_for_round()\n	phase = p\n	actor = who\n	phase = ACTION\n	actor = state.action_order()[0]",
     "接管没把回合退回开头", "tests/test_host_takeover.gd"),
    # 24d. 令牌不种。接管的人拿旧令牌连自己开的房，seat_peer 走不到 resumed 支，
    # 于是按空位顺序发座 —— 坐错位的话两个人的牌当场对调
    # （快照里的牌是按座位名存的）
    ("net/room.gd",
     "	if my_seat != \"\" and my_token != \"\" and tokens.has(my_seat):\n		tokens[my_seat] = my_token",
     "	if false:\n		tokens[my_seat] = my_token",
     "接管者原来那串令牌种进去了", "tests/test_host_takeover.gd"),
    # 24e. 进已开局的房不补 phase。阶段既不在 seated 的载荷里也不在快照里
    # （它是 PhaseMachine 的量），不补的话这一位的 _phase 是空串 ——
    # 连上了、牌摆好了、一步都走不了，一条错都不报
    ("net/server.gd",
     "	if not fresh and room.started():\n		_send_one(from, Protocol.phase(room.phase.phase, room.phase.actor))",
     "	if false:\n		_send_one(from, Protocol.phase(room.phase.phase, room.phase.actor))",
     "服务器给重连的这位补了一条 phase", "tests/test_host_takeover.gd"),
    # 24f. 随机那一档（默认端口开不了时的退路）改回从默认端口起顺延。
    # 走到这一档说明 8910 正被占着，头号嫌疑就是对面那个刚死的进程
    # （他掉线不等于退了，就算退了 TIME_WAIT 也压着一会儿）——
    # 从 8910 往上顺的最糟结果是**顺回到那个半死的房上**：
    # 同一个端口号、不同的进程。
    # 判据在 test_embedded_host T6 的第二支（那边 8910 的占用状态是自己摆的，
    # 所以「该退到随机段」这件事是确定的；T3 那边靠机器状态，判不了这一层）
    ("net/embedded_host.gd",
     "	var lo := rng.randi_range(RANDOM_PORT_LO, RANDOM_PORT_HI - PORT_TRIES)\n	return start(lo, PORT_TRIES)",
     "	return start(DEFAULT_PORT, PORT_TRIES)",
     "没有顺延到", "tests/test_embedded_host.gd"),
    # 24g. 旧连接的信号不摘就换。socket 真正关闭时它还会发一条 disconnected，
    # 那条打到 _on_net_down 上，而那时候我已经是主机了 ——
    # 症状是刚接管成功就被自己锁死（输入锁上、结束回合按钮灰掉）。
    #
    # 锚点带上后面那句 `var net := NetTransport.new(...)`：
    # 「摘信号 + 关旧连接」这两行在 _clear_old_session_for_reconnect 里
    # 一模一样地出现了第二次（那条走的是「从面板重新进来」），
    # 光那两行的话锚点匹配 2 处，整条被 SKIP 掉
    ("scenes/main.gd",
     "	_detach_net_signals(old)\n	old.close()\n\n	var net := NetTransport.new(_host.url(), room_code)",
     "	old.close()\n\n	var net := NetTransport.new(_host.url(), room_code)",
     "旧连接的 disconnected 也摘了", "tests/test_host_takeover.gd"),
    # 24h. 接管完不标对手不在线。提示挂不上，而 _foe_gone() 那道门也开着 ——
    # 玩家对着一个已经不在的人照样打得动牌，服务器照常裁决
    ("scenes/main.gd",
     "	_foe_online = false\n	_show_foe_offline_notice(true)\n	_show_waiting_as_host(room_code)",
     "	_show_waiting_as_host(room_code)",
     "标成了对手不在线", "tests/test_host_takeover.gd"),
    # 24i. 白名单那道门拆掉（只看状态、不看关闭码）。被拒的四种
    # （bad_version / table_mismatch / room_full / bad_room）也会去接管，
    # 而那四种意味着对面服务器活着并且明确说了「不让你进」：
    # 玩家看到的是「被拒 → 自己开了一间房」，对手照新地址连过来撞上同一个原因
    ("scenes/main.gd",
     "	return code in TAKEOVER_CODES \\",
     "	return true \\",
     "断线之后输入锁上了", "tests/test_net_client.gd"),
    # 24j. 接管走 begin_net_game（看着像是「进联网局」该走的那条路）。
    # 它一路走到 _draw_net_table → _respawn_all → _fly_from，那是**重摆桌子**：
    # 局面一个字节都没变，而玩家看到所有牌当场跳到新的随机位置,
    # 读出来的意思是「这一局被重置了」
    ("scenes/main.gd",
     "	_swap_transport(net)\n	# 阶段可能**还没开过**",
     "	_swap_transport(net)\n	_respawn_all()\n	# 阶段可能**还没开过**",
     "牌一张都没跳位", "tests/test_host_takeover.gd"),
    # 24k. 接管之后不补开阶段。桌子摆了、服务器那条 action 还没到就断的话，
    # 此后没有任何人会去开它：新连接的 seated 撞在 _on_net_seated 开头
    # 那道「桌子摆过就不再摆」上，而 _on_net_phase 是一次性的、
    # 服务器又不会为一个已入座的人再广播一次
    ("scenes/main.gd",
     '	if not _net_phase_seen and keep_phase != "":\n		_on_net_phase(keep_phase, keep_actor)',
     "	pass",
     "接管之后阶段自己补开了", "tests/test_host_takeover.gd"),

    # 24l. 接管门里不看「这条连接曾经通没通」。no_server 那个码
    # （get_close_code() == -1）盖了两件事：连上过再断（主机真走了）、
    # 和压根没连上（地址打错）。后者去接管的话，玩家自己开一间房自己坐着，
    # 而对手拿着他手上那个错地址永远连不过来 —— 而且一条错都不报
    ("scenes/main.gd",
     "	return code in TAKEOVER_CODES \\\n		and _net != null and _net.ever_open \\",
     "	return code in TAKEOVER_CODES \\\n		and _net != null \\",
     "装上了这条连接", "tests/test_rematch.gd"),

    # 24m. ever_open 压根不置位（等于「所有连接都算没通过」）—— 反方向那一面：
    # 上面那条挡的是「误判成通过」，这条挡的是「真通过了也不认」，
    # 症状是主机走了却完全不接管，对局白丢
    ("net/net_transport.gd",
     "			ever_open = true\n",
     "",
     # 报的是**超时那条**而不是它后面「自己开出了服务器」那条：接管压根没发生，
     # _until 等 400 帧等不到，check(false) 之后直接 return，后面那些一条都没跑到
     "主机断开之后我这边自己接管了", "tests/test_host_takeover.gd"),

    # --- 25. 重连恢复摆放：断开再进来，摞要回到断开那一刻的样子 ---
    # 这一整段的症状是同一句玩家原话：「对手断连再加入对局的时候，
    # 一开始摆放并未完全恢复成断开时候的状态」。摞是纯表现（只活在
    # board.groups 里），两头都不会重发 —— 重连的人手里是一张照快照摆出来的
    # 空桌，留下的那一位的 _push_piles 又是比指纹去重的。所以数据只剩服务器有
    #
    # 25a. 服务器不记摞。这是整条链的源头：不记的话回放无从谈起，
    # 而两端都不报错 —— 症状就是重连之后摆放没恢复
    ("net/room.gd",
     '	piles[seat] = Protocol.pile_lists(msg.get("piles", []))',
     "	pass",
     # 关键字取**报警那条**的文案，不能取它下面那句 check(true, ...) 的
     # ——「服务器把他声明的摞记了下来」只在通过时打，测试红了它一个字都不出现，
     # 报表上是一条查无实据的 MISS（工具找的是 [FAIL] 行里的关键字）
     "服务器记下了他那两摞", "tests/test_net_resume_piles.gd"),
    # 25b. 「记一笔」挪到 `foe == 0 就 return` 之后（看着像是「先判能不能转发」
    # 该有的次序）。对手不在场时的声明全部丢掉 —— 而那正是最要紧的那一刻：
    # 他掉线了，我还在挪我的摞。恢复出来的是**更早**那一份，
    # 症状和完全没恢复只差一点点，更难查
    ("net/room.gd",
     '''	piles[seat] = Protocol.pile_lists(msg.get("piles", []))
	var foe := int(occupants.get(GameState.opponent(seat), 0))
	if foe == 0:
		return []''',
     '''	var foe := int(occupants.get(GameState.opponent(seat), 0))
	if foe == 0:
		return []
	piles[seat] = Protocol.pile_lists(msg.get("piles", []))''',
     "对手不在场时的声明也记上了", "tests/test_net_resume_piles.gd"),
    # 25c. 重连时不回放**他自己**那些摞。快照里没有摞（那不是状态），
    # 于是理牌把它们当散卡摊回资源堆：「我摆了半天的阵型，重连之后没了」
    ("net/server.gd",
     "		if not mine.is_empty():\n			_send_one(from, Protocol.my_piles(mine))",
     "		if false:\n			_send_one(from, Protocol.my_piles(mine))",
     "服务器回放了他自己那些摞", "tests/test_net_resume_piles.gd"),
    # 25d. 不回放**对手**那些摞。留下的那一位不会重发（分组没变，
    # 他的指纹一个字都没动），于是重连这位的 foe_piles 是空的，
    # 落点退回「按共几摞现算成整行居中」—— 对手明明把组合拖到了桌角
    ("net/server.gd",
     "		if not foe_of_his.is_empty():",
     "		if false:",
     "服务器回放了**对手**那些摞", "tests/test_net_resume_piles.gd"),
    # 25e. 新局不清记着的摞。上一局那些 uid 一个都不在场上了，
    # 双方在新局一开始各收到一份全是查不着的 uid 的回放
    ("net/room.gd",
     "	game_num += 1\n	piles.clear()",
     "	game_num += 1",
     "新局把记着的摞清了", "tests/test_net_resume_piles.gd"),
    # 25f. MY_PILES 漏登记进 REQUIRED。那张表是**类型白名单**，
    # 漏了不是「字段丢了」而是整条被拒（from_dict 返回 bad_type，
    # 客户端 push_warning 一句就算完）—— 症状同 25c
    ("net/protocol.gd",
     '	MY_PILES: ["piles"],',
     "",
     "服务器回放了他自己那些摞", "tests/test_net_resume_piles.gd"),
    # 25g. 收方把「中点」直接当「起点」用（不退半个跨度）。my_pile_lists 报的
    # 锚点是整摞 z 向的中点，而 _layout_group 要的是起点 ——
    # 每摞往南偏半个摞长，长摞还会被 clamp 按在近边上
    ("scenes/main.gd",
     "			at.z -= Board.z_span(ng) / 2.0",
     "			pass",
     "纵向回到原处", "tests/test_net_resume_piles.gd"),
    # 25h. 挡「在任何组里」而不是「在组合里」（改动之前的写法）。
    # 回放到达那一刻桌上的摞几乎全是理牌刚摞出来的（_respawn_all 末尾），
    # 于是我声明的资源卡一张都过不去、cs 恒不足 2 张 ——
    # 这个函数整个变成空转，而症状和压根没有回放**一模一样**
    ("scenes/main.gd",
     "			if in_combo.has(u):\n				continue",
     "			if board.group_of(entities[u]) != null:\n				continue",
     "回放进来之后那一摞立回来了", "tests/test_net_resume_piles.gd"),
    # 25i. 恢复完顺手理一次牌（看着像是「摆完该收口」）。_tidy_player_idle
    # 头一件事就是解散纯资源摞，而我声明的摞十有八九正是那个 ——
    # 刚立起来的摞当场被拆掉，等于这条回放没生效
    ("scenes/main.gd",
     "		_piles_fp = _piles_fingerprint(my_pile_lists())",
     "		_piles_fp = _piles_fingerprint(my_pile_lists())\n		layout._tidy_player_idle()",
     "回放进来之后那一摞立回来了", "tests/test_net_resume_piles.gd"),
    # 25j. 恢复完不对齐去重基准。基准还是掉线前那份旧值，而恢复出来的实况
    # 恰好和它相等（摞就是照那份立的）—— 于是往后一条都不发：
    # 留下的那一位看到的永远是我掉线前那份摆放
    # 换成 pass 而不是直接删：那一句是 `if restored > 0:` 底下**唯一**的语句，
    # 删掉剩一段注释，变异体连编译都过不去（GDScript 要求 if 后面有缩进块），
    # 报表上是 BROKE —— 什么都没测到
    ("scenes/main.gd",
     "		_piles_fp = _piles_fingerprint(my_pile_lists())\n		# **不能**在这儿理牌",
     "		pass\n		# **不能**在这儿理牌",
     # 关键字取「不白发广播」那条而不是「基准对齐了实况」那条：两条都会红，
     # 但前者说的是**症状**（对面收到一条纯冗余的摆放），后者说的是手法。
     # 报表上读到的那句话，要能直接看出玩家会看到什么
     "回放照原样立起来之后不白发广播", "tests/test_net_resume_piles.gd"),
    # 25k. 反方向：把基准清空。下一帧无条件发一条，内容和服务器手里那份
    # 一模一样 —— 一条纯冗余的广播
    ("scenes/main.gd",
     '		_piles_fp = _piles_fingerprint(my_pile_lists())\n		# **不能**在这儿理牌',
     '		_piles_fp = ""\n		# **不能**在这儿理牌',
     "基准不是空串", "tests/test_net_resume_piles.gd"),
    # 25l. 摘牌那一步删掉（回放的牌还挂在理牌摞里就编新组）。一张牌同时
    # 属于两个组，两个组各自重排它 —— 牌在两处之间来回跳
    ("scenes/main.gd",
     "		for c in cs:\n			board._detach_from_group(c)",
     "		pass",
     "没有牌同时属于两个组", "tests/test_net_resume_piles.gd"),

    # ---------- 26. 判活（心跳，Protocol v6）----------
    # 玩家那句「我作为主机断开后，无法重连，对手处也没有自动建立新的服务端」。
    # 接管那条路本来是好的，坏在它等的 disconnected 永远不来 ——
    # TCP 保序但**不保活**（实测记在 Protocol.PING 那段注释里）。
    # 由 tests/test_net_liveness.gd 盯着，那个文件头上写了为什么这一条
    # 是整套里少见的**要看墙钟**的判据

    # 26a. poll 里不调 _beat。心跳一条都不发，也永远判不出死 ——
    # 这是加这套东西之前的原样，也就是玩家报的那个场景
    ("net/net_transport.gd",
     "			_beat()",
     "			pass",
     "客户端量到了往返延迟", "tests/test_net_liveness.gd"),
    # 26b. 判死那一步删掉（心跳照发，但没有回音也不宣告）。
    # 症状：双方各自停在「对手忽然不动了」，而那和「他在想」分不开
    ("net/net_transport.gd",
     "		_closed = true\n		close()\n		disconnected.emit(\"no_server\",",
     "		if false:\n			close()\n			disconnected.emit(\"no_server\",",
     "服务器沉默", "tests/test_net_liveness.gd"),
    # 26c. 判死用一个**新造的码**而不是 no_server。功能上「也算宣告了断线」，
    # 而 main.TAKEOVER_CODES 认不出它 —— 留下那位收到一句红字提示，
    # 没有人去开新房：玩家看到的和什么都不做一模一样。
    # 这条钉的是两个文件之间的接缝，26b 那种正向判据抓不到它
    ("net/net_transport.gd",
     '		disconnected.emit("no_server",\n			"服务器 %.0f 秒没有回音（%s）"',
     '		disconnected.emit("silent",\n			"服务器 %.0f 秒没有回音（%s）"',
     "判死用的码在接管白名单里", "tests/test_net_liveness.gd"),
    # 26d. 阈值判反（>= 改成 <=）：一条**有回音**的连接每帧都判死 ——
    # 自己造断线。26b/26c 那种正向判据对这个坏法全绿
    #
    # 关键字取的是「双方都入座了」而不是「有回音的连接不会被判死」，
    # 虽然后者读起来正对这个坏法。原因是这个变异体**下不到那条判据**：
    # 判死每帧都成立，第一次 poll 就把连接关了 —— 握手压根走不完，
    # 四条判据全停在「入座」这一步上。那条「不会被判死」的 check 一次都没跑到。
    # 取一条跑不到的判据当关键字，报表上是一条查无实据的 MISS（工具找的是
    # [FAIL] 行里的关键字），而变异其实**被抓住了**。
    # 「入座失败」也正是玩家会看到的那一面：连上了，当场又掉
    ("net/net_transport.gd",
     "	if _seen_at != 0 and now - _seen_at >= int(silent_sec * 1000.0):",
     "	if _seen_at != 0 and now - _seen_at <= int(silent_sec * 1000.0):",
     "双方都入座了", "tests/test_net_liveness.gd"),
    # 26e. 收到东西不记 _seen_at。心跳照发、pong 照回，可那一笔不往前走 ——
    # 到点了照样判死一条好连接。症状同 26d，成因相反
    ("net/net_transport.gd",
     "	_seen_at = Time.get_ticks_msec()\n	var dec: Dictionary = Protocol.decode(text)",
     "	var dec: Dictionary = Protocol.decode(text)",
     "有回音的连接不会被判死", "tests/test_net_liveness.gd"),
    # 26f. pong 回来不量延迟。rtt_ms 是 PONG 那个分支**唯一**的观察点 ——
    # 判活那一笔记在 _on_text 最外面，任何消息都会记它，
    # 于是「pong 根本没回」和「pong 回了」在 _seen_at 上分不开
    ("net/net_transport.gd",
     "			if at > 0:\n				rtt_ms = Time.get_ticks_msec() - at",
     "			if at > 0:\n				pass",
     "客户端量到了往返延迟", "tests/test_net_liveness.gd"),
    # 26g. 服务器不回 pong。客户端判活看的是「有没有回音」，
    # 而 seated/phase/applied 这些也算回音 —— 所以真跑的时候
    # 这个坏法在**局中**看不出来，只在「连上了还没入座」那段现形（T2）
    ("net/server.gd",
     "			_send_one(from, Protocol.pong(int(msg.get(\"at\", 0))))",
     "			pass",
     "没入座的连接也量到了往返", "tests/test_net_liveness.gd"),
    # 26h. 把 ping 交给 _dispatch（看着更整齐：所有消息都走同一条路）。
    # 一条还没 join 的连接换回来的是 rejected("no_room") ——
    # 判活比房间早，这一条把次序弄反了
    ("net/server.gd",
     "			_send_one(from, Protocol.pong(int(msg.get(\"at\", 0))))",
     "			_dispatch(from, func(r): return [])",
     "没入座的连接也量到了往返", "tests/test_net_liveness.gd"),
    # 26i. 服务器这一侧不扫。对手的网断了（不是进程走了）时那条 socket
    # 停在 STATE_OPEN，服务器不知道人没了 —— 留下那位收不到 foe_left，
    # 而且**座位一直被占着**（26k 那条说的就是它的后果）
    ("net/server.gd",
     "	_sweep_silent()",
     "	pass",
     "服务器扫出了没声音的连接", "tests/test_net_liveness.gd"),
    # 26j. 扫出来了但不断开（只把记录擦掉）。下一轮扫他已经不在 peer_seen 里，
    # 于是**永远**不会再被扫到 —— 一条死连接就这么留在座位上了
    ("net/server.gd",
     "		peer_seen.erase(id)\n		_peer.disconnect_peer(id)",
     "		peer_seen.erase(id)",
     "服务器扫出了没声音的连接", "tests/test_net_liveness.gd"),
    # 26k. 扫的阈值判反：把**还在说话**的连接踢掉。
    # 症状是「打着打着被踹出去，一条错都不报」
    ("net/server.gd",
     "		if now - int(peer_seen[id]) >= limit:",
     "		if now - int(peer_seen[id]) <= limit:",
     "还在说话的那一位没被牵连", "tests/test_net_liveness.gd"),
    # 26l. 收到消息不刷新 peer_seen。每个连接都停在「连上那一刻」，
    # 30 秒之后**所有人**一起被踢 —— 包括一直在正常出牌的那位
    ("net/server.gd",
     "	peer_seen[from] = Time.get_ticks_msec()\n	var dec: Dictionary = Protocol.decode(text)",
     "	var dec: Dictionary = Protocol.decode(text)",
     "还在说话的那一位没被牵连", "tests/test_net_liveness.gd"),

    # ---- 27. 断线之后那道「回去的路」（scenes/main.gd 的 _offer_reconnect） ----
    # 这一组盖的是**入口的可达性**，不是网络。它的错法一律静默：
    # 屏幕上少一个按钮、或者多一个按钮，没有哪一种会报错
    #
    # 27a. 门不看「曾经连上过」。压根没连上过的连接也给开门 ——
    # 而那种情形下联网面板本来就在屏幕上，于是局中那个入口被顶亮。
    # 这是真踩过的回归：它把 test_rematch 那条「联网入口没被放回来」顶红
    ("scenes/main.gd",
     "	if _net != null and _net.ever_open:",
     "	if _net != null:",
     "入口照旧藏着", "tests/test_reconnect_door.gd"),
    # 27b. 门开了但房间码没存下来。玩家点进面板看到的是**空的房间码栏** ——
    # 而他多半也不记得那四个字符（是对手报给他的），于是这道门等于没开
    # 锚点带上下一行：`_reconnect_room = room` 单独一条会撞上
    # _show_waiting_as_host 里的 `_reconnect_room = room_code`（它含前者做子串）
    ("scenes/main.gd",
     "	_reconnect_room = room\n	_reconnect_hint = hint",
     '	_reconnect_room = ""\n	_reconnect_hint = hint',
     "房间码替他填好了", "tests/test_reconnect_door.gd"),
    # 27c. 状态都存对了，就是没把按钮亮出来。最像「修好了」的一种坏法：
    # _reconnect_room / _reconnect_hint 全对，面板进去了也确实填好 ——
    # 只是玩家**进不去那个面板**，因为按钮还是藏着的
    ("scenes/main.gd",
     "	_reconnect_share = share\n	if btn_net:\n		btn_net.visible = true",
     "	_reconnect_share = share\n	if btn_net:\n		btn_net.visible = false",
     "联网入口回来了", "tests/test_reconnect_door.gd"),
    # 27d. 掉线提示不带地址 —— 回到用户报的那个原样：接管出来的地址只走
    # _show_message，而**当时**那条提示停 2.6 秒就淡掉，
    # 之后屏幕上再也找不到它。而端口是随机挑的、只在我这一侧，
    # 回来那位手上就只剩一个房间码 —— 密码是对的，连不上的是地址。
    # 锚点带上后面那行 `if where`：`var where := _host_where_text()`
    # 在 _show_waiting_as_host 里还有一处，只改牌子这一处
    ("scenes/main.gd",
     '	var where := _host_where_text()\n	if where != "":',
     '	var where := ""\n	if where != "":',
     "牌子上有端口", "tests/test_reconnect_door.gd"),
    # 27e. 描边写死回 5。带地址时字号收到 30，而 30 × 12% = 3.6 ——
    # 越线就成空心字（见 _setup_pawnshop 那条）。
    # 这一条的坏法是「字在那儿但读不出来」，比没有更难查
    ("scenes/main.gd",
     "	lb.outline_size = maxi(1, int(lb.font_size * 0.1))",
     "	lb.outline_size = 5",
     "描边没超字号", "tests/test_reconnect_door.gd"),
    # 27f. 那道拦一律放行。玩家填自己那个老地址 → 连上、坐下（令牌还在）、
    # 然后 _clear_old_session_for_reconnect 里的 stop_local_host
    # 把他刚连上的服务器关掉。屏幕上是「连上了又断了」，一条错都没有
    ("scenes/join_panel.gd",
     "	return _port_of(url) == mine and _is_local_host_name(_host_of(url))",
     "	return false",
     "127.0.0.1 那个写法认得出来", "tests/test_reconnect_door.gd"),
    # 27g. 认得出来但**没接在按钮上**。这一条盖的是接线：
    # 去掉调用点的话 _is_my_own_host 自己那几条判据照旧全绿
    ("scenes/join_panel.gd",
     "	if _is_my_own_host(typed):",
     "	if false:",
     "一条连接都没开出去", "tests/test_reconnect_door.gd"),
    # 27h. 拿 ends_with 比字符串顶替抠端口。normalize_url 对已经带 ws:// 的
    # 地址原样返回，于是玩家粘进来的可能是 `ws://127.0.0.1:8910/` ——
    # 尾巴上那个斜杠让字符串比法漏掉，而它指的确实是自己那间房
    ("scenes/join_panel.gd",
     "	return _port_of(url) == mine and _is_local_host_name(_host_of(url))",
     '	return url.ends_with(":%d" % mine)',
     "带尾巴斜杠的也认得出来", "tests/test_reconnect_door.gd"),

    # ---------- 28. 接管开房的端口：先默认，占了才随机（用户第二轮那句
    # 「进程相当于就是关闭了，接下来靠客机启动服务器等主机重新连接」）----------
    #
    # 这一组盖的是「回来那位要不要去问一个数」。端口一律随机的那一版
    # 功能上全对 —— 房开着、局面在、座位对 —— 只是那个号只长在接管方屏幕上，
    # 而回来那位手里只有房间码（用户：「输入相同的密码还是连不上」）

    # 28a. 不试默认端口，直接随机 —— 回到用户报的那个原样。
    # 同机双开时本来一个字都不用改的地址，变成必须去问
    ("net/embedded_host.gd",
     "	var r := start(DEFAULT_PORT, 1)\n	if r[\"ok\"]:\n		return r\n	return start_random()",
     "	return start_random()",
     "默认端口空着就开在默认端口", "tests/test_embedded_host.gd"),
    # 28b. 默认端口那一试改成顺延一段。顺延**成功**比失败更糟：
    # 8911 既不是那个两边都知道的数，又不像随机端口那样一眼看出「得去问」，
    # 于是玩家照面板默认地址填 8910，撞在对面那个半死的房上
    ("net/embedded_host.gd",
     "	var r := start(DEFAULT_PORT, 1)",
     "	var r := start(DEFAULT_PORT, PORT_TRIES)",
     "没有顺延到", "tests/test_embedded_host.gd"),
    # 28c. 那道拦回到「只比端口」。端口改成默认之后这是**假阳性**：
    # 「我开着 8910」和「对手也开着 8910」从巧合变成常态，
    # 于是对手报来的 ws://192.168.x.x:8910 被当成我自己那间房拦掉 ——
    # 而那正是他唯一能连的地址。拦错比漏拦更难查
    ("scenes/join_panel.gd",
     "	return _port_of(url) == mine and _is_local_host_name(_host_of(url))",
     "	return _port_of(url) == mine",
     "同一个端口但是别人那台机器", "tests/test_reconnect_door.gd"),
    # 28d. 主机名只认回环写法，不认本机那些局域网 IP。
    # 报给对手的就是那一行（lan_urls），玩家很容易抄回自己的输入框里 ——
    # 那时候该拦的没拦住，走的还是「连上了又断了」那条路。
    #
    # **这一条要机器上有局域网地址才判得动**：lan_ips 是空的时候
    # （没连网的 CI）变异体和原文行为一致，mutate_check 会报 MISS 而不是漏判
    ("scenes/join_panel.gd",
     "	return host in EmbeddedHost.lan_ips()",
     "	return false",
     "照旧认得出来", "tests/test_reconnect_door.gd"),
    # 28e. 已经开局的房不再收「令牌对不上」的人。听着像一条合理的收紧
    # （局都开了还让陌生人进来干什么），而它砸掉的正是用户描述的那条路：
    # 原主机进程重来之后手里只有地址和房间码，令牌只在内存里、一起没了 ——
    # 于是他是一条**空令牌**的新连接，走的就是 free_seat 这一支。
    # 断掉之后服务器回一句「房间满了」，而房里只坐着一个人
    #
    # 为什么不直接写成「没令牌就不给座」：那样连**开局第一次入座**都砸了
    # （谁的第一条连接都没有令牌），测试在 _seated_scene 那一步就红，
    # 判据压根到不了 —— 实测 MISS，报的是 5 条「双方都入座了（a= b=）」
    ("net/room.gd",
     "	var s := free_seat()\n	if s == \"\":",
     '	var s := "" if started() else free_seat()\n	if s == "":',
     "空令牌的新连接", "tests/test_host_takeover.gd"),
    # 29. 全卡表逐张过一遍那套（tests/test_all_combos.gd）。四条都实跑验证过，
    # 括号里是当时红掉的断言条数。
    #
    # 29d 有段来历值得留着：它最初**没被抓住** —— 攻击卡那一圈从头到尾
    # 组合都是齐整的，闸门恒真，删掉整行照旧全绿（231/0）。补了
    # `_t2b_broken_combo_cannot_fire`（抽掉配方里一张料再看池子）才判得动。
    # 这正是 MISS 的第 2 类：不是判据松，是那个量没有读者
    ("engine/combo_rules.gd",
     '	result["attack_n"] = ldef["attack_n"] * (CardDB.buff_mult("attack_x2") if attack_x2 else 1)',
     '	result["attack_n"] = ldef["attack_n"]',
     "热搜让山寨攻击", "tests/test_all_combos.gd"),                    # 29a：红 4 条
    ("engine/combo_rules.gd",
     '		if ldef["recipe_res"] == CardDB.RES_CASH:\n			result["recipe_pay_n"] = int(ldef["recipe_n"])',
     '		result["recipe_pay_n"] = int(ldef["recipe_n"])',
     "用户配方是席位", "tests/test_all_combos.gd"),                    # 29b：红 14 条
    ("engine/settle.gd",
     "			_consume_upgrade_materials(state, combo, eval)",
     "			pass",
     "源卡被吃掉", "tests/test_all_combos.gd"),                        # 29c：红 10 条
    ("engine/game_state.gd",
     "		if not combo_intact(who, combo):\n			continue\n",
     "",
     "拆散后点数池归零", "tests/test_all_combos.gd"),                  # 29d：红 2 条
    # 30. 同名升级组拆到只剩一张时，金光要跟着灭。
    # refresh_group 的 size()<2 提前返回原先只退 D 位进度、不灭灯 ——
    # 症状只在同名组上看得见（升级组 2 张就成立，配方组最少 3 张，
    # 只有同名组会走「2 张亮着 → 1 张」这条跳过清理的路）
    # 锚点带上注释末行才唯一：下面 has_core 那条提前返回是一模一样的两行
    ("scenes/board.gd",
     "		# 在下面那条 is_valid=false 的路上就已经灭了，症状因此只在同名组上看得见\n"
     "		_set_group_highlight(g, false)\n",
     "",
     "留下的那张也要灭灯", "tests/test_merge.gd"),
    # 31. 配方核心 1 点/张（原先是「一减到底」的整体靶）。两条 bug 报告
    # ——「组合后的用户牌打不掉」和「一个组合消耗不完应当能继续打其他组合」
    # ——出自同一个门槛，所以两半各钉一条变异：
    # 31a 把定价改回整体靶，31b 把「已破的组不再是首选」这条闸门去掉
    ("engine/game_state.gd",
     '			for u in core:\n'
     '				out.append({\n'
     '					"kind": "combo", "uids": [u], "cost": per_card,\n',
     '			if not core.is_empty():\n'
     '				out.append({\n'
     '					"kind": "combo", "uids": core, "cost": core.size() * per_card,\n',
     "各自成靶", "tests/test_all_combos.gd"),                # 31a：红 7 条
    # 32. 「玩家打对方和 AI 打玩家，撕毁动画是同一套、速度也一样」。
    # 撕牌本身两边一直共用 _tear_out，差的是外面那层节拍 ——
    # 所以两条变异钉的都是节拍，不是撕牌
    # 32a：AI 不再按摞攒（batch 键作废）→ 回到一条意图一拍，7 张 6.3 秒
    # （锚点跟着 GameState.target_batch 的收口改过一次：batch 名原先在这里
    # 手写 str(target.get(...))，「一次只打一个组合」把这句读法收进了引擎）
    ("scenes/main.gd",
     '\t\tvar batch := GameState.target_batch(target)',
     '\t\tvar batch := ""',
     # 实跑：AI 侧 14 声（1 声命中×7 批 + 7 声逐张）、两边差 5396ms
     "耗时相差", "tests/test_attack_dbl.gd"),          # 32a：红 2 条
    # 32b：起飞时刻不再排在公用队上 → 分次进来的 N 张同时撕开，读作一团
    ("scenes/main.gd",
     '\tvar slot := maxi(_tear_slot_ms, now)\n'
     '\tvar i := 0',
     '\tvar slot := now\n'
     '\tvar i := 0',
     # 实跑：7 张全挤在同一时刻，铺开 0ms
     "逐张往后推", "tests/test_attack_dbl.gd"),        # 32b：红 2 条
    # 32c：双击成立后不清追踪 → 第三击和第二击再配成一对，一摞牌闪一下。
    # 登记这条时先抓出了判据自己的洞：A5 原先两击之间 await settle()（0.52s），
    # 而 DBL_WINDOW 是 0.45 —— 第三击隔那么久，**单靠「离上一击太远」**
    # 就判不成双击，这行删掉 107 条一条不红。改成 settle_within_dbl() 才判得动。
    # 和 33b 那个洞同一个形状：判据落在「坏」之外，不是落在「好」和「坏」之间
    ("scenes/board.gd",
     '\t\t\t\tvar t := _dbl_target(picked)\n'
     '\t\t\t\t_reset_click_track()',
     '\t\t\t\tvar t := _dbl_target(picked)\n'
     '\t\t\t\tpass',
     # 实跑：红 1 条（「第三击没再切回去」）
     "第三击没再切回去", "tests/test_attack_dbl.gd"),  # 32c：红 1 条
    # 33. 「把一堆资源拖到组合卡上，组合卡有时候会消失」。两条补间登记表
    # 各写一次 CardEntity.position，谁也掐不掉谁 —— 两条变异各断一头
    # 33a：main 那侧的补间不登记 → board 编组时无从知道这张牌还在飞
    ("scenes/main.gd",
     '\tcard.set_meta("fly_tw", tw)\n\treturn tw',
     '\treturn tw',
     "起飞时登记了补间", "tests/test_merge.gd"),        # 33a：红 2 条
    # 33b：board 编组时不再掐别人那条（登记了也白登记）。
    # 锚点选 is_valid() 这一句而不是整段：留着下面读 dest_pos 的代码，
    # 变异体才编译得过
    #
    # 这两条登记时先抓出了判据自己的一个洞：距离那条断言原先写 d < 1.0，
    # 理由是「一张卡宽 1.3」—— 而脱队的实测值是 0.89，比 1.0 小，
    # bug 值稳稳地从判据底下过去了（把三个场景文件整体退回修复前，
    # 那一条照旧是绿的）。阈值收到 0.4（落在实测的 0.05 和 0.89 中间）之后
    # 两条变异才都报得出来。判据要落在「好」和「坏」之间，不是落在「坏」外面
    ("scenes/board.gd",
     '	if cancel_anim.is_valid() and is_instance_valid(c):',
     '	if false:',
     "按到补间终点", "tests/test_merge.gd"),            # 33b：红 3 条
    # 34. 「选中一个组合就得把它打完」（GameState.ATTACK_LOCK）。三条变异
    # 分别断掉这条规则的三个关节：记锁、按锁收窄候选面、只有组合才上锁
    # 34a：打了不记 → 下一下又是满桌可选，3 点拆着打两个组
    ("engine/game_state.gd",
     '	if batch_locks(target):\n		pools[ATTACK_LOCK] = target_batch(target)',
     '	if false:\n		pools[ATTACK_LOCK] = target_batch(target)',
     "池子里记下了", "tests/test_engine.gd"),           # 34a：红 13 条
    # 34b：锁还记着，但候选面不收窄 —— 选靶的人照旧看见满桌，
    # 挑中别组时 apply_attack 那道护栏把它拦下，攻击阶段当场断在「点选失败」
    ("engine/game_state.gd",
     '	var lock := attack_lock(pools)\n	if lock == "":\n		return out',
     '	var lock := attack_lock(pools)\n	if true:\n		return out',
     "候选面收窄到", "tests/test_engine.gd"),           # 34b：红 3 条
    # 34c：散卡也上锁 → 「先削一张散卡、再拿余点拆组合」这条一直允许的打法
    # 被顺手禁掉了。规则管的是组合，不是散卡堆
    ("engine/game_state.gd",
     '	return str(target.get("kind", "")) in ["combo", "spare"]',
     '	return true',
     "散卡不上锁", "tests/test_engine.gd"),             # 34c：红 2 条
    # 35. 「AI 上一回合攻击完，下一回合那张攻击卡没了」。链条是：装弹吃掉组合
    # 自己的配方现金 → AI 手头紧到触发 pawn_relief → relief 跑在重建组合之前，
    # 此时 finalize 已清空 locked 和 combos，那张刚立过功的攻击卡在
    # _pawn_candidate 眼里就是废牌。三条变异断掉这条修复的三个关节
    # 35a：不记开火回合 → 后面全都无从判断
    ("engine/game_state.gd",
     '		if charge:\n			_mark_fired(who, combo)',
     '		if charge:\n			pass',
     # 实跑：红 2 条（夹具那条 + 判据那条）
     "真实开火后", "tests/test_audit_fixes.gd"),           # 35a：红 2 条
    # 35c：保护窗口收成「只保护本回合」→ 正好漏掉出事的那一回合。
    # bug 现场是**下一**回合被卖，`<= 1` 那个 1 就是这个跨度
    ("engine/game_state.gd",
     '	return round_num - int(c["fired_round"]) <= 1',
     '	return round_num - int(c["fired_round"]) <= 0',
     "标记跨结算保留到下一回合", "tests/test_audit_fixes.gd"),        # 35c：红 1 条

    # --- 36. 换货架漏注销：board.cards 无界增长 ---
    # 漏 unregister_card 不崩也不报错（遍历点都有 is_instance_valid 挡着），
    # 症状只在数组长度上看得见。原先 _next_round 自己抄了一份清理、独独漏了这句，
    # 合并成 _clear_market 之后一处管两条路
    ("scenes/main.gd",
     '''		if is_instance_valid(c):
			board.unregister_card(c)
			c.queue_free()''',
     '''		if is_instance_valid(c):
			c.queue_free()''',
     "换货架后 board.cards 里没有已释放引用", "tests/test_market.gd"),

    # --- 37. 同名升级阶梯：判据从卡表现算，不许写死张数/卡名 ---
    # 这三条是补上来的：test_dup_upgrade 是判据里改动最大的一份
    # （原先钉「上市敲钟典当 70」这类具体数字，现在钉「两条路终点相同」这类恒等式），
    # 而在补之前**整张变异表一条都没守着它** —— 判据换成推导之后到底还判不判得动，
    # 没有任何东西验证过。凭「注释里写了改坏会红」不算数
    #
    # 37a：T1 直达路线整条从配置里删掉。T1×2 仍能凑对应 T2，所以低档照旧绿；
    # 断的是 upgrade_dup_n×2 那几档（【2b】整节），以及「一步和两步同一个终点」。
    # 路线表搬进配置之后，这个坏法**代码一个字都不用改** —— 表里少一行而已，
    # 所以变异也得下在表上，才是在验「少一条路线会不会被抓住」
    ("data/cards.json",
     '      { "kind": "product", "tier": 1, "key": "dup_key", "per": 2, "require_multiple": true },\n',
     '',
     "直达", "tests/test_dup_upgrade.gd"),
    # 37b：奇数张也去顶 T2。整数除法把 3 张当 1 张用，而 dup_t2 没有「×1」那一档，
    # 所以 ×3 仍旧落空 —— 真正露出来的是 ×5（5/2==2，正好撞上最低那档）。
    # 关键词因此不能取「奇数张」那条（它压根不红），要取实际红的那句
    ("data/cards.json",
     '{ "kind": "product", "tier": 1, "key": "dup_key", "per": 2, "require_multiple": true }',
     '{ "kind": "product", "tier": 1, "key": "dup_key", "per": 2, "require_multiple": false }',
     "只认偶数张", "tests/test_dup_upgrade.gd"),
    # 37d：折算率改成 3。T1 认的档跟着变成 upgrade_dup_n×3，
    # 原先的 ×4/6/8 全部落空、×6/9/12 顶上来（实测红 75 条）。
    #
    # **这条的意义要说清楚**：改 per 本来是合法调档（`_upgrade.routes` 里的 `per`），
    # 凡是从配置推期望值的判据都会跟着变、照旧全绿 —— test_config_complete
    # 整节就是这样，它守的是「代码不听配置」那一侧（见 44b）。
    # 真正红的是 test_dup_upgrade 里那些**从 per=2 隐含推出来的话**：
    # 「T1 只认偶数张」（per=3 之后 ×9 也成立了）和写着具体张数的那几节。
    # 所以这条守的东西是：调这个旋钮，必然有判据拦下来要求同步 ——
    # 而不是悄悄改掉整套升级阶梯
    ("data/cards.json",
     '{ "kind": "product", "tier": 1, "key": "dup_key", "per": 2, "require_multiple": true }',
     '{ "kind": "product", "tier": 1, "key": "dup_key", "per": 3, "require_multiple": true }',
     "直达", "tests/test_dup_upgrade.gd"),
    # 37e：代码不再按路线的 per 折算，写死成一张顶一张。
    # 配置里 per 还是 2，代码当 1 用 —— 这是「配置写了、代码不听」那一类，
    # 而它不报错，只是传说卡那几档静默合不出来
    ("engine/combo_rules.gd",
     '		var want_n: int = n / per',
     '		var want_n: int = n',
     "直达", "tests/test_dup_upgrade.gd"),
    # 37c：生产卡闸门去掉 → 攻击卡/Buff 卡跟着上车。
    # tier 1 不等于生产卡，而 upgrade_from 的对照只看张数，
    # 少了这道闸门「山寨×4」也会合出传说卡。
    # 闸门现在是路线表上的 kind 那一维，所以变异下在「代码不再看 kind」上 ——
    # 配置照旧写着 product，代码谁都放进来（and 短路，r["kind"] 不会被求值）
    ("engine/combo_rules.gd",
     '		if r.has("kind") and str(r["kind"]) != str(src.get("kind", "")):',
     '		if false and str(r["kind"]) != str(src.get("kind", "")):',
     "没有升级路线", "tests/test_dup_upgrade.gd"),
    # 37f：档位闸门去掉 → T2 也去试 T1 那条 per=2 的路线。
    # tier 那一维和 kind 是两回事，各自守一条
    ("engine/combo_rules.gd",
     '		if r.has("tier") and int(r["tier"]) != int(src.get("tier", 0)):',
     '		if false and int(r["tier"]) != int(src.get("tier", 0)):',
     "直达", "tests/test_dup_upgrade.gd"),

    # --- 38. 玩家理牌摊成几列：代码得听 PLAYER_PILE_* 那几个常量 ---
    # 同样是补上来的：test_tidy 原先一条变异都没有。
    # 注意不能拿常量自己做变异（`PLAYER_PILE_PER_COL := 8` 改成 4）——
    # 判据里每列几张是从这个常量读的，改常量两边一起变，照旧全绿，
    # 而那本来就是「配置调档、判据跟着走」的正常行为。
    # 该守的是**代码不再听常量**：常量还写着 8，代码按别的数切
    #
    # 38a：列的 x 不再按节距递增 → 所有列摞在锚点同一个 x 上。
    # 判据里那串「x 从锚点起、按 PLAYER_PILE_COL_PITCH 递增」正是为它留的
    ("scenes/settle_layout.gd",
     '		var origin := anchor + Vector3(col * PLAYER_PILE_COL_PITCH, 0, 0)',
     '		var origin := anchor',
     "节距", "tests/test_tidy.gd"),
    # 38b：每列张数改成写死的 4（常量仍是 8）。
    # 开局那点现金（`_game.start_cash`）于是比常量该给的多摊出几列，
    # 判据比的是整个分摞形状
    ("scenes/settle_layout.gd",
     '''	while col * PLAYER_PILE_PER_COL < pile.size():
		var chunk: Array = pile.slice(col * PLAYER_PILE_PER_COL,
			mini((col + 1) * PLAYER_PILE_PER_COL, pile.size()))''',
     '''	while col * 4 < pile.size():
		var chunk: Array = pile.slice(col * 4,
			mini((col + 1) * 4, pile.size()))''',
     "张分", "tests/test_tidy.gd"),

    # --- 39. 悬停说明里的升级阶梯：代码得照卡表报，不许自己拍数 ---
    # 补的：test_hover_desc 原先只有一条变异守着（而且守的是防御膜那句）。
    # 判据刚从「同名×4/6/8」这类字面改成从卡表现算，改完到底还判不判得动，
    # 在补这两条之前没有任何东西验证过
    #
    # 39a：传说卡说明里的张数不再读 upgrade_dup_n，写死成最低那档。
    # 判据两头各验一档（最高档和最低档），最高那档因此报错数
    ("scenes/board.gd",
     '			var dup: int = int(def.get("upgrade_dup_n", 0))',
     '			var dup: int = 2',
     "说明写清要", "tests/test_hover_desc.gd"),
    # 39b：试到的张数上界退回写死的小数，T1 直达传说那几档被砍掉尾巴。
    # 上界原本 = dup_t2 最高档×2；砍到 5 之后最高那两档试不出来，
    # 「同名×N/N/N → 传说卡」那一行就少了尾档
    ("scenes/board.gd",
     '	for n in range(2, CardDB.max_upgrade_n() + 1):',
     '	for n in range(2, 5):',
     "直达传说卡的", "tests/test_hover_desc.gd"),

    # --- 40. 座位映射：场景层念 my_seat，不许退回硬编 GameState.PLAYER ---
    # 补的：test_seat_map 原先零覆盖。它是全仓唯一一条把座位对调着跑的判据
    # （其余全跑 my_seat=PLAYER），所以这类退化**只有它抓得住** ——
    # 换句话说，没有变异守着它，就等于没人验证过「它还抓得住」
    ("scenes/settle_layout.gd",
     '	var is_near: bool = who == _main.my_seat',
     '	var is_near: bool = who == GameState.PLAYER',
     "落在近侧", "tests/test_seat_map.gd"),
    # 40 的第二条：理牌收集错座位 —— 玩家侧的理牌锚点上摞的成了对手的散卡。
    # 判据挂 test_tidy 而不是 test_seat_map：后者压根不触发 _tidy_player_idle
    # （实测挂过去 MISS，且是「失败 0 条」——不是关键词不对，是那份判据没走到这条路）。
    # 替换值也故意不写 `GameState.PLAYER`：写了会被 test_seat_map 里那条
    # **静态扫源码**的判据（「场景层无硬编码座位」）抓住，于是变异只验到扫描器、
    # 验不到摆位。写 foe_seat 两头都绕开，逼它靠牌摆错位置暴露
    ("scenes/settle_layout.gd",
     '	var piles := _collect_idle_units(_main.my_seat)',
     '	var piles := _collect_idle_units(_main.foe_seat)',
     "张分", "tests/test_tidy.gd"),

    # --- 40b. 理牌时「编了组的不算散牌」这道闸（玩家侧）---
    # 补的：test_tidy 那对新判据（2026-09-01 加，原先那条空断言只复述编组前的快照）
    # 现在真的编组后重扫散牌，得有变异盯着。
    # 闸门一去，编进组合那 recipe_n 张也被当散牌收走 —— 散牌于是按
    # start_user + recipe_n 张重排（10 + 7 = 17 张，每列 8 张 → [8,8,1]），
    # 列数和各列张数当场对不上，「仍只统计散牌」和「散牌只占 N 列」两条一起红。
    #
    # 锚点取 2 个 tab 那版：`for g in board.groups` 全文三处 —— `_collect_idle_units()`
    # 这道闸、`_tidy_player_idle()` 里那句 `.duplicate()`、`_relift_remainders()`，
    # 缩进不同才唯一。只写 `for g in board.groups:` 会撞 `_relift_remainders()`
    # 那处（见 check_anchors）
    ("scenes/settle_layout.gd",
     '\t\tfor g in board.groups:\n\t\t\tfor c in g["cards"]:\n\t\t\t\tgrouped[c.uid] = true',
     '\t\tfor g in []:\n\t\t\tfor c in g["cards"]:\n\t\t\t\tgrouped[c.uid] = true',
     "仍只统计散牌", "tests/test_tidy.gd"),

    # --- 41. D 位配方进度的分母得读卡表 ---
    # 补的：test_scene 原先零覆盖，而它那条「D 位显示 N/N」现在整条从 recipe_n 推。
    # 分母写死之后卡面念的就不是这张卡的配方量了
    # 替换值不能取被测那张卡的 recipe_n（取了就是空变异：卡面照旧念对，判据全绿）。
    # 这里故意取一个和它不同的数，让分母当场对不上
    ("scenes/card.gd",
     '	_recipe_need = int(def.get("recipe_n", 0))',
     '	_recipe_need = 5',
     "D 位显示", "tests/test_scene.gd"),

    # --- 44. 配置完备性：路线表和音效表都得是唯一那一份 ---
    # test_config_complete 换了个方向验：不看行为对不对，看**事实来源有没有变回两份**。
    # 它守的那几种坏法行为上全绿，所以这三条变异也都不是「功能坏了」型的
    #
    # 44a：音效表里少一个动作。代码里那句 play("combo_complete") 于是
    # 走到 Sfx.action 的 push_error 分支 —— 报了错，但游戏照跑、那一声没了。
    # 「配方凑满没有风铃声」这种事玩家不会报 bug，他只会觉得手感不对
    ("data/ui.json",
     '      "combo_complete": {\n        "sound": "complete",\n        "db": -2.0\n      },\n',
     '',
     "代码里用到的动作名配置里全都有", "tests/test_config_complete.gd"),
    # 44b：代码不按路线上的 per 折算，写死成一张顶一张。
    # 配置里 per 还是 2、代码当 1 用 —— 「配置写了、代码不听」那一类，
    # 不报任何错，只是传说卡那几档静默合不出来。
    # 和 37e 是同一处改动、不同判据：这条盯的是新那份从配置推期望值的判据
    ("engine/combo_rules.gd",
     '		var want_n: int = n / per',
     '		var want_n: int = n',
     "各档都对上 dup_key 侧同一张", "tests/test_config_complete.gd"),
    # 44c：响度写死在 play 里。配置那一档从此调了没反应，
    # 而响度不进任何行为判据 —— 全表除了这一条都是绿的。
    # 这也是 T4 非要起真场景读那 10 个 AudioStreamPlayer 的原因：
    # 替身的 play 是照配置自己算一遍，写死在 production 那句上它照旧全绿
    ("scenes/sfx.gd",
     '	p.volume_db = float(spec.get("db", 0.0))',
     '	p.volume_db = -4.0',
     "播出来是配置那一档", "tests/test_config_complete.gd"),

    # --- 46. 典当折价率得是唯一那一份 ---
    # 这个数原先有四份：CardDB.pawn_value 里两处、两个 python 检查各一处，
    # 外加 balance.md 三句散文和 README 一句里的「÷2」。抽成 `_game.pawn_rate` 之后
    # 分工是：代码不听配置 → test_pawn 红；散文没跟着改 → check_balance_numbers 红
    #
    # 46a：代码不按配置那个率折（写死成另一个数）。
    #
    # **替换值不能取 2.0**（= 配置现值）：那样期望和实际一起用旧率、一起对上，
    # 三条实测全 MISS —— memory 里那两种空判的第一种，「换的值恰好合法」。
    # 写死本身要等到有人调配置才发作，而那一刻这条判据就红了（见 46d）。
    # 所以这里改成 3.0：配置说 2.0、代码用 3.0，当场就是「代码不听配置」
    ("engine/card_db.gd",
     '		return maxi(1, roundi(price / pawn_rate()))',
     '		return maxi(1, roundi(price / 3.0))',
     "= round(标价/", "tests/test_pawn.gd"),
    # 46b：材料购价那一路不听配置。和 46a 是两条独立的路
    #（可购卡走标价、T2 走材料购价），各自能单独坏掉
    ("engine/card_db.gd",
     '		return maxi(1, roundi(int(get_def(from_id)["price"]) * dup_n / pawn_rate()))',
     '		return maxi(1, roundi(int(get_def(from_id)["price"]) * dup_n / 3.0))',
     "成本回收", "tests/test_pawn.gd"),
    # 46c：用户卡那个价钱不听配置
    ("engine/card_db.gd",
     '		return pawn_user() if def.get("res") == RES_USER else 0',
     '		return 2 if def.get("res") == RES_USER else 0',
     "一张换这么些现金", "tests/test_pawn.gd"),
    # 46d：折价率改成 3。这是**合法调档**（`_game.pawn_rate` 是配置项），
    # 所以 test_pawn 照旧全绿 —— 红的是那三句留在原地的散文。
    # 这条和 46a-c 合起来说明分工：一边守「代码听不听配置」，
    # 一边守「文档跟不跟配置」，缺哪边都有一整类坏法没人看
    ("data/cards.json",
     '    "pawn_rate": 2.0,',
     '    "pawn_rate": 3.0,',
     "T2 的折价率", "tools/check_balance_numbers.py"),

    # --- 47. README.md §「2.5 购买与典当」里 **典当行** 那段的六个配置事实 ---
    # 这段原先零覆盖：check_card_table 的 docstring 说它守「README 的回收价列」，
    # 而它只读 balance.md（那句已改）。于是 README 这句话里的用户卡价钱、
    # 折价率两处、T2 张数、三张传说卡的价钱，六个数全是手抄的、谁也不查
    #
    # 47a：用户卡价钱调了，README 没跟着改
    ("data/cards.json",
     '    "pawn_user": 1\n  },',
     '    "pawn_user": 2\n  },',
     "用户卡的价钱", "tools/check_balance_numbers.py"),
    # 47b：某张传说卡的回收价调了。逐张比而不是合成一个片段，
    # 所以报得出来是**哪一张**漂了
    # 锚在 flavor 那行 + pawn 两行上：`"pawn": 70` 单独一句撞两处
    #（国民应用和上市敲钟同价），只改一处等于随机挑一张，报出来指不到人
    ("data/cards.json",
     '    "flavor": "上至八十下至八岁，人手一个",\n    "pawn": 70',
     '    "flavor": "上至八十下至八岁，人手一个",\n    "pawn": 65',
     "的回收价", "tools/check_balance_numbers.py"),
    # 47c：README 那段被改写，锚点从此命中 0 行。
    # 这一路和「数字对不上」是两种失败：锚点失配意味着这条判据**静默失效**，
    # 六个数一个都不再有人看，比抄错一个数更危险（见文件头「锚点怎么定」）
    # 关键字取固定的「锚点」标签，不跨格式插值，确保静态检查也能识别
    ("README.md",
     '**典当行**',
     '**典当铺**',
     "锚点「", "tools/check_balance_numbers.py"),

    # ---- 48 新文件里播声音，动作名拼错 ----
    #
    # 盯的是 test_config_complete T3 的**扒取范围**。那条判据原先只读三份
    # （main/board/card）写死的名单，而眼下只有 main.gd 真在播 —— 名单是防以后的，
    # 可它防不住「以后」落在名单外。改成枚举 scenes/ 整个目录之后这条才成立。
    #
    # 为什么不能靠 Sfx.action() 里那句 push_error 兜：**实测它印的是 `ERROR:`**，
    # 而 run_tests.sh 只把 `SCRIPT ERROR` 当失败（见那边 rt_err 那段）。
    # 所以拼错动作名的下场是「那一声不响」+ 全套全绿，两道防线一起失效。
    # 顺带一提，`ERROR:` 不能简单地也加进那道网：这份判据自己就故意播一次
    # 不存在的动作（T4 那条「配置里没有的动作名不占池子」），加了它当场变红
    #
    # 48a：在旧名单外的文件里加一句播放，名字配置里没有。
    # 用「锚点 + 自身」的写法追加一个函数：变异表只会做替换，
    # 而这条要验的坏法本身是**新增**一处调用。
    #
    # 那句 play 必须**真的编译得过**：直接写 `sfx.play(...)` 是
    # `Parse Error: Identifier "sfx" not declared`（sfx 是 main.gd 的成员），
    # 报 BROKE 而不是抓住 —— 判据只把这些文件当文本读，可 Godot 启动时
    # 会把带 class_name 的脚本全解析一遍。所以声明一个真的 Sfx 局部变量，
    # 留在 null 分支里不执行：要验的是「源码里有这么一处调用」，不是它跑起来
    ("scenes/palette_panel.gd",
     'func _ready() -> void:',
     'func _probe_bogus_sfx() -> void:\n'
     '\tvar sfx: Sfx = null\n'
     '\tif sfx != null:\n'
     '\t\tsfx.play("meiyouzhege")\n\n\n'
     'func _ready() -> void:',
     "代码里用到的动作名配置里全都有", "tests/test_config_complete.gd"),
    # 48b：扒取范围自己被改回写死的名单 —— 判据静默失效那一路。
    #
    # **第一次登记时是 MISS**，而且是必然的：`for rel in _scene_scripts()` 一换，
    # 那个函数整个不再被调用，里面的 check 一条都不执行 —— 少一条断言不等于红
    # （实测 29 条变 28 条、0 失败）。判据被掏空，而它自己看不见。
    # 于是把范围记进 _scanned、在 T3 外面拿目录列表对账，这条才有人接
    ("tests/test_config_complete.gd",
     '	for rel in _scene_scripts():',
     '	for rel in ["res://scenes/main.gd"]:',
     "scenes/ 下每一份 .gd 都扒过了", "tests/test_config_complete.gd"),

    # ---- 49 行号引用重新爬回来 ----
    #
    # 盯 check_no_line_refs.py。这份检查有个特殊难处：**全仓扫完是 0 处**，
    # 所以「把它改弱」不会让任何数字变化 —— 正则写成永不匹配，输出照旧是
    # 「0 处」、照旧退出 0。这正是 48b 那个病（判据被掏空而它自己看不见），
    # 所以那边加了 SELFTEST 夹具，49b/49c 验的就是夹具真的在拦
    #
    # 49a：有人在文档里写回一处行号引用 —— 这是这份检查的正业。
    # 落点选那句已经改成函数名的（原先三处都拿行号指 combo_rules.gd，
    # 指的还是 `evaluate()` 上一行，从写下那天起就偏一行）
    # **这一轮换过文件**：原落点在 balance.md 已删的那节里，那句诊断现在在
    # README「一个用户值多少钱」那段。锚点得带上后面那句才唯一
    ("README.md",
     '`engine/combo_rules.gd` 的 `evaluate()`（用户没有消耗出口）',
     '`engine/combo_rules.gd:140`（用户没有消耗出口）',
     # 关键字取「写了行号引用」而不是表头那句「不许写行号引用」：
     # 捕获判定只看 `  - ` 那些失败行，表头不在其中（第一次登记就是这么 MISS 的）
     "写了行号引用", "tools/check_no_line_refs.py"),
    # 49b：正则被改成认不出裸 `:58` 那种（冒号前的前视放宽成任意字符）。
    # 放宽之后端口 `ws://[::1]:8910`、比例 `3:4` 全成违规，扫全仓当场一片红 ——
    # 可那是**误报**方向，看着也像「检查在干活」。夹具里那条反例专治这个：
    # 它要求端口/比例/时间必须被放过，改宽了就是夹具红，而不是全仓红
    ("tools/check_no_line_refs.py",
     r"BARE_LINE = re.compile(r'(?<=[\s(（、,，])([:：]\d+)')",
     r"BARE_LINE = re.compile(r'(?<=.)([:：]\d+)')",
     "夹具", "tools/check_no_line_refs.py"),
    # 49c：docstring 的**续行**不再算正文 —— 只看「这一行以什么开头」那一版。
    # 第一版就是这么写的，于是当时那个 _check_doc_lines.py（已删）docstring 里
    # 拿行号指 combo_rules 的那句整个漏掉：它在三引号块的中段，前面既没 `#`
    # 也没三引号。而那恰好是当时全仓最后一处，「0 处」看着像扫干净了。
    # 这条一去，全仓仍是 0 处、仍退出 0 —— 只有 SELFTEST_DOC 接得住
    ("tools/check_no_line_refs.py",
     '        if in_doc:\n            out.append((i, line))',
     '        if in_doc:\n            pass',
     "docstring 取舍", "tools/check_no_line_refs.py"),

    # --- 50. 历史诊断的两个观测量：组合刚被拆散、受保护的生产组合 ---
    # 这两个量是**只写不读**的：规则一条都不依赖它们，坏掉的方式全是静默的 ——
    # 报告照样打印，数字照样是个数字，只是不再对应任何东西。
    # 当前手动调参 Q1–Q9 不依赖它们；历史诊断仍需保证事件语义正确。
    # 所以四条变异分别对着「克制」的两个合取项、和「成型」的两道过滤
    #
    # 50a：克制丢掉 was_intact —— 打同一个已破组的第 2、3 张核心都各记一次，
    # 同一个组的失效会被重复计数
    ("engine/game_state.gd",
     "\t\t\tvoided = broke and was_intact",
     "\t\t\tvoided = broke",
     "组早就破了，不该再刷一次爽点", "tests/test_engine.gd"),
    # 50b：克制丢掉 broke —— 富余料顶上、配方压根没破的那一下也算克制。
    # 登记时这一条**先活下来过**：当时只测了 kind=spare（走的是另一个 match 分支，
    # 那支里 voided 恒为 false），漏了「打核心但富余顶上」这一例。
    # 补上那一例才咬住 —— 空洞的绿比红更难发现
    ("engine/game_state.gd",
     "\t\t\tvoided = broke and was_intact",
     "\t\t\tvoided = was_intact",
     "富余料顶上、配方没破", "tests/test_engine.gd"),
    # 50c：成型丢掉「只认生产组合」—— 升级组合的 protect_quota 是 0、核心天然为空，
    # 每次升级都会记成一次成型，即使从未出现受保护的生产组合
    ("engine/game_state.gd",
     '''		if combo["owner"] != who or combo["eval"].get("type") != "production":
			continue''',
     '''		if combo["owner"] != who:
			continue''',
     # 关键字取「只认生产组合」而不是「记下的是生产组合」：真红的是攻击组合那一例
     # （核心被 Buff 罩住 → 按字面满足「核心为空」），后一句在它下游、跑不到
     "只认生产组合", "tests/test_engine.gd"),
    # 50d：成型丢掉「核心点得到就不算」—— 什么生产组都算成型，
    # 「无解」这个词整个失去意义
    ("engine/game_state.gd",
     '''			if vulnerable.has(u):
				sealed = false
				break''',
     '''			if false:
				sealed = false
				break''',
     "的核心露在外面", "tests/test_engine.gd"),
    # 51j：档位没接到搜索上 —— `run_rounds` 收下 cfgs 就扔了。
    # 这条针对的是**空洞的绿**：强度那一串判据量的都是「参数对象长什么样」，
    # 参数被忽略的话它们全绿，而 `tools/eval.sh 500 0 max` 会印出
    # 一个规规矩矩的 50% 胜率
    #
    # 锚点带上后一行才唯一：`continue_from_attack` 抽出 `_loop_rounds` 之后，
    # 这一句在这个文件里有两处（`run_rounds` 的循环 和 `_loop_rounds`）。
    # 打的是 `run_rounds` 那一处 —— 那是 `tools/eval.sh` 走的入口
    #
    # 关键字盯的是**第 1 回合的快照**那条，不是终局哈希那条。这条曾经 MISS 过：
    # 选靶纳入搜索之后 `run_rounds` 里的 `Settle.run(state, cfgs)` 也读 cfgs，
    # 于是把行动阶段的 cfg 摘掉、终局照旧变，判据绿着。
    # 修法是把观察点挪到 `Settle.run` 还没跑过的那一刻
    ("engine/match_simulator.gd",
     '\t\t\taction_phase(state, who, cfgs.get(who))\n\t\tif not before_settle.is_null():',
     '\t\t\taction_phase(state, who)\n\t\tif not before_settle.is_null():',
     "改变第 1 回合的行动结果", "tests/test_ai_search.gd"),
    # 51t：`Settle.run` 不把 picker 穿下去。选靶于是永远是那份四档权重表 ——
    # 这**正是改造前的状态**：`attack_phase` 的 `target_picker` 参数早就在，
    # 只是无头这条路上没有调用方给得出一个会搜索的 picker。
    # 判据不能只看「参数存在」，得看那一条实参真的算出了 picker
    ("engine/settle.gd",
     '\tattack_phase(state, order[0], AIPlan.target_picker(cfgs.get(order[0])))',
     '\tattack_phase(state, order[0])',
     "满档的选靶真的在搜索", "tests/test_ai_search.gd"),

    # ---------- AI 参数面板（scenes/ai_panel.gd） ----------
    #
    # 这一段守的是「玩家点得到、点了有用」。参数层那一整串判据
    # （上面 51a~51j）一条都不看画面 —— 面板整块从 canvas 上摘掉，
    # 它们全绿。那正是 net/ 那一层踩过的坑（测试全绿而玩家点不到）
    #
    # 52a：面板不挂上去。第 2 条要的那个 tab 于是根本不存在，
    # 而 AISearch 的判据一条不少地全过
    ("scenes/main.gd",
     '\tvar aip := AIPanel.new()\n\taip.above = pal\n\tcanvas.add_child(aip)',
     '\tvar aip := AIPanel.new()\n\taip.above = pal',
     "面板在场景树里", "tests/test_ai_panel.gd"),
    # 52b：`above` 不赋值 —— 面板改去贴屏幕顶边，和配色面板叠在一起。
    # 这条钉的是「贴在配色下方」那个位置要求（第 2 条：结构类似于配色 tab）
    ("scenes/main.gd",
     '\taip.above = pal\n\tcanvas.add_child(aip)',
     '\tcanvas.add_child(aip)',
     "AI 面板在配色面板下方", "tests/test_ai_panel.gd"),
    # 52c：`main.gd` 移除新搜索前读取当前设置的接线，重规划继续沿用阶段开始时的值。
    # 面板拖得动、摘要照变，但下一次决策没有采用新参数。
    # 参数层判据全绿（它们直接调 prefs()，不经过 main.gd）
    ("scenes/main.gd",
     '\tagent.config_provider = AISearch.prefs',
     '\tagent.config_provider = Callable()',
     "场景层读玩家偏好", "tests/test_ai_live_parameters.gd"),
    # 52d：`_syncing` 护栏破掉。回填每一行会触发 toggled / value_changed，
    # 那两个回调往下写 set_override —— 于是**拖一下滑块就给每个旋钮盖一层覆盖**，
    # 滑块从此失灵（覆盖盖住档位），面板上只多一个星号
    ("scenes/ai_panel.gd",
     '\tif _syncing:\n\t\treturn\n\tAISearch.set_override(key, on)',
     '\tAISearch.set_override(key, on)',
     "回填没有反过来写覆盖", "tests/test_ai_panel.gd"),
    # 52c2：屏幕那条路整个空转 —— AI 回合什么都不做。
    # 「跑完没崩」那种判据抓不住它（空转也叫没崩），所以 test_ai_panel
    # 在这条路上数了落地的意图条数。这条同时是那个计数判据的非空证明
    #
    # 锚点搬过一次：双工那一步在这两行之间插进了 `agent.think = _think_off_thread`，
    # 原先那份「构造 + await」的连写从此不相邻。现在只钉 await 那一行
    ("scenes/main.gd",
     '\tagent.think = _think_off_thread\n\tawait agent.run_action_phase(_ai_beat)',
     '\tagent.think = _think_off_thread',
     "真的经管道落了意图", "tests/test_ai_panel.gd"),
    # 52d2：整数那一行的护栏。和 52d 是两段独立的代码（bool 走 CheckBox.toggled，
    # int 走 SpinBox.value_changed），删任一段都要有人报 ——
    # 只钉 bool 那段的话，把 int 那段的护栏删掉一条判据不红
    ("scenes/ai_panel.gd",
     '\tif _syncing:\n\t\treturn\n\tAISearch.set_override(key, int(v) if kind == "int" else v)',
     '\tAISearch.set_override(key, int(v) if kind == "int" else v)',
     "回填没有反过来写覆盖", "tests/test_ai_panel.gd"),
    # 52e：回填整个不跑 —— 拖滑块之后每一行还显示上一档的数。
    # 玩家照着面板上的数判断「现在 AI 有多强」，而那是错的
    ("scenes/ai_panel.gd",
     '\tAISearch.set_pref_strength(v)   # 会清掉逐项覆盖：拖滑块 = 整档换掉\n\t_sync_rows()',
     '\tAISearch.set_pref_strength(v)   # 会清掉逐项覆盖：拖滑块 = 整档换掉',
     "每一行显示的都是这一档的真值", "tests/test_ai_panel.gd"),
    # 52f：星号不打。有逐项覆盖时滑块的数已经不能描述 AI 强度了，
    # 不标出来的话「滑块在 0 但 AI 在搜索」看着像 bug ——
    # 玩家会去查代码，而代码是对的
    ("scenes/ai_panel.gd",
     '\tvar star := "*" if AISearch.has_overrides() else ""',
     '\tvar star := ""',
     "读数带星号", "tests/test_ai_panel.gd"),
    # 52g：拖滑块就落盘。AI 参数只在本次运行中生效，不应再生成偏好文件。
    # 直接注入写盘，避免依赖已经移除的 save() API 导致变异仅被语法检查拦住。
    ("scenes/ai_panel.gd",
     '\tAISearch.set_pref_strength(v)   # 会清掉逐项覆盖：拖滑块 = 整档换掉',
     '\tAISearch.set_pref_strength(v)\n\tvar stale := FileAccess.open(AISearch.USER_PATH, FileAccess.WRITE)\n\tstale.store_string(JSON.stringify({"strength": v}))\n\tstale.close()',
     "拖滑块不落盘", "tests/test_ai_panel.gd"),
    # 52h：跟随失效 —— 改成记一个常量偏移。配色面板一展开，两块面板就叠在一起
    ("scenes/ai_panel.gd",
     '\t\ttop = above.offset_bottom + GAP',
     '\t\ttop = 56.0 + GAP',
     "跟着下移", "tests/test_ai_panel.gd"),
    # 52i：档位按钮的 tooltip 念错档。面板和 `tools/eval.sh` 认的是同一批档位名
    # （ai_panel.gd `_build_presets` 那条注释），说明念错的话玩家照着报告调不出同一个 AI
    #
    # tooltip 直接读取该预设的实际强度，不能写死成其他档位。
    ("scenes/ai_panel.gd",
     '\t\tb.tooltip_text = "强度 %.2f" % float(AISearch.PRESETS[key])',
     '\t\tb.tooltip_text = "强度 %.2f" % 0.5',
     "悬停说明念的是它真会设的强度", "tests/test_ai_panel.gd"),
    # 52j：展开之后压根不重算高度，面板还是折叠时那么高 ——
    # 里头的行被裁在框外。
    # 这条原先锚在 `await get_tree().process_frame\n\t_relayout()` 上，
    # 而那句 await 本身就是 bug（见 54e）：min size 在改完 visible 的同一帧
    # 就已经是新值了，await 只买来一帧的不一致。修掉之后锚点跟着换到这里。
    #
    # 关键字**不是**「展开后面板变高」了 —— 那条现在有第二道防线兜着：
    # 54g 那个 minimum_size_changed 一样会触发重算，只是晚一帧，
    # 而「展开后面板变高」那条判据前面等了两帧，照旧全绿（实测）。
    # 去掉 _relayout 之后唯一还看得见的破坏就是那一帧的不一致，
    # 所以钉的是零间隔那条判据
    ("scenes/ai_panel.gd",
     '\t_toggle.text = "收起" if _body.visible else "展开"\n\t_relayout()',
     '\t_toggle.text = "收起" if _body.visible else "展开"',
     "当帧就自洽", "tests/test_ai_panel.gd"),

    # ---------- 53：牌局录像（engine/tape.gd + 场景层的接线） ----------
    # 53a：不报意图只报结果。录像录的就是 landed_intent —— 不发它，
    # 磁带永远是 0 步，而存出来的文件形状完全正常（看着像「这一局什么都没发生」）
    ("engine/intent_apply.gd",
     '\t\tlanded_intent.emit(dec["intent"], from_seat)',
     '\t\tpass',
     "这一步进了录像", "tests/test_tape.gd"),
    # 53b：报的是**入参**而不是规范化后的那份。入参可能是一段 JSON 文本
    # （联网那条路就是），也可能是一份 uid 全是 double 的字典 ——
    # 前者进了磁带就不是 Dictionary 了，读磁带的代码全得先猜类型
    ("engine/intent_apply.gd",
     '\t\tlanded_intent.emit(dec["intent"], from_seat)',
     '\t\tlanded_intent.emit(intent if intent is Dictionary else {}, from_seat)',
     "录进去的都是规范化后的字典", "tests/test_tape.gd"),
    # 53c：先报结果再报意图。landed 的回调里还能再落地一条意图
    # （AI 那几条就是），于是子意图排在父意图**前面** ——
    # 重放时子意图先跑，它依赖的那张卡还没出现
    ("engine/intent_apply.gd",
     '\t\tlanded_intent.emit(dec["intent"], from_seat)\n\t\tlanded.emit(r)',
     '\t\tlanded.emit(r)\n\t\tlanded_intent.emit(dec["intent"], from_seat)',
     "父意图（买）排在子意图（典当）前面", "tests/test_tape.gd"),
    # 53d：来路座位不录（一律按空的存）。
    #
    # 注意它**抓不到重放**：重放照样逐字相同。真正决定动谁的牌是意图里那个
    # `seat`，`from_seat` 只管冒充校验，而那道闸门头一个条件就是
    # `from_seat != ""` —— 抹平之后整道闸门被跳过，客户端那几条全都放行。
    # 所以 T1 里专门有一条逐步比来路的判据（memory: vacuous-mutation-two-flavors）
    ("engine/tape.gd",
     '\t\t"from": from_seat,',
     '\t\t"from": "",',
     "每一步的来路座位都录对了", "tests/test_tape.gd"),
    # 53e：哈希不录。replay 里 `want == ""` 就不比，于是逐步比对**整段静默跳过**——
    # 重放永远「一致」，定位能力整个没了。
    # 注意抓住它的是 T5（拿磁带上的哈希和停在那一步的状态对）而不是 T1 的末态判据：
    # 末态那条比的是「重放结果 vs 现场状态」，一个字段都没读磁带
    ("engine/tape.gd",
     '\t\t"hash": StateCodec.state_hash(_applier.state),',
     '\t\t"hash": "",',
     "逐步停都停得准", "tests/test_tape.gd"),
    # 53f：每一步存的是**上一步**的哈希（差一步）。这一份磁带看着一切正常 ——
    # 每步都有值、步数也对、末态也对（末态那条比的是重放结果不是磁带），
    # 只有「停在第 k 步」时才露出来：报出来的分叉步号一律差一
    ("engine/tape.gd",
     '\t\t"hash": StateCodec.state_hash(_applier.state),',
     '\t\t"hash": str((steps[-1] as Dictionary)["hash"]) if not steps.is_empty() else "",',
     "逐步停都停得准", "tests/test_tape.gd"),
    # 53g：开局快照不存池子。攻击点数池在裁决器身上，既不在 GameState 里
    # 也不在 state_hash 里 —— 从攻击回合中途存的那份重放时
    # 「还没装弹」当场拒掉第一步（联网那边踩过同一个坑）
    ("engine/tape.gd",
     '\thead_pools = applier.pools_snapshot()',
     '\thead_pools = {}',
     "带着池子重放得动", "tests/test_tape.gd"),
    # 53h：head 存的不是「此刻」而是一局的开头（只存种子重开一份）。
    # 中途开始录的那份就此追不上：种子是起点，而录的这一刻已经抽过几十个随机数
    ("engine/tape.gd",
     '\thead = StateCodec.snapshot(applier.state)',
     '\tvar _fresh := GameState.new()\n'
     '\t_fresh.rng_restore(applier.state.rng_snapshot())\n'
     '\t_fresh.new_game()\n'
     '\thead = StateCodec.snapshot(_fresh)',
     "零步重放 = 开录那一刻的状态", "tests/test_tape.gd"),
    # 53i：重放不还原开局快照，从 new_game 现开一局。
    # 从开局录的那份**照样绿**（那时两者恰好一样），只有中途录的才红 ——
    # memory: vacuous-mutation-two-flavors 的第一种（换的值恰好合法）
    ("engine/tape.gd",
     '\tStateCodec.restore(s, t.head)',
     '\ts.new_game()',
     "中途录的这一份重放末态也逐字相同", "tests/test_tape.gd"),
    # 53j：upto 不裁。要「停在第 k 步」时一路跑到底 ——
    # 报出第 k 步不对之后就再也读不到 k-1 那一刻的局面了
    ("engine/tape.gd",
     '\tvar n: int = t.steps.size() if upto < 0 else mini(upto, t.steps.size())',
     '\tvar n: int = t.steps.size()',
     "逐步停都停得准", "tests/test_tape.gd"),
    # 53k：分叉了不报，接着往下跑。「末态不一致」这句话没有排查价值 ——
    # 分叉可能发生在三百步之前，而这个功能存在的理由正是答「哪儿开始不一致」
    ("engine/tape.gd",
     '\t\tif want != "" and want != got:',
     '\t\tif false:',
     "报的是状态分叉", "tests/test_tape.gd"),
    # 53l：落不了地也接着跑。后面那些必然连锁失败，
    # 报出来的第一处就不是真正的那一处了
    ("engine/tape.gd",
     '\t\tif not r.get("ok", false):',
     '\t\tif false:',
     "报的是第 3 步落不了地", "tests/test_tape.gd"),
    # 53m：版本对不上也尽力解析。格式不符时重放出来的分叉是假的，
    # 比读不出来更费时间
    ("engine/tape.gd",
     '\tif v != VERSION:',
     '\tif false:',
     "版本对不上的录像被拒了", "tests/test_tape.gd"),
    # 53n：读磁带时不过 Intent.from_dict（照抄 JSON 读出来的那份）。
    # uid 全是 double —— 重放本身不会错（apply 内部还要再规范化一次），
    # 错的是所有**读磁带**的代码：目录、按 uid 找那一步、界面上标「哪张卡出问题」
    ("engine/tape.gd",
     '\t\t\t"intent": dec["intent"],',
     '\t\t\t"intent": ((e as Dictionary)["intent"] as Dictionary).duplicate(true),',
     "读回来的 uid 都是整数", "tests/test_tape.gd"),
    # 53o：场景层不开录（等玩家按键才开始）。按下才录会把最有用的那种 bug
    # 排除在外：玩家看到不对劲的时候，导致它的那几步已经过去了
    ("scenes/main.gd",
     '\ttape.start(pipe.applier(), "界面局")',
     '\tpass',
     "开局就在录了", "tests/test_tape.gd"),
    # 53p：重开一局不重新指向新的裁决器。录像还连在**上一局**那份上，
    # 于是新局一步都录不到 —— 而界面上一点表现都没有，
    # 存出来的文件也完全正常（只是短得离谱）
    ("scenes/main.gd",
     '\tpipe = LocalTransport.new(IntentApply.new(state))',
     '\tif pipe == null:\n\t\tpipe = LocalTransport.new(IntentApply.new(state))',
     "重开一局换了裁决器", "tests/test_tape.gd"),
    # 54a：存录像按钮不挂到画面上（回到「只有 F5」那一版）。
    # 上面 53a-53p 一条都不会红 —— 它们走 tape.save() 和 pipe，
    # 谁也不看画面上有没有这颗按钮。用户就是在这一步找不到入口的
    ("scenes/main.gd",
     '\tbtn_save.pressed.connect(_save_replay)\n\tcanvas.add_child(btn_save)',
     '\tbtn_save.pressed.connect(_save_replay)',
     "存录像按钮在场景树里", "tests/test_tape.gd"),
    # 54b：按钮在画面上但没接线。比 54a 更坏：看得见、点得着、什么也不发生
    ("scenes/main.gd",
     '\tbtn_save.pressed.connect(_save_replay)\n\tcanvas.add_child(btn_save)',
     '\tcanvas.add_child(btn_save)',
     "点一下真存出一份", "tests/test_tape.gd"),
    # 54c：面板预填回环地址。两台机器时对面照着默认值按下去连的是它自己 ——
    # 而 _share_hint 那条判据照旧全绿（它自己去调 lan_urls，不看输入框）
    ("scenes/join_panel.gd",
     '\t_url_edit = _edit(default_url())',
     '\t_url_edit = _edit(DEFAULT_URL)',
     "预填的不是回环", "tests/test_join_panel.gd"),
    # 54d：没有局域网地址时不兜底回环，直接给个空串。
    # 那一支平时跑不到（开发机都有地址），所以要单独钉：
    # 空地址会让「同机双开」这条路也断掉
    ("scenes/join_panel.gd",
     '\tif ips.is_empty():\n\t\treturn DEFAULT_URL',
     '\tif ips.is_empty():\n\t\treturn ""',
     "没有局域网地址时兜底成回环", "tests/test_join_panel.gd"),
    # 54e：展开 / 收起时 await 一帧再重算框子。那一帧里 visible 和按钮文案
    # 都翻了、框子还是旧的 —— 协程没恢复就永久停在
    # 「按钮写着展开、底下压着一大片空框子」（用户报的就是这个）
    ("scenes/ai_panel.gd",
     '\t_toggle.text = "收起" if _body.visible else "展开"\n\t_relayout()',
     '\t_toggle.text = "收起" if _body.visible else "展开"\n'
     '\tawait get_tree().process_frame\n\t_relayout()',
     "当帧就自洽", "tests/test_ai_panel.gd"),
    # 54f：选色面板同款（同一个缺陷的两处）
    ("scenes/palette_panel.gd",
     '\t_toggle.text = "收起" if _body.visible else "展开"\n\t_relayout()',
     '\t_toggle.text = "收起" if _body.visible else "展开"\n'
     '\tawait get_tree().process_frame\n\t_relayout()',
     "选色面板连按", "tests/test_ai_panel.gd"),
    # 54g：内容自己变尺寸时不重算框子。开关那条路照旧全绿 ——
    # 漏的是 _sync_rows：读数多一个星号，收起态下星号被切掉
    ("scenes/ai_panel.gd",
     '\tget_node("Frame").minimum_size_changed.connect(_relayout)',
     '\tpass',
     "读数变长之后框子跟着变宽", "tests/test_ai_panel.gd"),
    # ---- 55：三处「玩家要拿走的信息」（tests/test_copyable_info.gd）----
    # 55a：左上角资源面板改成吃鼠标。取牌是 board.gd 在 _unhandled_input 里打射线
    # 做的，Control 吃掉的事件到不了那儿 —— 而这块面板盖的正是对手牌区的投影。
    # 症状是「屏幕左上角那几张牌点不动」，画面上没有任何东西暗示那儿有层玻璃
    ("scenes/main.gd",
     '\tpc.mouse_filter = Control.MOUSE_FILTER_IGNORE',
     '\tpc.mouse_filter = Control.MOUSE_FILTER_STOP',
     "面板不吃鼠标事件", "tests/test_copyable_info.gd"),
    # 55b：底改成实心。半透明是要求的一部分（用户原话「半透明的tab」）——
    # 实心那块把底下对手的明牌挡死，而看得见对手阵型是玩法的一部分
    ("scenes/main.gd",
     '\tsb.bg_color = Color(0.08, 0.09, 0.12, 0.55)',
     '\tsb.bg_color = Color(0.08, 0.09, 0.12, 1.0)',
     "底是半透明的", "tests/test_copyable_info.gd"),
    # 55c：录像路径退回那条会淡出的提示。这一条钉的就是用户那句原话
    # 「当前保存路径的提示是直接渲染到画面，这个不合适」—— 改回去之后
    # 一切看着正常，只是路径 2.6 秒后消失、而且从来选不中
    ("scenes/main.gd",
     '\tsave_notice.show_saved(abs_path, tape.size())',
     '\t_show_message("录像已存：%s" % abs_path, Color(0.7, 1, 0.7))',
     "存完之后面板立起来了", "tests/test_copyable_info.gd"),
    # 55d：路径框关掉选中。**看不出来** —— 关着的 LineEdit 和开着的长得一样，
    # 而这块面板存在的唯一理由就是那行路径抄得走
    ("scenes/save_notice.gd",
     '\t_path_edit.selecting_enabled = true',
     '\t_path_edit.selecting_enabled = false',
     "选得中 —— 这是这块面板存在的理由", "tests/test_copyable_info.gd"),
    # 55e：分享地址那一块永不立起来。接管成功、这一局没丢，
    # 而对手永远收不到新地址（端口可能已经变了，老地址连不上任何东西）
    ("scenes/join_panel.gd",
     '\t_share_row.visible = true',
     '\t_share_row.visible = false',
     "面板上立着分享地址那一块", "tests/test_copyable_info.gd"),
    # 55f：分享框关掉选中。同 55d，钉的是用户那句「并且，可以选中复制」
    ("scenes/join_panel.gd",
     '\t_share_edit.selecting_enabled = true',
     '\t_share_edit.selecting_enabled = false',
     "选得中 —— 用户那句", "tests/test_copyable_info.gd"),
    # 55g：接管之后不把地址存给面板。面板打得开、房间码也填好了，
    # 就是没有那行地址 —— 而那行是这次改动唯一要交付的东西
    ("scenes/main.gd",
     '\t_reconnect_share = where',
     '\t_reconnect_share = ""',
     "存下来的分享地址里有端口", "tests/test_copyable_info.gd"),
    # 55h：只读闸门失效 → 局中那两颗连接按钮点得动。按一下「加入对局」会
    # emit joined → _on_net_joined → _clear_old_session_for_reconnect →
    # stop_local_host，**把自己正驮着这一局的服务器关掉**。
    # 屏幕上看着是「点开个面板，牌桌就废了」，一条错都不报
    ("scenes/join_panel.gd",
     '\tvar live := _read_only',
     '\tvar live := false',
     "「加入对局」禁着", "tests/test_copyable_info.gd"),
    # 55i：只读态也去锁桌面。这一局还在打（对手可能正连回来），
    # 而玩家只是开面板抄一行地址 —— 锁下去之后他自己的牌不动了
    ("scenes/join_panel.gd",
     '\tif _read_only:\n\t\treturn\n\tvar board: Node = _main.get("board") if _main else null\n'
     '\tif board:\n\t\t_board_was_locked = bool(board.get("input_locked"))',
     '\tvar board: Node = _main.get("board") if _main else null\n'
     '\tif board:\n\t\t_board_was_locked = bool(board.get("input_locked"))',
     "桌面**没被锁**", "tests/test_copyable_info.gd"),

    # ---- 56. 提示不许自己消失 + 录像存在牛马牌自己的目录里 ----
    # 用户原话：「游戏开局左上角出现了一行字又消失了，杜绝这种突然出现又消失的
    # 提示，既看不清楚，也无法复现」/「录像保存路径调整为"牛马牌"app路径」。
    # 那句抱怨里的两个理由要两样东西治：不淡出（治「看不清」）+
    # 留一份记录（治「无法复现」）。这一组两边都钉

    # 56a：提示不再进记录 —— 回到用户报的原样的**后半**。屏幕上那句还在,
    # 但前后脚来的两条里第一条永久找不回来了。
    # 这一条最像「已经修好了」：开局那句照旧看得见，只有翻记录时才发现是空的
    ("scenes/main.gd",
     "\tif msg_log:\n\t\tmsg_log.append(",
     "\tif false and msg_log:\n\t\tmsg_log.append(",
     "被顶掉的第一句还在记录里", "tests/test_no_vanishing.gd"),
    # 56b：alpha 推回 0 —— 「补间删了但 alpha 忘了推回来」那个坏法的原样。
    # text 是对的、父子关系是对的、记录也是对的，只有屏幕上是空白。
    # T1 里单独钉 modulate.a 就是为了这一条
    ("scenes/main.gd",
     '\tlbl_msg.add_theme_color_override("font_color", color)',
     '\tlbl_msg.add_theme_color_override("font_color", color)\n\tlbl_msg.modulate.a = 0.0',
     "而且**看得见**：alpha 还是 1", "tests/test_no_vanishing.gd"),
    # 56c：提示条改成吃鼠标事件。常驻 + STOP 凑一起才是真的坑 ——
    # 它盖住的那块地方**永久**点不到牌（board.gd 打射线取牌）。
    # 从前只盖 2.6 秒，所以这条是「不淡出」这个改动新引进来的风险
    ("scenes/main.gd",
     "\tlbl_msg.mouse_filter = Control.MOUSE_FILTER_IGNORE",
     "\tlbl_msg.mouse_filter = Control.MOUSE_FILTER_STOP",
     "不吃鼠标事件", "tests/test_no_vanishing.gd"),
    # 56d：认输过期时把提示条**清空**而不是换一句。这是「凭空消失」的
    # 原样重现 —— 按钮复原了、屏幕上那句失效的话没了、而没人说过它为什么没了。
    #
    # 注：改的是那个字符串，不是把整个调用注掉。整句 _show_message(...)
    # 横跨两行，只注掉头一行会留下一个没人要的续行（`Expected statement,
    # found "Indent"`），变异体压根编译不过 —— 那种「红」是我写坏了，
    # 不是判据抓到了
    ("scenes/main.gd",
     '\t\t\t_show_message("认输取消了（等太久）。真要认输就再点一次",',
     '\t\t\t_show_message("",',
     "而且不是清空", "tests/test_no_vanishing.gd"),
    # 56e：bbcode 不转义。房间码是玩家自己敲的（join_panel →
    # _show_waiting_as_host → _show_message，这条路上没人洗过），
    # 敲进一个真标签的话后面整段被当格式吃掉 —— 症状是记录里凭空少几行,
    # 而「少了几行」这件事在屏幕上看不出来。
    #
    # 判据挑的是「我自己那个 [/color] 有没有漏进正文」：喂 `[百亿补贴]`
    # 那种测不出来（_bb_probe.gd 实测：不是认得的标签，转不转义都一样）
    ("scenes/msg_log.gd",
     '\tvar safe := text.replace("[", "[lb]")',
     "\tvar safe := text",
     "我自己那个结束标签没漏进正文", "tests/test_no_vanishing.gd"),
    # 56f：计数器不涨。标题栏永远写「0 条」，于是收起态**说不出自己藏了什么**——
    # 玩家没有理由去按那个展开钮
    ("scenes/msg_log.gd",
     "\t_total += 1",
     "\tpass",
     "条数涨了 2", "tests/test_no_vanishing.gd"),
    # 56g：丢错头 —— 满了之后留最旧的、丢最新的。
    # 「翻回去看刚才发生了什么」正好落空，而记录看着是满的
    ("scenes/msg_log.gd",
     "\tvar start: int = maxi(0, lines.size() - MAX_LINES)",
     "\tvar start: int = 0",
     "最旧那条被挤掉了", "tests/test_no_vanishing.gd"),
    # 56h：上限失效（照收不丢）。几百条之后 RichTextLabel 全量重排,
    # 越按展开越卡 —— 而卡的原因在屏幕上看不出来
    ("scenes/msg_log.gd",
     "\tfor i in range(start, lines.size()):",
     "\tfor i in range(0, lines.size()):",
     "存着的行数封在上限附近", "tests/test_no_vanishing.gd"),
    # 56i：单向开关 —— 展开之后收不回去。这是用户报过的那个 bug 的原样
    # （原话「AI强度tab无法正确展开和收齐」），换个面板又长出来一次
    ("scenes/msg_log.gd",
     "\t_body.visible = not _body.visible",
     "\t_body.visible = true",
     "再按一下 → 收回去了", "tests/test_no_vanishing.gd"),
    # 56j：断掉尺寸信号。框子从此**冻在收起态那么高**（48），而 body 展开着 ——
    # 一大片内容溢出到框子外面，压的是玩家自己的桌面区。
    #
    # 注：钉的是这条连接，不是 _toggle_body 里那句 _relayout()。
    # 那一句实测是冗余的（注掉它两头的位置尺寸每帧都一样），
    # 拿它当锚点得到的是「退出码 0、失败 0 条」——判据看着有洞，其实是
    # 变异本身什么都没改坏
    ("scenes/msg_log.gd",
     "\t_frame.minimum_size_changed.connect(_relayout)",
     "\tpass",
     "offset 跟着宽度重算过了", "tests/test_no_vanishing.gd"),
    # 56k：标题栏不报条数。收起态只写「提示记录」——
    # 它藏着玩家刚错过的那一行，而它说不出来（同 side_spec 那条的坏法）
    ("scenes/msg_log.gd",
     '\t_title.text = "提示记录 · %d 条" % _total',
     '\t_title.text = "提示记录"',
     "标题栏报了条数", "tests/test_no_vanishing.gd"),
    # 56l：默认展开。这一块在右下角且必须是 STOP（要点钮、要选文本），
    # 默认展开等于开局就有一片 380x300 的地方点不到牌
    ("scenes/msg_log.gd",
     "\t_body.visible = false",
     "\t_body.visible = true",
     "开局是**收起**的", "tests/test_no_vanishing.gd"),
    # 56m：录像目录退回 user://。改完路径照样报得出来、文件也真在那儿,
    # 只是落在 …/Application Support/… 底下 —— 正是用户点名要挪走的地方。
    # 「存哪儿」这种事没有判据的话，改回去谁也不会发现
    ("engine/tape.gd",
     "\treturn home.path_join(DIR_NAME)",
     "\treturn ProjectSettings.globalize_path(PATH_DIR_FALLBACK)",
     "不在 Application Support 底下", "tests/test_no_vanishing.gd"),
    # 56n：`~` 不展开。存出来的是一个**真叫 `~` 的相对目录**，
    # 落在进程的工作目录底下 —— 也就是仓库根，录像存进 git 里去了。
    # 而这个坏法在屏幕上看不出来：面板照样念出一条路径，文件也真在那条路径上
    ("engine/tape.gd",
     '\t\tvar v := OS.get_environment(key)\n\t\tif v != "":\n\t\t\treturn v',
     '\t\tvar v := OS.get_environment(key)\n\t\tif v != "":\n\t\t\treturn "~"',
     "`~` 展开过了", "tests/test_no_vanishing.gd"),
    # 56o：目录名改了。`.niumapai_record` 是用户点名的那个名字,
    # 少个点、写错一个字母，玩家按他记的路径去 Finder 里找就是空的
    ("engine/tape.gd",
     'const DIR_NAME := ".niumapai_record"',
     'const DIR_NAME := "niumapai_record"',
     "录像目录就是 ~/.niumapai_record", "tests/test_no_vanishing.gd"),
    # 56p：存的时候不建目录。第一次存必然失败（目录还不存在），
    # 而失败那条路是报「存不下来」+ 目标目录 —— 玩家看到的是功能坏了
    ("engine/tape.gd",
     "\tif not DirAccess.dir_exists_absolute(dir):\n\t\tDirAccess.make_dir_recursive_absolute(dir)",
     "\tif false:\n\t\tDirAccess.make_dir_recursive_absolute(dir)",
     "目录不存在也存得下来", "tests/test_no_vanishing.gd"),
    # 57a：整条线程分支失效 —— 每次都走同步退化那一路。
    #
    # 这条是 test_ai_think.gd 存在的理由：**返回值一模一样**，
    # 所有既有判据（场景侧那批走 main.gd 钩子的）照旧全绿，
    # 唯一的症状是满档那 1.7 秒里画面冻住。
    # 加这份文件之前，线程分支可以从头到尾没执行过而没人知道
    ("engine/ai_think.gd",
     "\tif tree == null:\n\t\treturn job.call()",
     "\tif true:\n\t\treturn job.call()",
     "job 跑在工作线程上", "tests/test_ai_think.gd"),
    # 57b：信箱退回共用那一格（这是真出过的 bug，不是假想的坏法）。
    # 两个调用方共用 `_box`：第二个进闸门时那一格里还是第一份的结果,
    # 于是它的 `while box.is_empty()` 一进来就成立，**领走第一份的结果**
    # 就返回了——自己那份反而被扔掉。两个 AI 座位同时开口就是「A 座拿到 B 座的计划」
    ("engine/ai_think.gd",
     "\tvar box: Array = []\n\tvar th := Thread.new()",
     "\tvar box: Array = _box\n\tvar th := Thread.new()",
     "第二份任务算出了自己的结果", "tests/test_ai_think.gd"),
    # 57c：重入闸门拆掉。两条搜索线程并排烧两个核，
    # 而 `_thread`/`_box` 两格只认得最后进来那个 —— 退出时 flush() 只收得掉一条。
    #
    # 抓它的判据是**两段区间不重叠**，不是「有没有漏 Thread」：
    # 线程句柄是各自的 local，闸门拆了也各自 join 得掉，busy() 照旧是假。
    # 拿漏没漏当判据这条就是 MISS（判据没有观察点那一类）
    ("engine/ai_think.gd",
     "\twhile _thread != null:",
     "\twhile false:",
     "闸门把两份串起来了", "tests/test_ai_think.gd"),
    # 58a：秒表没装在 AI 那条路上。顶部从不显示当前搜索计时，
    # 而 ThinkClock 自己的那些判据（start/stop 对不对）照旧全绿
    ("scenes/main.gd",
     "\tThinkClock.start(ThinkClock.SRC_AI)\n\t_update_thinking_hint()",
     "\t_update_thinking_hint()",
     "计时器记下了", "tests/test_think_clock.gd"),
    # 58b：搜索之前就停表。次数仍正确，但每次记录接近零，漏掉了实际搜索。
    ("scenes/main.gd",
     "\tThinkClock.start(ThinkClock.SRC_AI)\n\t_update_thinking_hint()",
     "\tThinkClock.start(ThinkClock.SRC_AI)\n\tThinkClock.stop()\n\t_update_thinking_hint()",
     "记下的时长真裹住了搜索", "tests/test_think_clock.gd"),
    # 58c：联网局也念「AI」。对面是个人，管他叫 AI 是错的；
    # 而且联网那一路量到的含网络往返，说法本来就不该和本地 AI 一样
    ("scenes/main.gd",
     '\t\tvar prefix := (" · " if drawer_presentation else "\\n") + "对手思考中… "',
     '\t\tvar prefix := (" · " if drawer_presentation else "\\n") + "AI思考中… "',
     "念「对手」而**不**念 AI", "tests/test_think_clock.gd"),
    # 58d：念的还是估值。这是「换了行、没换数据源」那个坏法 ——
    # 实测计数器若被改成固定数字，便不会随实际计算时间变化。
    # 屏幕上看不出区别（都是「1.8 秒」），只有换台机器才会发现它不动
    ("engine/think_clock.gd",
     "\tvar ms := Time.get_ticks_msec() - _t0",
     "\tvar ms := 1788",
     "停表之后 last_ms 是真花掉的时间", "tests/test_think_clock.gd"),
    # 58e：换局不清。上一局的趟数和平均被算进新一局，
    # 而联网局和单机局量的还不是同一件事（一个含网络往返、一个是纯搜索），
    # 混在一个平均值里那个数没有意义
    ("scenes/main.gd",
     "\tThinkClock.reset()\n\t# 撕牌的截止时刻一局一次性",
     "\t# 撕牌的截止时刻一局一次性",
     "把上一局的趟数和读数清了", "tests/test_think_clock.gd"),
]

# 哪条变异该由哪个测试抓（默认 test_engine）
TEST_FOR = {
    "engine/ai_search.gd": "tests/test_ai_search.gd",
    "engine/ai_agent.gd": "tests/test_ai_search.gd",
    "engine/pile_solver.gd": "tests/test_pile_solver.gd",
    "scenes/settle_layout.gd": "tests/test_arrivals.gd",
    "scenes/board.gd": "tests/test_market.gd",
    "scenes/main.gd": "tests/test_arrivals.gd",
    "engine/card_db.gd": "tests/test_simulator.gd",
    "data/cards.json": "tests/test_simulator.gd",
    "data/ai.json": "tests/test_simulator.gd",
    "data/ui.json": "tests/test_config_complete.gd",
    "engine/match_simulator.gd": "tests/test_simulator.gd",
}


## 单条变异的墙钟上限。必须有：变异改坏的那一行要是让 `_initialize` 半路崩了
## （运行时错误，不是编译错误），脚本就永远走不到 harness 的 finish() ——
## 而 quit() 只在那里。Godot 的主循环于是一直在帧间 nanosleep 转下去，
## 没有超时的话 subprocess.run 无限期等，整批跟着停在那一条上。
## 实测撞过一次：card_db.gd 的 `defaults := _builtin_section(key)` 改成 `{}` 之后，
## test_simulator 那条「整段回退内置配置」在对空字典取键处崩掉，Godot 转了 11 分钟，
## 只烧了 10 秒 CPU（1.3% 占用 —— 空转的样子和「在算大题」完全不同）。
##
## 定 180 秒的依据：跑得最慢的单个文件是 test_arrivals，**不设 TEST_SPEED**
## （run_test 就是不设）实测 19 秒；其余量过的都在 5 秒内。180 秒是最慢那个的 9 倍，
## 松到不会误杀慢文件，紧到挂死三分钟内就报出来
RUN_TIMEOUT_S = 180


def _cmd_for(path):
    """判据文件该怎么跑。按扩展名分派。

    为什么要分派：run_tests.sh 里除了 .gd 测试，还有六个 python 检查
    （check_card_table / check_balance_numbers / check_shell_utf8 /
    check_launch_script / check_doc_refs / check_no_line_refs）。它们盯的是
    「文档和配置飘了」这类**没有任何 .gd 判据会红**的坏法 —— 拿 Godot 去跑 .py
    只会当场报错，于是这些从加进 run_tests.sh 那天起就在变异表射程之外
    """
    if path.endswith(".py"):
        return [sys.executable, path]
    return [GODOT, "--headless", "-s", path]


## 各类判据「红了」长什么样。捕获判定要在这些行里找关键字，
## 认错一种就会把「抓住了」报成 MISS（见 check_keywords 的文档）
_FAIL_MARK = {".gd": "[FAIL]", ".py": "  - "}


def _fail_lines(out, path):
    """输出里哪些行是「某一条判据红了」。

    .gd 走 harness 的 `[FAIL]` 前缀；python 检查印的是 `  - <说法>`
    （见 check_balance_numbers.main 的收尾）—— 两种前缀都得认，
    不然 python 那侧登记进来永远是 MISS
    """
    mark = _FAIL_MARK[".py" if path.endswith(".py") else ".gd"]
    if mark == "  - ":
        return [l for l in out.splitlines() if l.startswith(mark)]
    return [l for l in out.splitlines() if mark in l]


def run_test(path):
    """跑一个测试文件。返回 (退出码, 输出)；超时返回 (None, 已收到的输出)。

    超时不能当成 MISS：MISS 的意思是「判据跑完了、但没红」，
    而超时是「判据一条都没结论」，修法完全不同（见 main 里的 HANG 那一支）
    """
    try:
        r = subprocess.run(_cmd_for(path),
                           cwd=ROOT, capture_output=True, text=True,
                           timeout=RUN_TIMEOUT_S)
    except subprocess.TimeoutExpired as e:
        # 子进程已被 subprocess 杀掉。已收到的那截输出仍然有用：
        # 崩在哪一句通常就印在最后几行
        got = (e.stdout or "") + (e.stderr or "")
        if isinstance(got, bytes):
            got = got.decode("utf-8", "replace")
        return None, got
    return r.returncode, r.stdout + r.stderr


## GDScript 的格式符：%s %d %.1f %02d 这些
_FMT_SPEC = re.compile(r"%[-+ #0-9.*]*[a-zA-Z]")
## 字面段和格式符之间通常还隔着空格（「翻 %d 倍」），紧贴着找会直接失配
_SPEC_AFTER = re.compile(r"[ \t]*(%[-+ #0-9.*]*[a-zA-Z])")
_SPEC_BEFORE = re.compile(r"(%[-+ #0-9.*]*[a-zA-Z])[ \t]*$")


def _spans_interpolation(keyword, seg, src):
    """关键字是不是跨过了一个 %s/%d —— 跨过了就永远匹配不上运行时那行。

    `seg` 是关键字里能在源码找到的最长字面段，剩下的那截要么是插值**产物**
    （合法：`%s` 填进 "arm_attacks"，正好补全关键字），要么是被插值**隔开的
    源码字面**（必坏：格式串写 "翻 %d 倍"，关键字写「翻倍」，中间永远有个数字）。

    分辨办法：看剩余段在不在紧邻那个格式符的字面里。在 → 它是源码文本，
    被插值隔开了；不在 → 只能是插值产物。返回坏掉的说明，好的返回 None
    """
    if keyword.startswith(seg):          # 剩余段在尾部，格式符在 seg 之后
        left, after = keyword[len(seg):], True
    elif keyword.endswith(seg):          # 剩余段在头部，格式符在 seg 之前
        left, after = keyword[: -len(seg)], False
    else:
        return None
    if not left:
        return None
    # 同一字面段可能出现多处：只要**有一处**能命中，这条变异就抓得住。
    # 逐处判，全都不可能命中才报 —— 闸门报错会中止整轮，误报的代价比漏报大
    why = None
    for m in re.finditer(re.escape(seg), src):
        if after:
            spec = _SPEC_AFTER.match(src, m.end())
            if not spec:
                continue                      # 后面不是插值：整串本就该字面命中
            # 该格式符之后、下一个格式符之前的那段字面
            lit = _FMT_SPEC.split(src[spec.end():])[0].split("\n")[0]
        else:
            spec = _SPEC_BEFORE.search(src[: m.start()])
            if not spec:
                continue
            lit = _FMT_SPEC.split(src[: spec.start(1)])[-1].split("\n")[-1]
        if left not in lit:
            return None                       # 剩余段只可能是插值产物 → 能命中
        why = "「%s」是%s那头的源码字面，被 %s 隔开" % (
            left, "后" if after else "前", spec.group(1))
    return why


def check_keywords():
    """每条变异的关键字必须在它指定的测试文件里出现过。

    捕获判据是「关键字出现在某条 [FAIL] 行里」。关键字写成断言文案的**转述**时，
    变异明明被抓住了也会报 MISS —— 一次改测试文案就漂了 3 条，全部表现为
    「测试红了但工具说没抓住」，很容易误判成判据没覆盖。
    这一关把它前移成启动就报的错，而不是跑完 20 分钟才看出来。

    比对的是断言里的**格式串**，而运行时那行是插值后的结果，两者不完全一样：
    `"...%s 段一致"` 跑出来是「knobs_game 段一致」，关键字取 `_game 段一致` 就跨过了
    `%s` 的边界，在源码里怎么找都找不到。所以掐头去尾各让一段（≥4 字符的残余仍要
    在源码里出现）—— 松到容得下插值，紧到断言文案被重写时一定报

    但只让一段还是**比运行时松**：那头容差只证明关键字的某一头是字面，
    没证明整串能命中 `[FAIL]` 行。判据把倍数改成从配置取（「翻倍」→「翻 %d 倍」）之后，
    关键字「带 996 产出翻倍」靠前缀「带 996 产出翻」照旧过关，跑起来却因为
    中间多了个数字而报 MISS —— 变异其实红了 33 条。这正是本函数要前移的那种误判，
    却从它眼皮下溜过去了。所以再加一道 `_spans_interpolation`：
    剩余段是被格式符隔开的源码字面就直接报错
    """
    # harness 也要一起找：公用的判据（入座、摆桌、起服务器这些脚手架）住在
    # tests/harness.gd 里，而每个测试文件都 extends 它 —— 只翻指定的那个文件
    # 会把「判据在，只是被收进了 harness」误报成文案漂了
    harness = (ROOT / "tests/harness.gd").read_text()
    bad = []
    for mut in MUTATIONS:
        rel, _, _, keyword = mut[:4]
        test = _test_of(mut)
        src = (ROOT / test).read_text() + "\n" + harness
        if keyword in src:
            continue
        # 头部或尾部可能来自 %s/%d 插值，剩下的字面段仍必须在格式串里
        tails = [keyword[i:] for i in range(1, len(keyword) - 3)]
        heads = [keyword[:i] for i in range(len(keyword) - 1, 3, -1)]
        hit = [seg for seg in tails + heads if seg in src]
        if hit:
            # 头尾容差比运行时判据松：只证明了某一头是字面，没证明整串能命中
            split = _spans_interpolation(keyword, max(hit, key=len), src)
            if split:
                bad.append("  - 关键字「%s」跨过 %s 的插值：%s（变异目标 %s）"
                           % (keyword, test, split, rel))
            continue
        bad.append("  - 关键字「%s」在 %s 里找不到（变异目标 %s）" % (keyword, test, rel))
    if bad:
        print("关键字和断言文案对不上（%d 处），改测试文案时忘了同步：" % len(bad))
        print("\n".join(bad))
        return False
    return True


def check_anchors():
    """每条变异的原文必须在目标文件里**恰好出现一次**。

    跑变异那头本来就查这个（撞两处报 SKIP、找不到报 SKIP），但那是**跑到才报**，
    而 SKIP 混在「N 条变异未被捕获」里长得像噪声 —— 于是「这条从来没验过任何东西」
    这件事在报表上看不出来。前移成启动就报。

    实测三条从加进表那天起就是死的（2026-09-01 查出）：
    `combo_spread_step` 和 `declared_spread_step` 最后两行逐字相同，撞掉两条；
    `scenes/main.gd` 22d 那两行在掉线和主机接管两处各有一份。
    前两条和那个新函数同在提交 9166689 里进来 —— 加的时候就撞了，一直没人发现。

    只查一次的原因：`replace(old, new, 1)` 换第一处。撞名时它去改了另一个调用点，
    那里没有判据盯着，报出来是一条查无实据的 MISS（第三种 MISS，见文件头）
    """
    cache = {}
    bad = []
    for mut in MUTATIONS:
        rel, old = mut[0], mut[1]
        if rel not in cache:
            cache[rel] = (ROOT / rel).read_text()
        n = cache[rel].count(old)
        if n == 1:
            continue
        head = old.strip().splitlines()[0][:60]
        if n == 0:
            bad.append("  - %s 找不到原文（重构动过那几行？）：%s" % (rel, head))
        else:
            bad.append("  - %s 锚点撞 %d 处，得加一行才唯一：%s" % (rel, n, head))
    if bad:
        print("锚点不唯一或已成孤儿（%d 处），这些变异什么都不验：" % len(bad))
        print("\n".join(bad))
        return False
    return True


## 这条变异该由哪个测试抓。第 5 项省略时按 TEST_FOR 取默认，
## 都没有就退到 test_engine.gd —— 只有一处出处，check_keywords 和跑变异那头
## 各算一遍就会在「省略第 5 项」这种情况下算出不同的测试
def _test_of(mut):
    rel = mut[0]
    return mut[4] if len(mut) > 4 else TEST_FOR.get(rel, "tests/test_engine.gd")


## 过滤串命中吗。三处都看：关键字（改完一条判据）、目标文件（改完一处代码）、
## 测试文件（写完一个新测试要确认它这一批全 OK —— 新登记那批的关键字各不相同，
## 只按关键字过滤选不出「同一个测试的那几条」）
def _matches(mut, only):
    return only in mut[3] or only in mut[0] or only in _test_of(mut)


def main():
    # 自己开行缓冲，不要求调用方记得 `python3 -u`：重定向到文件时 stdout 默认是
    # 块缓冲（4K/8K），而这一关要跑二十分钟 —— 症状是 `tail -f` 半天不出一行，
    # 看起来和「卡死了」一模一样，于是真卡死和正常跑分不出来。
    # 每条结果一行、跑完就见，比事后追查「到底跑到哪了」便宜
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:  # 3.7 以下没有 reconfigure，退回原行为即可
        pass
    if not check_keywords():
        return 1
    # 锚点也在启动就查：跑到才报 SKIP 的话，「这条从来没验过东西」
    # 会混在「N 条变异未被捕获」里看不出来（见 check_anchors 的说明）
    if not check_anchors():
        return 1
    # 只跑关键字 / 目标文件 / 测试文件名里带某段文字的那几条：
    # 改完一处判据时不用等全表跑完（全表约 20 分钟）
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    picked = [m for m in MUTATIONS if not only or _matches(m, only)]
    if only and not picked:
        print("过滤串「%s」一条都没选中（关键字 / 目标文件 / 测试文件里都没有）"
              % only)
        return 1
    # 基线只跑选中那几条要用的测试：过滤时跑全套基线比变异本身还慢
    used = sorted({_test_of(m) for m in picked})
    for test in used:
        code, out = run_test(test)
        if code != 0:
            print("基线就没过（%s），先修测试" % test)
            print(out[-2000:])
            return 1
    print("基线通过\n")

    bad = 0
    for mut in picked:
        rel, old, new, keyword = mut[:4]
        test = _test_of(mut)
        f = ROOT / rel
        src = f.read_text()
        if old not in src:
            print("SKIP  %s 找不到原文：%s" % (rel, old.strip()[:50]))
            bad += 1
            continue
        # 锚点必须**只匹配一处**。replace(old, new, 1) 换的是第一处 ——
        # 锚点撞了名的时候它去改了另一个调用点，那里没人看，于是报 MISS。
        # 这是第三种 MISS，修法和另两种都不一样（另两种见文件头）：
        # 不是判据太松、也不是没有观察点，是**变异根本没打在想改的地方**。
        # 实测：'layout._layout_ai_idle()' 在 scenes/main.gd 里有 7 处，
        # 登记的那条一直在改第 2 处，报表上是一条查无实据的 MISS
        hits = src.count(old)
        if hits > 1:
            print("SKIP  %s 锚点匹配 %d 处（必须唯一）：%s"
                  % (rel, hits, old.strip()[:50]))
            bad += 1
            continue
        f.write_text(src.replace(old, new, 1))
        try:
            code, out = run_test(test)
        finally:
            f.write_text(src)
        # 第五种 MISS：变异让脚本**半路崩了**，判据一条都没结论（见 RUN_TIMEOUT_S）。
        # 和 BROKE 是两回事 —— BROKE 是编译不过（整份没加载），这种编译得过、
        # 跑起来才在某一句上炸，于是 finish() 走不到、Godot 永远转。
        # 单独报是因为修法不同：这里要么让判据在那条路上「失败」而不是「崩」
        # （比如取键换成 .get()），要么这条变异本身该换个落点
        if code is None:
            print("HANG  改坏「%s」→ %d 秒没跑完，判据一条都没结论"
                  % (old.strip()[:40], RUN_TIMEOUT_S))
            for l in [x for x in out.splitlines() if x.strip()][-3:]:
                print("        " + l.strip()[:110])
            print("        脚本没走到 finish()（quit() 只在那儿）。"
                  "多半是变异那行让运行时报错、_initialize 中断了")
            bad += 1
            continue
        failed_lines = _fail_lines(out, test)
        hit = any(keyword in l for l in failed_lines)
        # 变异体**编译不过**要单独报，不能算 MISS。
        #
        # 第四种 MISS（另三种见文件头）：改出来的那行 GDScript 根本不合法，
        # 于是整份脚本没加载、被测的量一个都没产生。报表上和「没有观察点」
        # 长得一模一样（退出码 0，失败 0 条），修法却相反 —— 那种要补判据，
        # 这种要改变异本身，判据一点问题都没有。
        # 实测：`var at := _rest_pos(c)` 改成 `var at := c.global_position`，
        # c 来自 Dictionary（Variant），`:=` 推不出类型 → Parse Error，
        # settle_layout.gd 整份没加载，一条断言都没跑到，
        # tests/harness.gd 那时还照样打「8 通过 / 0 失败」退出码 0
        # python 判据这一侧对应的是 Traceback：变异把 data/cards.json 改成非法 JSON
        # 之后 json.loads 当场抛，退出码非 0 但一条 `  - ` 都没有 ——
        # 不单独认的话报出来是「MISS，退出码 1，失败 0 条」，
        # 和「判据没覆盖」长得一样，而这里该修的是变异本身
        broke = [l for l in out.splitlines()
                 if "Parse Error" in l or "Compile Error" in l
                 or "Traceback (most recent call last)" in l]
        # BROKE 这一路打**改成的**那段，另两路打**原文**：三行讲的不是一件事。
        # BROKE 要修的是变异本身（改出来那行不合法），所以得让人看见改成了什么；
        # OK/MISS 要人回去找「哪一行的判据」，原文才是树里真实存在、能直接 grep
        # 的那段。以前三行统一打改后文本，`pass` 这类替换就打出「改坏「pass」」，
        # 指不到任何一行 —— 平时看不出来是因为多数变异只动行尾（`<= 1`→`<= 0`），
        # 一截断两边长得一样
        if broke:
            print("BROKE 改成「%s」→ 变异体编译不过，什么都没测到：%s"
                  % (new.strip()[:40], broke[0].strip()[:90]))
            print("        改成合法的写法再登记（比如显式标类型 var x: T = ...）")
            bad += 1
            continue
        if code != 0 and hit:
            print("OK    改坏「%s」→ 报警：%s"
                  % (old.strip()[:40], keyword))
        else:
            print("MISS  改坏「%s」→ 没报「%s」（退出码 %d，失败 %d 条）"
                  % (old.strip()[:40], keyword, code, len(failed_lines)))
            for l in failed_lines[:5]:
                print("        " + l.strip())
            bad += 1

    print("\n%d 条变异未被捕获" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

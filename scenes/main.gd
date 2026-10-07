# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node3D

## 游戏控制器（M4：完整对局流程）
## 抽卡 → 组卡 → 结算演出 → 胜负，引擎 GameState ⇄ 场景实体的装配层

const RoundFlow = preload("res://engine/round_flow.gd")
const ResultPresentation = preload("res://scenes/result_presentation.gd")
const TableSnapshot = preload("res://scenes/table_snapshot.gd")
const ReplayPresentation = preload("res://scenes/replay_presentation.gd")
const ReplaySession = preload("res://engine/replay_session.gd")
const ReplayTransition = preload("res://scenes/replay_transition.gd")
const TableScene = preload("res://scenes/table_scene.gd")
const TableActions = preload("res://scenes/table_actions.gd")
const CardMotion = preload("res://scenes/card_motion.gd")

const ReplayPicker = preload("res://scenes/replay_picker.gd")

const DebugShot = preload("res://scenes/debug_shot.gd")
const PileSolver = preload("res://engine/pile_solver.gd")
const SettleLayout = preload("res://scenes/settle_layout.gd")
const DrawerWindow = preload("res://scenes/drawer_window.gd")
const DrawerPresentation = preload("res://scenes/drawer_presentation.gd")
const DrawerTableLayout = preload("res://scenes/drawer_table_layout.gd")
const TableLighting = preload("res://scenes/table_lighting.gd")
const TableSurface = preload("res://scenes/table_surface.gd")
const TableRegions = preload("res://scenes/table_regions.gd")
const UIButtonTheme = preload("res://scenes/ui_button_theme.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")
const PlatformMode = preload("res://engine/platform_mode.gd")
const TouchInput = preload("res://scenes/table_touch_input.gd")
const WebFiles = preload("res://scenes/web_files.gd")
const CardConfig = preload("res://engine/card_config.gd")

const PLAYER_ZONE_Z := TableRegions.PLAYER_ZONE_Z
const MARKET_Z := TableRegions.TABLE_MARKET_Z
const BOT_ZONE_Z := TableRegions.BOT_ZONE_Z
const MARKET_GAP_MAX := TableRegions.MARKET_GAP_MAX

static func market_gap(n: int) -> float:
	return TableRegions.market_gap(n)

## 阶段名**转引** engine/phase_machine.gd，不再在这里各写一套字符串。
## 原先两处各写一份字面量（都是 "action"/"attack"/…），逐字一致是靠人盯着的 ——
## 联网之后阶段名要过网线（Protocol.PHASE 消息），一边改成 "attacking"
## 另一边还认 "attack" 的后果是界面永远等不到自己的回合，而且不报错。
## 转引之后那种分叉是编译期错误（见 engine/phase_machine.gd 文件头）
const PHASE_ACTION := PhaseMachine.ACTION     # 行动阶段（买卡+组卡，先后手轮流）
const PHASE_ATTACK := PhaseMachine.ATTACK     # 攻击阶段（点数池+点选）
const PHASE_SETTLING := PhaseMachine.SETTLING # 结算演出（产出/升级）
const PHASE_OVER := PhaseMachine.OVER

## 演出节拍（秒）。全是「让玩家看清刚发生了什么」的停顿，不是平衡数值 ——
## 所以留在场景层，不进 cards.json。
## 都起名字是为了「BOT 回合太慢」能一眼定位到是哪一段停顿，不用逐个 await 去猜
const BEAT_BOT_THINK := 0.6         # BOT 先手时的思考停顿（回合刚开，给玩家读提示的时间）
const BEAT_BOT_THINK_LATE := 0.4    # BOT 后手时更短：玩家刚操作完，不用再等
const BEAT_BOT_BUY := 0.5           # BOT 每买一张之间（连买时能看清买了什么）
const BEAT_BOT_STEP := 0.3          # BOT 买完 → 组卡之间的换手
const BEAT_PHASE := 0.5            # 阶段切换（进攻击、结算铺完卡）
const BEAT_BANNER := 0.6           # 大字横幅（「结算开始！」）
const BEAT_COMBO_SHOW := 0.5       # 亮出正在结算的组合
const BEAT_COMBO_DONE := 0.7       # 一组结算完（产出飞完、数字跳完）
const BEAT_ATTACK_BOTM := 0.35      # 高亮靶子（看清打的是哪个）
const BEAT_ATTACK_HIT := 0.55      # 一击落地（爆花 + 数字变化）
const BEAT_WASTED := 1.2           # 「余点作废」这类需要读完的长提示
const BEAT_GAME_OVER := 0.8        # 终局前的静场
## 配方消耗那一拍**没有固定常数**：它等的是 `_suck_batch_time(n)`，
## 也就是逐张错开演完正好要的时间（和攻击那边一个口径，见 _consume_recipe_visual）

## 复用的界面文案。只收「同一句写在多处」的那几条 ——
## 全部文案外置成 JSON 会把「%s 少一个参数」从编辑期错误变成运行期崩溃，
## 这项目又没有本地化需求，不值当；同一句改一处漏一处才是真问题
const TXT_ACTION_DONE := "完成行动 ✓"
const TXT_BOT_ACTING := "对手行动中…"
const TXT_ATTACK_MINE := "⚔ 你的攻击"
const TXT_ATTACK_FOE := "对手攻击"
## 认输按钮的两段字。点第一下不认，先换成 TXT_RESIGN_SURE 再点一下才算 ——
## 认输不可撤销（没有「撤回认输」这条意图），而这个按钮就在联网入口旁边，
## 位置和尺寸都一样，点错的代价是整局没了
const TXT_RESIGN := "认输"
const TXT_RESIGN_SURE := "真的认输？"
## 主机易位之后那句提示（用户原话「提示"等待对局"」）。
## **和 join_panel 那个按钮上的字是同一句**（join_panel.gd 的 `_ready()` 里那个 `_host_btn`），
## 而这里没法共用一个常量：本场景没有 class_name（extends Node3D），
## 外部引用不到。改字的话两处一起改 —— 玩家看到的应该是同一句，
## 因为这一刻他的处境和当初按下那个按钮时完全一样：房开着，在等人连进来
const TXT_WAIT_MATCH := "等待对局"

## 提示条从前的停留时长（亮 2 秒 + 淡 0.6 秒）曾经是两个常量，
## 现在**没有了** —— 提示条不淡出，留到下一条来换它（见 _show_message）。
## 留这段注释是因为仓库里还有几处注释在讲「2.6 秒就没了」那个坑，
## 它们说的是历史，不是现状

var state: GameState

## 意图管道。场景层**不再直接调引擎入口**（state.buy / create_combo / apply_attack …），
## 一律 await pipe.submit(Intent.xxx(...))。单机局这条管道两头都在本进程里
## （LocalTransport），联网时换成 NetTransport，这个文件一行都不用改。
##
## 为什么单机也绕这一圈：两条执行路径就会分叉 —— 「至少留 1 张现金」这类规则
## 在一条路上补好、另一条漏掉，而且不会报错（见 README.md §「3. 文件目录结构」）。
## 攻击点数池也在管道那头（applier 持有），不再是本文件的成员变量：
## 池子放在客户端，等于「扣多少点由客户端说了算」
##
## 类型是 **Transport 而不是 LocalTransport**：联网局要往这儿装 NetTransport。
## 写窄了的后果不是编译错误就能挡住的那种 —— 是「联网这条路根本装不进来」，
## 于是 attach_net 只能把 net 层挂在旁边（拖拽照转、状态照旧从本地那份读），
## 界面全对、一条错不报，而每一条玩家输入都落在本地那份 state 上
var pipe: Transport

# 所有跨帧工作属于一份场景会话。重开/换局后旧回调只收尾，不得再读写新局。
var _session_generation := 0
var _client_action_pending := false
var _attack_completion_pending := false
var _client_restore_board := false
var _client_restore_button := false

func _session_current(generation: int) -> bool:
	return generation == _session_generation and is_inside_tree() and not is_queued_for_deletion()

func _invalidate_session() -> void:
	_session_generation += 1
	for card in _foe_tear_cards:
		if is_instance_valid(card):
			card.queue_free()
	_foe_tear_cards.clear()
	_foe_tear_uids.clear()
	_foe_tear_batch = ""
	_foe_tear_target.clear()
	if is_instance_valid(table_hands):
		table_hands.clear()
	if is_instance_valid(_table_actions):
		_table_actions.cancel_pawn()
	if pipe != null and pipe.applied.is_connected(_on_intent_applied):
		pipe.applied.disconnect(_on_intent_applied)
	_client_action_pending = false
	_attack_completion_pending = false
	_thinking = false
	ThinkClock.stop()
	_resign_armed = false
	_shield_signature.clear()
	# 玩家攻击等待的是信号，必须唤醒才能退出；恢复后仍需检查会话。
	attack_turn_finished.emit()

func _start_client_action() -> bool:
	if _client_action_pending:
		return false
	_client_action_pending = true
	_client_restore_board = board.input_locked
	_client_restore_button = btn_pass.disabled
	board.input_locked = true
	btn_pass.disabled = true
	return true

func _end_client_action(generation: int, restore := true) -> void:
	if not _session_current(generation):
		return
	_client_action_pending = false
	if restore and phase == PHASE_ACTION and _actor == my_seat and state.winner == "":
		board.input_locked = _client_restore_board
		btn_pass.disabled = _client_restore_button
	_refresh_drawer_pause()

func _round_flow() -> RefCounted:
	var generation := _session_generation
	return RoundFlow.new(func(): return pipe, func(): return not _session_current(generation))

func _action_failed(result: Dictionary) -> void:
	sfx.play("deny")
	_show_message(str(result.get("reason", "操作未成功，请重试")), Palette.semantic("danger"))

## 按当前那份 state 重建管道。**开局和重开必须走同一个函数**。
##
## 为什么单拎出来：`IntentApply` 在 `_init` 里就把 state 存成成员
## （engine/intent_apply.gd 的 `_init()`），所以「换 state」和「换管道」是同一件事的两半。
## 重开一局时只换了 `state = GameState.new()` 而没重建管道的后果是：
## 界面读新 state（画面全对），而每一条玩家输入都被写进**上一局那份**state ——
## 上一局的 winner 不为空，`apply` 那条「已分胜负后只放 finalize」把它们全挡了。
## 症状是「第二局买不了卡」，以及结算时崩溃：产出组合数从旧 state 数、
## 演出下标却按新 state 取，旧局有组合新局没有时就越界。
##
## 一个引用换了另一个没换，而且不报错 —— 这正是 共享状态引用失配造成的静默分叉。
## 所以这个函数是**唯一**建管道的地方，`_uid`、点数池、台账一起换成新的一份
func _rebuild_pipe() -> void:
	# 管道要在 new_game() 之后建：applier 拿着这一份 state 的引用
	pipe = LocalTransport.new(IntentApply.new(state))
	# 对手侧的画面**从落地的意图来**，不从「驱动对手的那段代码」来。
	# 为什么这条连接是联网的前提：见 _on_intent_applied
	pipe.applied.connect(_on_intent_applied)
	# 录像**从这一刻就开始录**，不等玩家按键。
	# 按下才开始录会把最有用的那种 bug 排除在外：玩家看到不对劲的时候，
	# 导致它的那几步已经过去了。代价是每条落地的意图存一份字典 + 一个 md5
	# （见 engine/tape.gd 文件头），所以不给它开关
	tape.start(pipe.applier(), "界面局")
	_bind_tape_view()

## 这一局的录像。随时按 F5 存出去（见 _input），存出来的那份能重放、
## 重放能指出「从第几步开始不对」（engine/tape.gd）。
##
## 为什么是成员而不是每次新建：它得跨整局活着。而重开一局时**必须重新 start**——
## 那时 applier 换了新的一个（见 _rebuild_pipe），还连在旧 applier 上的话
## 这一局一步都录不到，而存出来的文件看着一切正常（只是短得离谱）
var tape := Tape.new()
# 回放场景在入树前注入，不启动BOT、不录制回放自身。
var replay_session: RefCounted
var _replay_picker: CanvasLayer
var _replay_busy := false
var _replay_previous_button: Button
var _replay_step_input: LineEdit
var _replay_jump_button: Button
var _replay_step_range: Label
var _replay_presenter: Node
var _record_layout_pending := false
var _record_layout_seat := ""


## 联网双方记录实际消费的服务器结果与快照，主机和纯客户端均可保存完整录像。
func _retarget_tape() -> void:
	# 联网两端都按实际采纳的服务器快照逐条录制，避免主机与纯客户端漏录。
	if _net != null:
		tape.start_remote(_net, "联网局")
		_bind_tape_view()
	else:
		tape.stop()

func _bind_tape_view() -> void:
	tape.view_provider = func(): return TableSnapshot.capture(self)
	tape.meta["my_seat"] = my_seat
	var settings: Dictionary = tape.configuration["settings"]
	settings["my_seat"] = my_seat
	settings["sound_enabled"] = not sfx.user_muted if is_instance_valid(sfx) else true
	if drawer_presentation:
		settings["perspective_angle"] = drawer_presentation.perspective_angle
	if drawer_window:
		settings["window_ratio"] = drawer_window.get_size_ratio()
	tape.update_view.call_deferred()

func _request_record_layout() -> void:
	if replay_session == null:
		_record_layout_pending = true
		_record_layout_seat = my_seat

func _flush_record_view() -> void:
	if replay_session != null or not tape.recording() or not is_instance_valid(board):
		return
	if not board._drag_cards.is_empty() or not _drag_lease.is_empty():
		return
	if _record_layout_pending:
		_record_layout_pending = false
		tape.record_layout(_record_layout_seat)
	else:
		tape.update_view()

## 本机做主机时，这一局所在的那间房。不是主机则 null。
##
## 按**房间码**认，不按「只有一间房」认：EmbeddedHost 起的是一个完整的
## NetServer（见 net/embedded_host.gd 文件头「没有第二套逻辑」那段），
## 它能同时有别的房。认错一间房，录出来的是别人那一局 ——
## 那比不录更误导（重放对得上，可它压根不是玩家看到的那局）
func _host_room() -> NetRoom:
	if _host == null or _host.server == null:
		return null
	var code := _net.room if _net != null else ""
	var r = (_host.server.rooms as Dictionary).get(code)
	return r as NetRoom if r is NetRoom else null

## 座位。引擎里 GameState.PLAYER / BOT 是**座位编号**，不是「人 / 电脑」——
## 联网时远端客户端的 my_seat 会是 GameState.BOT，界面上它照样叫「你的公司」。
## 场景层一律念 my_seat / foe_seat，不再直接写 GameState.PLAYER / BOT：
## 那两个常量在项目里被引用近八百处（九成在测试里），改名会波及三十多个测试文件，
## 而座位这件事本来就只该在场景层存在（引擎不关心谁在看这一局）。
##
## 单机局是 my_seat=PLAYER / foe_seat=BOT，与改造前完全一致。
## 谁坐哪个座位由 net 层在开局前设定（见 set_seats），此后整局不变
var my_seat := GameState.PLAYER
var foe_seat := GameState.BOT

## 单机局那一对座位。**重开一局要用它复位**（_reset_session_flags），
## 而那儿不能再写一次 GameState.PLAYER / BOT —— 座位对只该有一个定义处，
## 写第二遍就是「以后有人只改了一处」的入口（tests/test_seat_map.gd 的静态检查
## 正是为此而设，它在这一条上报过一次）
const SOLO_SEATS := [GameState.PLAYER, GameState.BOT]

## 开局前设座位。必须在 state.new_game() 之前调 ——
## 摆放层按座位决定往哪半边摆，中途换座位会让整桌牌左右互换
func set_seats(mine: String, foe: String) -> void:
	my_seat = mine
	foe_seat = foe
	_actor = mine

## 座位 → 界面上的公司名。措辞与 HUD 一致（lbl_player_res / lbl_bot_res）。
## 引擎不存名字（那是视角量，见 GameState.seat_arg 那段），场景层按 my_seat 现算
func _seat_name(who: String) -> String:
	return GameState.seat_name(who, my_seat)

## 把一条战报渲染成这一侧看到的文本。
## 引擎存的是 { fmt, args }，args 里的座位到这里才变成公司名
func _render_log(entry: Dictionary) -> String:
	return GameState.render_entry(entry, my_seat)

var board: Board
var drawer_window: DrawerWindow
var drawer_presentation: DrawerPresentation
var table_hands: Node
var _foe_tear_uids: Array = []
var _foe_tear_cards: Array = []
var _foe_tear_center := Vector3.ZERO
var _foe_tear_batch := ""
var _foe_tear_target: Dictionary = {}
## 有头与无头使用相同的布局路径；回归测试显式打开此项。
var force_drawer_layout := false
## Android/iOS 使用横屏完整牌桌；测试可在桌面用此开关模拟移动模式。
var force_mobile_layout := false
var mobile_mode := false
## 浏览器复用完整牌桌，不创建桌面原生抽屉；测试可在无头模式走同一布局。
var force_web_layout := false
var web_mode := false
var web_files: Node
var drawer_ui_scale := 1.0
var _drawer_owns_pause := false
var _drawer_pause_at := -1
var _drawer_pause_total := 0
## 摆放那一层（见 scenes/settle_layout.gd）。测试和 scenes/debug_shot.gd
## 也从这儿进去：main.layout._stack_settled(...)
var layout: SettleLayout
var sfx: Sfx
var _card_motion: Node
var _table_scene: RefCounted
var _table_actions: Node
var phase := PHASE_ACTION
var _actor := GameState.PLAYER   # 当前行动方（PHASE_ACTION 时有效）；开局由 set_seats 校正
var entities := {}             # uid(int) -> CardEntity
var market_cards: Array[CardEntity] = []
var market_slots: Array[Vector3] = []
var market_price_labels: Array = []

# 攻击阶段（点选模式）
signal attack_turn_finished
## 玩家当前攻击点数池（分资源）。**只读**：真正那一份在管道那头（IntentApply._pools），
## 这里现问现取。曾经是本文件的成员变量，那等于「扣多少点由客户端说了算」——
## apply_attack 是就地改 pools 的，池子在场景层就没人能证明扣的数对不对
var _attack_pools: Dictionary:
	get:
		if pipe == null:
			return { CardDB.RES_CASH: 0, CardDB.RES_USER: 0 }
		return pipe.applier().pools(my_seat)
var _attack_hl: Array = []       # 当前高亮的可点目标实体

# HUD
var table_hud: CanvasLayer
var lbl_round: Label
var lbl_player_res: Label
var lbl_bot_res: Label
var hud_player_card: ResourceHUD
var hud_bot_card: ResourceHUD
var hud_panel: PanelContainer
var hud_status_panel: PanelContainer
var _table_hud_content := Rect2()
## 提示条。常驻于底部状态栏，不淡出。
## 位置和寿命都在 _setup_res_panel / _show_message 里讲
var lbl_msg: Label
## 提示记录（右下角，默认收起）。屏幕上说过的每一句都留在这儿
var msg_log: MsgLog
var lbl_attack: Label            # 兼容旧引用；攻击时由固定点数面板展示
var attack_panel: PanelContainer
var attack_pool_text: Label
var attack_target_text: Label
var _attack_follow_mouse := false
var btn_pass: Button
## 联网入口按钮。联网局开起来之后要**藏掉** —— 局中再点一次会开出第二条连接，
## 而 begin_net_game 会把 pipe 换成新那条：旧连接还挂在服务器上占着座位，
## 新那条进不去（房间满）。症状是「联网局里手滑点了一下，整局废掉」
var btn_net: Button
## 认输按钮。和 btn_net 不同，它**局中一直可点** —— 认输在任何阶段都成立
## （见 Intent.OP_RESIGN），包括对手行动时：那正是最想认的时候
var btn_resign: Button
## 存录像按钮。和认输一样局中一直可点 —— 随时能存是这个功能的定义
## （见 _save_replay），出了 bug 那一刻正是最想存的时候
var btn_save: Button

## 存完录像之后报路径的那块面板（scenes/save_notice.gd）。
## 路径不走 _show_message：那条是会淡出的一行字，抄不走
var save_notice: SaveNotice
## 认输按钮点过第一下了吗。第二下才真发意图（见 _on_resign_pressed）
var _resign_armed := false
var game_over_panel: PanelContainer = null

# 选色面板要能实时改世界配色，故把这几个对象留下引用（见 _refresh_world_palette）
var _env: Environment = null
var _table_mat: StandardMaterial3D = null
var _table_frame_mat: StandardMaterial3D = null
var _table_felt_lit := false     # 台面毛毡素材在位时侧壁要压暗，取的是另一个配置键

var _debug_shot: DebugShot = null   # 开发用截图钩子（见 _ready 末尾）

func _ready() -> void:
	mobile_mode = force_mobile_layout or PlatformMode.is_mobile() or PlatformMode.force_mobile()
	web_mode = force_web_layout or OS.has_feature("web")
	if web_mode:
		web_files = WebFiles.new()
		add_child(web_files)
	# 先应用卡表再创建卡面/规则说明，避免界面缓存了默认值才切到试玩配置。
	if replay_session == null and not _apply_solo_cards_or_stop():
		return
	_setup_drawer_window()
	if not get_window().files_dropped.is_connected(_on_window_files_dropped):
		get_window().files_dropped.connect(_on_window_files_dropped)
	_setup_environment()
	_setup_table()
	board = _table_scene.create_board()
	board.touch_mode = mobile_mode
	# 桌子要能掐掉 main 这侧那条位移补间（买卡飞入、理牌搬运、产出飞入）。
	# 接 Callable 而不是让 board 持有 main：board 一次都没读过 main，
	# 读了就得跟着「重开一局换掉 state」那条路一起维护 —— 桌子是复用的，
	# 而 state 每局换新，board 上存一份就是「第二局还在问上一局」
	# （memory: member-that-survives-a-restart）
	board.cancel_anim = _cancel_fly
	board.dropped_on_market.connect(_on_dropped_on_market)
	board.dropped_on_pawn.connect(_on_dropped_on_pawn)
	board.attack_clicked.connect(_on_attack_clicked)
	# 手上这摞的动静广播给对手（scenes/main.gd 的拖拽广播与租约处理）。单机局 _net 是 null，回调直接返回 ——
	# 连接无条件建：场景层不该知道「有没有在联网」
	board.drag_broadcast.connect(_on_drag_broadcast)
	layout = _table_scene.create_layout()
	sfx = Sfx.new()
	add_child(sfx)
	_card_motion = CardMotion.new()
	add_child(_card_motion)
	_card_motion.bind(board, sfx, _uses_fitted_table())
	_table_actions = TableActions.new()
	add_child(_table_actions)
	_table_actions.bind(self)
	board.card_dropped_table.connect(_request_record_layout)
	board.pile_toggled.connect(_request_record_layout)
	_setup_hud()
	_setup_drawer_presentation()
	if mobile_mode:
		var touch := TouchInput.new()
		add_child(touch)
		touch.bind(self)
	if replay_session != null:
		set_seats(str(replay_session.record.meta.get("my_seat", SOLO_SEATS[0])),
			GameState.opponent(str(replay_session.record.meta.get("my_seat", SOLO_SEATS[0]))))
		_replay_presenter = ReplayPresentation.new()
		add_child(_replay_presenter)
		_replay_presenter.bind(self)
		_render_replay_step()
		return
	state = GameState.new()
	# 开发用：CARD_SEED=<整数> 固定发牌，两次运行画面一致，截图才能逐像素比对
	var seed_env := OS.get_environment("CARD_SEED")
	if seed_env != "":
		state.set_seed(int(seed_env))
	state.new_game()
	_rebuild_pipe()
	_sync_round()
	if CardConfig.has_launch_override():
		print("CARDS_CONFIG_READY: " + CardDB.loaded_from)
	# 启动参数里指定了服务器/房间码就直接进联网局（需求 5，网页版靠这条走）。
	# 放在 _sync_round 之后：联机入座时可能替换当前牌局，需要先完成初始化
	_apply_launch_config()
	# 开发用截图钩子（CARD_SHOT=...），见 scenes/debug_shot.gd。
	# 必须存住实例：run() 是协程，实例被回收就跑不到 await 之后
	_debug_shot = DebugShot.new()
	_debug_shot.run(self)
	if drawer_window and not mobile_mode and DisplayServer.get_name() != "headless" and OS.get_environment("CARD_SHOT") == "":
		drawer_window.start_collapsed(true)

# ---------- 场景搭建 ----------

func _on_window_files_dropped(files: PackedStringArray) -> void:
	if drawer_presentation != null:
		drawer_presentation.handle_card_config_files(files)

## Palette 广播的回调。哪一项变了都整体重刷一遍：43 项里除了底板色以外
## 都可能牵动多处，逐项分派不值得，全刷一次的开销也就是重设几个 albedo
func _on_palette_changed(_section: String, _key: String) -> void:
	_refresh_world_palette()
	_refresh_hud_palette()
	_refresh_button_theme()
	if drawer_presentation:
		drawer_presentation.relayout()

## HUD 读数字体色跟随配色配置实时更新（选色面板拖一下即生效）
func _refresh_hud_palette() -> void:
	if lbl_player_res:
		lbl_player_res.add_theme_color_override("font_color", Palette.get_color("hud", "player"))
	if lbl_bot_res:
		lbl_bot_res.add_theme_color_override("font_color", Palette.get_color("hud", "bot"))
	if is_instance_valid(hud_player_card):
		hud_player_card.refresh_palette()
	if is_instance_valid(hud_bot_card):
		hud_bot_card.refresh_palette()
	if drawer_presentation == null and lbl_round:
		lbl_round.add_theme_color_override("font_color", Palette.semantic("ink"))
	for panel in [hud_panel, hud_status_panel]:
		if not is_instance_valid(panel):
			continue
		var box := panel.get_theme_stylebox("panel") as StyleBoxFlat
		if box:
			box.bg_color = Color(Palette.semantic("surface"), 0.96)
			box.border_color = Palette.semantic("muted")

## 配色变更后重刷画面。选色面板拖一下颜色就走这里：
## 世界那几个材质直接改 albedo，卡牌交给各自的 refresh_palette（底板色在着色器里）
func _refresh_world_palette() -> void:
	if _table_scene:
		_table_scene.refresh_palette()
	if board:
		for c in board.cards:
			if is_instance_valid(c):
				c.refresh_palette()


func _uses_fitted_table() -> bool:
	return drawer_window != null or mobile_mode or web_mode

func _setup_drawer_window() -> void:
	var headless := DisplayServer.get_name() == "headless"
	if mobile_mode or web_mode:
		# 移动端和浏览器直接进入共享牌桌，不创建原生抽屉或运行收放状态机。
		# UI尺寸按当前可见视口统一计算；卡牌大小由共享镜头决定。
		get_window().content_scale_size = Vector2i.ZERO
		get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		get_window().transparent = false
		get_window().transparent_bg = false
		if OS.has_feature("android"):
			DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)
		return
	if headless and not force_drawer_layout:
		return
	if OS.get_cmdline_user_args().has("--table"):
		return
	drawer_window = DrawerWindow.new()
	drawer_window.name = "DrawerWindow"
	var requested := OS.get_environment("CARD_DRAWER_SIZE").split("x")
	if requested.size() == 2 and int(requested[0]) >= 900 and int(requested[1]) >= 600:
		drawer_window.set_expanded_size(Vector2i(int(requested[0]), int(requested[1])))
	add_child(drawer_window)
	drawer_window.can_collapse = _drawer_can_collapse
	drawer_window.expanded_changed.connect(_on_drawer_expanded_changed)
	drawer_window.transition_finished.connect(_on_drawer_transition_finished)
	drawer_window.transition_started.connect(func(expanded: bool):
		_drawer_stack_sway(expanded)
		if not expanded and drawer_presentation:
			drawer_presentation.suspend_panels())
	if headless:
		get_window().content_scale_size = Vector2i.ZERO
		get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		drawer_window.setup(false, Rect2i(Vector2i.ZERO, get_window().size))
		drawer_window.set_display_scale(drawer_ui_scale)
		drawer_window.pin()
	else:
		drawer_window.setup()
		drawer_ui_scale = clampf(DisplayServer.screen_get_scale(get_window().current_screen), 1.0, 2.0)
		drawer_window.set_display_scale(drawer_ui_scale)
		if OS.get_environment("CARD_SHOT") != "":
			drawer_window.set_process(false)

func _setup_drawer_presentation() -> void:
	if not _uses_fitted_table():
		return
	drawer_presentation = DrawerPresentation.new()
	add_child(drawer_presentation)
	drawer_presentation.bind(self)
	table_hands = preload("res://scenes/table_hands.gd").new()
	add_child(table_hands)
	table_hands.bind(self)
	board.interaction_blocked = _drawer_input_blocked
	board.hover_blocked = func(): return drawer_presentation.pointer_over_panels(board.pointer_position())

func _drawer_input_blocked() -> bool:
	# 面板只消费自身的 GUI 输入，不再把整张牌桌锁住。
	return drawer_window != null and (not drawer_window.is_expanded() or drawer_window.is_transitioning())

func _drawer_can_collapse() -> bool:
	# 打开任何设置、记录、联机面板都不影响自动收起；仅正在进行的拖拽等松手。
	return (board == null or board._drag_cards.is_empty()) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		and not (is_instance_valid(_replay_picker) and _replay_picker.visible)

func _on_drawer_expanded_changed(expanded: bool) -> void:
	# 展开开始就切换入口与桌面 UI，不能等动画结束才隐藏入口。
	if drawer_presentation:
		drawer_presentation.set_collapsed(not expanded)
	if sfx:
		# 抽屉收起时暂时停止播放，展开后恢复玩家在喇叭按钮选择的状态。
		# 不能直接改 user_muted，否则每次收起都会覆盖玩家偏好。
		sfx.set_drawer_suspended(not expanded)
	_refresh_mascot_state()
	_refresh_drawer_pause()

## 收起后让对手和自动结算继续进行；只有等待玩家操作时才暂停本地牌局。
## 网络握手、主机与客户端始终运行，暂停只由抽屉自己取得/释放。
func _refresh_drawer_pause() -> void:
	if replay_session != null:
		return
	if drawer_window == null or not is_inside_tree():
		return
	var should_pause := not drawer_window.is_expanded() and _net == null and _host == null \
		and not _network_join_pending() and _drawer_waiting_for_player()
	if should_pause and not get_tree().paused:
		_drawer_pause_at = Time.get_ticks_msec()
		_drawer_owns_pause = true
		get_tree().paused = true
	elif not should_pause and _drawer_owns_pause:
		if _drawer_pause_at >= 0:
			_drawer_pause_total += Time.get_ticks_msec() - _drawer_pause_at
			_drawer_pause_at = -1
		get_tree().paused = false
		_drawer_owns_pause = false

func _drawer_waiting_for_player() -> bool:
	if state == null or board == null or btn_pass == null:
		return false
	if phase == PHASE_OVER:
		return true
	# 典当冲线等动作先写winner、再等待终局演出，期间仍须继续推进。
	if state.winner != "":
		return false
	if phase == PHASE_ACTION:
		return _actor == my_seat and not board.input_locked and not btn_pass.disabled
	if phase == PHASE_ATTACK:
		# 点击后的裁决和撕牌尚未完成时不能暂停，否则最后一击会卡住换手/终局。
		return board.attack_mode and _player_attack_busy == 0
	return false

func _on_drawer_transition_finished(expanded: bool) -> void:
	if drawer_presentation:
		drawer_presentation.set_collapsed(not expanded)
		if expanded:
			drawer_presentation.relayout()

func _drawer_stack_sway(expanding: bool) -> void:
	# 抽屉启动/收起时给真实的牌摞一小段惯性回弹。只动 CardVisual，
	# 不改刚体位置和碰撞，避免影响理牌、拖牌和落点计算。
	if board == null or not is_instance_valid(board):
		return
	var direction := drawer_window.get_open_direction() if drawer_window else Vector2.LEFT
	if not expanding:
		direction = -direction
	var seen := {}
	for g in board.groups:
		var cards: Array = g.get("cards", [])
		for i in cards.size():
			var card: CardEntity = cards[i]
			if not is_instance_valid(card) or card._visual == null or seen.has(card):
				continue
			seen[card] = true
			card.reset_interaction_visual()
			var depth := float(mini(i, 8))
			var amplitude := 0.028 + depth * 0.004
			var yaw := 0.018 + depth * 0.002
			var delay := depth * 0.012
			var shift := Vector3(direction.x, 0.0, direction.y) * amplitude
			var tilt := Vector3(-direction.y, direction.x, 0.0) * yaw
			var tw := create_tween().bind_node(card)
			tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
			tw.tween_property(card._visual, "position", shift, 0.10).set_delay(delay)
			tw.parallel().tween_property(card._visual, "rotation", tilt, 0.10).set_delay(delay)
			tw.tween_property(card._visual, "position", shift * -0.48, 0.10)
			tw.parallel().tween_property(card._visual, "rotation", tilt * -0.48, 0.10)
			tw.tween_property(card._visual, "position", Vector3.ZERO, 0.16)
			tw.parallel().tween_property(card._visual, "rotation", Vector3.ZERO, 0.16)

func _animation_now_ms() -> int:
	var now := Time.get_ticks_msec()
	var pending := now - _drawer_pause_at if _drawer_pause_at >= 0 else 0
	return now - _drawer_pause_total - pending

func _await_drawer_resume() -> void:
	var session := _session_generation
	# 真正暂停等待玩家时，工作线程结果仍等恢复；后台BOT回合不会取得暂停。
	while _session_current(session) and get_tree().paused:
		await get_tree().process_frame

func _market_slot(index: int, count: int) -> Vector3:
	return TableRegions.market_slot(index, count, _uses_fitted_table())

func _pawn_position() -> Vector3:
	return TableRegions.facility_position(int(CardDB.game_rules()["market_size"]), _uses_fitted_table())

func _setup_environment() -> void:
	_table_scene = TableScene.new(self, _uses_fitted_table())
	_table_scene._setup_environment()
	_env = _table_scene._env

func _setup_table() -> void:
	_table_scene._setup_table()
	_table_mat = _table_scene._table_mat
	_table_frame_mat = _table_scene._table_frame_mat
	_table_felt_lit = _table_scene._table_felt_lit

## 公共区空槽占位框：由 TableScene 创建，卡被买走后露出来。
## 槽位数量与坐标每回合恒定，故建一次即可，不随 _spawn_market_card 重建
func _add_market_slot_frames() -> void:
	_table_scene._add_market_slot_frames()

## 分区只提供视觉参照，没有碰撞，牌仍能自由摆到实际可见的桌面边缘。
func _add_zone_tray(mine: bool) -> void:
	_table_scene._add_zone_tray(mine)

func _add_market_tray() -> void:
	_table_scene._add_market_tray()

## 桌框、双方分区与公共市场，均为绘制层，不参与牌桌碰撞。
func _setup_table_decor() -> void:
	_table_scene._setup_table_decor()

## 典当行设施牌：保留天平插画，外框、底色和标题带与普通卡一起程序绘制。
## 典当行占一个标准卡位，作为购牌带内的固定设施牌；不计入 market/state。
## 通过中立色、“设施”徽标和无价格标签与可购卡区分。
func _setup_pawnshop_card() -> void:
	_table_scene._setup_pawnshop_card()

func _facility_label(text: String, size: int) -> Label3D:
	return _table_scene._facility_label(text, size)

## 设施没有刚体/市场索引，悬停只按实际卡面范围拾取，不改变购买/典当路由。
func facility_contains_pointer(pointer: Vector2) -> bool:
	if board == null or board.camera == null:
		return false
	var ray := board.camera.project_ray_normal(pointer)
	if absf(ray.y) < 0.00001:
		return false
	var origin := board.camera.project_ray_origin(pointer)
	var at := _pawn_position()
	var t := (at.y + CardEntity.Y_PLATE - origin.y) / ray.y
	if t < 0.0:
		return false
	var hit := origin + ray * t - at
	return absf(hit.x) <= CardEntity.CARD_SIZE.x * 0.5 and absf(hit.z) <= CardEntity.CARD_SIZE.z * 0.5

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "TableHUD"
	table_hud = canvas
	add_child(canvas)
	# lbl_msg 在这里头（资源面板的第四行），不再是顶部中间那条浮字。
	# 搬家的理由见 _setup_res_panel 里那段注释
	_setup_res_panel(canvas)

	# 提示记录。**必须在 _setup_res_panel 之后**：_show_message 往这两处各写一份,
	# 而开局第一条提示是 _begin_action_phase 发的，那时候两块都得在
	msg_log = MsgLog.new()
	canvas.add_child(msg_log)

	# 右上角选色面板。改色广播回来后统一走 _refresh_world_palette 重刷画面
	var pal := PalettePanel.new()
	canvas.add_child(pal)
	Palette.bus().changed.connect(_on_palette_changed)

	# BOT 参数面板，贴在选色面板下方。
	# above 在 add_child 之前赋值：BOTPanel._ready 里要按它算自己的位置，
	# 而 _ready 是 add_child 那一刻同步跑的，之后再赋就晚了。
	# 这个面板不连任何信号到主场景：每次新行动搜索和选靶都会读取
	# BOTSearch.prefs()。已经开始的搜索和已生成的行动计划持有自己的快照。
	var aip := BOTPanel.new()
	aip.above = pal
	canvas.add_child(aip)

	# 联网入口。放左下角是因为右上被选色面板占了，右下角是提示记录那一块。
	# **这个按钮就是联网这条路的唯一入口** —— 在它之前 net/ 那一整层
	# 测试全绿而玩家点不到（见 scenes/join_panel.gd 文件头）
	btn_net = Button.new()
	# 文案和它打开的那个面板标题对齐（join_panel.gd 的 `_ready()` 里那句 "局域网对战"）——
	# 点之前叫「联网对战」、点开之后叫「局域网对战」，看着不像同一个东西
	btn_net.text = "局域网对战"
	btn_net.set_meta("ui_role", "tool")
	btn_net.tooltip_text = "工具：建立或加入局域网对局"
	btn_net.add_theme_font_override("font", Fonts.zh())
	btn_net.add_theme_font_size_override("font_size", 20)
	btn_net.custom_minimum_size = Vector2(150, 44)
	btn_net.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	btn_net.position = Vector2(24, -68)
	btn_net.pressed.connect(_open_join_panel)
	canvas.add_child(btn_net)

	# 认输，摞在联网入口上面（同左下角，往上 52）。
	# 不和 btn_net 二选一显示：这两个的可用时机是错开的但**不互斥** ——
	# 联网入座后 btn_net 会禁掉，认输恰恰是从那一刻才真正有意义
	btn_resign = Button.new()
	btn_resign.text = TXT_RESIGN
	btn_resign.set_meta("ui_role", "danger")
	btn_resign.tooltip_text = "结束本局并认输；需要再次确认"
	btn_resign.add_theme_font_override("font", Fonts.zh())
	btn_resign.add_theme_font_size_override("font_size", 20)
	btn_resign.custom_minimum_size = Vector2(150, 44)
	btn_resign.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	btn_resign.position = Vector2(24, -218)
	btn_resign.pressed.connect(_on_resign_pressed)
	canvas.add_child(btn_resign)

	# 存录像，摞在认输上面（同左下角，再往上 52）。
	# 原先只有 F5，理由是「这是排查用的口子，不该混进玩法按钮里」——
	# 那个理由站不住：用户找不到入口（原话「对局保存入口在哪儿？找不到」），
	# 一个找不到的功能等于没有。F5 留着（手上占着牌也能按），按钮是给能看见的那条路
	btn_save = Button.new()
	btn_save.text = "存录像"
	btn_save.set_meta("ui_role", "tool")
	btn_save.tooltip_text = "把这一局到此刻的过程存出去，不打断对局（也可以按 F5）"
	btn_save.add_theme_font_override("font", Fonts.zh())
	btn_save.add_theme_font_size_override("font_size", 20)
	btn_save.custom_minimum_size = Vector2(150, 44)
	btn_save.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	btn_save.position = Vector2(24, -120)
	btn_save.pressed.connect(_save_replay)
	canvas.add_child(btn_save)
	# 联网和录像组成工具区；认输独立留在上方，并保留确认行为。
	var tool_frame := Panel.new()
	tool_frame.name = "ToolGroup"
	tool_frame.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	tool_frame.position = Vector2(16, -160)
	tool_frame.size = Vector2(166, 144)
	tool_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tool_style := StyleBoxFlat.new()
	tool_style.bg_color = Color(Palette.semantic("surface"), 0.86)
	tool_style.border_color = Palette.semantic("muted")
	tool_style.set_corner_radius_all(12)
	tool_style.set_border_width_all(1)
	tool_frame.add_theme_stylebox_override("panel", tool_style)
	canvas.add_child(tool_frame)
	canvas.move_child(tool_frame, btn_net.get_index())
	var tool_title := _make_label(tool_frame, Vector2(12, 7), 15, Palette.semantic("muted"))
	tool_title.text = "工具"
	tool_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tool_frame.visible = not _uses_fitted_table()

	# 存完之后报路径的那一块。**一直在树里，靠 visible 收放** ——
	# 每次现造的话「复制路径」按钮每次都是新对象，
	# 而它按下之后要改自己的文案（见 SaveNotice._on_copy）
	save_notice = SaveNotice.new()
	add_child(save_notice)

	btn_pass = Button.new()
	btn_pass.set_meta("ui_role", "primary")
	btn_pass.add_theme_font_override("font", Fonts.zh())
	btn_pass.add_theme_font_size_override("font_size", 30)
	btn_pass.add_theme_color_override("font_color", Palette.semantic("surface"))
	btn_pass.add_theme_color_override("font_hover_color", Palette.semantic("surface"))
	btn_pass.add_theme_color_override("font_disabled_color", Palette.semantic("disabled"))
	btn_pass.custom_minimum_size = Vector2(240, 72)
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Palette.semantic("primary")   # 主要操作色：来自语义色板
	sb_normal.set_corner_radius_all(14)
	sb_normal.set_border_width_all(3)
	sb_normal.border_color = Palette.semantic("surface")
	btn_pass.add_theme_stylebox_override("normal", sb_normal)
	var sb_hover := sb_normal.duplicate()
	sb_hover.bg_color = Palette.semantic("pending")
	btn_pass.add_theme_stylebox_override("hover", sb_hover)
	var sb_pressed := sb_normal.duplicate()
	sb_pressed.bg_color = Palette.semantic("cash")
	btn_pass.add_theme_stylebox_override("pressed", sb_pressed)
	var sb_disabled := sb_normal.duplicate()
	sb_disabled.bg_color = Palette.semantic("muted")
	btn_pass.add_theme_stylebox_override("disabled", sb_disabled)
	canvas.add_child(btn_pass)
	_refresh_button_theme()
	_position_pass_button()
	_set_button(TXT_ACTION_DONE, _on_action_done)

	# 攻击点数标签：玩家攻击时跟随鼠标，BOT 攻击时置顶居中
	lbl_attack = _make_label(canvas, Vector2(0, 120), 34, Color(1.0, 0.45, 0.35))
	lbl_attack.visible = false
	lbl_attack.set_anchors_preset(Control.PRESET_CENTER_TOP)
	lbl_attack.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attack_panel = PanelContainer.new()
	attack_panel.name = "AttackPoolPanel"
	attack_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attack_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	attack_panel.position = Vector2(-250, 116)
	attack_panel.custom_minimum_size = Vector2(500, 52)
	var attack_box := VBoxContainer.new()
	attack_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attack_panel.add_child(attack_box)
	attack_pool_text = _make_label(attack_box, Vector2.ZERO, 18, Palette.semantic("danger"))
	attack_pool_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attack_target_text = _make_label(attack_box, Vector2.ZERO, 13, Palette.semantic("muted"))
	attack_target_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attack_panel.visible = false
	canvas.add_child(attack_panel)

## 顶部三列状态与底部常驻提示，均不吞掉牌桌鼠标事件。
## ResourceHUD 拆出资金、用户、待付与风险，完整摘要仍供抽屉首行复用。
func _setup_res_panel(canvas: CanvasLayer) -> void:
	hud_panel = PanelContainer.new()
	hud_panel.name = "ResPanel"
	hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(Palette.semantic("surface"), 0.96)
	style.border_color = Palette.semantic("muted")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(6)
	hud_panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(hud_panel)
	# 两层父级关系保留给抽屉收养回合摘要；普通横屏则是阶段+双方资源的三列。
	var row := HBoxContainer.new()
	row.name = "ResourceHeaderRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	hud_panel.add_child(row)
	lbl_round = _make_label(row, Vector2.ZERO, 20, Palette.semantic("ink"))
	lbl_round.name = "RoundStatus"
	lbl_round.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl_round.custom_minimum_size = Vector2(184, 0)
	lbl_round.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_round.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_round.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl_round.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	hud_player_card = ResourceHUD.new()
	hud_player_card.name = "PlayerResourceCard"
	row.add_child(hud_player_card)
	hud_player_card.setup("你的公司", "player", _uses_fitted_table())
	hud_bot_card = ResourceHUD.new()
	hud_bot_card.name = "BOTResourceCard"
	row.add_child(hud_bot_card)
	hud_bot_card.setup("对手公司", "bot", _uses_fitted_table())
	lbl_player_res = hud_player_card.summary
	lbl_bot_res = hud_bot_card.summary

	# 当前提示独立放在底部工具与主操作之间，长文本省略且完整内容在 tooltip/记录中。
	# 抽屉会立即把它收养到自己的底栏，不建立第二个空面板。
	var message_parent: Node = row
	if not _uses_fitted_table():
		hud_status_panel = PanelContainer.new()
		hud_status_panel.name = "StatusPanel"
		hud_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var status_style := style.duplicate() as StyleBoxFlat
		status_style.set_content_margin_all(9)
		hud_status_panel.add_theme_stylebox_override("panel", status_style)
		canvas.add_child(hud_status_panel)
		message_parent = hud_status_panel
	lbl_msg = _make_label(message_parent, Vector2.ZERO, 17, Palette.semantic("warning"))
	lbl_msg.name = "StatusMessage"
	lbl_msg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl_msg.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl_msg.clip_text = true
	lbl_msg.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not _uses_fitted_table():
		get_viewport().size_changed.connect(_position_table_hud)
		hud_panel.resized.connect(_fit_table_camera)
		_position_table_hud()
		_fit_table_camera.call_deferred()

## 牌桌相机据此预留上栏，不再让资源面板盖住对手明牌。
func table_hud_rect() -> Rect2:
	return hud_panel.get_global_rect() if is_instance_valid(hud_panel) else Rect2()

func _position_table_hud() -> void:
	if _uses_fitted_table() or not is_instance_valid(hud_panel):
		return
	var viewport_size := get_viewport().get_visible_rect().size
	# 上栏按阶段/资源的实际内容定宽，右上工具区仍保留自己的空间。
	var row: Control = hud_panel.get_child(0)
	var style: StyleBox = hud_panel.get_theme_stylebox("panel")
	var wanted := row.get_combined_minimum_size().x + style.get_minimum_size().x
	var width := minf(wanted, viewport_size.x - 48.0)
	hud_panel.custom_minimum_size.x = 0.0
	hud_panel.size.x = width
	hud_panel.position = Vector2(maxf(16, roundf((viewport_size.x - 320.0 - width) * 0.5)), 12)
	if is_instance_valid(hud_status_panel):
		hud_status_panel.position = Vector2(194, viewport_size.y - 68)
		hud_status_panel.size = Vector2(maxf(180, viewport_size.x - 482), 44)
	_fit_table_camera()

## 只在窗口/顶栏尺寸变化时拟合镜头。世界与卡牌几何保持原值，透视角仍为71度。
func _fit_table_camera() -> void:
	if _uses_fitted_table() or not is_instance_valid(hud_panel) or board == null or board.camera == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var north := maxf(hud_panel.get_global_rect().end.y, 124.0) + 10.0
	var south := hud_status_panel.position.y - 12.0 if is_instance_valid(hud_status_panel) else viewport_size.y - 90.0
	_table_hud_content = Rect2(20, north, maxf(viewport_size.x - 40, 1), maxf(south - north, 1))
	var fit := DrawerCameraFit.fit_perspective(viewport_size, _table_hud_content,
		Rect2(-11.5, -8.30, 23.0, 14.5), 0.0, 1.5, 71.0, 50.0, 8.0)
	DrawerCameraFit.apply(board.camera, fit)

func table_content_rect() -> Rect2:
	return _table_hud_content

const RES_PANEL_W := 900

## 「完成行动」按钮固定在右下角，距视口边 24 px
func _position_pass_button() -> void:
	if drawer_presentation != null:
		return
	if not btn_pass:
		return
	btn_pass.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var margin := 24.0
	# PRESET_BOTTOM_RIGHT 之后四个锚点全是 1.0（相对于父容器右下角）。
	# 此时要通过 offset 而不是 position 来偏移：
	# position 的 setter 会减去 anchor * parent_size，
	# 写 position = Vector2(-264, -96) 实际上等于又往左上移了整个父容器大小，按钮出屏。
	btn_pass.offset_left   = -(btn_pass.custom_minimum_size.x + margin)
	btn_pass.offset_top    = -(btn_pass.custom_minimum_size.y + margin)
	btn_pass.offset_right  = -margin
	btn_pass.offset_bottom = -margin

## 兜底：拖拽中途松手被 HUD 控件吃掉时，把牌放回桌面
## （_unhandled_input 只收未被 GUI 消费的事件，光靠它会漏）
func _input(event: InputEvent) -> void:
	if is_instance_valid(_replay_picker) and _replay_picker.visible:
		return
	if (drawer_window or mobile_mode or web_mode) and event is InputEventKey and event.pressed and not event.echo 		and event.keycode == KEY_ESCAPE:
		if drawer_presentation and drawer_presentation.panels_open():
			drawer_presentation.close_panels()
		else:
			if board and not board._drag_cards.is_empty():
				board.cancel_drag()
			if drawer_window:
				drawer_window.collapse_now()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
		and not event.pressed and board and not board._drag_cards.is_empty():
		if event.canceled:
			board.cancel_pointer()
		else:
			board.release_pointer.call_deferred(event.position)
	if event is InputEventKey and event.pressed and not event.echo \
		and (event as InputEventKey).keycode == KEY_F5:
		_save_replay()

func _notification(what: int) -> void:
	if not mobile_mode or not is_instance_valid(board):
		return
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if is_instance_valid(_replay_picker) and _replay_picker.visible:
			_replay_picker.close()
		elif is_instance_valid(_join_panel):
			_join_panel._on_cancel()
		elif drawer_presentation and drawer_presentation.panels_open():
			drawer_presentation.close_panels()
		elif not board._drag_cards.is_empty():
			board.cancel_pointer()
		else:
			get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		board.cancel_pointer()
		if replay_session == null and tape.size() > 0:
			_flush_record_view()
			tape.save()

## 把这一局到此刻的过程存出去。**不必等到结束**，也不打断这一局 ——
## 存完录像还在继续录（tape 没 stop）。
##
## 两条入口都通：左下角的 btn_save，和 _input 里的 F5。
## 一开始只做了 F5，理由是「排查用的口子不该混进玩法按钮里」——
## 结果是用户找不到它（原话「对局保存入口在哪儿？找不到」）。
## 藏起来的功能等于没有，所以补了按钮；F5 也留着，
## 因为它在别处没有绑定（项目里没有 InputMap 动作），
## 而且拖着牌的时候手不用离开桌面
func _save_replay() -> void:
	if web_mode:
		_flush_record_view()
		var record: Tape = replay_session.record if replay_session != null else tape
		var downloaded: bool = web_files.download_json(record.to_dict(), record.default_name())
		if drawer_presentation != null:
			drawer_presentation.show_record_download(downloaded)
		if downloaded:
			_show_message("已发起录像下载，请在浏览器下载列表查看。", Palette.semantic("success"))
		else:
			_show_message("浏览器下载不可用，请允许此页面下载文件后重试。", Palette.semantic("danger"))
		return
	if replay_session != null:
		_present_save_result(replay_session.path, replay_session.record.size())
		return
	_flush_record_view()
	var path := tape.save()
	if path == "":
		_present_save_result(Tape.path_dir(), 0, true)
		return
	# 路径进的是 save_notice 那块面板，**不是 lbl_msg**：一条要拿去 Finder 用的
	# 绝对路径在提示条里抄不走，而且 440 宽装不下会折成三四行
	# （用户原话「当前保存路径的提示是直接渲染到画面，这个不合适」）。
	# 理由整段在 scenes/save_notice.gd 文件头
	#
	# globalize_path 留着：Tape.save 现在回的已经是绝对路径（~/.niumapai_record/…）,
	# 这一步是个 no-op，但退路那一支回的还是 user:// 底下的（见 Tape.path_dir）
	var abs_path := ProjectSettings.globalize_path(path)
	_present_save_result(abs_path, tape.size())
	print("[录像] %s（%d 步）" % [abs_path, tape.size()])

func _present_save_result(path: String, steps: int, failed := false) -> void:
	if drawer_presentation != null:
		drawer_presentation.show_record_result(path, steps, failed)
	elif failed:
		save_notice.show_failed(path)
	else:
		save_notice.show_saved(path, steps)

func _drawer_timer(seconds: float) -> SceneTreeTimer:
	# 演出计时器遵守场景暂停；联网时不暂停场景，网络仍正常轮询。
	return get_tree().create_timer(seconds, false)

func _process(delta: float) -> void:
	_flush_record_view()
	_update_thinking_hint()
	# 联网局的心跳。WebSocketPeer 是轮询式的，不 poll 就什么都不会发生
	# （收不到、发不出、也不报错）。
	#
	# NetTransport 自己在 submit / _await_server_op 的等待循环里也 poll ——
	# 但那**只覆盖「我正在等一条回音」的时候**。等对手行动那一段
	# （_await_foe_action 循环在 get_tree().process_frame 上）谁都没在 poll，
	# 于是对手的每一条动作都到不了：我这边一直显示「对手正在行动」，
	# 而对手那边早就收手了。两边都不报错
	if _net != null:
		_net.poll()
	# 本机开着房的话服务器也在这个进程里，同样是轮询式的（见 EmbeddedHost.poll）。
	# 不 poll 的后果比客户端不 poll 更隐蔽：对手的 socket 连上了、
	# 握手完不成，他那边显示「服务器没让我入座」，而**我这边一切正常**
	if _host != null:
		_host.poll()
	_position_pass_button()
	_tick_drag_lease(delta)
	# 摞分组变了就广播（联网局才发，见 _push_piles）
	_push_piles()
	if board:
		_refresh_shields()
		_refresh_attack_panel()
	# 攻击点数追踪鼠标（玩家攻击回合）
	if _attack_follow_mouse and lbl_attack.visible:
		lbl_attack.set_anchors_preset(Control.PRESET_TOP_LEFT)
		lbl_attack.position = get_viewport().get_mouse_position() + Vector2(24, -8)
		if drawer_presentation:
			var area: Rect2 = drawer_presentation.content_rect()
			var extent := lbl_attack.get_combined_minimum_size()
			lbl_attack.position.x = clampf(lbl_attack.position.x, area.position.x, maxf(area.position.x, area.end.x - extent.x))
			lbl_attack.position.y = clampf(lbl_attack.position.y, area.position.y, maxf(area.position.y, area.end.y - extent.y))

func _refresh_button_theme() -> void:
	for button in [btn_net, btn_save, btn_resign, btn_pass]:
		if is_instance_valid(button):
			UIButtonTheme.apply(button)
	if drawer_presentation and drawer_presentation.has_method("refresh_button_roles"):
		drawer_presentation.refresh_button_roles()

var _connection_mascot_state := "idle"
var _phase_mascot_state := "idle"
# BOT 对局首次购牌或完成行动前保留邀请；联机只显示实际对局状态。
var _opening_action_pending := true
var _foe_completed_round := -1
var _attack_actor := ""
var _player_attack_busy := 0

func _set_mascot_state(value: String) -> void:
	_phase_mascot_state = value
	_refresh_mascot_state()

func _set_connection_mascot_state(value: String) -> void:
	_connection_mascot_state = value
	_refresh_mascot_state()

## 以实际业务优先级决定角色状态，网络回调和回合回调不会相互覆写终局/确认。
func _refresh_mascot_state() -> void:
	if replay_session != null:
		return
	if not drawer_presentation:
		return
	var value := _phase_mascot_state
	if state != null and state.winner != "":
		value = "success" if state.winner == my_seat else "defeat"
	elif _resign_armed:
		value = "danger"
	elif _connection_mascot_state != "idle":
		value = _connection_mascot_state
	elif _net != null and _net._closed:
		value = "disconnected"
	elif _foe_gone():
		value = "foe_offline"
	elif _net != null and not _net_table_drawn:
		value = "waiting"
	elif state != null:
		match phase:
			PHASE_ACTION:
				if _actor == foe_seat:
					value = "resolving" if _foe_completed_round == state.round_num else "foe_acting"
				elif _foe_completed_round == state.round_num:
					# 提醒玩家时必须真的轮到玩家；自动换阶段期间显示结算状态。
					value = "foe_done" if not board.input_locked and not btn_pass.disabled else "resolving"
				elif _opening_action_pending and _net == null and _foe_is_bot():
					value = "opening"
				else:
					value = "your_turn"
			PHASE_ATTACK:
				if board.attack_mode and _player_attack_busy == 0:
					value = "your_attack"
				elif _attack_actor == foe_seat:
					value = "foe_attacking"
				else:
					value = "resolving"
			PHASE_SETTLING:
				value = "resolving"
	drawer_presentation.set_mascot_state(value)

func _refresh_attack_panel() -> void:
	if not is_instance_valid(attack_panel):
		return
	var active := phase == PHASE_ATTACK and board != null and board.attack_mode
	attack_panel.visible = active
	if not active or pipe == null:
		return
	var pools := _attack_pools
	attack_pool_text.text = "现金攻击 %d    用户攻击 %d" % [
		int(pools.get(CardDB.RES_CASH, 0)), int(pools.get(CardDB.RES_USER, 0))]
	var count := pipe.applier().affordable_targets(foe_seat).size()
	attack_target_text.text = "可攻击目标 %d · 点击高亮卡牌选择目标" % count

func _set_button(text: String, cb: Callable) -> void:
	btn_pass.text = text
	btn_pass.accessibility_name = text
	for c in btn_pass.pressed.get_connections():
		btn_pass.pressed.disconnect(c["callable"])
	btn_pass.pressed.connect(cb)
	btn_pass.disabled = false

func _make_label(parent: Node, pos: Vector2, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", Fonts.zh())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.position = pos
	parent.add_child(l)
	return l

# ---------- 回合同步 ----------

## 按当前 state 重画整桌，然后开行动阶段。开局和重开走这一个。
func _sync_round() -> void:
	_respawn_all()
	_begin_action_phase()

## 把桌上的实体全删掉，**不摆新的**。
##
## 从 _respawn_all 里拆出来是给「入座了但还没发牌」用的（_draw_net_table）：
## 那一刻没有牌可摆，但单机局那副牌还在桌上，留着会让人以为联网局已经开打了
func _clear_table() -> void:
	if is_instance_valid(_table_actions):
		_table_actions.cancel_pawn()
	for uid in entities.keys():
		var e: CardEntity = entities[uid]
		if is_instance_valid(e):
			board.unregister_card(e)   # 不注销会在 board.cards 里留下已释放引用
			e.queue_free()
	entities.clear()
	_clear_market()

## 收掉货架上的卡和价签。
##
## `unregister_card` 不能省，理由同 `_clear_table` 里那句：货架卡也是
## `board.register_card` 注册过的（见 _spawn_market_card），不注销就会在
## `board.cards` 里留下已释放引用。遍历那边都有 `is_instance_valid` 挡着，
## 所以症状不是崩，是**数组无界增长** —— 原先 _next_round 自己抄了一份清理、
## 独独漏了这一句，实测每回合攒 8 条死引用（四个回合后 board.cards 从 68 涨到 100）
func _clear_market() -> void:
	for c in market_cards:
		if is_instance_valid(c):
			board.unregister_card(c)
			c.queue_free()
	market_cards.clear()
	for lb in market_price_labels:
		if is_instance_valid(lb):
			lb.queue_free()
	market_price_labels.clear()

## 按 `state.market` 重摆货架：先收掉旧的，再照当前张数算间距摆一排。
##
## 间距按张数算而不是定长：货架张数是会变的（买空之后补牌），
## 定长排布在张数少时会在中间留一段空当
func _respawn_market() -> void:
	_clear_market()
	market_slots.clear()
	for i in state.market.size():
		var slot: Vector3 = replay_session.market_position(i, _uses_fitted_table()) if replay_session != null else _market_slot(i, state.market.size())
		market_slots.append(slot)
		_spawn_market_card(i, state.market[i], slot)

## 重画整桌 —— **不碰阶段**。
##
## 从 _sync_round 里拆出来是为了联网局的重连（scenes/main.gd 的 _offer_reconnect / _on_net_down）：
## 那一条路要「照服务器那份快照把桌子摆出来」，但**不能**顺手开行动阶段 ——
## 阶段由服务器广播（Protocol.phase），本地自己开一个的后果是
## 客户端以为轮到自己、按钮亮着，点下去被服务器 not_your_turn 拒掉。
## 而那条拒绝只会闪一句红字，玩家看到的是「按钮能点但没反应」
##
## 前置条件：state.players 里**两个座位都在**（也就是 new_game 跑过了）。
## 联网局里这一条不是白给的 —— 见 _draw_net_table
func _respawn_all() -> void:
	_clear_table()

	for c in state.players[my_seat]["cards"]:
		_spawn_entity(c, _rand_pos(PLAYER_ZONE_Z + 0.8, PLAYER_ZONE_Z + 3.5), true)
	for c in state.players[foe_seat]["cards"]:
		var e := _spawn_entity(c, _rand_pos(BOT_ZONE_Z - 2.5, BOT_ZONE_Z + 1.0), false)
	# 已有的组合要**在理牌之前**变回 board.groups（重连时快照里可能带着组合）。
	# 次序不能反：_tidy_player_idle 认「哪些牌是闲置的」是问 board.groups 的
	# （settle_layout.gd 的 _collect_idle_units 对我这一侧读 groups，
	# 对对手那一侧读 state.combos），组还没建起来时我编好的组合会被
	# 当成散牌拆进现金堆、用户堆里 —— 状态里组合还在，桌上散了
	_restore_my_combo_groups()
	layout._layout_bot_idle()   # BOT 理牌：闲置现金/用户各自成堆
	layout._tidy_player_idle() # 玩家理牌：散落现金/用户各自成摞

	_respawn_market()

	_update_hud()
	# 「桌上摆的是一份发过牌的局面」。**置在末尾，不置在开头**：
	# GDScript 的运行时错误只中止**出错的那个函数**，调用方照样往下跑
	# （callback-script-error-doesnt-fail-test 说的是同一件事）。
	# 置在开头的话，上面任何一行抛错都会留下「摆失败了却记成摆好了」——
	# 于是补发的那份 seated 被 _on_net_seated 当成重复的挡掉，桌子再没人摆。
	# 置在末尾时中途出错留下的是 false，下一份 seated 还能重试一次
	#
	# **在这里置位而不是在调用方**：摆桌子的路有四条（开局 _sync_round、
	# 联网入座 _draw_net_table、rematch _on_rematch_started、重连），
	# 联网那道「桌子没摆就不开阶段」的门（_on_net_phase）对四条都要成立。
	# 放调用方就会漏 —— rematch 那条漏掉的症状是新局双方灰按钮、
	# 谁也动不了，而且一条错都不报
	_net_table_drawn = true

## 把 state.combos 里属于我这一侧的组合变回 board.groups 的摞。
##
## 为什么只有我这一侧要：对手侧的组合根本不进 board.groups ——
## 那边的摆放是 settle_layout._bot_piles 现从 state.combos 读的（每次重排都重读），
## 所以对手的组合重画时自动就在。我这一侧反过来：board.groups 是**桌面的实况**，
## 它只由拖拽产生，重画一遍桌子就没了。
##
## 少了这个函数，重连之后我编好的组合在状态里还在（服务器那份就是权威），
## 桌上却是散牌 —— 而且下一次 _register_player_combos 会把它们当成没编过，
## 重发一遍 create_combo 被引擎以「卡已在别的组合里」拒掉。
## 症状是「重连之后我的组合没了，重编也编不上」，一条错都不报
func _restore_my_combo_groups() -> void:
	board.groups.clear()
	# 已经许诺出去的落点。逐组现查 entities 是不够的：这一组的牌此刻还摊在
	# _rand_pos 撒出来的随机位置上，_free_spot 看到的是**旧坐标**，
	# 于是第二组很可能挑中第一组刚被搬到的那个点（那儿在它眼里是空的）。
	# 两组精确重叠的样子就是「重连之后少了一个组合」——牌都在，只是摞在一起
	var claimed: Array = []
	for combo in state.combos:
		if str(combo["owner"]) != my_seat:
			continue
		var cs: Array = []
		var mine: Dictionary = {}
		for u in combo["uids"]:
			if entities.has(u) and is_instance_valid(entities[u]):
				cs.append(entities[u])
				mine[u] = true
		if cs.size() < 2:
			continue   # 不成摞（升级吃掉了配方卡，只剩一张）——留给理牌当散卡
		# ignore 传自己这一组：它们的旧坐标是随机撒出来的，不该把自己挡在外面
		var at: Vector3 = layout._free_spot(
			layout._unit_anchor(my_seat, cs[0].def_id), my_seat, claimed, mine)
		claimed.append(at)
		# was_valid 传 true：这一组**已经被引擎收下了**，它当然是齐整的。
		# 让 board 现算的话，重连后第一次重排会当场判出「刚凑满」而放一遍风铃
		# ——玩家什么都没做却听见成组音效
		var g: Dictionary = board.make_group(Board.core_first_order(cs), true, true)
		board.groups.append(g)
		board._layout_group(g, at)

func _rand_pos(z_min: float, z_max: float) -> Vector3:
	return Vector3(randf_range(-7, 7), 0.2 if _uses_fitted_table() else randf_range(2, 5), randf_range(z_min, z_max))

## from_pos —— 生出来时先摆在这儿，再飞到 pos。用于结算产出：现金/用户得从
## 产出它们的那个组合上飞出来，而不是凭空出现在资源堆旁边。
## 传 null（默认）就是老行为：直接落在 pos
func _spawn_entity(state_card: Dictionary, pos: Vector3, draggable: bool,
		from_pos = null, idx: int = 0, total: int = 1) -> CardEntity:
	if _uses_fitted_table() and layout:
		var safe: Rect2 = layout._center_bounds(my_seat if draggable else foe_seat)
		if safe.has_area():
			pos.x = clampf(pos.x, safe.position.x, safe.end.x)
			pos.z = clampf(pos.z, safe.position.y, safe.end.y)
		if draggable:
			pos = board.clamp_player_position(pos)
	var e: CardEntity = _table_scene.spawn_card(board, state_card, pos, draggable)
	entities[state_card["uid"]] = e
	if from_pos != null:
		_fly_from(e, from_pos, pos, idx, total)
	return e

## 产出的卡从组合位置飞到落点。
## 落地用 BACK/EASE_OUT 收一下，和别处的落卡手感一致（见 _spawn_market_card）
##
## idx / total —— 这是这一批的第几张、一共几张。产出是按资源量来的（output_n 4~16），
## 得让人**数得出来是几张**。同时同点出发（哪怕带 ±0.45 随机偏移）整批会完全重叠，
## 看着就是「产出了一张牌」，所以两件事一起做：
##   1. 依次起飞（SPAWN_FLY_STAGGER），后面的先在原地等着 —— 数量是「一张张蹦出来」
##      的节奏读出来的，不是靠瞬间铺开的一片；
##   2. 起点按 idx 铺成一圈而不是纯随机，随机会撞在一起，等角度铺开一定不重叠。
## 错开总时长压在 SPAWN_FLY_SPREAD 内：_resolve_combo_visual 演完这一组只等 0.7s
## 就往下走，再之后 _stack_settled 会把没跑完的补间一律掐掉（见 _cancel_fly），
## 错太开的话最后几张等于没飞
const SPAWN_FLY_TIME := CardMotion.SPAWN_FLY_TIME
const SPAWN_FLY_SPREAD := CardMotion.SPAWN_FLY_SPREAD     # 整批错开的总时长上限
const SPAWN_FLY_RING := CardMotion.SPAWN_FLY_RING      # 起点铺开的半径
func _fly_from(e: CardEntity, from_pos: Vector3, to_pos: Vector3,
		idx: int = 0, total: int = 1) -> void:
	_card_motion._fly_from(e, from_pos, to_pos, idx, total)

## 把一张牌搬到 target，并且**在飞的过程中就宣告它的归宿**。
##
## 为什么要宣告：`layout._free_spot` 拿坐标当占用判据，而飞行中的牌实时坐标
## 还在出发点。买卡飞 0.35s，这期间任何一处再问落点都会把同一个坑再许诺一次
## —— 两张牌精确重合，后到的把先到的整个盖住（memory: settle-runs-mid-flight）。
## 记在 meta 上而不是另存一份台账：牌被 queue_free 时这条记录跟着走，
## 不会留下「指着已释放实体的落点」这种要单独清理的东西
##
## 和 fly_tw 那个 meta 分开：那个是「有没有在飞」给 _cancel_fly 用的，
## 这个是「要飞到哪」给避让用的，两个量的读者不同（同一个 meta 兼两用时，
## 掐掉补间就等于把归宿也忘了，而归宿这时候恰恰还得算占用）
## 撤掉归宿宣告。单拎出来是因为撤的地方有三处（落地回调、_cancel_fly、
## 以及同一张牌被连着搬两次时前一个回调），而 remove_meta 撤一个不存在的键
## 会 push_error —— 那种报错不会让测试失败（memory:
## callback-script-error-doesnt-fail-test），只会在日志里堆一片红
func _clear_dest(e: CardEntity) -> void:
	_card_motion._clear_dest(e)

func _move_to(card: CardEntity, target: Vector3, time := 0.35,
		trans := Tween.TRANS_BACK) -> Tween:
	return _card_motion._move_to(card, target, time, trans)

## 搬卡之前先掐掉还没跑完的飞入补间（见 _fly_from）
func _cancel_fly(e: CardEntity) -> void:
	_card_motion._cancel_fly(e)

func _spawn_market_card(idx: int, def_id: String, slot: Vector3) -> void:
	var entry: Dictionary = _table_scene.spawn_market_card(board, idx, def_id, slot)
	market_cards.append(entry["card"])
	market_price_labels.append(entry["price"])

## 移除某个货架位的价签并保持与 market_cards 的下标对齐
func _drop_price_label(idx: int) -> void:
	if idx < 0 or idx >= market_price_labels.size():
		return
	var lb = market_price_labels[idx]
	if is_instance_valid(lb):
		if lb.has_method("retire"):
			lb.retire()
		else:
			lb.queue_free()
	market_price_labels.remove_at(idx)

# ---------- 抽卡阶段：购买 ----------

## 程序化购买（测试/调试用）：公共区卡牌本身不可拖动，
## 游戏内购买走 _on_dropped_on_market（拖现金堆到货架卡上）。
## 两条路都只是「凑出 pay_uids 交给 state.buy，成交后调 _commit_buy」，
## 规则在引擎那一份、收尾在 _commit_buy 那一份，这里不再有第二套
func _try_buy(market_idx: int, pay_uids: Array = []) -> Dictionary:
	var session := _session_generation
	if not _start_client_action():
		return {"ok": false, "code": "busy", "reason": "上一步还在处理中"}
	var result: Dictionary = await _try_buy_impl(market_idx, pay_uids)
	_end_client_action(session)
	return result

func _try_buy_impl(market_idx: int, pay_uids: Array = []) -> Dictionary:
	var session := _session_generation
	if replay_session != null:
		return {"ok": false, "reason": "录像播放中"}
	var card := market_cards[market_idx]
	var result: Dictionary = await pipe.submit(Intent.buy(my_seat, market_idx, pay_uids), my_seat)
	if not _session_current(session):
		return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}
	if not result["ok"]:
		sfx.play("deny")
		_show_message(result["reason"], Palette.semantic("danger"))
		_shake(card)
		return result
	_commit_buy(market_idx, card, result)
	return result

## 成交后的收尾：付掉的卡吸进货架卡，货架卡转成己方卡飞进卡牌区。
## 拖拽买和程序化买共用这一份 —— 两处各抄一遍时，
## 「买到手恢复可拖动」这类改动漏掉一处就只在其中一条路上生效
func _commit_buy(idx: int, card: CardEntity, result: Dictionary) -> void:
	_opening_action_pending = false
	_refresh_mascot_state()
	_table_actions.purchase(idx, card, result)
	_update_hud()
	_show_message("购入「%s」" % CardDB.card_name(card.def_id), Palette.semantic("success"))

func _shake(card: CardEntity) -> void:
	_card_motion._shake(card)

func _fly_out(card: CardEntity, target := Vector3(0, 4, 2)) -> void:
	_card_motion._fly_out(card, target)

## 被打掉的卡：横向从中间撕成上下两片、朝反方向翻出去，同时整体淡掉。
## 不翻卡背也不放泡沫粒子 —— 翻面是「离场」的语汇（典当/买卡都用它），
## 被打掉该是「毁掉」；泡沫那圈 SphereMesh 粒子（_burst）跟纸牌质感也不搭。
##
## 横着撕而不是竖着：卡面是竖构图（1.2×1.7），标题带横在顶上、图标横在中间，
## 竖着切会把标题带和图标各劈成左右两半，读不出撕的是哪张牌；
## 横着切正好在图标腰上断开，上片带着标题带和上半个图标，一眼看得出是现金还是用户。
##
## 撕口做在底板着色器里（card_tear.gdshader 沿一条横向锯齿线切），不是拿两个方块拼的：
## 卡面上的框线、标题带、卡面色全在同一张母版上，切母版才连得上。
## 图标也合进了那个着色器（见 CardEntity._feed_icon），跟着一起被切断 ——
## 图标和文字一淡掉，撕开的两片上就只剩空白底板，
## 看着像「把模板撕了」而不是「把这张现金牌撕了」。
## 卡名等 Label3D 进不了着色器，按它在卡上的位置分派给上片或下片带走，
## 同样不淡掉：字跟着自己那半张纸飞，比原地消失自然
##
## 素材缺失回退（没有底板母版可切）时退回老的飞出动画，不至于卡牌原地不动
const TEAR_TIME := CardMotion.TEAR_TIME
func _tear_out(card: CardEntity, dir: Vector3) -> void:
	_card_motion._tear_out(card, dir)

## 配方消耗的演出（scenes/main.gd 的 _resolve_combo_visual）：这一组结算要吃掉的现金卡朝资金堆方向吸走。
##
## 朝**资金堆锚点**吸而不是屏幕上那行 HUD 文字：桌面是 3D 的，
## HUD 是 CanvasLayer 上的 2D 文字，没有一个「世界坐标」可以吸过去
## （硬反投影一个也只是屏幕边缘某处，看着像卡飞出了桌子）。
## 资金堆是玩家心里「我的钱在这儿」的那个地方，往那儿吸读作「付出去了」
##
## 付 0 的组（用户配方、升级组）名单是空的，直接返回 —— 那种组不掏钱
##
## **节奏和攻击对齐**（同 _animate_removed）：逐张错开 TEAR_STAGGER 起飞、
## 每张响一声、等的时长**正好等于演的时长**。
## 从前这里是「全部同时吸走 + 固定等 0.28s」，那有两处不对：
##   1. 一次付 N 张读作一团糊掉的东西，数不出付了几张
##      （攻击那边同样 N 张是「刺啦刺啦刺啦」一串，N 声就是 N 张）
##   2. 0.18s 演完、等 0.28s → 每组结算白挂 0.1s 空场，桌上什么都不动。
##      而攻击那边 await 的就是 dur 本身，一毫秒的空场都没有
func _payment_animation_target(owner: String, combo: Dictionary) -> Vector3:
	# 现金→用户的生产组合要和用户卡使用同一个「下一张用户卡」落点。
	# 不能只返回现金锚点：那只是资源列的起始锚，而真实用户产出会经
	# _pile_slot 避开已有摞后落到具体组位。preview 不改台账，随后 arrival_spot
	# 会用完全相同的 _arr_count/_arr_taken 再算一次，保证实际 tween 终点一致。
	var eval: Dictionary = combo.get("eval", {})
	if eval.get("type", "") == "production" and eval.get("output_res", "") == CardDB.RES_USER \
		and layout.has_method("preview_arrival_spot"):
		return layout.preview_arrival_spot(owner, {"def_id": CardDB.unit_id(CardDB.RES_USER)})
	return layout.payment_spot(owner, CardDB.RES_CASH)

func _consume_recipe_visual(owner: String, combo: Dictionary, paid_uids: Variant = null) -> void:
	# 结算演出传裁决器返回的实付名单，避免联网拒付时先把现金演走。
	var pay: Array = state.recipe_pay_uids(owner, combo) if paid_uids == null else paid_uids
	if pay.is_empty():
		return
	var n: int = _table_actions.pay_recipe(pay, _payment_animation_target(owner, combo))
	if n > 0:
		await _drawer_timer(_suck_batch_time(n)).timeout

## 逐张错开吸走一批的总时长。和攻击那边同一个式子（见 _animate_removed 的 dur）：
## 最后一张的起飞时刻 + 它自己吸完要的时间
func _suck_batch_time(count: int) -> float:
	if count <= 0:
		return 0.0
	return TEAR_STAGGER * float(count - 1) + SUCK_TIME

## 到点再响。sfx 没有延迟播放的接口，而错开起飞就要求声音跟着各自那一拍
## （攻击那边是 _delayed_flyout 里顺手播的，那条路每张卡本来就有自己的补间）。
## 只收动作名：响度是配置说的，不从调用方一路带下来
func _delayed_sfx(action_name: String, delay: float) -> void:
	_card_motion.sfx = sfx
	_card_motion.delayed_sound(action_name, delay)

## 吸入动画：卡牌被快速吸进目标点（购买付款、典当回收）
## 吸走一张的时长。和撕开（TEAR_TIME）不是一个数，两套语汇本来就不同快慢；
## 要对齐的是**节奏**（逐张错开 + 等的时长正好等于演的时长），不是这个数
const SUCK_TIME := CardMotion.SUCK_TIME

## delay：这一张比第一张晚多久起飞。逐张错开的那份偏移由调用方算
## （攻击那边同一份职责在 _delayed_flyout / _animate_removed）
func _suck_into(card: CardEntity, target: Vector3, delay := 0.0) -> void:
	_card_motion._suck_into(card, target, delay)

# ---------- 抽卡阶段：堆叠购买（拖现金堆到公共区卡上） ----------

## 拖现金堆到货架卡上 = 买。发的是意图，不是直接改状态：
## pay_uids 的**次序**是真输入（引擎按 slice(0, price) 取前几张），联网时要原样传过去
func _on_dropped_on_market(drag_cards: Array, market_card: CardEntity) -> void:
	var session := _session_generation
	if not _start_client_action():
		return
	await _on_dropped_on_market_impl(drag_cards, market_card)
	_end_client_action(session)

func _on_dropped_on_market_impl(drag_cards: Array, market_card: CardEntity) -> void:
	var session := _session_generation
	if replay_session != null:
		return
	var idx := market_cards.find(market_card)
	if idx < 0:
		return
	if phase != PHASE_ACTION or _actor != my_seat:
		_return_cards_to_player_zone(drag_cards)
		_show_message("现在不能买卡", Palette.semantic("danger"))
		return
	var pay_uids: Array = []
	for c in drag_cards:
		pay_uids.append(c.uid)
	var result: Dictionary = await pipe.submit(Intent.buy(my_seat, idx, pay_uids), my_seat)
	if not _session_current(session):
		return
	if not result["ok"]:
		# 抖一下只给「够买但不该买 / 差一点就够」这两类：拖错卡种是操作失误，
		# 抖起来像是这张卡有问题
		if result.get("code", "") in ["short", "zero_out"]:
			_shake(market_card)
		_return_cards_to_player_zone(drag_cards)
		sfx.play("deny")
		_show_message(result["reason"], Palette.semantic("danger"))
		return

	_commit_buy(idx, market_card, result)
	# 多付的现金：保持堆叠状态退回卡牌区。
	# 引擎只收走 price 张（removed_uids），拖来的其余几张差集算出来
	var paid := {}
	for u in result["removed_uids"]:
		paid[u] = true
	var excess: Array = []
	for c in drag_cards:
		if not paid.has(c.uid):
			excess.append(c)
	_return_cards_to_player_zone(excess)

## 把一摞卡退回玩家卡牌区（多张保持堆叠，单张散放）。
## 收拢态跟着一起还回去：玩家把收拢好的现金摞拖去买卡，付掉一部分后剩下的
## （以及被拒时退回的全部）还是同一摞钱，摊开等于每买一次卡就要重新双击收一次
func _return_cards_to_player_zone(drag_cards: Array) -> void:
	if drag_cards.is_empty():
		return
	# 退回点要避让，不能硬钉在 PLAYER_ZONE_Z + 2.2 上：那是「买到的牌不见了」
	# 同一个毛病的另一道门 —— 拖一摞钱去买、被拒退回，落点和桌上已有的牌
	# 精确重合就又是一次掩埋。x 沿用手放下的位置（退回该看着像退回原处）
	var ignore := {}
	for c in drag_cards:
		ignore[c.uid] = true
	var base := layout._free_spot(
		Vector3(clampf(drag_cards[0].global_position.x, -8.0, 8.0), 0.2,
			PLAYER_ZONE_Z + 2.2),
		my_seat, [], ignore)
	base.y = 0.2
	drag_cards[0].global_position = base
	if drag_cards.size() > 1:
		# 预评估，退回已凑满的组合不误报叮
		var ng: Dictionary = board.make_group(drag_cards.duplicate(), board.last_drag_compact)
		board.groups.append(ng)
		board._layout_group(ng)
	else:
		drag_cards[0].freeze = false

# ---------- 典当行（回收非现金卡 → 现金） ----------

func _on_dropped_on_pawn(drag_cards: Array) -> void:
	var session := _session_generation
	if not _start_client_action():
		return
	await _on_dropped_on_pawn_impl(drag_cards)
	_end_client_action(session)

func _on_dropped_on_pawn_impl(drag_cards: Array) -> void:
	var session := _session_generation
	if replay_session != null:
		return
	if phase != PHASE_ACTION or _actor != my_seat:
		_return_cards_to_player_zone(drag_cards)
		return
	var uids: Array = []
	var cash_cards: Array = []
	for c in drag_cards:
		if CardDB.pawn_value(c.def_id) > 0:
			uids.append(c.uid)
		else:
			cash_cards.append(c)
	if uids.is_empty():
		sfx.play("deny")
		_show_message("典当行不收现金卡", Palette.semantic("danger"))
		_return_cards_to_player_zone(drag_cards)
		return
	# 自杀护栏：用户归零 = 当场判负。规则本身在 GameState.pawn() 里兜着，
	# 这里先问一次是为了把卡放回去 —— 等 pawn() 拒绝时卡已经飞到典当行了。
	# 原先这里自己数了一遍用户卡张数，那是同一条规则的第二份实现
	if state.pawn_would_zero_user(my_seat, uids):
		sfx.play("deny")
		_show_message(GameState.REASON_PAWN_ZERO_USER, Palette.semantic("danger"))
		_return_cards_to_player_zone(drag_cards)
		return
	var r: Dictionary = await pipe.submit(Intent.pawn(my_seat, uids), my_seat)
	if not _session_current(session):
		return
	if not r["ok"]:
		sfx.play("deny")
		_show_message(r["reason"], Palette.semantic("danger"))
		_return_cards_to_player_zone(drag_cards)
		return
	_table_actions.pawn(drag_cards, uids)
	if not cash_cards.is_empty():
		_return_cards_to_player_zone(cash_cards)
	_update_hud()
	_show_message("典当回收 → 现金 +%d" % r["total"], Palette.semantic("pending"))
	# 典当变现冲过胜利线（传说卡=胜利筹码）→ 立即终局
	if state.winner != "":
		await _drawer_timer(BEAT_GAME_OVER).timeout
		if not _session_current(session):
			return
		_show_game_over()

# ---------- 行动阶段（先手方先买卡组卡，后手方后行动） ----------

## 回合开始：确定行动顺序，先手方先行动
func _begin_action_phase(resume_actor := "") -> void:
	var session := _session_generation
	var round_state := state
	phase = PHASE_ACTION
	_attack_actor = ""
	_actor = resume_actor if resume_actor != "" else state.action_first()
	if state.round_num > 1:
		_opening_action_pending = false
	_set_mascot_state("idle")
	_update_hud()
	if _actor == my_seat:
		var order_label := "先手" if _actor == state.action_first() else "后手"
		_show_message("第 %d 回合 · 你%s：拖现金到公共区买卡，拖卡堆叠编组" % [state.round_num, order_label], Palette.semantic("info"))
		_set_button(TXT_ACTION_DONE, _on_action_done)
		board.input_locked = false
	else:
		var order_label := "先手" if _actor == state.action_first() else "后手"
		_show_message("第 %d 回合 · 对手%s，正在行动……" % [state.round_num, order_label], Palette.semantic("warning"))
		btn_pass.text = TXT_BOT_ACTING
		btn_pass.disabled = true
		board.input_locked = true
		await _drawer_timer(BEAT_BOT_THINK).timeout
		if not _session_current(session):
			return
		if state != round_state or state.winner != "":
			return
		_foe_action()
	_refresh_mascot_state()
	_refresh_drawer_pause()

## 玩家点「认输」。两下才算 —— 第一下只是把按钮改成「真的认输？」。
##
## 为什么不弹确认框：这个按钮和联网入口同在左下角、同样 150×44，
## 而认输没有撤回（协议里没有这条意图，服务器那份 winner 一落地就定了）。
## 就地改字比弹框轻，而且改完的按钮**自己**就是那个确认框
##
## 定时解除，不是一直挂着：挂着的话下一次手滑点在「真的认输？」上就直接认了，
## 而玩家未必记得上次点过 —— 那等于把两下确认退化成一下
## 这里**故意没有** _foe_gone() 那道门（对比 _on_attack_clicked 开头那条）。
## 攻击要拦是因为它动的是**他的**牌，而裁决结果他收不到；认输动的是我自己这一半，
## 而且「对手掉线了、我不想等」恰恰是最想认输的时刻 —— 拦掉就是把人锁在
## 一局没有对手的棋里。他回来时从快照里读到这局已经结束了，和冲线结束没有区别
func _on_resign_pressed() -> void:
	var session := _session_generation
	if replay_session != null:
		_exit_replay()
		return
	if phase == PHASE_OVER:
		return   # 终局面板已经在了，这时候认输没有意义
	if not _resign_armed:
		_resign_armed = true
		btn_resign.set_meta("danger_armed", true)
		btn_resign.text = TXT_RESIGN_SURE
		_refresh_button_theme()
		_set_mascot_state("danger")
		_show_message("再点一下就认输了。这局不会再有下一手", Palette.semantic("warning"))
		await _drawer_timer(RESIGN_ARM_HOLD).timeout
		if not _session_current(session):
			return
		# 这几秒里可能已经认了（面板起来了、按钮也放掉了），也可能又点了一下
		# 别的东西把它复原了 —— 两种情况都不该在这里改字
		if _resign_armed and is_instance_valid(btn_resign):
			_resign_armed = false
			btn_resign.set_meta("danger_armed", false)
			btn_resign.text = TXT_RESIGN
			_refresh_button_theme()
			_set_mascot_state("idle")
			# **提示条也得跟着退**。上面那句「再点一下就认输了」描述的是一个
			# 会过期的状态，而提示条现在是常驻的（_show_message 不淡出了）——
			# 不管它的话，按钮早复原了而屏幕上还挂着一句已经失效的话。
			#
			# 换成一句新的，不是清空：清空就是「凭空消失」，正是用户要杜绝的那个。
			# 说出去的话由说话的人收回，这一条也进记录
			_show_message("认输取消了（等太久）。真要认输就再点一次",
				Palette.semantic("info"))
		return
	_resign_armed = false
	btn_resign.disabled = true
	# 认输走管道，不在这里直接置 winner：联网局里胜负要服务器落地，
	# 对手才收得到（他那边靠 _on_intent_applied 的 OP_RESIGN 分支起面板）。
	# 见 Intent.OP_RESIGN
	var r := await pipe.submit(Intent.resign(my_seat), my_seat)
	if not _session_current(session):
		return
	if not r.get("ok", false):
		# 认输被拒基本只有一种情形：这局刚好已经结束了（对手冲线/我掉线重连）。
		# 把按钮放回去，让玩家看得出「没认成」而不是「点了没反应」
		btn_resign.disabled = false
		btn_resign.set_meta("danger_armed", false)
		_refresh_button_theme()
		_set_mascot_state("danger")
		btn_resign.text = TXT_RESIGN
		sfx.play("deny_quiet")
		_show_message("认输没成：%s" % r.get("reason", "这局的状态变了"),
			Palette.semantic("danger"))
		return
	_release_drag_lease()
	_show_game_over()

## 「真的认输？」这个状态留多久（秒）。
##
## 这个数原本的理由是「比提示条的 2.6 秒长一点，别让按钮先复原」——
## 那个理由**已经失效**：提示条不淡出了，没有「谁先没」这回事。
## 现在的理由是反过来的：按钮复原时提示条得由 _on_resign_pressed
## 自己换掉（那里有一句），4 秒是「够看清这句话、又不至于误触了要等半天」
const RESIGN_ARM_HOLD := 4.0

## 玩家点「完成行动」：注册组合，然后交接给下一行动方 / 进入攻击阶段
func _on_action_done() -> void:
	if replay_session != null:
		_replay_next()
		return
	var local := _net == null
	if local:
		_local_turn_flows += 1
	await _finish_player_action()
	if local:
		_local_turn_flows -= 1

func _finish_player_action() -> void:
	var session := _session_generation
	if phase != PHASE_ACTION or _actor != my_seat or board.input_locked or btn_pass.disabled:
		return
	# 任何意图、锁牌、阶段切换发生之前检查，联网玩家被拒时仍可拆摞调整。
	var safety := Settle.check_action_completion(state, my_seat, _core_piles())
	if not safety["ok"]:
		UIMotion.deny_button(btn_pass)
		sfx.play("deny")
		_show_message(safety["reason"], Palette.semantic("danger"))
		return
	if not _start_client_action():
		return
	_opening_action_pending = false
	_refresh_mascot_state()
	var registered: bool = await _register_player_combos()
	if not _session_current(session):
		return
	if not registered:
		_end_client_action(session)
		return
	# 「我行动完了」也是一条意图。它不改状态，收信人是**次序** ——
	# 联网时服务器要靠它才知道该换手了，而这件事不能由对方客户端说
	# （见 engine/phase_machine.gd 文件头）。走管道是为了让它和别的玩家输入
	# 过同一套冒充校验和 seq 编号：否则它就是唯一一件绕过管道的玩家输入
	var completed: Dictionary = await pipe.submit(Intent.action_done(my_seat), my_seat)
	if not _session_current(session):
		return
	if not completed.get("ok", false):
		_action_failed(completed)
		_end_client_action(session)
		return
	_show_message("已完成行动", Palette.semantic("success"))
	_end_client_action(session, false)
	if state.action_first() == foe_seat:
		# 玩家是后手：双方都已行动 → 收市场、整理、进入攻击阶段
		await _finish_actions()
		if not _session_current(session):
			return
	else:
		# 对手后手行动（看得到玩家亮出的阵型）
		_actor = foe_seat
		_refresh_mascot_state()
		_refresh_drawer_pause()
		btn_pass.text = TXT_BOT_ACTING
		await _drawer_timer(BEAT_BOT_THINK_LATE).timeout
		if not _session_current(session):
			return
		_foe_action()

## 桌上带核心卡的那些摞，每项 `{uids: Array}`。
##
## 只给读数用：HUD 的「本回合待付」（`pending_pay`）、「进账」
## （`pending_cash_income`）和「在岗 / 闲置」（`user_deployment`）。
## 三个调用方共用一份，是为了让它们数的是同一批摞 ——
## 各搭一遍的话「待付 10」和「进账 7」可能来自两个不同的摞集合。
##
## **不排序**：这三个调用方都是把每摞的数加总，次序不进结果。
## （从前这里按核心卡标价排过序，因为自动补料要按那个次序在资金见底时截断；
## 补料撤掉之后那个次序没有读者了，留着就是一份没人依赖的规格）
##
## 理牌摞（没有核心卡）跳过：它没有配方，既不待付也不占席位
func _core_piles() -> Array:
	var piles: Array = []
	for g in board.groups:
		var uids: Array = []
		var has_core := false
		for c in g["cards"]:
			if not is_instance_valid(c):
				continue
			uids.append(c.uid)
			if CardDB.get_def(c.def_id).get("kind", "") != CardDB.KIND_UNIT:
				has_core = true
		if not has_core:
			continue
		piles.append({ "uids": uids })
	return piles

## 注册玩家组合（拖拽堆叠 ≥2 张的牌摞 → 引擎组合）
## 跳过纯单位卡的摞：那是 _tidy_player_idle 自动理出来的现金/用户堆，
## 提交它们必然以「组合需要一张核心卡」失败，红字还会盖掉真正有用的提示
func _register_player_combos() -> bool:
	var session := _session_generation
	var registered := 0
	for g in board.groups.duplicate():
		if g["cards"].size() < 2:
			continue
		var has_core := false
		for c in g["cards"]:
			if CardDB.get_def(c.def_id).get("kind", "") != CardDB.KIND_UNIT:
				has_core = true
				break
		if not has_core:
			continue   # 理牌摞，不是编组意图
		var uids: Array = []
		for c in g["cards"]:
			uids.append(c.uid)
		# 服务器已确认的组在重试时不能重复提交。拒绝后修正其他组仍可结束行动。
		var already := state.combos.any(func(combo): return combo["owner"] == my_seat and combo["uids"] == uids)
		if already:
			registered += 1
			continue
		# 不完整或不符合配方的牌摞只是闲置牌，不阻止结束行动。
		# 在提交前按引擎规则筛掉；实际提交失败仍须中止，避免吞掉网络错误。
		var cards: Array = []
		for uid in uids:
			cards.append(state.find_card(my_seat, uid))
		if not ComboRules.evaluate(cards)["valid"]:
			continue
		var r: Dictionary = await pipe.submit(Intent.create_combo(my_seat, uids), my_seat)
		if not _session_current(session):
			return false
		if r["ok"]:
			registered += 1
		else:
			_show_message("有编组未生效：%s" % r["reason"], Palette.semantic("danger"))
			return false
	if registered == 0:
		_show_message("你没有编成组合", Palette.semantic("muted"))
	else:
		sfx.play("confirm_turn")  # 确认行动：柔和双音
	return true

## 对手侧的一条意图落地了 → 画出来。
##
## **这是联网局对手侧唯一的画面来源**，也是这个连接存在的全部理由。
## 改造前对手的每一处画面都长在「驱动对手的那段代码」里
## （那时这个文件里有 _bot_buy_once / _bot_pawn_relief 两个函数，买完顺手
## _spawn_entity、典当完顺手 _fly_out；两个名字现在都不在仓里了，
## 决策次序搬去了 engine/bot_agent.gd）。
## 那在单机局能跑，因为驱动 BOT 的正是这个进程；联网局里对手是人，
## **没有任何一段本地代码在驱动他** —— 于是对手买了什么、编了什么组，
## 这一侧一个像素都不会变，而且不报错（共享执行路径失配造成的静默分叉）。
##
## 现在反过来：驱动方只管决策和节拍，画面一律由落地结果驱动。
## 单机局的 BOT 走 applier.apply（IntentApply.landed → LocalTransport 广播），
## 联网局的对手走服务器广播（NetTransport._on_applied），
## 两条路进到这里是同一个 Dictionary 形状。
##
## 只认对手的**客户端操作**：produce 的 seat 是组合主人（可能就是对手），
## 但那是结算阶段的事，_resolve_combo_visual 自己在演，不能被这里重画一遍。
## 自己那条也不进来 —— 玩家的操作在各自的输入回调里已经画过了
func _on_intent_applied(r: Dictionary) -> void:
	if not is_foe_client_op(r):
		return
	match str(r.get("op", "")):
		Intent.OP_BUY:
			_render_foe_buy(r)
		Intent.OP_PAWN:
			_render_foe_pawn(r)
		Intent.OP_COMBO:
			_render_foe_combo(r)
		Intent.OP_ATTACK:
			_render_foe_attack(r)
		Intent.OP_ATTACK_DONE:
			_flush_foe_attack()
		Intent.OP_ACTION_DONE:
			# 没有画面 —— 这条意图不改状态（见 Intent.OP_ACTION_DONE 的说明）。
			# 它的收信人是**次序**：联网局里 _await_foe_action 等的就是它
			_foe_action_done = true
			_foe_completed_round = state.round_num
			_refresh_mascot_state()
		Intent.OP_RESIGN:
			_render_foe_resign()

## 这条落地结果该由对手侧的渲染接管吗。
##
## 拆成一个能单独调的判定，而不是写在 _on_intent_applied 的 if 里：
## 判错的后果是**在信号回调里出脚本错误**（拿我的 uid 去 find_card(foe_seat, …)
## 得到空字典，_spawn_entity 在 state_card["uid"] 上崩），而回调里的脚本错误
## 不会让调用方失败 —— 于是它在测试里是隐形的。实测把这个判定改成恒真，
## 「对手区没多出一张」和「公共区没被再摘一格」两条判据**都还是绿的**：
## 崩在渲染函数的第一行，后面那些有观察点的副作用一个都没发生。
## 拆出来之后 tests/test_foe_render.gd 能直接问它（T6），判定本身就有了读者
func is_foe_client_op(r: Dictionary) -> bool:
	# 只认对手的**客户端操作**：produce 的 seat 是组合主人（可能就是对手），
	# 但那是结算阶段的事，_resolve_combo_visual 自己在演，不能被重画一遍
	return str(r.get("seat", "")) == foe_seat and Intent.is_client_op(str(r.get("op", "")))

## 对手买了一张。市场那一格的实体在这里摘掉 ——
## 下标取自结果而不是「刚才决策选的那个」：联网局里决策不在本地
func _render_foe_buy(r: Dictionary) -> void:
	var idx := int(r.get("market_idx", -1))
	var def_id := str(r.get("def_id", ""))
	var e := _spawn_entity(
		state.find_card(foe_seat, r["new_uid"]),
		layout._free_spot(layout._unit_anchor(foe_seat, def_id), foe_seat), false)
	for u in r.get("removed_uids", []):
		if entities.has(u):
			_fly_out(entities[u], Vector3(0, 4, -2))
			entities.erase(u)
	if idx >= 0 and idx < market_cards.size():
		var mc := market_cards[idx]
		market_cards.remove_at(idx)
		_drop_price_label(idx)
		_fly_out(mc, Vector3(0, 4, -2))
	layout._layout_bot_idle()   # 买到新卡后顺手理牌
	_update_hud()
	_show_message("对手购入「%s」" % CardDB.card_name(def_id), Palette.semantic("warning"))

## 对手典当了几张。「冲线」和「救急」的区别从状态读，不从驱动方传：
## 典当变现冲过胜利线时 winner 已经落定（GameState.pawn 里 check_victory），
## 那是结果自带的信息，联网局照样读得到
func _render_foe_pawn(r: Dictionary) -> void:
	var uids: Array = r.get("uids", [])
	var cards: Array = _table_actions._members(uids)
	var counts := {}
	for card in cards:
		counts[card.def_id] = int(counts.get(card.def_id, 0)) + 1
	var names: Array[String] = []
	for def_id in counts:
		names.append("「%s」×%d" % [CardDB.card_name(def_id), counts[def_id]])
	_table_actions.pawn(cards, uids, foe_seat)
	_update_hud()
	var message := "对手典当 %s → 现金 +%d" % ["、".join(names) if not names.is_empty() else "%d 张卡" % uids.size(), int(r.get("total", 0))]
	if state.winner != "":
		message += "，现金已达 %d" % state.resource_count(foe_seat, CardDB.RES_CASH)
	_show_message(message, Palette.semantic("danger" if state.winner != "" else "pending"))

## 对手认输了。
##
## 这一条**自己起终局面板**，而 _render_foe_pawn 冲线那支只发一句提示、
## 把起面板留给驱动方（_await_foe_action 之后那些 `if state.winner != ""`）。
## 差别在于认输不看阶段（见 Intent.OP_RESIGN）：它可能落在**我的**行动阶段里，
## 而那时候没有任何一个循环在盯 state.winner —— 输入是开着的，代码就停在
## 等我按按钮那一步。留给驱动方的话，症状是「对手认输了，我这边毫无反应，
## 直到我点了完成行动才突然弹出胜利面板」
##
## 重复调用是安全的：_show_game_over 开头那道 phase == PHASE_OVER 挡着，
## 后面驱动方再调一次会直接返回
func _render_foe_resign() -> void:
	_show_message("对手认输了", Palette.semantic("success"))
	_show_game_over()

## 对手编成一组。整区重排一次 —— 组合区的摆放是「当前所有组合」的函数，
## 不是逐组累加的（见 settle_layout.gd 的 _layout_bot_zone），所以逐条调它是幂等的
func _render_foe_combo(_r: Dictionary) -> void:
	layout._layout_bot_zone()
	_foe_combo_shown += 1
	_show_message("对手编成了 %d 个组合" % _foe_combo_shown, Palette.semantic("warning"))

## 同摞的连续裁决先退出交互，再持有全部实体，批次收尾时统一演一次撕纸。
func _render_foe_attack(r: Dictionary) -> void:
	var target: Dictionary = r.get("target", {})
	var batch := GameState.target_batch(target)
	if not _foe_tear_uids.is_empty() and (batch == "" or batch != _foe_tear_batch):
		_flush_foe_attack()
	if _foe_tear_cards.is_empty():
		_foe_tear_center = _target_center(target)
	_foe_tear_batch = batch
	_foe_tear_target = target.duplicate(true)
	_foe_tear_uids.append_array(r.get("removed", []))
	for uid in r.get("removed", []):
		if entities.has(uid) and is_instance_valid(entities[uid]):
			var card: CardEntity = entities[uid]
			_foe_tear_cards.append(card)
			entities.erase(uid)
			board.drop_card(card)
			card.reset_interaction_visual()
			card.freeze = true
			card.collision_layer = 0
			card.collision_mask = 0
	if batch == "":
		_flush_foe_attack()

func _flush_foe_attack() -> void:
	if _foe_tear_uids.is_empty():
		return
	var session := _session_generation
	var removed := _foe_tear_uids.duplicate()
	var cards := _foe_tear_cards.duplicate()
	_foe_tear_cards.clear()
	var center := _foe_tear_center
	var target := _foe_tear_target.duplicate(true)
	_foe_tear_uids.clear()
	_foe_tear_batch = ""
	_foe_tear_target.clear()
	_impact_once(center, foe_seat, str(target.get("res", "")))
	var duration := _animate_removed(removed, true, cards)
	if duration > 0.0:
		await _drawer_timer(duration).timeout
	if _session_current(session):
		_update_hud()

# ---------- 拖拽广播（scenes/main.gd 的拖拽广播与租约处理）----------

## 两侧半区的 z 跨度**不一样**：近侧 [0.6, 5.2] 跨度 4.6（board.player_min_z /
## player_max_z 和 _free_spot 取的是同一对数），远侧 [-7.6, -1.8] 跨度 5.8
## （settle_layout.gd 的 `combo_spread_step()`）。所以传的是**归一化坐标**，不是世界坐标 ——
## 把 z 取反发过去会落到区域外面（-5.2 越过了 -1.8 那条北缘…反过来更糟：
## 近侧 z=0.6 取反是 -0.6，那是购牌区，牌会画在公共区的牌上）。
##
## x 不镜像：两侧的现金锚都在左（-8.0 / -6.4）、用户锚都在右（4.0 / 4.8），
## 布局本来就不是左右镜像的（scenes/main.gd 的拖拽广播与租约处理）
const DRAG_NEAR_Z := Vector2(0.6, 5.2)
const DRAG_FAR_Z := Vector2(-7.6, -1.8)
## 归一化 x 的跨度。取一个两侧公用的定值而不是各自的实际用地：
## 用地是随牌数变的，两边算出来的分母不一样，同一个 u 就落到不同的地方
const DRAG_X := Vector2(-9.0, 9.0)

## 多久收不到 dragging 帧就认为对方掉线了，把租约收回去（scenes/main.gd 的拖拽广播与租约处理）。
## 没有这个超时，对手在拖着牌的时候断线，那几张牌会**永远浮在半空**：
## 布局被租约挡着不敢动它们，而释放租约的那条消息永远不会到
const DRAG_LEASE_TIMEOUT := 2.0

## 正被远端拖着的 uid → true。**布局绕开这些牌**（settle_layout.gd 的
## _collect_idle_units / _bot_piles 都问它），否则 _layout_bot_idle 每步都会
## 抢着把牌摆回摞里，和网络驱动的位置打架，牌会抽搐
var _drag_lease := {}
var _drag_lease_t := 0.0    # 上一帧 dragging 到现在过了多久
var _drag_lease_seq := 0    # 收到的最后一帧的 seq；比它小的直接丢

## 远端拖拽的一帧。挂在 NetTransport.foe_drag 上（见 set_foe_remote 那一段）。
##
## 落点**不由这条消息决定**：松手是权威事件，走的是意图那条路
## （scenes/main.gd 的拖拽广播与租约处理）。这条只管「牌在半空的哪儿」，丢几帧只是画面抖一下
func on_foe_drag(msg: Dictionary) -> void:
	var seq := int(msg.get("seq", 0))
	# 乱序帧直接丢：dragging 走的是不可靠通道，晚到的旧帧会把牌拽回去，看着是抽搐。
	# pickup/cancel 不受这条管 —— 它们是可靠的一次性事件，而且 cancel 必须收得到。
	#
	# 这条豁免还兼着另一件事：**水位是每次拎牌重置的，不是每条连接**。
	# pickup 不受水位管、而且它自己会把水位写成自己的 seq，所以换一条新连接
	# （seq 从 1 重新发，见 NetTransport._drag_seq）时第一帧 pickup 照样进得来，
	# 后面的 move 就以它为基准。少了这条豁免，新连接的每一帧都小于旧水位、
	# 全被丢掉 —— 症状是「对手拎起牌和松手都看得见，中间那段不动」。
	# 所以 attach_net 里**不需要**再清一次水位（试过，那是句死代码）
	var ph := str(msg.get("phase", ""))
	if ph == Protocol.DRAG_MOVE and seq <= _drag_lease_seq:
		return
	_drag_lease_seq = seq
	tape.record_drag(foe_seat, ph, msg.get("uids", []), foe_drag_point(float(msg.get("u", 0.5)), float(msg.get("v", 0.5))))
	if ph == Protocol.DRAG_CANCEL and replay_session == null:
		_record_layout_pending = true
		_record_layout_seat = foe_seat
	match ph:
		Protocol.DRAG_PICKUP:
			_lease_foe_cards(msg.get("uids", []))
			_move_foe_drag(msg)
		Protocol.DRAG_MOVE:
			_move_foe_drag(msg)
		Protocol.DRAG_CANCEL:
			_release_drag_lease()

## 把这几张牌从布局手里接过来。draggable 一直是 false（对手的牌本地点不动），
## 所以这里不用改输入，只要让布局别再摆它们
func _lease_foe_cards(uids: Array) -> void:
	_drag_lease.clear()
	for u in uids:
		var uid := int(u)
		if entities.has(uid) and is_instance_valid(entities[uid]):
			_drag_lease[uid] = true
			# 掐掉还在跑的飞入补间：牌可能正从上一次理牌里飞回去，
			# 补间不掐会逐帧盖掉下面写的位置（_cancel_fly 的注释里有同一个道理）
			_cancel_fly(entities[uid])
			# 归位补间同理。租约只挡「之后」的摆放，已经在跑的那条得掐
			layout.kill_bot_move(uid)
			(entities[uid] as CardEntity).freeze = true
	_drag_lease_t = 0.0

## 按归一化坐标把租约里的牌摆到远侧半区。抬到 DRAG_HEIGHT 并加上 board 那个
## -5° 倾斜 —— 和自己侧拎牌的样子一致，看得出「那几张牌在他手上」
func _move_foe_drag(msg: Dictionary) -> void:
	if _drag_lease.is_empty():
		return
	_drag_lease_t = 0.0
	var at := foe_drag_point(float(msg.get("u", 0.5)), float(msg.get("v", 0.5)))
	var i := 0
	for uid in _drag_lease:
		if not entities.has(uid) or not is_instance_valid(entities[uid]):
			continue
		var e: CardEntity = entities[uid]
		# 多张时沿层高摞起来，和自己侧拎一摞的形状一样
		e.global_position = at + Vector3(0, Board.ladder_y(mini(i, 7) if _uses_fitted_table() else i), 0)
		e.rotation_degrees = Vector3(0, e.rotation_degrees.y, -5.0)
		i += 1

## 归一化坐标 → 远侧半区的桌面点。
##
## 抽成一个能单独调的函数：这是整条拖拽通道里**唯一有算术**的一步，
## 而它算错的后果是「牌画在了别人的半区/购牌区上」—— 一个纯位置问题，
## 靠看画面才发现。让它自己有读者（tests/test_foe_drag.gd 直接问它）
func _drag_x_range() -> Vector2:
	if _uses_fitted_table():
		return Vector2(board.player_bounds.position.x + 0.7, board.player_bounds.end.x - 0.7)
	return DRAG_X

func _drag_near_z_range() -> Vector2:
	if _uses_fitted_table():
		return Vector2(board.player_bounds.position.y + 0.9, board.player_bounds.end.y - 0.9)
	return DRAG_NEAR_Z

func _drag_far_z_range() -> Vector2:
	if _uses_fitted_table():
		return Vector2(DrawerTableLayout.DRAWER_FOE_RECT.position.y + 0.9, DrawerTableLayout.DRAWER_FOE_RECT.end.y - 1.25)
	return DRAG_FAR_Z

func foe_drag_point(u: float, v: float) -> Vector3:
	return Vector3(
		lerpf(_drag_x_range().x, _drag_x_range().y, clampf(u, 0.0, 1.0)),
		Board.DRAG_HEIGHT,
		lerpf(_drag_far_z_range().x, _drag_far_z_range().y, clampf(v, 0.0, 1.0)))

## 自己这几张牌的桌面位置 → 归一化坐标。发送方用（见 _on_drag_broadcast）。
## 和 foe_drag_point 互为逆运算，两边共用 DRAG_X 这个分母
func my_drag_uv(at: Vector3) -> Vector2:
	return Vector2(
		clampf(inverse_lerp(_drag_x_range().x, _drag_x_range().y, at.x), 0.0, 1.0),
		clampf(inverse_lerp(_drag_near_z_range().x, _drag_near_z_range().y, at.z), 0.0, 1.0))

## 租约到期/收到 cancel：把牌交还给布局。
## 倾斜要**清掉**，否则那几张牌会歪着躺在摞里
func _release_drag_lease() -> void:
	if _drag_lease.is_empty():
		return
	for uid in _drag_lease:
		if entities.has(uid) and is_instance_valid(entities[uid]):
			var e: CardEntity = entities[uid]
			e.rotation_degrees = Vector3(0, e.rotation_degrees.y, 0)
	_drag_lease.clear()
	_drag_lease_t = 0.0
	# 交还给布局：牌现在浮在 DRAG_HEIGHT 上，得有人把它们摆回去。
	# 对手买/典当那几张牌可能已经不在场上了，_layout_bot_idle 只摆还在的
	layout._layout_bot_idle()

## uid 正被远端拖着吗。settle_layout.gd 问这个 —— 它是租约唯一的读者，
## 也是租约存在的理由：移动中的远端牌必须临时脱离自动布局。
func is_drag_leased(uid: int) -> bool:
	return _drag_lease.has(uid)

## 租约超时。每帧从 _process 走一趟 —— 见 DRAG_LEASE_TIMEOUT 的说明：
## 对方拖着牌掉线时，释放租约的那条消息永远不会到
func _tick_drag_lease(delta: float) -> void:
	if _drag_lease.is_empty():
		return
	_drag_lease_t += delta
	if _drag_lease_t >= DRAG_LEASE_TIMEOUT:
		_release_drag_lease()
		_show_message("对手那边没动静，牌放回去了", Palette.semantic("muted"))

## 本地拖拽的一帧 → 要发出去的那几个字段（不含 seq，seq 是 net 层的账）。
##
## 单独抽出来是为了让**发送端的字段安排自己有读者**：u/v 写反了的后果是
## 对手屏幕上我的牌沿着错的轴跑，而两侧都不报错。抽出来之后
## tests/test_foe_drag.gd 能把这份 packet 补个 seq 直接喂给 on_foe_drag ——
## 收发两端接同一个形状，写反了当场对不上（回环判据）
func drag_packet(phase_name: String, uids: Array, at: Vector3) -> Dictionary:
	var uv := my_drag_uv(at)
	return { "phase": phase_name, "uids": uids, "u": uv.x, "v": uv.y }

## 本地拖拽的一帧要广播出去（board.drag_broadcast）。
## 单机局这里什么都不做：没有对手在看
func _on_drag_broadcast(phase_name: String, uids: Array, at: Vector3) -> void:
	tape.record_drag(my_seat, phase_name, uids, at)
	if phase_name == Protocol.DRAG_CANCEL:
		_request_record_layout()
	if _net == null:
		return
	var p := drag_packet(phase_name, uids, at)
	_net.send_drag(p["phase"], p["uids"], p["u"], p["v"])

## 我这边的摞分组 → [{uids, compact, u, v}...]（发送端的形状，见 Protocol.PILES）。
## 只取**桌上**的摞：board.groups 就是桌面上的分组，手里的牌不在里面
## （见 board 那句「组字典从 groups 摘掉纯粹是记账」）。
##
## compact 是双击收拢/摊开那一位（board.toggle_compact 翻的就是它）。
## 带上它是因为收方光有名单时只能照几何自己猜形态，猜的结果和我这边
## 不一致 —— 而收拢/摊开是玩家亲手做的动作，两边该一一对应。
##
## u/v 是这一摞**摆在哪**，归一化坐标，和拖拽那条通道同一套口径
## （my_drag_uv / foe_drag_point）。这一条是个 bug 修回来的：不带位置的话
## 收方只有名单和形态，落点由 _layout_bot_zone 按「第几摞 / 共几摞」现算
## （整行居中，见那边的 x0/pitch）—— 于是对手把一个组合拖到桌角还是拖到中间，
## 我这边看到的都是同一个格子。玩家亲手挪的位置和双击收拢是同一类动作，
## 两边都该一一对应。
##
## 口径**必须**和拖拽共用一套：拖的那几十帧走 my_drag_uv，松手之后归这里说话，
## 两套算法的话同一个点算出两个位置，症状是松手一瞬间那一摞横跳一下。
## 锚点取**整摞 z 向的中点**（北端 + 跨度的一半），不是队首那张：
## 队首在两种形态下坐的位置不一样（摊开态最北、收拢态最南，见 Board.z_span），
## 拿它当锚点的话双击收拢会让摞在对手屏幕上平移半个摞长 —— 而收拢是原地的动作。
## 中点和形态无关，也和「哪张是队首」无关
func my_pile_lists() -> Array:
	var out: Array = []
	if board == null:
		return out
	for g in board.groups:
		var uids: Array = []
		for c in g["cards"]:
			if is_instance_valid(c) and c.uid >= 0:
				uids.append(int(c.uid))
		if uids.is_empty():
			continue
		var rec := { "uids": uids, "compact": bool(g.get("compact", false)) }
		# 位置读**静止位**（board.rest_origin 走 rest_pos）：牌可能正被重排的
		# 补间送着，读实时坐标发出去的是路上某一帧，对手那边跟着抖
		if is_instance_valid(g["cards"][0]):
			var mid: Vector3 = board.rest_origin(g)
			mid.z += Board.z_span(g) / 2.0
			var uv := my_drag_uv(mid)
			rec["u"] = uv.x
			rec["v"] = uv.y
		out.append(rec)
	return out

## 分组名单的指纹。发之前拿它和上一次比 —— 摞分组每帧都能算，
## 但**只在真的变了**的时候才该发（见 Protocol.piles 那段「没有 seq」）。
##
## 指纹里带次序：board.groups 的次序就是摞的摆放次序，
## 换了次序对手那边的摞也该跟着换位置。
##
## **compact 也进指纹**。这条是个 bug 修回来的：双击收拢/摊开时 uid 名单
## 一个字都不变（toggle_compact 只翻那一位，收拢时顺手 _core_first 重排一次），
## 于是摊开那一下的指纹和上一份**完全相同** —— 一条都不发，
## 对手那边什么反应都没有。而这正是玩家最直观的一个动作。
##
## **位置也进指纹**，同一个道理：把一摞整个拖到别处，名单和形态都不变，
## 不带位置的话这一下同样一条都不发。
##
## 位置量化到 PILES_UV_STEP 再进指纹：坐标是浮点，重排补间每帧都在改它，
## 原样进指纹等于「每帧都变了」—— 而这条通道的前提就是「只在真的变了时发」
## （见 Protocol.piles 那段「没有 seq」）。量化之后拖动中途只发几条，
## 落定后不再发
func _piles_fingerprint(groups: Array) -> String:
	var parts: Array = []
	for g in groups:
		var uids: Array = (g as Dictionary).get("uids", [])
		parts.append("%s:%s:%s" % [
			"c" if bool((g as Dictionary).get("compact", false)) else "s",
			_uv_bucket(g as Dictionary),
			",".join(uids.map(func(u): return str(u)))])
	return "|".join(parts)

## 指纹里位置那一段的量化步长（归一化坐标，1.0 = 整个半区的跨度）。
## 0.01 ≈ 18 格 x / 4.6 格 z 里的一格，也就是几毫米 —— 比一张卡窄得多，
## 玩家挪得动的最小距离都能进指纹，而补间路上的抖动进不来
const PILES_UV_STEP := 0.01

## 一摞的位置在指纹里的样子。没带位置的（老形状的包、测试里的 send_piles([[1,2]])）
## 出 "-"：**不能**出 "0.00,0.00"，那是桌角一个真实的点，
## 会让「没说位置」和「就在桌角」两件事在指纹里一模一样
func _uv_bucket(g: Dictionary) -> String:
	if not g.has("u") or not g.has("v"):
		return "-"
	return "%d,%d" % [
		roundi(float(g["u"]) / PILES_UV_STEP),
		roundi(float(g["v"]) / PILES_UV_STEP)]

## 分组变了就广播一次。每帧从 _process 走一趟。
##
## 为什么是**每帧比指纹**而不是在改动处发信号：board.groups 有七八处会变
## （落卡并组、合并两组、整摞拎起、拆组、卡被打掉、prune_groups…），
## 挂信号得一处不漏地挂，漏一处的症状是「某种摞法对面看不见」——
## 而那种漏最难发现，因为其余摞法全是对的。指纹比一次是几十个整数拼串，
## 比漏一处便宜：所有执行路径都要同步同一份状态。
func _push_piles() -> void:
	if _net == null:
		return
	var groups := my_pile_lists()
	var fp := _piles_fingerprint(groups)
	if fp == _piles_fp:
		return
	_piles_fp = fp
	_net.send_piles(groups)

## 上一次广播出去的分组指纹（见 _push_piles）
var _piles_fp := ""

## 对手声明的摞分组：[{uids, compact}...]（形状由 Protocol.pile_lists 归一化，
## 光名单的老形状也会被补齐成字典）。**表现状态，不是玩法状态** ——
## 它只决定对手区那些牌怎么摆（settle_layout._bot_piles），
## 谁拥有什么牌一律以 state 为准
var foe_piles: Array = []

## 对手声明的收拢位：uid → bool。摆放层查它决定摊开还是收拢
## （settle_layout._layout_bot_zone），查不着的按几何自己定。
##
## 按 uid 摊平而不是按摞查，是为了让**组合**也能沿用：对手收手那一刻
## 他的摞变成 state.combos 里的组合，声明摞被 claimed 剔掉（_bot_piles），
## 于是「那一摞是收拢的」这件事在组合这条路上就没了出处 ——
## 而玩家看见的是收手一瞬间摞自己摊开了。uid 是两条路唯一共有的东西
func foe_compact_of(uid: int) -> Variant:
	for g in foe_piles:
		if not (g is Dictionary):
			continue
		if Intent.ints((g as Dictionary).get("uids", [])).has(int(uid)):
			return bool((g as Dictionary).get("compact", false))
	return null

## 对手声明的位置：uid → Vector2(u, v)，没说返回 null。
##
## 按 uid 查、而不是按摞，理由同 foe_compact_of：他收手那一刻声明摞变成
## state.combos 里的组合，声明那一条被 claimed 剔掉 —— 位置这件事在组合
## 这条路上就没了出处，而玩家看见的是收手一瞬间那一摞跳回行中间。
## uid 是「声明摞」和「组合」两条路唯一共有的东西
func foe_anchor_of(uid: int) -> Variant:
	for g in foe_piles:
		if not (g is Dictionary):
			continue
		var d := g as Dictionary
		if not d.has("u") or not d.has("v"):
			continue
		if Intent.ints(d.get("uids", [])).has(int(uid)):
			return Vector2(float(d["u"]), float(d["v"]))
	return null

## 归一化坐标 → 对手区的**桌面**点（不是半空中那个）。
##
## 和 foe_drag_point 分开的只有 y：拖拽那条抬到 DRAG_HEIGHT 表示「在他手上」，
## 落定的摞得贴着桌面（0.05，同各处摆放锚点）。x/z 一律走同一个函数 ——
## 各算一份的话拖着的位置和落定的位置对不上，症状是松手一瞬间那一摞横跳
func foe_pile_point(u: float, v: float) -> Vector3:
	var p := foe_drag_point(u, v)
	p.y = 0.05
	return p

## 归一化坐标 → **我这一侧**的桌面点。my_drag_uv 的逆运算，
## 两个方向共用 DRAG_X / DRAG_NEAR_Z 这两个分母 —— 各写一份的话
## 「发出去的位置」和「回放回来的位置」会差一截，
## 症状是重连之后每一摞都整体平移了一点
func my_pile_point(u: float, v: float) -> Vector3:
	return Vector3(
		lerpf(_drag_x_range().x, _drag_x_range().y, clampf(u, 0.0, 1.0)),
		0.05,
		lerpf(_drag_near_z_range().x, _drag_near_z_range().y, clampf(v, 0.0, 1.0)))

## 收到对手的分组（NetTransport.foe_piles）。存下来 + 重排一次对手区。
##
## 不校验 uid 的归属：摆放层逐个 uid 查自己那份 state
## （_bot_piles 只认对手名下、有实体、没被租约占着的卡），
## 查不着的静默跳过 —— 校验放在读的那一侧，因为那里才知道「现在还在不在」
func on_foe_piles(msg: Dictionary) -> void:
	foe_piles = Protocol.pile_lists(msg.get("piles", []))
	if replay_session == null:
		_record_layout_pending = true
		_record_layout_seat = foe_seat
	if layout != null:
		layout._layout_bot_zone()

## 服务器回放**我自己**上一次声明的摞（NetTransport.my_piles）。
## 只在重连进一间开着局的房时来一条，用途是把 board.groups 补回来。
##
## 为什么必须由服务器回放：摞是**纯表现**，只活在 board.groups 里
## （见 Protocol.PILES）。重连的人手里是一份新进程 / 一张刚摆好的空桌 ——
## 快照能把牌、钱、和**已经收手的组合**还给他（_restore_my_combo_groups），
## 但行动阶段里摞好还没收手的那些摞在引擎里根本不存在。
## 少了这一条，重连之后理牌把它们当散卡摊回现金堆/用户堆：
## 「我摆了半天的阵型，重连之后没了」
##
## 四件事各挡一种脏数据：
##   - 只认**我名下、且桌上真有实体**的 uid。回放是服务器转述的一份旧名单，
##     那期间牌可能被打掉、被典当、被升级吃掉了
##   - 已经进了**组合**的 uid 跳过。次序上 _restore_my_combo_groups 先跑，
##     它按 state.combos 建的组是**权威**的；同一张牌既在组合里又在声明摞里时
##     （收手那一瞬间掉线，服务器两份都有）以组合为准 ——
##     一张牌进两个组会让 board 的记账彻底乱掉
##   - 少于 2 张的不成摞，留给理牌当散卡（同 _restore_my_combo_groups 那条）
##   - 挡的是「在组合里」而**不是**「在任何组里」：这一刻桌上那些摞几乎全是
##     理牌刚摞出来的（_respawn_all 末尾 _tidy_player_idle 把散资源并成
##     现金堆/用户堆），拿 board.group_of 当判据的话我声明的那些资源卡
##     一张都过不去 —— 于是 cs 恒不足 2 张，这个函数整个变成空转，
##     而症状和没有这条回放**一模一样**（摆放没恢复）。
##     所以要把它们从理牌那堆里**摘出来**（_detach_from_group，
##     和玩家用手拖开时走的是同一条路，摘完那堆自己会重排收口）
func on_my_piles(msg: Dictionary) -> void:
	if board == null or state == null or not _net_table_drawn:
		return
	# 组合占着的 uid。**读 state.combos 而不是数 board.groups**：
	# 后者此刻还混着理牌摞（见上面第四条）
	var in_combo := {}
	for combo in state.combos:
		if str(combo["owner"]) == my_seat:
			for u in combo["uids"]:
				in_combo[int(u)] = true
	var groups: Array = Protocol.pile_lists(msg.get("piles", []))
	var restored := 0
	for g in groups:
		var d := g as Dictionary
		var cs: Array = []
		for u in Intent.ints(d.get("uids", [])):
			if not entities.has(u) or not is_instance_valid(entities[u]):
				continue
			if state.find_card(my_seat, u).is_empty():
				continue
			if in_combo.has(u):
				continue
			cs.append(entities[u])
		if cs.size() < 2:
			continue
		# 摘出来**放在 make_group 之前**：一张牌同时挂在两个组里的话
		# 两个组会各自重排它，牌在两处之间来回跳。
		# 判过 cs.size() 之后才摘 —— 不成摞的那几张该原样留在理牌堆里
		for c in cs:
			board._detach_from_group(c)
		# was_valid 传 true：这一摞在掉线之前就摆成这样了，玩家没有刚做什么。
		# 让 board 现算的话，重连后第一次重排会当场判出「刚凑满」而放一遍风铃
		# ——玩家什么都没做却听见成组音效（同 _restore_my_combo_groups）
		var ng: Dictionary = board.make_group(
			Board.core_first_order(cs), bool(d.get("compact", false)), true)
		board.groups.append(ng)
		# 位置：他声明的锚点是**整摞 z 向的中点**（my_pile_lists 那段），
		# 而 _layout_group 要的是**起点**。差的正好是半个跨度 ——
		# 不减这一下，每摞往南偏半个摞长，长摞会被 clamp 按在近边上
		var at := Vector3.INF
		if d.has("u") and d.has("v"):
			at = my_pile_point(float(d["u"]), float(d["v"]))
			at.z -= Board.z_span(ng) / 2.0
		board._layout_group(ng, at)
		restored += 1
	if restored > 0:
		# 指纹**要跟着更新**：下一帧 _push_piles 会拿我这边的实况算一遍，
		# 而这份实况就是服务器刚回放给我的那一份 —— 不更新的话它们相等，
		# 于是那一帧照样不发。留下的那一位因此看不到我恢复了（他那边
		# 的 foe_piles 还是我掉线前那份，而牌可能已经变了）。
		# 更新成**回放那份**的指纹而不是清空：清空会让下一帧无条件发一条，
		# 内容和服务器手里那份一模一样 —— 一条纯冗余的广播
		_piles_fp = _piles_fingerprint(my_pile_lists())
		# **不能**在这儿理牌（试过，那一句把刚立起来的摞当场拆掉）：
		# _tidy_player_idle 头一件事就是解散「纯资源摞」，而我声明的摞
		# 十有八九正是那个 —— 一摞现金卡。理牌本来就只在回合边界跑，
		# 行动阶段里玩家摞的摞能留着靠的也是这一点。
		# 摘牌留下的空位不用理牌收口：_detach_from_group 每摘一张
		# 都会把余下那堆重排一遍

## 联网时由 net 层塞进来的那条连接。单机局是 null ——
## 场景层因此不需要知道「有没有在联网」，只需要知道「有没有人要听」
var _net: NetTransport = null

## 联网局开局：把 net 层接上来。**入口只有这一个** ——
## 拖拽的收发两端 + 摞分组的收发两端 + 「对手是人」必须一起生效，分开设置的话
## 漏掉哪一个都不报错，症状各不相同（只设 _net：对手看得到我拖牌，我看不到他的；
## 只连 foe_drag：反过来；只 set_foe_remote：本地还在驱动 BOT 替对手行动；
## 只连 foe_drag 不连 foe_piles：拖的过程看得见，松手之后牌弹回资源堆）
func attach_net(net: NetTransport) -> void:
	_net = net
	set_foe_remote(true)
	if not net.foe_drag.is_connected(on_foe_drag):
		net.foe_drag.connect(on_foe_drag)
	if not net.foe_piles.is_connected(on_foe_piles):
		net.foe_piles.connect(on_foe_piles)
	# 重连回来时服务器回放我自己那些摞（见 Protocol.MY_PILES）。
	# 不连的话重连之后我摆好的阵型被理牌摊回资源堆
	if not net.my_piles.is_connected(on_my_piles):
		net.my_piles.connect(on_my_piles)
	# 断线要把租约收回去：不然对方拖着牌断线时那几张牌会一直浮着，
	# 而超时那条路要等满 2 秒 —— 已经知道断了就不用等
	if not net.disconnected.is_connected(_on_net_down):
		net.disconnected.connect(_on_net_down)
	if not net.foe_left.is_connected(_on_foe_left_drag):
		net.foe_left.connect(_on_foe_left_drag)
	# 成对连。只连走的那一头，提示挂上去就摘不下来了
	if not net.foe_back.is_connected(_on_foe_back):
		net.foe_back.connect(_on_foe_back)

## 联网局真正的开局入口：**把管道换成网络那条**，然后照服务器那份快照摆桌子。
##
## 和 attach_net 分开是因为两者的时机不同：attach_net 只要有连接就能调
## （拖拽转发、「对手是人」都不依赖状态），而这一个必须等 seated ——
## 那一刻之前 net.state() 是一份空局，照它摆桌子摆出来是空桌。
##
## 这里换的是**四样东西，一次换齐**（少换一样都不报错，症状各不相同）：
##   state  —— 不换：界面读的还是本地那份空局，桌上一张牌都没有
##   pipe   —— 不换：每条玩家输入落在本地那份 state 上，服务器完全不知道；
##              两边各打各的，直到某一步被判非法才第一次出现症状
##   座位   —— 不换：远端那位的 my_seat 是 BOT，摆放层会把他的牌摆到对面半区
##              （他看着自己在对手位上出牌）
##   applied —— 不连：对手做的任何事这一侧一个像素都不变（见 _on_intent_applied）
##
## 阶段**不在这里开**：服务器会广播 phase（Protocol.phase → _on_net_phase）。
## 自己开一个的后果是客户端以为轮到自己、按钮亮着，点下去被 not_your_turn 拒掉
func begin_net_game(net: NetTransport) -> void:
	_invalidate_session()
	net.restore_checkpoint()
	board.attack_mode = false
	_clear_attack_hl()
	_hide_attack_label()
	# 联网局永远使用内置卡表；即使调用方漏掉切换，这里仍作为最后一道边界。
	_load_card_rules(false)
	# 新连接不继承上一条连接的离线标记，当前房间的presence消息会随后恢复。
	_foe_online = true
	_show_foe_offline_notice(false)
	_set_connection_mascot_state("idle")
	if game_over_panel != null:
		_teardown_for_new_game()
	# 新连接不继承上一局的终局守卫、首阶段和对手收手标记。
	phase = PHASE_ACTION
	_net_phase_seen = false
	_foe_action_done = false
	_opening_action_pending = false
	_foe_completed_round = -1
	_attack_actor = ""
	attach_net(net)
	# 入座这件事**也要打到 stdout**，不能只有屏幕上那句话。
	#
	# 「已入座」原先只在 _draw_net_table 里 _show_message 一次，而联机现在是靠
	# `启动游戏.command N` 开两份、或者两个 --headless 进程来验的 ——
	# 无头跑起来主机侧打「已在本机开房：ws://...」，客户端侧**一个字都不打**。
	# 于是「连上了」和「连上了但没入座」在日志里长得一模一样，
	# 只能去数 lsof 里的 ESTABLISHED（那还分不出是否进了同一间房）
	print("已入座：座位 %s ｜ 房间 %s ｜ %s" % [net.my_seat, net.room, net.url])
	# 入口按钮在这里藏，不在调用方藏：放回来那一半在 _reset_session_flags 里
	# （退房时），一进一出分在两个函数里的话，将来第二条「进联网局」的路径
	# （重连、或者从别处直接装一条连接）会漏掉藏这一步 ——
	# 症状是局中还能再点一次联网，开出第二条连接，而旧那条仍占着服务器的座位
	if btn_net:
		btn_net.visible = false
	set_seats(net.my_seat, net.foe_seat)
	state = net.state()
	pipe = net
	_retarget_tape()   # 录像要跟到权威那一份裁决器上，见 _retarget_tape
	_attach_net_state_signals(net)
	# 复位：**桌上现在摆的是单机局那副牌**，而这个量问的是「这一局的桌子摆了没有」。
	# 不复位的话它从单机局带着 true 进来（开局 _sync_round → _respawn_all 置的），
	# 于是 _on_net_seated 一进门就返回 —— 补发的那份 seated 没人接，
	# 先进房那位整局看着一张空桌，state 里 30 张牌、桌上 0 张
	_net_table_drawn = false
	_draw_net_table()   # 提示语在这里头按「摆没摆上」分两种
	# 阶段还没来，先按「等服务器」摆界面：按钮灰着比亮着对 ——
	# 亮着的按钮点下去会被服务器拒掉，玩家看到的是「能点但没反应」。
	# 两支都要灰：等对手进房、和等服务器广播阶段，都还轮不到自己动
	board.input_locked = true
	btn_pass.text = TXT_BOT_ACTING
	btn_pass.disabled = true
	# 等旧行动结束后才交接时，phase 可能已被候选连接收过，不能再等一次广播。
	if net.phase() != "":
		_on_net_phase(net.phase(), net.actor())
	# 先建立状态、牌桌与监听，再回放等待期间的操作，不能丢掉对手的收手/认输。
	net.resume_scene_events()
	if state.winner != "":
		_show_game_over()

## 联网局摆桌子。**只在牌已经发下来的时候摆**，返回有没有真摆。
##
## 分出这个函数是因为 seated 会到**两次**，而两次带的快照不一样
## （net/server.gd 的 _on_join：进房时发一份，满座开局时给所有人再发一份）：
##
##   先进房那位  第一份 = 房间刚建好的空局（players 是**空字典**）→ 这里不摆
##               第二份 = 开局后的真局面 → 在 _on_net_seated 里摆
##   后进房那位  两份都是真局面（start_if_ready 在发 seated 之前跑完）→ 第一份就摆上
##
## 空局那一份照着摆的后果是 _respawn_all 第一行就读 state.players[my_seat]，
## 空字典上取键**抛脚本错误**。而它是在 joined 信号的回调里跑的 ——
## 脚本错误不会让调用方失败，只是把那条回调剩下的部分**静默丢掉**
## （锁输入、灰按钮、提示语全没执行）。玩家看到的就是「点了连接，桌子空了，没有任何提示」，
## 也就是「好像没连上」。所以这里宁可先摆一张空桌 + 一句明确的等待提示
func _draw_net_table() -> bool:
	if not _net_dealt():
		# 桌上还有单机局那副牌的话，先清掉：留着会让人以为已经在打联网局了
		_clear_table()
		# 首次等候也把可分享资料留在记录里；底栏只保留短状态和查看入口。
		var room := _net.room if _net != null else ""
		var details := "已入座（%s），等对手进同一个房间码。" % _seat_name(my_seat)
		_show_message(_reconnect_status("已入座，等对手加入", "连接说明"), Palette.semantic("info"),
			_reconnect_details(room, details, _host_where_text(), "连接地址"))
		return false
	_respawn_all()   # 这一句里置 _net_table_drawn
	_show_message("已入座（%s），等服务器发牌……" % _seat_name(my_seat), Palette.semantic("info"))
	return true

## 服务器发牌了没有。**判据是「两个座位都在 state.players 里」**。
##
## 不看 round_num：房间刚建好那份快照里它也是 1（GameState.new() 的初值），
## 拿它当判据的话空局会被当成真局面，于是又崩回 _respawn_all 那一行
func _net_dealt() -> bool:
	return state != null and state.players.has(my_seat) and state.players.has(foe_seat)

## **这一局**的桌子摆了没有（摆的是一份发过牌的局面）。
##
## 置位在 _respawn_all —— 摆桌子的四条路都经过它。
## 复位有两处，各管一种「新的一局」：_reset_session_flags（重开/rematch）、
## begin_net_game（单机局 → 联网局）。后者少了的话它带着单机局那个 true 进联网局，
## 症状见那一句上面的说明
##
## 读它的有两处，防的是两件不同的事：
##   _on_net_seated —— 防重复摆。后进房那位两份 seated 都带真局面，不拦的话
##     _respawn_all 跑两遍，第二遍把第一遍摆好的实体全删了重建，
##     位置是随机的（_rand_pos），看着就是「牌自己跳了一下」
##   _on_net_phase  —— 防在空桌上开阶段。见那个函数里的说明
var _net_table_drawn := false

## 又一份 seated 到了（NetTransport.connected）。**用途只有一个：补摆桌子**。
##
## 先进房那位的第一份 seated 是空局（见 _draw_net_table），真局面在这一份里。
## 座位也在这里跟着换一次：满座开局时服务器才定先手，
## 而 draw_first 轮换是在 room.reset_for_rematch 里做的 —— 第一局这两份 seated
## 的座位是同一对，换一次不花成本，将来服务器改成「开局才分座」也不用再动这里
func _on_net_seated(mine: String, foe: String) -> void:
	if _net_table_drawn or _net == null:
		return
	set_seats(mine, foe)
	if not _draw_net_table():
		return
	# 入座检查点已带当前阶段；phase 广播也可能先于摆桌到达。
	if _net.phase() != "":
		_on_net_phase(_net.phase(), _net.actor())
	else:
		board.input_locked = true
		btn_pass.text = TXT_BOT_ACTING
		btn_pass.disabled = true

## 新会话按权威阶段恢复；后续 phase 广播仍交给正常演出流程消费。
## ACTION 恢复当前 actor，ATTACK 复用已有弹药池，不能再从回合先手重新装弹。
func _on_net_phase(p: String, actor_seat: String) -> void:
	if _net_phase_seen or not _net_table_drawn:
		return
	if p not in [PhaseMachine.ACTION, PhaseMachine.ATTACK, PhaseMachine.OVER]:
		return
	_net_phase_seen = true
	_foe_action_done = false
	if p == PhaseMachine.ACTION:
		if actor_seat != state.action_first() and state.action_first() == foe_seat:
			_foe_completed_round = state.round_num
		_begin_action_phase(actor_seat)
	elif p == PhaseMachine.ATTACK:
		_clear_market()
		_run_attacks(actor_seat)
	else:
		_show_game_over()

## 本会话已按权威阶段启动；正常流程中后续 phase 可能早于动画到达，不能重启。
var _net_phase_seen := false

## 候选连接等待时仍需轮询握手与心跳，收抽屉不暂停网络。
func _network_join_pending() -> bool:
	return is_instance_valid(_join_panel) and _join_panel.has_pending_connection()

## 覆盖思考与买卡/攻击/结算间的全部等待，认输后也必须等旧流程真正退出。
var _local_turn_flows := 0

## 等待期间可以继续原牌局；只在没有旧行动协程要恢复时接入另一局。
func can_start_pending_net_game() -> bool:
	if _net != null: # 已有联网局的断线重连，沿用服务器当前阶段。
		return true
	if _local_turn_flows > 0 or _thinking or not board._drag_cards.is_empty():
		return false
	for card in board.cards:
		if is_instance_valid(card) and card.has_meta("fly_tw"):
			var tween: Tween = card.get_meta("fly_tw")
			if tween != null and tween.is_valid() and tween.is_running():
				return false
	return phase == PHASE_OVER or (state.winner == "" and phase == PHASE_ACTION
		and _actor == my_seat and not board.input_locked)

## 打开联网面板。双方到齐发牌前不换管道，等待和取消都保留当前 BOT 牌局。
func _open_join_panel() -> JoinPanel:
	if replay_session != null:
		_show_message("请退出录像后再开始局域网对局", Palette.semantic("info"))
		return null
	if _join_panel != null and is_instance_valid(_join_panel):
		return _join_panel
	_join_panel = JoinPanel.new()
	_join_panel.bind(self)
	_join_panel.joined.connect(_on_net_joined)
	add_child(_join_panel)
	# 断线之后攒下的那点东西（房间码 + 一句话）在这儿交给面板。
	# **加完子节点才交** —— prefill 要写 LineEdit，而那几个控件是 _ready 里造的
	if _reconnect_room != "":
		_join_panel.prefill(_reconnect_room, _reconnect_hint, _reconnect_share)
	return _join_panel

var _join_panel: JoinPanel = null

## 重连时该往面板里填的房间码，以及配它的那句话。空串表示「没什么要填的」。
##
## 存下来而不是直接写面板：offer 那一刻面板通常还没造出来
## （玩家得先看见按钮、再去点它），而造出来的时机在他手上
var _reconnect_room := ""
var _reconnect_hint := ""

## 「对手该填我这边哪个地址」。只有本机开着房时才有（接管之后就是这条路）。
##
## 存在 main 而不是面板里，理由同上面那两个：知道这个数的时刻
## （接管成功那一刻）面板通常还没造出来，而造它的时机在玩家手上
var _reconnect_share := ""

## 把「局域网对战」这个入口放回来，让掉线的人有路可走（用户那句「无法重连」）。
##
## 为什么非要放回来 —— 这个按钮是 begin_net_game 藏掉的（局中再点会开出
## 第二条连接），而放回来的那一半只在 _reset_session_flags 里，也就是**退房**。
## 于是打到一半网断了的人，屏幕上一个能点的东西都没有：
## 面板进不去、退出房间只长在结算面板上。他唯一的出路是重启整个游戏,
## 而重启之后座位令牌（只在内存里）也一起没了 —— 那就真的回不去了
##
## 不自动重连，只恢复入口、预填房间码并把说明写入可复制的提示记录。
## share 是本机开房时供对手使用的当前地址；announce=false 由调用方合并当前事件说明，
## 避免一次断线重复记两条详情。
func _offer_reconnect(room: String, hint: String, share := "", announce := true) -> void:
	_reconnect_room = room
	_reconnect_hint = hint
	_reconnect_share = share
	if btn_net:
		btn_net.visible = true
		btn_net.disabled = false
	if _join_panel != null and is_instance_valid(_join_panel):
		_join_panel.prefill(room, hint, share)
	if announce:
		_show_message(_reconnect_status("对手断开，等他/她回来"), Palette.semantic("warning"),
			_reconnect_details(room, hint, share))

## 常驻状态只告诉玩家去哪儿查看；地址和房间码只存在可选择、复制的记录中。
func _reconnect_status(summary: String, topic := "重连说明") -> String:
	var entry := "选项 → 提示记录" if drawer_presentation else "提示记录"
	return "%s · %s见「%s」" % [summary, topic, entry]

func _reconnect_details(room: String, hint: String, share := "", address_label := "断线前连接地址") -> String:
	var details := hint
	if room != "":
		details += "\n房间码：%s" % room
	if share != "":
		details += "\n对手连接地址（IP 与端口）：%s" % share
	elif _net != null and _net.url != "":
		details += "\n%s（IP 与端口）：%s" % [address_label, _net.url]
	return details

# ---------- 本机自己开的那个服务器 ----------

## 本机当服务器时的那一份（net/embedded_host.gd）。不开房时是 null。
##
## **所有权在 main**，不在面板里：面板入座之后 queue_free，
## 服务器不能跟着一起没（那一刻对手还没进来）。而且它要每帧 poll，
## 而 main._process 是这个场景里唯一每帧都跑的地方
var _host: EmbeddedHost = null

## 开房间：在这个进程里起一个服务器。返回 { ok, url } 或 { ok: false, reason }。
##
## 供 JoinPanel._on_host 调。已经开着就直接把地址报回去 ——
## 重复开一个的话端口会顺延，而玩家可能已经把上一个地址报给对手了
##
## `want_port > 0`（`--host --port=N` 传下来的）时**不顺延**：
## 指定端口的人是要把这个数报给对手的（脚本里第二个实例就照这个数去连），
## 顺延等于换了个地方开，而报出去的还是原来那个数 —— 症状是「开着但连不上」。
## 顺延只在「随手开一局、地址现看现抄」那条路上才是对的
func start_local_host(want_port := 0) -> Dictionary:
	var cards_result := prepare_network_cards()
	if not cards_result.get("ok", false):
		return cards_result
	if _host != null and _host.running():
		return { "ok": true, "url": _host.url(), "port": _host.port }
	_host = EmbeddedHost.new()
	var r: Dictionary = _host.start(
		want_port if want_port > 0 else EmbeddedHost.DEFAULT_PORT,
		1 if want_port > 0 else EmbeddedHost.PORT_TRIES)
	if not r["ok"]:
		_host = null
		return r
	print("已在本机开房：%s" % _host.url())
	for u in EmbeddedHost.lan_urls(_host.port):
		print("  对手可以填：%s" % u)
	return { "ok": true, "url": _host.url(), "port": _host.port }

## 接管开房（主机易位专用）。**先试默认端口，占了才退到随机** ——
## 那一条取舍整段写在 EmbeddedHost.start_takeover 上面。
##
## 和 start_local_host 分开而不是加个参数，差别在**顺延**：
## 那一条占了就往上顺（8911、8912……），这一条不顺 ——
## 顺出来的号既不是「两边都知道的那个数」，又不像随机端口那样一眼看出「得问」，
## 于是玩家照着面板默认地址填 8910，撞在对面那个半死的房上
func start_local_host_takeover() -> Dictionary:
	var cards_result := prepare_network_cards()
	if not cards_result.get("ok", false):
		return cards_result
	if _host != null and _host.running():
		return { "ok": true, "url": _host.url(), "port": _host.port }
	_host = EmbeddedHost.new()
	var r: Dictionary = _host.start_takeover()
	if not r["ok"]:
		_host = null
		return r
	print("已在本机开房（接管）：%s" % _host.url())
	for u in EmbeddedHost.lan_urls(_host.port):
		print("  对手可以填：%s" % u)
	return { "ok": true, "url": _host.url(), "port": _host.port }

func local_host_port() -> int:
	return _host.port if _host != null else 0

## 关掉本机那个服务器。走三条路：点「单机继续」放弃开房、退出房间、重开一局。
##
## **要真关**：留着的话端口一直被占，下次开房顺延到下一个端口，
## 而那时候玩家已经把上一个地址报给对手了 —— 对手照着填，连不上
func stop_local_host() -> void:
	if _host == null:
		return
	_host.stop()
	_host = null

## 照启动参数直接进联网局（需求 5）。开局末尾调一次。
##
## 网页版读网址里的查询参数，桌面版读命令行 —— 两者的分歧全在 LaunchConfig 里，
## 这里看到的是同一份配置字典。solo 就什么都不做（绝大多数启动走这一支）
func _apply_launch_config() -> void:
	var cfg: Dictionary = LaunchConfig.current()
	if str(cfg.get("mode", LaunchConfig.MODE_SOLO)) == LaunchConfig.MODE_SOLO \
		and str(cfg.get("url", "")) == "":
		return
	var panel := _open_join_panel()
	panel.apply_launch(cfg)

## 面板入座成功，把这一局换成联网局。
## 藏入口按钮那一步在 begin_net_game 里（和放回来那半对称，见那里的说明）
func _on_net_joined(net: NetTransport) -> void:
	_join_panel = null
	# 这一次进的是**重连**（上一条连接还在身上）→ 先把上一场的残留拆干净。
	# 少拆一样都不报错，症状各不相同，见 _clear_old_session_for_reconnect
	if _net != null and _net != net:
		_clear_old_session_for_reconnect()
	begin_net_game(net)

## 重连入座之前，把上一场留下的东西拆掉。
##
## 只有「掉线之后从面板重新进来」这一条路会走到（_on_net_joined 里那道
## `_net != net`）。第一次入座时 _net 是 null，什么都不用拆。
##
## 四样，每一样漏掉的症状都不一样、而且都不报错：
##   旧连接的信号 —— 不摘：它稍后那条 disconnected 打到 _on_net_down 上，
##                    刚重连成功就被上一条连接锁死（和接管那条一个坏法）
##   旧连接本身   —— 不关：主机那一侧它连的是**回环**，网断了它照样活着、
##                    照样每帧 poll、照样占着服务器一个座位。
##                    而我正要用新连接去坐的很可能就是那个座位
##   我自己那个服务器 —— 不关：端口一直被占；更要紧的是 _host != null 会让
##                    _can_take_over_host 恒假 —— 这一局往后**再也不能接管**
##   _net_phase_seen —— 不复位：它是一次性的、整局不重置（见 _on_net_phase）。
##                    带着 true 进来的话服务器发来的当前阶段被直接丢掉，
##                    症状是那句熟悉的「连上了、牌摆好了、按钮全灰」
func _clear_old_session_for_reconnect() -> void:
	var old: NetTransport = _net
	_detach_net_signals(old)
	old.close()
	# 我自己开过房的话（接管过、或者本来就是我开的）那间房现在没用了：
	# 对局的权威已经在对面那个进程里 —— 我是去当客户端的
	stop_local_host()
	_net_phase_seen = false
	_reconnect_room = ""
	_reconnect_hint = ""
	# 断线那一刻锁的输入要放开：新连接的 seated / phase 会重新按当前阶段摆界面
	# （begin_net_game 末尾照旧锁一次，然后等服务器那条 phase 解锁）
	board.input_locked = false

## 断线 / 被拒。**理由要显示出来** —— 三种拒连（版本不符 / 卡表不一致 / 房间满）
## 各自要做的事完全不同，只收租约不说话的话玩家看到的是「对手忽然不动了」，
## 而真正的原因（比如两边 cards.json 不一样）在关闭帧里躺着没人读
func _on_net_down(code: String, reason: String) -> void:
	var lost_connection := _net
	_release_drag_lease()
	if code == "":
		return
	# 断的是**主机**、而且这一局还打得下去 → 自己接管（scenes/main.gd 的 _take_over_host）。
	# 这一条要放在下面那句「连接断开」之前：接管成功的话这一局没断，
	# 说一句「连接断开」再说一句「你成了主机」，玩家读到的是自相矛盾的两句
	if _can_take_over_host(code):
		var restored: bool = await _take_over_host()
		if restored or _net != lost_connection or not is_inside_tree() or is_queued_for_deletion():
			return
		# 接管没成（开不出端口）。往下走原来那条路 —— 局是真的走不下去了
	# 断线之后这一局走不下去了（每一步都要服务器裁决）。按钮全灰 +
	# 锁输入比「让玩家继续点」对：点下去的每一条意图都会卡在 submit 上等 8 秒
	board.input_locked = true
	btn_pass.disabled = true
	# 但**要留一条回去的路**。上面那两句只是不让他白点，走不下去不等于回不去：
	# 服务器那间房还在（座位令牌也还在，drop_peer 只把座位置 0），
	# 对面那位大概率已经在等他 —— 要么他自己没走、要么他接管开了新房。
	# 少了这一句，玩家看到的是「一句红字 + 一桌点不动的牌」，
	# 而那和「这局废了」在屏幕上是同一个样子（用户那句「无法重连」）
	#
	# 门只给**进过房间的人**开（ever_open）。压根没连上过的话没有可回去的地方：
	# 座位、令牌都不存在，那个房间码服务器也从没认过 —— 拿它去「重连」
	# 只会撞上同一个连不上。那种情形该说话的是面板自己那句拒连原因
	# （它这时还在屏幕上，begin_net_game 一次都没跑过，按钮也没被藏）
	var details := "连接断开：%s" % reason
	if _net != null and _net.ever_open:
		var hint := ("房间码已经替你填好。打开「局域网对战」加入对局；"
			+ "对手已接管开房时，先向对手索取「提示记录」中的当前地址，替换原连接地址。")
		_offer_reconnect(_net.room, hint, "", false)
		details = _reconnect_details(_net.room, details + "\n" + hint)
	_show_message(_reconnect_status("连接断开"), Palette.semantic("danger"), details)

## 断线之后**能接管的那些码**（用户那句「如果对方是主机断开」）。
##
## 白名单而不是黑名单：这两个的意思是「socket 死了」——
##   closed    —— 关闭码认不出来（对端进程走了、网线断了都归这儿）
##   no_server —— 连都没连上（get_close_code() == -1）
##
## 剩下四个（bad_version / table_mismatch / room_full / bad_room）是**被拒**，
## 一个都不能接管：那是对面服务器活着并且明确说了「不让你进」。
## 拿这种情况去接管，等于「因为版本不对被拒 → 自己开一间房自己坐着」，
## 而对手照着新地址连过来会撞上同一个版本不匹配 —— 玩家绕了一圈回到原地
const TAKEOVER_CODES := ["closed", "no_server"]

## 这次断线能靠「自己当主机」救回来吗。七道都要成立，各挡一种不该接管的情形：
##
##   code 在白名单里  —— 见 TAKEOVER_CODES
##   _net != null    —— 没有连接就没有「这一局」可保
##   _net.ever_open  —— 这条连接**曾经**通过。no_server 那个码盖了两件事，
##                      「连上过再断」才是主机走了；「从没连上」是地址打错了，
##                      接管出来是一间自己坐着的空房，对手拿着错地址永远连不过来
##                      （见 net_transport.gd 里 ever_open 上面那段）
##   _host == null   —— 服务器本来就在我这个进程里。它没断，断的是**对手**，
##                      而那条路是 foe_left（scenes/main.gd 的 _offer_reconnect / _on_net_down 的提示与输入拦截），
##                      不是这里
##   _net_table_drawn —— 牌发下来了。没发牌就没有「保得住的对局」，
##                      接管出来的是一间空房
##   winner == ""    —— 局还没结束。终局面板已经在了的话保它没有意义，
##                      rematch 也要两个人（这时候该走的是退出房间）
##   my_seat / token 齐 —— 接管的人必须坐回原座（见 NetRoom.adopt）
func _can_take_over_host(code: String) -> bool:
	return code in TAKEOVER_CODES \
		and _net != null and _net.ever_open \
		and _host == null and _net_table_drawn \
		and state != null and state.winner == "" \
		and _net.my_seat != "" and _net.resume_token != ""

## 主机断开后从服务端原子检查点接管。展示状态可能还在上一回合，不能用于开房。
## 取消旧演出并补齐状态；已有卡的位置保留，只同步增删及需要更新的市场。
func _take_over_host() -> bool:
	var session := _session_generation
	var old: NetTransport = _net
	var room_code: String = old.room
	var seat: String = old.my_seat
	var token: String = old.resume_token
	var checkpoint := old.recovery_checkpoint()
	if checkpoint.is_empty(): return false
	var keep_phase: String = checkpoint["phase"]
	var keep_actor: String = checkpoint["actor"]
	var snap: Dictionary = checkpoint["snapshot"]
	var catch_up := old.recovery_pending() or _client_action_pending

	_show_message(_reconnect_status("主机断开，正在恢复对局"), Palette.semantic("pending"),
		"主机断开了，正在改由你来开房；本局的牌面和房间码会保留。")

	var r: Dictionary = start_local_host_takeover()
	if not r.get("ok", false):
		_show_message(_reconnect_status("接管失败"), Palette.semantic("danger"),
			"接管失败：%s" % r.get("reason", "开不出端口"))
		return false
	# 旧演出仍可能 await 攻击或产出，必须先撤销会话再恢复，不能让它接着消费新连接。
	_invalidate_session()
	session = _session_generation
	board.input_locked = true
	btn_pass.disabled = true
	board.attack_mode = false
	_clear_attack_hl()
	_hide_attack_label()
	old.restore_checkpoint(true)
	var adopted := _host.server.adopt_room(room_code, snap, keep_phase, keep_actor, seat, token)
	adopted.seq = int(checkpoint["seq"])

	# 旧连接的信号先全摘掉再换。不摘的话它稍后那条 disconnected
	# （socket 真正关闭时才发）会打到 _on_net_down 上，
	# 而那时候我已经是主机了 —— 症状是刚接管成功就被自己锁死
	_detach_net_signals(old)
	old.close()

	var net := NetTransport.new(_host.url(), room_code)
	net.resume_token = token   # 凭它坐回原座（NetRoom.adopt 把它种进去了）
	var opened: Dictionary = net.connect_to_server()
	if not opened.get("ok", false):
		stop_local_host()
		_show_message(_reconnect_status("接管失败"), Palette.semantic("danger"),
			"接管失败：%s" % opened.get("reason", "连不上自己开的房"))
		return false
	# 自己连自己：**两头都要泵**。_process 里那句 poll 认的是 _net，
	# 而这条还没交给它 —— 少泵一头，握手就永远完不成（socket 连上了、
	# join 发不出去，一条错都不报）
	var deadline := Time.get_ticks_msec() + int(TAKEOVER_TIMEOUT_SEC * 1000.0)
	while net.my_seat == "" and Time.get_ticks_msec() < deadline:
		net.poll()
		_host.poll()
		await get_tree().process_frame
		if not _session_current(session):
			net.close()
			return false
	if net.my_seat == "":
		net.close()
		stop_local_host()
		_show_message(_reconnect_status("接管失败"), Palette.semantic("danger"),
			"接管失败：自己开的房没让我入座")
		return false

	_swap_transport(net)
	# 新连接从当前检查点恢复，所有旧流程已由会话代号取消。
	# 回执可能已更新 state，但旧输入协程还没画出购买/典当结果；实体差分每次都同步。
	_sync_entities()
	if catch_up:
		_respawn_market()
		_update_hud()
	_net_phase_seen = false
	_on_net_phase(keep_phase, keep_actor)
	# 对手此刻不在（他那半个进程刚走）。挂提示 + 拦掉针对他的行为，
	# 走的是 scenes/main.gd 的 _offer_reconnect / _on_net_down 中已有的断线处理 —— 对我这一侧来说「主机走了」和
	# 「对手掉线了」要做的事完全一样，区别只在服务器现在是我开的
	_foe_online = false
	_show_foe_offline_notice(true)
	_show_waiting_as_host(room_code)
	return true

## 接管时等自己那间房让我入座的上限（秒）。比 JoinPanel.SEAT_TIMEOUT_SEC 短：
## 那边等的是**对面**开的服务器（网络往返 + 人在不在都不知道），
## 这边等的是同一个进程里的一间已经摆好的房 —— 要几帧而不是几秒。
## 等久了没意义：真没成的话玩家该看到的是「接管失败」而不是十秒白屏
const TAKEOVER_TIMEOUT_SEC := 3.0

## 接管时更换连接并保留同一局的录像与牌桌位置。
##
## 顺序要紧：先接信号再换 state。反过来的话中间那几帧里
## applied 到了没人接，而那条结果带着快照 —— 丢一条就是丢一步
func _swap_transport(net: NetTransport) -> void:
	attach_net(net)
	_attach_net_state_signals(net)
	state = net.state()
	pipe = net
	tape.rebind_remote(net)
	_bind_tape_view()
	# _net_table_drawn **保持 true**：桌上摆的就是这份局面。
	# 置回 false 的后果是下一条 seated（对手连进来那一刻服务器给我补的那份）
	# 会触发 _on_net_seated → _respawn_all，所有牌当场跳位
	print("已接管：座位 %s ｜ 房间 %s ｜ %s" % [net.my_seat, net.room, net.url])

## 接上一条连接的**局面信号**（进联网局、主机易位两条路共用，
## 后者见 scenes/main.gd 的 _take_over_host）。
##
## 和 attach_net 分家的理由同 begin_net_game：attach_net 那几条（拖拽转发、
## 断线、离场）只要有连接就能接，这三条却要等 state 换过来才有意义。
##
## 抽成一个函数的理由同 _detach_net_signals —— 漏接一条的症状各不相同且都不报错：
## applied 漏接 → 对手做什么这一侧一个像素都不变；
## phase_changed 漏接 → 阶段永远停在原地，按钮灰着；
## connected 漏接 → 补发的那份 seated 没人接，先进房那位整局看着一张空桌
## （state 里 30 张牌、桌上 0 张）。
##
## 三条都用 is_connected 挡一次：这两条路都可能在同一条连接上走第二遍
## （重连、接管完再接管），重复 connect 会让同一步演两遍
func _attach_net_state_signals(net: NetTransport) -> void:
	if not net.applied.is_connected(_on_intent_applied):
		net.applied.connect(_on_intent_applied)
	if not net.phase_changed.is_connected(_on_net_phase):
		net.phase_changed.connect(_on_net_phase)
	if not net.connected.is_connected(_on_net_seated):
		net.connected.connect(_on_net_seated)

## 摘掉一条连接上所有打到本场景的信号。
##
## 抽成一个函数是因为漏摘一条的症状**各不相同且都不报错**：
## disconnected 漏摘 → 刚接管成功就被旧连接锁死；
## foe_drag 漏摘 → 对手侧的牌被两条连接各摆一次；
## applied 漏摘 → 同一步演两遍。而 _reset_session_flags 里那份原先只摘三条
func _detach_net_signals(net: NetTransport) -> void:
	if net == null:
		return
	if net.disconnected.is_connected(_on_net_down):
		net.disconnected.disconnect(_on_net_down)
	if net.foe_drag.is_connected(on_foe_drag):
		net.foe_drag.disconnect(on_foe_drag)
	if net.foe_piles.is_connected(on_foe_piles):
		net.foe_piles.disconnect(on_foe_piles)
	if net.my_piles.is_connected(on_my_piles):
		net.my_piles.disconnect(on_my_piles)
	if net.foe_left.is_connected(_on_foe_left_drag):
		net.foe_left.disconnect(_on_foe_left_drag)
	if net.foe_back.is_connected(_on_foe_back):
		net.foe_back.disconnect(_on_foe_back)
	if net.applied.is_connected(_on_intent_applied):
		net.applied.disconnect(_on_intent_applied)
	if net.phase_changed.is_connected(_on_net_phase):
		net.phase_changed.disconnect(_on_net_phase)
	if net.connected.is_connected(_on_net_seated):
		net.connected.disconnect(_on_net_seated)
	if net.rematch_voted.is_connected(_on_rematch_voted):
		net.rematch_voted.disconnect(_on_rematch_voted)
	if net.rematch_started.is_connected(_on_rematch_started):
		net.rematch_started.disconnect(_on_rematch_started)

## 我这台机器上那间房「对手该填什么」。只供提示记录与联网面板读取。
## 局域网地址优先；没有网卡地址时保留回环地址，并明确只有同机双开可用。
func _host_where_text() -> String:
	if _host == null:
		return ""
	var urls := EmbeddedHost.lan_urls(_host.port)
	if urls.is_empty():
		return "%s（没找到局域网地址，只有同机双开连得上）" % _host.url()
	return " 或 ".join(urls)

## 接管成功只在底栏显示等待状态；完整说明和地址入记录，面板保留复制入口。
func _show_waiting_as_host(room_code: String) -> void:
	var where := _host_where_text()
	var hint := "现在由你开房，房间码不变。把当前地址和房间码发给对手，让他在「局域网对战」加入对局。"
	if _host != null and _host.port == EmbeddedHost.DEFAULT_PORT:
		hint += "\n端口仍是默认值；同一台机器上可以继续使用原回环地址。"
	_offer_reconnect(room_code, hint, where, false)
	_show_message(_reconnect_status("对手断开，等他/她回来"), Palette.semantic("success"),
		_reconnect_details(room_code, TXT_WAIT_MATCH + " —— " + hint, where))
	print("已接管开房：房间码 %s ｜ 对手填 %s" % [room_code, where])

## 这一局此刻是不是**活着的联网局**。JoinPanel 拿它决定要不要把
## 「等待对局 / 加入对局」两颗按钮禁掉（见那边 _ready 的说明）。
##
## 认的是 online() 而不是 `_net != null`：断线之后 _net **还留着**
## （_on_net_down 不清它，重连那条路要从它身上取房间码和令牌），
## 只看非空的话掉线的人反而被拦住不许重连 —— 那正是这个面板要救的人
func net_live() -> bool:
	return _net != null and _net.online()

## 对手掉线了。**对局不结束** —— 房间和座位令牌都还在服务器那边留着
## （net/room.gd 的 drop_peer 只把座位置 0），他拿原来那串令牌能坐回原位。
##
## 这一侧要做三件事，而在这条改动之前只做了第一件：
##   1. 收租约 —— 他拖着牌断线的话那几张会一直浮着（超时那条路要等满 2 秒）
##   2. 在他的牌区挂一句「对手断开」—— 少了这个，玩家看到的是「对手忽然不动了」，
##      而这和「他在想」「网卡了」「程序崩了」在屏幕上是同一个样子
##   3. 把**针对他的**行为拦住（见 _foe_offline_block）。我自己这半边照常
##      （买卡、编组、典当都只动我自己的牌），拦的是攻击点选：
##      打一张牌要服务器裁决，而裁决完的结果他收不到 ——
##      他回来时拿的是服务器那份快照，牌已经没了，中间那段演出他一眼没看见
func _on_foe_left_drag() -> void:
	_release_drag_lease()
	var was_online := _foe_online
	_foe_online = false
	_show_foe_offline_notice(true)
	# 同一次掉线只记一次详情、开一次延迟提示；绘制或重复离场通知不会刷记录。
	if not was_online:
		return
	var room := _net.room if _net != null else ""
	var hint := "对手断开，等他/她回来。你自己这半边照常，打对手的牌先等等。"
	var share := _host_where_text()
	if share != "":
		hint += "\n本机仍在开房；把下面的地址和房间码发给对手，让他在「局域网对战」加入对局。"
	_show_message(_reconnect_status("对手断开，等他/她回来"), Palette.semantic("warning"),
		_reconnect_details(room, hint, share))
	_arm_reconnect_offer()

## 「对手掉线」到「给我自己一条重连的路」之间等多久。
##
## 为什么这一侧也要有 —— 我**分不清**对手不见了是哪一种：
##   a) 他的网断了 → 服务器（在我这儿）还好着，他会拿令牌连回来。我什么都不用做
##   b) **我的**网断了 → 他那条连接判死（NetTransport.SILENT_SEC，10 秒）之后
##      会接管开一间新房等我。而我这一侧**永远收不到 disconnected**：
##      主机连的是自己进程里那个服务器，走的是回环 —— 网线拔了它照样通。
##      于是 _on_net_down 那条路一次都不走，上面那句 _offer_reconnect 也不会执行
## 屏幕上 a 和 b 长得一模一样（都只是「对手断开」），所以这里按 b 也可能
## 为真来处理：等过他判死接管的那段时间，把门打开，让他自己决定要不要走
##
## 20 秒 = 明显大于对面判死的 10 秒（他接管完、新房开好了我这门才开，
## 不然玩家点进去连的还是那个已经不存在的地址），
## 又明显小于服务器踢人的 30 秒（PEER_SILENT_SEC）—— 情形 a 里
## 他通常几秒就回来了，那时 _on_foe_back 会把这一条撤掉
const RECONNECT_OFFER_SEC := 20.0

## 第几次「对手掉线」。撤销靠的是它而不是取消定时器：
## 掉线-回来-又掉线的话会有两条计时同时在跑，回来那一下只该撤掉**当时那一条**
var _foe_gone_gen := 0

func _arm_reconnect_offer() -> void:
	var session := _session_generation
	_foe_gone_gen += 1
	var gen := _foe_gone_gen
	await _drawer_timer(RECONNECT_OFFER_SEC).timeout
	if not _session_current(session):
		return
	# 三道都要看：他回来了（gen 变了 / _foe_online 翻回来了）、
	# 或者这一局已经不是联网局了（退房、重开）—— 任一条成立就当没这回事
	if gen != _foe_gone_gen or _foe_online or _net == null:
		return
	_offer_reconnect(_net.room,
		"对手还没回来。要是断的其实是你这边的网，他现在多半自己开了房在等你 —— "
		+ "打开「局域网对战」，房间码已经填好；向对手索取「提示记录」里的当前地址。",
		_host_where_text())

## 对手回来了（重连回原座位，或者空座位又被人坐上）。
##
## 不重摆桌子：他那边刚收了一份全量快照（server._on_join 里的 seated_msg），
## 我这份从他走到他回来一直是权威那份的副本 —— 中间我做过的每一步
## 都经服务器落地过。要重摆的是**他**，不是我
func _on_foe_back() -> void:
	_foe_online = true
	_show_foe_offline_notice(false)
	_show_message("对手回来了", Palette.semantic("success"))
	# 把那条重连的门收回去（见 _arm_reconnect_offer）。**藏按钮这一步不能省**：
	# 他回来了，局照旧在打，而这个按钮点下去是开第二条连接 ——
	# 旧那条仍占着服务器的座位，症状是「重连之后发现自己被自己顶掉了」
	_foe_gone_gen += 1
	_reconnect_room = ""
	_reconnect_hint = ""
	if btn_net:
		btn_net.visible = false

## 对手的连接还在吗。单机局恒真（本地 BOT 不会掉线），
## 联网局由 foe_left / foe_back 这一对翻它
var _foe_online := true

## 对手牌区那句「对手断开」。挂在 BOT 区托盘上方，跟着 Label3D 那套走
var _foe_offline_lbl: Label3D

## 针对对手的行为要不要拦。**只在联网局且他确实掉线时**为真 ——
## 单机局的 BOT 不会掉线，_foe_online 恒真
##
## 拦住的时候要说一句话：不说的话点下去没反应，和「这张牌点不起」
## 在屏幕上分不开（那种是有音效的，见 _on_attack_clicked 里 deny 那条）
func _foe_offline_block(what: String) -> void:
	sfx.play("deny_quiet")
	_show_message(_reconnect_status("对手断开，%s要等他/她回来" % what), Palette.semantic("warning"))

func _foe_gone() -> bool:
	return _foe_remote and not _foe_online

func _offline_notice_anchor() -> Vector3:
	# 以真实对手托盘取景，不再把标记挂在托盘外的远端 z 上。
	# 取中间偏前的位置：避开顶部栏投影，同时不压住两侧现金/用户资源摞。
	var count := int(CardDB.game_rules().get("market_size", 8))
	var rect := TableRegions.zone_rect(false, _uses_fitted_table(), count)
	var z := lerpf(rect.position.y, rect.end.y, 0.58)
	return Vector3(rect.get_center().x, 0.66, z)

func _show_foe_offline_notice(on: bool) -> void:
	if not on:
		if _foe_offline_lbl != null:
			_foe_offline_lbl.queue_free()
			_foe_offline_lbl = null
		return
	if _foe_offline_lbl != null:
		return
	var lb := Label3D.new()
	lb.font = Fonts.zh_bold()
	lb.text = "对手断开"
	# 牌区只保留离线标记；重连资料放进提示记录，避免覆盖卡牌且无法复制。
	# 字号收小一档，保持状态醒目但不抢走整块对手牌区。
	lb.pixel_size = 0.012
	lb.font_size = 36
	# 描边随字号走，保持实心可读。
	lb.outline_size = maxi(1, int(lb.font_size * 0.1))
	lb.outline_modulate = Color(0, 0, 0, 0.9)
	lb.modulate = Color(1.0, 0.72, 0.42)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.rotation_degrees = Vector3(-65, 0, 0)
	lb.position = _offline_notice_anchor()
	add_child(lb)
	_foe_offline_lbl = lb

## 这一轮对手已经亮出几个组合。攒着只为了提示语里那个数 ——
## 逐条落地的结果里没有「这是第几组」，而每回合要从头数
var _foe_combo_shown := 0

## 对手的完整行动阶段。
##
## 这个函数是**分人机的唯一一处**：单机局在这里驱动 BOT，联网局在这里等对方
## 发来的 action_done。除它以外，对手侧的代码路径两种局完全相同 ——
## 画面来自 _on_intent_applied，与谁在驱动无关（README.md §「3. 文件目录结构」）。
##
## foe_seat 一直只表示「对手座位」，不表示「对手是电脑」：
## 座位在两种局里都不变，变的只是谁来填这几条意图
func _foe_action() -> void:
	var local := _net == null
	if local:
		_local_turn_flows += 1
	await _run_foe_action()
	if local:
		_local_turn_flows -= 1

func _run_foe_action() -> void:
	var session := _session_generation
	_foe_combo_shown = 0
	if _foe_is_bot():
		await _drive_bot_action()
		if not _session_current(session):
			return
	else:
		await _await_foe_action()
		if not _session_current(session):
			return
	if _table_actions.pawn_busy():
		await _table_actions.pawn_finished
		if not _session_current(session):
			return
	_foe_completed_round = state.round_num
	_refresh_mascot_state()
	if state.winner != "":   # 对手典当冲线，直接终局
		_show_game_over()
		return
	# 单机与联网共用的行动收尾：所有操作完成后只提醒一次，不在每次搜索后响。
	sfx.play("foe_action_done")
	if state.action_first() == foe_seat:
		# 对手先手行动完毕 → 玩家后手行动（看得到对手的阵型）
		_actor = my_seat
		board.input_locked = false
		_show_message("你的行动：对手阵型已亮出，针对性买卡编组", Palette.semantic("info"))
		_set_button(TXT_ACTION_DONE, _on_action_done)
		_refresh_mascot_state()
		_refresh_drawer_pause()
	else:
		# 对手后手行动完毕 → 双方都行动完 → 收市场、整理、攻击
		await _finish_actions()
		if not _session_current(session):
			return

## 对手是本地 BOT 吗。单机局恒真；联网局由 net 层置 false（见 set_foe_remote）。
## 这个量是**这次改造引入的第一个「人 / 电脑」判别**：
## 在此之前场景层只认座位，而座位分不出对面是谁在按键
func _foe_is_bot() -> bool:
	return not _foe_remote

var _foe_remote := false

## 联网局开局时由 net 层调一次：对手是远端的人，本地不要驱动他
func set_foe_remote(remote: bool) -> void:
	_foe_remote = remote

## 单机局：本地 BOT 依次发出典当 / 买卡 / 编组三段意图。
## 这里**只有节拍**，画面全在 _on_intent_applied ——
## 所以这个函数删掉之后，联网局的对手侧照样画得出来。
##
## 「一个行动阶段由哪几步、按什么次序组成」不在这里，在 engine/bot_agent.gd。
## 原先它在这里有一份、在 MatchSimulator.action_phase 有另一份，
## 行动步骤只由 BOTAgent 负责，场景和无头共用同一份计划，
## 而平衡数字只从模拟器那一份量出来
func _drive_bot_action() -> void:
	var session := _session_generation
	# 本次运行的设置在每次新搜索前读取；已有搜索和行动计划保持快照。
	var agent := BOTAgent.new(pipe, foe_seat, BOTSearch.prefs())
	agent.config_provider = BOTSearch.prefs
	agent.decision_observer = tape.record_bot_decision
	# 搜索放在工作线程，增加计算预算时仍保持画面与输入响应。
	# `BOTThink` 的类注释说明线程间的状态隔离边界。
	agent.think = _think_off_thread
	agent.cancelled = func(): return not _session_current(session)
	await agent.run_action_phase(_bot_beat)
	if not _session_current(session):
		return

## BOT 那份纯决策交给工作线程。签名见 `BOTAgent.think`。
##
## 这里是**唯一**一处开线程的地方：意图落地、掷骰、画面全留在主线程，
## 所以随机流和画面次序都不受线程调度影响
func _think_off_thread(job: Callable) -> Variant:
	var session := _session_generation
	_thinking = true
	# 只量本次搜索的真实墙钟；方案之后逐条落地的演出不计入思考耗时。
	ThinkClock.start(ThinkClock.SRC_BOT)
	_update_thinking_hint()
	var out: Variant = await _think.run(job, get_tree(), func(): return not _session_current(session))
	if not _session_current(session):
		return {}
	ThinkClock.stop()
	_thinking = false
	_update_thinking_hint()
	await _await_drawer_resume()
	if not _session_current(session):
		return {}
	return out

## 那个工作线程。整个场景共用一个 —— 同一时刻只有一个座位在想
var _think := BOTThink.new()
var _thinking := false
var _thinking_tick := -1

## 只在十分之一秒读数变化时更新回合标签，不重算资源、盾牌或整块 HUD。
func _update_thinking_hint(force := false) -> void:
	if state == null or lbl_round == null or replay_session != null:
		return
	var tick := int(ThinkClock.elapsed_ms() / 100) if ThinkClock.running() else -1
	if not force and tick == _thinking_tick:
		return
	_thinking_tick = tick
	var phase_text: String = {PHASE_ACTION:"行动", PHASE_ATTACK:"攻击",
		PHASE_SETTLING:"结算中", PHASE_OVER:"终局"}[phase]
	var first := "你" if state.draw_first == my_seat else "对手"
	var base := "第 %d 回合 · %s · %s先手" % [state.round_num, phase_text, first]
	if drawer_presentation == null:
		base = "第 %d 回合 · %s\n%s先手" % [state.round_num, phase_text, first]
	var text := base
	var reserved := base
	if tick >= 0:
		var prefix := (" · " if drawer_presentation else "\n") + "对手思考中… "
		text += prefix + "%.1f秒" % (tick / 10.0)
		# 预留三位秒数，0.0→999.9 期间数字增长不推动顶栏；更久仍可自然扩展。
		reserved += prefix + "9".repeat(maxi(3, str(int(tick / 10)).length())) + ".9秒"
	var wanted := 184.0
	var font := lbl_round.get_theme_font("font")
	var font_size := lbl_round.get_theme_font_size("font_size")
	for line in reserved.split("\n"):
		wanted = maxf(wanted, ceilf(font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x))
	var resized := not is_equal_approx(lbl_round.custom_minimum_size.x, wanted)
	lbl_round.custom_minimum_size.x = wanted
	if drawer_presentation:
		# 抽屉主题按逻辑尺寸缩放，保留动态占位，避免 relayout 恢复旧宽度。
		lbl_round.set_meta("drawer_min_base", Vector2(wanted / drawer_presentation._responsive_factor(), 0))
	lbl_round.text = text
	lbl_round.tooltip_text = text
	if resized:
		if drawer_presentation:
			drawer_presentation.relayout.call_deferred()
		else:
			_position_table_hud.call_deferred()

## 退出前把工作线程收干净。
##
## 这是本仓第一个 `_exit_tree` —— 加它不是习惯问题：Godot 的 `Thread` 没被
## `wait_to_finish` 就析构会报「Thread must be disposed」，而那条错误在导出版里
## 只进日志。玩家关窗口时 BOT 可能正在想（满档 1.7 秒，关窗口撞得上）
func _exit_tree() -> void:
	_invalidate_session()
	tape.stop()
	if _drawer_owns_pause and get_tree():
		get_tree().paused = false
	_think.flush()

## BOT 每走完一步，停多久。返回 Signal 就等它，返回 null 就不等
## （见 BOTAgent.run_action_phase）。节拍长度是表现层的事，所以判断在这边
func _bot_beat(step: String):
	if step == BOTAgent.STEP_PAWN and _table_actions.pawn_busy():
		return _table_actions.pawn_finished
	if step == BOTAgent.STEP_BUY:
		_update_hud()
		return _drawer_timer(BEAT_BOT_BUY).timeout
	if step == BOTAgent.STEP_BUY_DONE or step == BOTAgent.STEP_COMBO:
		return _drawer_timer(BEAT_BOT_STEP).timeout
	return null

## 联网局：等对方把行动阶段走完。
##
## 期间对方的每条意图都会经 _on_intent_applied 画出来 ——
## 这个函数自己不画任何东西，它只是在等一条 action_done。
## 超时不在这里兜：那是传输层的事（NetTransport.TIMEOUT_SEC），
## 这里等的是「对方还在想」，而对方掉线会走 foe_left
func _await_foe_action() -> void:
	var session := _session_generation
	# 联网局的「对手想了多久」就量在这儿。这一路**不经过 BOTThink** ——
	# 对手在他自己那台机器上想，这边只是在等一条 action_done，
	# 所以秒表不能挂在 BOTThink 上（`ThinkClock` 的类注释写了这件事）。
	#
	# 量到的是**含网络往返**的墙钟，不是对方的纯搜索时间：
	# 那个数这边拿不到（协议里没有这一项），而玩家等的确实是这一段
	ThinkClock.start(ThinkClock.SRC_FOE)
	_update_thinking_hint()
	while _session_current(session) and state.winner == "" and not _foe_action_done:
		await get_tree().process_frame
	if _session_current(session):
		ThinkClock.stop()
		_update_thinking_hint()
		_foe_action_done = false

## 对方发来的 action_done 把这个置起来。由 _on_intent_applied 之外的
## 那条分支设置（action_done 不改状态，没有画面）
var _foe_action_done := false

## 双方行动完毕：收走公共区 → 自动整理 → 攻击阶段
func _finish_actions() -> void:
	var session := _session_generation
	# 公共区收走
	for c in market_cards:
		_fly_out(c, Vector3(0, 4, -2))
	market_cards.clear()
	for lb in market_price_labels:
		if is_instance_valid(lb):
			lb.queue_free()
	market_price_labels.clear()
	# BOT 侧收拢重排；玩家侧不动（见 _next_round 里的说明）
	layout._layout_bot_idle()
	_update_hud()
	await _drawer_timer(BEAT_PHASE).timeout
	if not _session_current(session):
		return
	await _run_attacks()
	if not _session_current(session):
		return

# ---------- 牌该摆哪儿 ----------
## 摆放那一层整段搬去了 scenes/settle_layout.gd（挂成子节点 layout）。
## 这个文件留下的是回合流程：谁该行动、买了什么、什么时候进攻。
## 分界见 settle_layout.gd 开头 —— 流程决定有哪些牌要摆，那边决定摆哪儿。
##
## 转出 PILE_CHUNK：结算产出按它分份，而 _resolve_combo_visual（在这个文件里）
## 要按同一个份额决定演出节奏，两份数会各说各话
const PILE_CHUNK := SettleLayout.PILE_CHUNK

# ---------- 攻击阶段（先手先攻：点数池 + 点选目标） ----------

func _run_attacks(resume_actor := "") -> void:
	var session := _session_generation
	phase = PHASE_ATTACK
	board.input_locked = true
	btn_pass.text = "攻击阶段…"
	btn_pass.disabled = true
	_update_hud()
	var flow := _round_flow()
	var result: Dictionary = {"ok": true}
	if resume_actor == "":
		result = await flow.run_attacks(_play_attack_turn)
	else:
		# 当前攻击者已由服务器装弹；从现有池继续，之前收过手的人不能再装一次。
		var order: Array = state.action_order()
		for index in range(order.find(resume_actor), order.size()):
			var who: String = order[index]
			if who == resume_actor:
				result = await _play_attack_turn(who, pipe.applier().pools(who))
			else:
				result = await flow.run_attack_turn(who, _play_attack_turn)
			if not _session_current(session) or not result.get("ok", false) or state.winner != "":
				break
	if not _session_current(session):
		return
	if not result.get("ok", false):
		_action_failed(result)
		return
	_hide_attack_label()
	if state.winner != "":
		# 决胜那一击也要撕完再报结果：清零即胜时最后一批往往就是好几张，
		# 弹出胜负板会盖住桌面，没撕完的那几张等于没撕
		await _tears_drained()
		if not _session_current(session):
			return
		await flow.finalize()
		if not _session_current(session):
			return
		_show_game_over()
	else:
		await _run_settle()
		if not _session_current(session):
			return

## 单方攻击回合：BOT 自动点选（演出），玩家手动点选（互动）
## 清零即胜：每次点选后立刻判胜，对方现金/用户到 0 当场结束
## 装弹与攻击顺序由 RoundFlow 共用；这里仅提供互动和演出。
func _attack_turn(who: String) -> void:
	var flow := _round_flow()
	await flow.run_attack_turn(who, _play_attack_turn)

func _play_attack_turn(who: String, pools: Dictionary) -> Dictionary:
	var session := _session_generation
	_attack_actor = who
	_refresh_mascot_state()
	if who == foe_seat:
		_show_attack_label(_attack_label_text(TXT_ATTACK_FOE, pools), false)
		_show_message("对手发动攻击！", Palette.semantic("danger"))
		await _drawer_timer(BEAT_PHASE).timeout
		if not _session_current(session):
			return Intent.err("cancelled", "牌局已切换")
		if _foe_is_bot():
			var attack_result: Dictionary = await _drive_bot_attack(who, pools)
			if not _session_current(session):
				return Intent.err("cancelled", "牌局已切换")
			if not attack_result.get("ok", false):
				return attack_result
		else:
			await _await_foe_attack(who)
			if not _session_current(session):
				return Intent.err("cancelled", "牌局已切换")
		await _flush_foe_attack()
		_hide_attack_label()
	else:
		# 玩家互动点选：点数必须花完（点不起任何目标时自动结束，余点作废）
		# 开局就得先判一次能不能点得起——对方把全部单位卡塞进受保护的组合时，
		# 目标列表可能一开始就是空的；不判空会卡在 await 上，而按钮此刻已 disabled，
		# 整局无法继续。三处都要判：这里、BOT 分支、每点掉一个之后
		if pipe.applier().affordable_targets(who).is_empty():
			_show_message("你有攻击点数，但对手没有点得起的目标，余点作废", Palette.semantic("muted"))
			var exhausted: Dictionary = await pipe.submit(Intent.attack_done(who, Intent.DONE_EXHAUSTED))
			if not _session_current(session):
				return Intent.err("cancelled", "牌局已切换")
			if not exhausted.get("ok", false):
				return exhausted
			await _drawer_timer(BEAT_WASTED).timeout
			if not _session_current(session):
				return Intent.err("cancelled", "牌局已切换")
			return {"ok": true}
		board.attack_mode = true
		_show_attack_label(_attack_label_text(TXT_ATTACK_MINE, _attack_pools), true)
		_show_message("你的攻击：现金点打现金、用户点打用户，点数必须花完", Palette.semantic("danger"))
		_refresh_attack_targets()
		_refresh_mascot_state()
		_refresh_drawer_pause()
		await attack_turn_finished
		if not _session_current(session):
			return Intent.err("cancelled", "牌局已切换")
		board.attack_mode = false
		_clear_attack_hl()
		_hide_attack_label()
	return {"ok": true}

## 单机局的对手攻击回合：本地 BOT 反复点选。
##
## 击中的画面（音效、飞出、爆花、HUD）在 _render_foe_attack ——
## 这里留下的是**只有驱动方才知道的东西**：瞄准高亮和两拍停顿。
## 联网局里那两样也没有（对方在他自己那边瞄），所以走 _await_foe_attack。
##
## 发的意图和次序必须与 Transport.run_attack_phase 一致（装弹 → 反复点选 → 收尾）
func _drive_bot_attack(who: String, pools: Dictionary) -> Dictionary:
	var session := _session_generation
	var choose := _live_bot_target_picker()
	var before := func(target: Dictionary) -> void:
		_hl_target(target, true)
		await _drawer_timer(BEAT_ATTACK_BOTM).timeout
	var after := func(target: Dictionary) -> void:
		_hl_target(target, false)
		await _flush_foe_attack()
		_show_attack_label(_attack_label_text(TXT_ATTACK_FOE, pools), false)
	var exhausted := func(): _show_message("对手剩余点数点不起任何目标，余点作废", Palette.semantic("muted"))
	var flow := _round_flow()
	var result: Dictionary = await flow.run_automatic_attack(who, choose, before, after, exhausted)
	return result if _session_current(session) else Intent.err("cancelled", "牌局已切换")

## 每次选靶读取当前设置；未改参数时复用闭包，保留整个攻击阶段的共享预算。
func _live_bot_target_picker() -> Callable:
	var active := {"model":"", "parameters":{}, "picker":Callable()}
	return func(current: GameState, seat: String, targets: Array, current_pools: Dictionary) -> Dictionary:
		var cfg := BOTSearch.prefs()
		var parameters := cfg.resolved_parameters()
		if cfg.model != active["model"] or parameters != active["parameters"]:
			active["model"] = cfg.model
			active["parameters"] = parameters
			active["picker"] = BOTPlan.target_picker(cfg,current,seat)
		# 与行动计划同一边界：主线程冻结输入，搜索期间认输/退出只改真实牌桌。
		var picker: Callable = active["picker"]
		# 同组同类靶在搜索中等价，锁定组合后的续击通常无需再开线程。
		# 仍调用原选择器，消费缓存续打并推进预算，保持真实执行与模拟一致。
		if cfg.implementation().can_pick_target_inline(targets):
			return picker.call(current,seat,targets,current_pools)
		var snapshot := BOTEnvironment.copy(current)
		var target_snapshot := targets.duplicate(true)
		var pool_snapshot := current_pools.duplicate(true)
		return await _think_off_thread(func(cancelled_check: Callable = Callable()):
			if picker.get_argument_count() >= 5: return picker.call(snapshot,seat,target_snapshot,pool_snapshot,cancelled_check)
			return picker.call(snapshot,seat,target_snapshot,pool_snapshot))

## 联网局：等对方把攻击回合走完。他每一击都会经 _render_foe_attack 画出来；
## 这里等的是一条 attack_done —— 池子清零是它的效果（IntentApply._attack_done），
## 所以判「池子空了」和判「收到 attack_done」是同一件事，取前者不必再存一个标志位
func _await_foe_attack(who: String) -> void:
	var session := _session_generation
	while state.winner == "" and not pipe.applier().pool_empty(who):
		await get_tree().process_frame
		if not _session_current(session):
			return
		_show_attack_label(_attack_label_text(
			TXT_ATTACK_FOE, pipe.applier().pools(who)), false)

func _attack_label_text(title: String, pools: Dictionary) -> String:
	return "%s · %s" % [title, GameState.pool_text(pools)]

## 玩家点选攻击目标（board.attack_clicked 信号）
func _on_attack_clicked(card: CardEntity) -> void:
	var session := _session_generation
	if replay_session != null:
		return
	_player_attack_busy += 1
	_refresh_drawer_pause()
	await _apply_player_attack(card)
	_player_attack_busy -= 1
	if not _session_current(session):
		return
	_refresh_mascot_state()
	_refresh_drawer_pause()

func _apply_player_attack(card: CardEntity) -> void:
	var session := _session_generation
	if phase != PHASE_ATTACK or not board.attack_mode:
		return
	if card.uid < 0:   # 公共区占位卡（正常攻击阶段已收走，兜底）
		return
	# 对手掉线期间**不许打他的牌**。这一条拦在最前面（连「是不是他的牌」都还没问）：
	# 攻击是这个游戏里唯一动得到对面牌的行为，所以掉线要拦的就是它 ——
	# 买卡、编组、典当都只动我自己那半边，照常。
	#
	# 为什么不是「让他自动弃点」：那等于替他做了一个决定。他回来时拿的是
	# 服务器那份快照，牌少了一批、点数也没了，而中间那段演出他一眼没看见
	if _foe_gone():
		_foe_offline_block("打他的牌")
		return
	if state.find_card(foe_seat, card.uid).is_empty():
		if not state.find_card(my_seat, card.uid).is_empty():
			sfx.play("deny_quiet")
			_show_message("不能点自己的卡", Palette.semantic("danger"))
		return
	# 点在 BOT 的摞上 = 点这一摞：摞在玩家眼里是一个整体，收拢之后连张数都只在
	# 侧边写着，点一下只扣一张就成了「看上去摞好了，却还得一张一张点」。
	# 所以摞走「一路啃到底」：靶按 _pile_target_by_key 反复挑，点数花光或摞空为止。
	# 组合摞本来就是一次拆整份核心，这里让闲置摞（现金/用户/备牌）也一样。
	# 不在任何摞里的散卡保持原样：一张就是一张，没有「整体」可言
	var pile_key := str(layout._bot_pile_of_uid.get(card.uid, ""))
	if pile_key != "":
		await _attack_pile(pile_key)
		if not _session_current(session):
			return
		return
	# 散卡：靶就是它自己
	if card._shield_on:
		_table_actions.shield_feedback([card])
	var target := {}
	for t in state.attack_targets(foe_seat):
		if t["uids"].has(card.uid):
			target = t
			break
	if target.is_empty():
		sfx.play("deny_quiet")
		var def: Dictionary = CardDB.get_def(card.def_id)
		var kind := str(def.get("kind", ""))
		if kind in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_BUFF]:
			_show_message("核心卡/Buff 卡无法被点——拆组合要抽走它的配方单位卡", Palette.semantic("danger"))
		elif kind == CardDB.KIND_LEGEND:
			_show_message("传说卡无法被攻击——只能典当变现", Palette.semantic("danger"))
		else:
			_show_message("该卡受防御 Buff 保护，无法被点", Palette.semantic("danger"))
		return
	if not GameState.target_affordable(target, _attack_pools):
		sfx.play("deny_quiet")
		# 所有靶同价（attack_cost_per_card），所以这条只在对应池已经空了的时候念得到
		var need := "%s攻击×%d" % [CardDB.card_label(target["res"]), target["cost"]]
		_show_message("点数不够：需要 %s，你手上只有（%s×%d %s×%d）" % [
			need,
			CardDB.card_label(CardDB.RES_CASH), _attack_pools[CardDB.RES_CASH],
			CardDB.card_label(CardDB.RES_USER), _attack_pools[CardDB.RES_USER],
		], Palette.semantic("danger"))
		return
	var center := _target_center(target)
	var r: Dictionary = await pipe.submit(Intent.apply_attack(my_seat, target), my_seat)
	if not _session_current(session):
		return
	if not r["ok"]:
		sfx.play("deny_quiet")
		_show_message(r["reason"], Palette.semantic("danger"))
		return
	await _settle_attack(r["removed"], center)
	if not _session_current(session):
		return

## 点一摞：摞内的靶一个接一个啃，点数花光或摞里再没有点得起的靶为止。
## 靶每轮现问（见 _pile_target_by_key）：核心卡扣穿之后整组作废，
## 剩下的卡从「组合内的富余」变成「场上散卡」，定价和 uids 都跟着变。
## 扣掉的牌攒成一批，动画/音效/重排在最后统一走一次 —— 一次点击就是一次攻击，
## 不该按摞里的张数连放 N 声
func _attack_pile(key: String) -> void:
	var session := _session_generation
	var removed: Array = []
	var center := Vector3.INF
	var first_target := {}
	while true:
		var t := _pile_target_by_key(key)
		if t.is_empty():
			break
		if first_target.is_empty():
			first_target = t
			center = _target_center(t)
		var r: Dictionary = await pipe.submit(Intent.apply_attack(my_seat, t), my_seat)
		if not _session_current(session):
			return
		if not r["ok"]:
			# 池子不够/目标已失效：本轮到此为止。一张都没扣掉才算「点空了」
			if removed.is_empty():
				sfx.play("deny_quiet")
				_show_message(r["reason"], Palette.semantic("danger"))
				return
			break
		for c in r["removed"]:
			removed.append(c)
	if removed.is_empty():
		# 摞里一个点得起的靶都没有：区分「点不起」和「压根点不了」
		sfx.play("deny_quiet")
		var pool_txt := "（%s）" % GameState.pool_text(_attack_pools)
		_table_actions.shield_feedback(_table_actions._members(layout._bot_pile_uids.get(key, [])))
		var blocked := _pile_blocked_reason(key)
		if blocked != "":
			_show_message(blocked, Palette.semantic("danger"))
		else:
			_show_message("点数不够：这一摞里没有点得起的目标 %s" % pool_txt, Palette.semantic("danger"))
		return
	await _settle_attack(removed, center)
	if not _session_current(session):
		return

## 一摞点不动时的说明：摞里全是不可点的卡（核心/Buff/传说）就直说，
## 否则交给调用方按「点数不够」报。空字符串 = 不是这种情况
func _pile_blocked_reason(key: String) -> String:
	var uids: Array = layout._bot_pile_uids.get(key, [])
	var any_unit := false
	for u in uids:
		var c: Dictionary = state.find_card(foe_seat, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT:
			any_unit = true
			break
	if any_unit:
		return ""
	return "这一摞里没有可点的单位卡——核心卡/Buff 卡打不掉，传说卡只能典当变现"

## 一次攻击点选之后的统一收尾：动画、特效、BOT 区重排、胜负与点数结算
func _settle_attack(removed: Array, center: Vector3) -> void:
	var session := _session_generation
	# 和对手侧同一份职责（_render_foe_attack）：按摞报一次。
	# 这边本来就是攒成一批进来的，走同一个入口是为了连点两下时
	# 也按摞算 —— 前一摞还在撕，第二下不该再叠一声
	var resource := ""
	if not removed.is_empty() and entities.has(int(removed[0])):
		resource = str(CardDB.get_def(entities[int(removed[0])].def_id).get("res", ""))
	_impact_once(center, my_seat, resource)
	_clear_attack_hl()
	# 先把这一批撕完再往下走。下面第一句就是重排 BOT 区，
	# 不等的话重排会把还没轮到的那几张连补间带卡一起清掉（见 _animate_removed）：
	# 一组三张，玩家只看见撕掉一张，另外两张凭空不见了
	await _await_removed(removed, false)
	if not _session_current(session):
		return
	# BOT 的摞是自己摆的（不进 board.groups），扣完必须重排一次：
	# 不排的话被扣掉那几张的层位空着、侧边清单还挂着扣之前的张数，
	# 看上去就像点了一下什么都没扣掉
	layout._layout_bot_zone()
	# 清零即胜由 applier 在 apply_attack 里判过了（IntentApply._attack），这里不再判第二遍
	if state.winner != "":
		_hide_attack_label()
		attack_turn_finished.emit()
		return
	if pipe.applier().pool_empty(my_seat):
		_hide_attack_label()
		# 点数花光也得报一声：联机时换手只认 attack_done（NetRoom._advance），
		# 不报的话服务器一直停在「等我点选」，两边一起卡到超时。
		# 单机走 LocalTransport，池子本来就空，applier 那边零影响（IntentApply._attack_done
		# 只在 had 为真时记战报），所以两条路共用这一句
		await _finish_player_attack()
		if not _session_current(session):
			return
		return
	_show_attack_label(_attack_label_text(TXT_ATTACK_MINE, _attack_pools), true)
	_update_hud()
	if pipe.applier().affordable_targets(my_seat).is_empty():
		_show_message("剩余点数点不起任何目标，余点作废", Palette.semantic("muted"))
		await _finish_player_attack(Intent.DONE_EXHAUSTED)
		if not _session_current(session):
			return
		return
	_refresh_attack_targets()

func _finish_player_attack(reason := Intent.DONE_FORFEIT) -> void:
	var session := _session_generation
	if _attack_completion_pending:
		return
	_attack_completion_pending = true
	btn_pass.disabled = true
	var result: Dictionary = await pipe.submit(Intent.attack_done(my_seat, reason), my_seat)
	if not _session_current(session):
		return
	_attack_completion_pending = false
	if not result.get("ok", false):
		_action_failed(result)
		_set_button("重试结束攻击", func(): _finish_player_attack(reason))
		return
	attack_turn_finished.emit()

# ---------- 攻击阶段辅助 ----------

## 点在收拢摞上时，摞内点得起的靶。
## 优先配方核心（kind="combo"），点不起核心才退回富余卡：
## 玩家点一摞组合的本意是拆掉它，核心少一张配方就不成立，
## 而啃富余卡不影响配方与产出 —— 先给能废组的那张。
## 核心与富余现在同价（都按 attack_cost_per_card 逐张算），所以这里只分先后、不比 cost。
##
## 按摞的 key 而不是 CardEntity 找靶：连点同一摞时被点的那张已经从场上移掉了，
## 拿不到实体再去问「它在哪一摞」。摞内的靶每次都要现问 state
func _pile_target_by_key(key: String) -> Dictionary:
	if key == "":
		return {}
	var uids: Array = layout._bot_pile_uids.get(key, [])
	if uids.is_empty():
		return {}
	var core := {}
	var spare := {}
	for t in state.attack_targets(foe_seat):
		var inside := false
		for u in t["uids"]:
			if uids.has(u):
				inside = true
				break
		if not inside or not GameState.target_affordable(t, _attack_pools):
			continue
		if t["kind"] == "combo":
			if core.is_empty():
				core = t
		elif spare.is_empty():
			spare = t
	return core if not core.is_empty() else spare

## 高亮当前所有点得起的目标（玩家点选模式的视觉引导）。
##
## 分两种摞：
##   - **收拢**摞：牌埋在底下，高亮它们看不见 —— 红光收到摞顶那一张
##     （= 玩家点得到的那一张）
##   - **摊开**摞：每张都露着，就每个点得起的靶各自变红。
##     以前这里不分形态，一律收到 uids[0]，于是一个摊开的组合只有一张卡是红的，
##     而 core_first_order 的队首**是核心卡** —— 核心卡不是合法靶
##     （GameState.attack_targets 只出单位卡），玩家看到的是「唯一红的那张点不动、
##     真能打的那几张一片灰」。这就是「可被攻击的牌没有都变红」
func _refresh_attack_targets() -> void:
	_clear_attack_hl()
	var pile_hl := {}
	for t in state.affordable_targets(foe_seat, _attack_pools):
		for u in t["uids"]:
			if not entities.has(u) or not is_instance_valid(entities[u]):
				continue
			var key: String = str(layout._bot_pile_of_uid.get(u, ""))
			if key != "" and bool(layout._bot_pile_compact.get(key, true)):
				pile_hl[key] = true
				continue
			entities[u].set_highlight(true, Color(1.5, 0.55, 0.45))
			_attack_hl.append(entities[u])
	for key in pile_hl:
		var uids: Array = layout._bot_pile_uids.get(key, [])
		if uids.is_empty():
			continue
		var top: int = uids[0]   # 摞顶 = core_first_order 的队首
		if entities.has(top) and is_instance_valid(entities[top]):
			entities[top].set_highlight(true, Color(1.5, 0.55, 0.45))
			_attack_hl.append(entities[top])

func _clear_attack_hl() -> void:
	for e in _attack_hl:
		if is_instance_valid(e):
			e.set_highlight(false)
	_attack_hl.clear()

func _hl_target(target: Dictionary, on: bool) -> void:
	for u in target["uids"]:
		if entities.has(u) and is_instance_valid(entities[u]):
			entities[u].set_highlight(on, Color(1.5, 0.55, 0.45))

func _target_center(target: Dictionary) -> Vector3:
	for u in target["uids"]:
		if entities.has(u) and is_instance_valid(entities[u]):
			return entities[u].global_position + Vector3(0, 0.5, 0)
	return Vector3(0, 1.0, 0.0)

## 同一次攻击命中的全部卡共用抓握、撕开和退场节拍，数量不增加动画次数。
func _animate_removed(removed: Array, toward_ai: bool, held_cards: Array = []) -> float:
	var cards: Array = held_cards.filter(func(card): return is_instance_valid(card))
	for uid in removed:
		if entities.has(uid) and is_instance_valid(entities[uid]):
			cards.append(entities[uid])
	if cards.is_empty():
		return 0.0
	for card in cards:
		entities.erase(card.uid)
	_card_motion.sfx = sfx
	var dir := Vector3(0, 4, -2) if toward_ai else Vector3(0, 4, 2)
	var duration: float = _card_motion.tear_batch(cards, table_hands, dir)
	var until := _animation_now_ms() + int(duration * 1000.0)
	_tear_slot_ms = until
	_tear_until_ms = maxi(_tear_until_ms, until)
	return duration

## 结算消耗仍可错开；攻击不再逐张排队。
const TEAR_STAGGER := UIMotion.STAGGER

## 整批演出结束时刻；同步结算消耗与攻击的等待边界。
var _tear_until_ms := 0
var _tear_slot_ms := 0

## 每个完整攻击批次只调用一次命中反馈。
func _impact_once(center: Vector3, attacker := "", resource := "") -> void:
	_table_actions.attack_feedback(center, attacker, resource)

## 整批撕完（含最后一张撕开的 TEAR_TIME）。调用方 await 它，
## 别拿裸 create_timer 各写一遍时长
func _await_removed(removed: Array, toward_bot: bool) -> void:
	var dur := _animate_removed(removed, toward_bot)
	if dur > 0.0:
		await _drawer_timer(dur).timeout

## 等场上的撕牌演完。
##
## 为什么不靠调用方各自 await：撕牌有两个发起点，一个能 await（我自己点选，
## _settle_attack），另一个**不能** —— 对手那一击是 _on_intent_applied
## 这个信号回调里画的，回调里 await 只挂起回调自己，发信号的人照旧往下跑。
## 于是「撕牌还没撕完就直接结算看到结果」在联机局里从对手侧漏进来。
##
## 盯**时刻**而不是补间对象：补间是 bind_node 到卡上的，卡在结算重建里
## 随时会被 queue_free，拿着一把可能已经失效的 Tween 去问 is_running
## 反而会漏等。时刻是纯数，谁被释放都不影响
func _tears_drained() -> void:
	await _flush_foe_attack()
	while true:
		var left: int = _tear_until_ms - _animation_now_ms()
		if left <= 0:
			_tear_until_ms = 0
			_tear_slot_ms = 0    # 队排空了，下一摞重新从「现在」起
			return
		await _drawer_timer(float(left) / 1000.0).timeout

func _delayed_flyout(card: CardEntity, dir: Vector3, delay: float) -> void:
	_delayed_flyout_ex(card, dir, delay, true)

## 同上，但不响拆除音。给 _sync_entities 的兜底路径用：
## 那条路上消失的卡是**自己的组合吃掉的**（升级吃配方卡、配方吃用户卡），
## 不是被谁打掉的 —— 响一声攻击音会把「我升级了」读成「我被打了」
func _delayed_flyout_torn(card: CardEntity, dir: Vector3, delay: float) -> void:
	_delayed_flyout_ex(card, dir, delay, false)

func _delayed_flyout_ex(card: CardEntity, dir: Vector3, delay: float,
		with_sfx: bool) -> void:
	_card_motion.sfx = sfx
	_card_motion.delayed_tear(card, dir, delay, with_sfx)

## 攻击点数标签：玩家回合跟随鼠标（_process 驱动），BOT 回合置顶居中
func _show_attack_label(text: String, follow_mouse: bool) -> void:
	_refresh_attack_panel()
	attack_panel.visible = true if is_instance_valid(attack_panel) else false
	lbl_attack.text = text
	lbl_attack.visible = true
	_attack_follow_mouse = follow_mouse
	if not follow_mouse:
		lbl_attack.set_anchors_preset(Control.PRESET_CENTER_TOP)
		lbl_attack.custom_minimum_size = Vector2(360, 44)
		lbl_attack.position = Vector2(-180, 120)

func _hide_attack_label() -> void:
	lbl_attack.visible = false
	if is_instance_valid(attack_panel):
		attack_panel.visible = false
	_attack_follow_mouse = false

# ---------- 结算演出 ----------

func _run_settle() -> void:
	var session := _session_generation
	phase = PHASE_SETTLING
	_set_mascot_state("resolving")
	# 攻击阶段的撕牌全部演完才开结算。少了这一句，最后一击的后几张
	# 还在排队等着撕，结算已经在重画桌子 —— 那几张连补间带卡一起没了，
	# 玩家看到的是「牌还没撕完就跳到结果」（见 _tears_drained）
	await _tears_drained()
	if not _session_current(session):
		return
	_update_hud()
	_show_message("结算开始！", Palette.semantic("pending"))
	await _drawer_timer(BEAT_BANNER).timeout
	if not _session_current(session):
		return

	# 产出的卡自己摞到屏幕左侧，桌上原有的布局一律不动（见 _stack_settled）。
	# 「现在场上有哪些卡」必须在**任何组合演出之前**记：_resolve_combo_visual
	# 每演完一组自己就调一次 _sync_entities()，产出的卡在演出途中就已经生成实体。
	# 记晚了（放到演出循环之后）等于把本回合全部产出都算成「原有的卡」，
	# _stack_settled 拿到的新卡是 0 张，既不分组也不摞。
	# tools/ 里的调试钩子必须保持同样的次序：先记 known，再加卡
	var known := {}
	for uid in entities:
		known[uid] = true

	# 到货窗口：产出的资源卡从组合中心直接飞到左侧资源带的分组席位上，
	# 而不是先随手落一处再被末尾那趟拽走（见 layout 的「结算到货窗口」一节）
	layout.begin_arrivals()
	# 结算也是一条条意图：产出按组发（OP_PRODUCE 带组下标），收尾单独一条（OP_FINALIZE）。
	# 演出是一组一组演的，所以拆到这个粒度 —— 和 Transport.run_settle 发的次序一致
	if pipe.applier().production_count() == 0:
		_show_message("本回合没有产出/升级组合，直接收尾", Palette.semantic("muted"))
	var present := func(index: int, resolve: Callable) -> Dictionary:
		return await _resolve_combo_visual(index, {}, resolve)
	var flow := _round_flow()
	var result: Dictionary = await flow.run_settle(present)
	if not _session_current(session):
		return
	if not result.get("ok", false):
		layout.end_arrivals()
		_action_failed(result)
		return
	_sync_entities()
	layout.end_arrivals()
	board.prune_groups()
	_update_hud()
	layout._layout_bot_idle()   # 结算后 BOT 新产出的单位卡也归堆
	layout._stack_settled(known)
	await _drawer_timer(BEAT_PHASE).timeout
	if not _session_current(session):
		return

	if state.winner != "":
		_show_game_over()
	else:
		await _next_round()
		if not _session_current(session):
			return

## 演一组产出。参数是**组下标**而不是组合对象：意图里能带的只有下标，
## 组合对象过不了网线。下标取自 Settle.ordered_production_combos，finalize 之前稳定
func _resolve_combo_visual(combo_idx: int, recorded: Dictionary = {}, resolve: Callable = Callable()) -> Dictionary:
	var session := _session_generation
	var combo: Dictionary = recorded.get("combo", {}) if not recorded.is_empty() else Settle.ordered_production_combos(state)[combo_idx]
	var owner: String = combo["owner"]
	var eval: Dictionary = combo["eval"]
	var owner_name := _seat_name(owner)
	var leader_name := CardDB.card_name(eval["leader"])

	# 高亮该组合
	var combo_entities: Array = []
	for u in combo["uids"]:
		if entities.has(u):
			combo_entities.append(entities[u])
			entities[u].set_highlight(true)
	_table_actions.prepare_combo(combo)
	_show_message("%s 的「%s」结算中……" % [owner_name, leader_name], Palette.semantic("pending"))
	await _drawer_timer(BEAT_COMBO_SHOW).timeout
	if not _session_current(session):
		return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}

	# 组合的位置要在结算**之前**量：升级会把配方卡吃掉，结算完再量就没实体可量了。
	# 取全体成员的中心而不是第一张：产出得看着是从整组里迸出来的，
	# 而摞起来的组合第一张在最外沿，从那儿飞会偏出组合一截
	var combo_center := Vector3(0, 0.6, 0)
	var n_alive := 0
	for e in combo_entities:
		if is_instance_valid(e):
			combo_center += e.global_position
			n_alive += 1
	if n_alive > 0:
		combo_center /= float(n_alive)
	else:
		combo_center = Vector3(0, 0.6, 0)

	# 演出按裁决器的实付结果走：网络端同样取服务器返回的 resolution。
	# 引擎先落地，牌桌暂不同步；确认成功后仍按「现金吸走 → 产出落下」播放。
	var log_before: int = state.log.size()
	var settled := recorded
	if recorded.is_empty():
		var flow := _round_flow()
		settled = await resolve.call() if resolve.is_valid() else await flow.produce(combo_idx)
	if not _session_current(session):
		return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}
	var resolution: Dictionary = settled.get("resolution", {})
	if not settled.get("ok", false) or resolution.is_empty():
		for e in combo_entities:
			if is_instance_valid(e):
				e.set_highlight(false)
		_show_message(str(settled.get("reason", "未收到组合结算结果")), Palette.semantic("danger"))
		_sync_entities()
		_update_hud()
		return settled
	var resolved: bool = resolution.get("resolved", false)
	if resolved:
		await _consume_recipe_visual(owner, combo, resolution.get("paid_uids", []))
		if not _session_current(session):
			return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}
		if eval["type"] == "upgrade":
			var material_count: int = _table_actions.consume_upgrade(combo, combo_center)
			if material_count > 0:
				await _drawer_timer(_suck_batch_time(material_count)).timeout
				if not _session_current(session):
					return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}
	# 取结算产生的最后一条战报作为结果展示（含实际移除数/保护提示/作废原因）。
	# 过一遍 _render_log：引擎存的是 { fmt, args }，公司名在这里才按视角定
	var result_msg := ""
	for i in range(log_before, state.log.size()):
		result_msg = _render_log(state.log[i])

	var burst_pos := combo_center + Vector3(0, 0.6, 0)

	var stamped_card: CardEntity = null
	if not resolved:
		# 作废不销毁幸存卡：只在核心盖一个章，并保持到结果那一拍结束。
		sfx.play("combo_broken")
		for e in combo_entities:
			if is_instance_valid(e):
				e.set_highlight(true, Color(1.3, 0.5, 0.5))
				if e.def_id == str(eval["leader"]) and stamped_card == null:
					stamped_card = e
		if stamped_card:
			stamped_card.set_void_stamp(true)
		var message := result_msg if result_msg != "" else "%s 的「%s」%s，整组作废！" % [owner_name, leader_name, resolution.get("reason", "")]
		_show_message(message, Palette.semantic("danger"))
	else:
		_table_actions.combo_feedback(eval, burst_pos, combo)
		# 把战报结果摆上台面：实际产出/移除数/保护格挡，光放音效读不出这些数
		if result_msg != "":
			var msg_color := Palette.semantic("danger") if eval["type"] == "attack" else Palette.semantic("success")
			_show_message(result_msg, msg_color)

	# 只在确认产出成功时让新资源从组合中心飞出。
	_sync_entities(combo_center if resolved and eval["type"] != "attack" else null)
	board.prune_groups()
	_update_hud()
	await _drawer_timer(BEAT_COMBO_DONE).timeout
	if not _session_current(session):
		return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}
	for e in combo_entities:
		if is_instance_valid(e):
			e.set_highlight(false)
	if is_instance_valid(stamped_card):
		stamped_card.set_void_stamp(false)
	return settled

## 实体差分同步：消失的撕掉，新增的落入。
##
## from_pos —— 这一批新卡从哪儿飞出来。结算时传产出它们的那个组合的位置，
## 现金/用户就是从组合上迸出来的而不是凭空出现；其余场合传 null（直接落位）
func _sync_entities(from_pos = null) -> void:
	# 测试替身/运行时声音切换都通过main.sfx生效，公用CardMotion不缓存旧音效池。
	if is_instance_valid(_card_motion):
		_card_motion.sfx = sfx
	var state_uids := {}
	for who in [my_seat, foe_seat]:
		for c in state.players[who]["cards"]:
			state_uids[c["uid"]] = who
	# 正常受击、付款和升级已分别由撕毁、付款吸入、材料收束处理。
	# 差分兜底中尚未移除的卡仍用逐张撕开，避免快照修复时残留实体。
	#
	# 结算消耗逐张错开；攻击则把命中的 N 张抓成一叠同时撕开。一次吃掉 N 张
	# 全部同时撕开的话读作一团，数不出吃了几张。
	# 同时把这一批登记进 _tear_until_ms —— 这条路没有调用方 await 它，
	# 靠的是 _tears_drained 兜住（结算重画桌子前会等），
	# 不登记的话错开还没轮到的那几张会被连补间带卡一起清掉
	# 从桌面**当场**摘登记（board.drop_card），只把「撕开」这段演出错开 ——
	# 和攻击那边一个写法（_animate_removed 先 drop_card 再 _delayed_flyout）。
	# 摘登记也一起延迟的话，这几张牌在错开的那 n×0.08s 里还留在 board.cards：
	# 点得到、射线打得着、理牌还会把它们排进摞，而引擎里它们已经不存在了
	# 起飞时刻也排在那条公用队上（同 _animate_removed）：结算里
	# 差分移除可能紧跟上一批受击，
	# 各自从 0 数的话两批会重叠成一团
	var now := _animation_now_ms()
	var slot := maxi(_tear_slot_ms, now)
	var gone := 0
	for uid in entities.keys():
		if not state_uids.has(uid):
			if is_instance_valid(entities[uid]):
				var e: CardEntity = entities[uid]
				board.drop_card(e)
				_delayed_flyout_torn(e, Vector3(0, 0, 1.0),
					float(slot - now) / 1000.0)
				slot += int(TEAR_STAGGER * 1000.0)
				gone += 1
			entities.erase(uid)
	if gone > 0:
		_tear_slot_ms = slot
		_tear_until_ms = maxi(_tear_until_ms,
			slot - int(TEAR_STAGGER * 1000.0) + int(TEAR_TIME * 1000.0))
	# 先数一遍这一批有几张要新建：飞入动画要按「第几张 / 共几张」错开起飞，
	# 让 output_n 张产出看着就是 output_n 张（见 _fly_from）
	var to_spawn: Array = []
	for who in [my_seat, foe_seat]:
		for c in state.players[who]["cards"]:
			if not entities.has(c["uid"]):
				to_spawn.append([who, c])
	for i in to_spawn.size():
		var who = to_spawn[i][0]
		var c: Dictionary = to_spawn[i][1]
		# 落点：结算期间直接飞进左侧资源带的分组席位，其余场合是该资源堆锚点
		# 附近的空位。两条都不压已组好的牌（见 layout.arrival_spot）
		var e := _spawn_entity(c, layout.arrival_spot(who, c),
			who == my_seat, from_pos, i, to_spawn.size())

## 事件明确选择动效语义：购买收束、产出上升、攻击纸屑、升级扩环。
func _event_feedback(event: String, pos: Vector3, color: Color, amount := 16) -> void:
	if drawer_window and not drawer_window.is_expanded():
		return
	UIMotion.play(self, event, pos, color, amount)

# ---------- 回合推进 ----------

func _next_round() -> void:
	var session := _session_generation
	# 一条意图管两件事（end_round + start_round），顺带把攻击点数池清掉：
	# 下一回合要能重新装弹（见 IntentApply._next_round）
	await pipe.next_round()
	if not _session_current(session):
		return
	_sync_entities()   # 兜底：结算漏生成的卡按空位落点补齐

	# 重摆公共区（正常流程在组卡阶段已收走，_respawn_market 先清一遍兜底防重复）
	_respawn_market()

	phase = PHASE_ACTION
	layout._layout_bot_idle()      # 回合开始：BOT 散牌归堆
	# 玩家侧不再自动理牌：桌面归玩家自己摆。
	# _tidy_player_idle 会先解散全部纯资源摞再整片重排，回合一开就把玩家
	# 上一回合摆好的现金堆、用户堆洗了个位置；更要紧的是它会把结算刚在左侧
	# 摞好的那几摞（见 _stack_settled）当成「上轮理牌产物」解散掉。
	# 现金要成摞才好整摞付账，这件事现在由到货时就地摞好来保证（_stack_arrivals）
	_update_hud()
	_begin_action_phase()

# ---------- 终局 ----------

## 终局标题：赢了也不夸、输了不安慰，每局随机一句。
## 用 randi 而不是 state 的种子随机数：这只是句台词，不该动战局的随机序列
## （同一个种子的对局要能复现，无头模拟器也在按它跑）
const WIN_TAUNTS = ResultPresentation.WIN_TAUNTS
const LOSE_TAUNTS = ResultPresentation.LOSE_TAUNTS

func _show_game_over() -> void:
	if replay_session != null:
		return
	if phase == PHASE_OVER:
		return   # 防重入：典当冲线的延时分支和正常流程可能都调到这里
	_invalidate_session()
	phase = PHASE_OVER
	_set_mascot_state("success" if state.winner == my_seat else "defeat")
	board.cancel_drag()
	board.attack_mode = false
	board.input_locked = true   # 面板背后的牌不该还能拖
	btn_pass.disabled = true
	# 认输按钮跟着灰掉，理由和 btn_pass 一样：面板背后不该还有能点的东西。
	# _on_resign_pressed 开头那道 PHASE_OVER 也拦得住，但那是**点下去之后**才拦
	# —— 一个点得动却什么都不发生的按钮，和「卡住了」在屏幕上分不开
	if btn_resign:
		btn_resign.disabled = true
		btn_resign.text = TXT_RESIGN
	_resign_armed = false
	_update_hud()
	var result := ResultPresentation.create(self, state, my_seat, sfx, _on_restart, "再战一局", drawer_presentation != null)
	var canvas: CanvasLayer = result["layer"]
	game_over_panel = result["panel"]
	var vb: VBoxContainer = result["body"]
	var btn: Button = result["button"]
	if _net != null:
		_add_rematch_row(vb, btn)
	# 在全部控件（含联机按钮）建好后接入，主题、尺寸、收放走同一入口。
	# 必须同步注册：联机局可能在抽屉已经收起时才收到胜负结果。
	if drawer_presentation:
		drawer_presentation.register_result_panel(canvas)

## 联网局的终局面板：把「再战一局」拆成两个意思。
##
## 单机局里它只有一个意思（重开本机这一局）。联网局有两个，而且后果差很远：
##   再来一局 —— 要**对手也点**，双方留在房间里接着打（rematch 协议）
##   退出房间 —— 单方面就能做，对手侧照 foe_left 收场
## 一个按钮兼两个意思的话，点的人不知道自己在做哪件 —— 而这两件都不可撤销
## （退了要重新对房间码，投了票没有撤票消息，见 Protocol.REMATCH）。
##
## 原来那个按钮在这里被改字成「退出房间」而不是删掉：它已经接好了 _on_restart，
## 而 _on_restart 在联网局里做的正是退房（_reset_session_flags 断连接、退回单机局）
func _add_rematch_row(vb: VBoxContainer, exit_btn: Button) -> void:
	exit_btn.text = "退出房间"
	exit_btn.set_meta("drawer_primary", false)
	var again := Button.new()
	again.name = "ResultRematch"
	again.set_meta("drawer_primary", true)
	again.text = "再来一局"
	again.add_theme_font_override("font", Fonts.zh())
	again.add_theme_font_size_override("font_size", 24)
	again.custom_minimum_size = Vector2(220, 42)
	# 投票进度显示在按钮上，不另占一行：等待状态只在投票期间存在。
	again.pressed.connect(func() -> void:
		if _net == null:
			return
		_net.request_rematch()
		again.disabled = true
		again.text = "等对手…")
	vb.add_child(again)
	_rematch_btn = again
	# 对手先点的话这边要能看见。信号是**每局重连一次**的：面板每局新建，
	# 上一局那个按钮已经 queue_free 了，lambda 里捕获的引用是野的
	if not _net.rematch_voted.is_connected(_on_rematch_voted):
		_net.rematch_voted.connect(_on_rematch_voted)
	if not _net.rematch_started.is_connected(_on_rematch_started):
		_net.rematch_started.connect(_on_rematch_started)

## 终局面板上那个「再来一局」。面板一关就置空 —— 见 _on_rematch_voted
var _rematch_btn: Button = null

## 投票进度变了。**只处理对手那一票**：自己那票在按钮的 pressed 里已经改过字了
## （那时候还没往返，等服务器广播回来才改的话点下去有一拍没反应）
func _on_rematch_voted(votes: Array) -> void:
	if _rematch_btn == null or not is_instance_valid(_rematch_btn):
		return
	if votes.has(foe_seat) and not votes.has(my_seat):
		_rematch_btn.text = "对手想再来一局 →"
		_show_message("对手想再来一局", Palette.semantic("info"))

## 收掉终局面板 + 把桌子清空。**两条重开路径共用**（单机的 _on_restart、
## 联网的 _on_rematch_started）—— 两处各抄一遍的话，往后加一样「一局之内有效」
## 的东西只清一处，而漏掉的那条路要等到第二局才出症状。
## 返回 false = 面板已经收过了（防二次进入）
func _teardown_for_new_game(force := false) -> bool:
	if game_over_panel == null and not force:
		return false   # queue_free 是延迟的，按钮当帧仍可点：防二次进入
	_invalidate_session()
	# 要释放的是整层 CanvasLayer，不是面板的直接父节点（那是居中用的
	# CenterContainer）：只放掉容器会把空的 CanvasLayer 留在场景里，每重开一局漏一层
	var layer: Node = game_over_panel
	while layer != null and not (layer is CanvasLayer):
		layer = layer.get_parent()
	if layer != null:
		layer.queue_free()
	game_over_panel = null
	_rematch_btn = null          # 面板连着这个按钮一起放掉了，留着引用就是野的
	layout.end_arrivals()        # 结算中途重开：到货台账不许留给下一局
	board.cancel_drag()          # 清掉可能还黏在光标上的牌 + 悬垂的 _hover_group
	for g in board.groups.duplicate():
		board._remove_group(g)
	board.groups.clear()
	board.cards.clear()          # 上局的实体已全部释放，注册表必须清空
	board.attack_mode = false
	board.input_locked = false
	_hide_attack_label()
	_clear_attack_hl()
	return true

func prepare_network_cards() -> Dictionary:
	# 等人期间保留原单机局及录像，不能在这里热换它的价格和配方。
	if CardDB.loaded_from != CardConfig.DEFAULT_PATH:
		return {"ok": false, "reason": "当前对局使用自定义卡表；请先恢复默认卡表并开启新局，再进入联网对战"}
	# 内嵌服务器启动仍会加载默认规则；它与场景共享 CardDB，先收完搜索。
	_think.flush()
	return {"ok": true, "path": CardConfig.DEFAULT_PATH, "custom": false}

## 搜索只隔离对局状态，规则仍读全局 CardDB；任何重载之前都必须 join。
func _load_card_rules(solo: bool) -> Dictionary:
	_think.flush()
	return CardConfig.apply_solo() if solo else CardConfig.apply_default()

func _apply_solo_cards_or_stop() -> bool:
	var loaded := _load_card_rules(true)
	if loaded.get("ok", false) or loaded.get("used_default", false):
		return true
	var reason := str(loaded.get("reason", "卡表加载失败"))
	push_error(reason)
	set_process(false)
	set_physics_process(false)
	if DisplayServer.get_name() != "headless" and not OS.has_feature("web"):
		OS.alert(reason, "无法启动指定配置")
	get_tree().quit(1)
	return false

func card_config_info() -> Dictionary:
	var active := CardDB.loaded_from
	return {"network_locked": _net != null or _host != null, "selected": CardConfig.selected_path(),
		"launch_locked": CardConfig.has_launch_override(), "replay_locked": replay_session != null,
		"active": active, "default": CardConfig.DEFAULT_PATH,
		"pending": CardConfig.selected_path() != "" and active != CardConfig.selected_path()}

func choose_card_config(path: String) -> Dictionary:
	if replay_session != null:
		return {"ok": false, "reason": "请先退出录像，再修改卡牌配置。"}
	if _net != null or _host != null:
		return {"ok": false, "reason": "联网期间只使用默认 cards.json"}
	var result := CardConfig.select(path)
	if not result["ok"]:
		return result
	return {"ok": true, "reason": "已保存；下一局单机对局生效", "path": result["path"]}

func clear_card_config() -> Dictionary:
	if replay_session != null:
		return {"ok": false, "reason": "请先退出录像，再修改卡牌配置。"}
	if _net != null or _host != null:
		return {"ok": false, "reason": "联网期间只使用默认 cards.json"}
	if CardConfig.has_launch_override():
		return {"ok": false, "reason": "本次启动由 --cards-config 指定卡表；关闭游戏后重新启动才能恢复默认"}
	var cleared := CardConfig.clear_selection()
	if not cleared.get("ok", false):
		return cleared
	return {"ok": true, "reason": "已恢复默认；下一局单机对局生效"}

func apply_selected_card_config() -> Dictionary:
	if replay_session != null:
		return {"ok": false, "reason": "请先退出录像，再应用配置并开始新局。"}
	if _net != null or _host != null:
		return {"ok": false, "reason": "联网期间只使用默认 cards.json"}
	if _local_turn_flows > 0 or (board != null and not board._drag_cards.is_empty()):
		return {"ok": false, "reason": "当前行动尚未结束，请在回合边界切换卡牌配置"}
	var loaded := _load_card_rules(true)
	if not loaded.get("ok", false):
		return {"ok": false, "reason": str(loaded.get("reason", "卡表加载失败"))}
	if not _teardown_for_new_game(true):
		return {"ok": false, "reason": "当前牌桌还没有准备好"}
	_reset_session_flags()
	state = GameState.new()
	state.new_game()
	_rebuild_pipe()
	_sync_round()
	return {"ok": true, "reason": "已应用卡牌配置并开始新单机局"}

func _on_restart() -> void:
	if not _teardown_for_new_game():
		return
	_reset_session_flags()
	if not _apply_solo_cards_or_stop():
		return
	state = GameState.new()
	state.new_game()
	# 换 state 就必须重建管道 —— 漏掉这句的后果见 _rebuild_pipe 的注释：
	# 第二局什么都做不了，而且不报错
	_rebuild_pipe()
	_sync_round()

## 服务器说新局开始了（双方都点了「再来一局」）。
##
## 和 _on_restart 的差别只有三样，但每一样都是必需的：
##   连接留着 —— _reset_session_flags(true)。断了就没有对手了
##   state 不换 —— net 那条 rematch_start 已经把新局**覆盖进**同一个对象了
##     （NetTransport._on_rematch_start → _adopt → StateCodec.restore）。
##     这里再 new 一个的话，界面读的是空局、服务器那份没人读，桌上一张牌都没有
##   不开阶段 —— 走 _respawn_all 而不是 _sync_round：第一个行动阶段由服务器
##     那条 phase 开（见 _on_net_phase），本地自己开一个会让按钮亮着而点不动
##
## 座位按服务器给的换：先手在局间轮换（net/room.gd 的 reset_for_rematch），
## 也就是说这一局我可能坐到了另一个座位上 —— 摆放层、draggable、战报视角
## 全按 my_seat 走，不换就是「我的牌摆在远侧半区，而且我能拖对手的牌」
## （和 _reset_session_flags 里 set_seats 那段说的是同一件事）
func _on_rematch_started(mine: String, foe: String) -> void:
	if _net == null or pipe != _net:
		return
	if not _teardown_for_new_game():
		return
	_reset_session_flags(true)
	set_seats(mine, foe)
	state = _net.state()
	pipe = _net
	_attach_net_state_signals(_net)
	_retarget_tape()   # 联网重开：又是新的一局，录像从这一刻重新开始
	_respawn_all()
	# 和 begin_net_game 末尾一样：阶段还没来，按钮先灰着 ——
	# 亮着的按钮点下去会被服务器 not_your_turn 拒掉，玩家看到「能点但没反应」
	board.input_locked = true
	btn_pass.text = TXT_BOT_ACTING
	btn_pass.disabled = true
	_show_message("新的一局（%s先手）" % [
		"你" if state.draw_first == my_seat else "对手"], Palette.semantic("success"))

## 重开一局要清掉的**跨局残留量**。
##
## 单拎一个函数是因为这类 bug 全长一个样：某个成员活过了重开，
## 而它记的是上一局的事（bug 2 就是 pipe 活过了重开）。以后往 main 上加
## 「一局之内有效」的量时，清空的地方在这儿，不用再想一遍 _on_restart 该改哪
##
## 为什么这两个量非清不可：
##   - _drag_lease 记的是 uid，而 uid **跨局重用**（新的 GameState 从头发号）。
##     不清的话上一局那几个 uid 在新局里对应的是**另外几张牌**，布局绕开它们，
##     直到 2 秒超时才放回去 —— 期间还会弹一句「对手那边没动静」，
##     而这一局对手根本没拖过牌
##   - _foe_action_done 是「对方说他行动完了」。终局那一帧收到、
##     还没被 _await_foe_action 取走的话，它会活到下一局，
##     让新局对手的第一个行动阶段**一帧就过去**（联网局才有的症状）
##   - _net / _foe_remote 记的是「对手是房间里那个人」。**单机路径**下
##     「再战一局」只重置本机这一局：不清的话新局第一个对手回合会停在
##     _await_foe_action 里等一条永远不来的 action_done ——
##     画面不报错，就是**再也不动了**。所以那条路上重开等于退出房间：
##     断开连接，对手侧照 foe_left 收场，本机退回单机局。
##
##     联网局现在有第二条路：rematch（见 net/room.gd 的 rematch 投票与重开）。双方都点「再来一局」时
##     连接**要留着**，于是这个函数带一个 keep_net —— 见那个参数的说明
##
## keep_net: true 时不断连接、不改座位、不放回联网入口。
## rematch 走这一支：那三件事都由服务器那条 rematch_start 决定
## （座位会变 —— 先手在局间轮换），本机自己改一份就是两处各说各话
func _reset_session_flags(keep_net := false) -> void:
	_opening_action_pending = true
	_foe_online = true
	_show_foe_offline_notice(false)
	_foe_completed_round = -1
	_attack_actor = ""
	_drag_lease.clear()
	_drag_lease_t = 0.0
	_foe_action_done = false
	_foe_combo_shown = 0
	# 思考秒表也一局一次性。放在 keep_net 那道返回**之前**：rematch 也要清 ——
	# 上一局的趟数和平均值不能混入新局，而且联网局和单机局
	# 量的还不是同一件事（一个含网络往返，一个是纯搜索）
	ThinkClock.reset()
	# 撕牌的截止时刻一局一次性：上一局末尾那批撕到一半就重开的话，
	# 新局第一次结算会白等那几百毫秒（而新局桌上根本没有在撕的牌）
	_tear_until_ms = 0
	# 这个量是「服务器发来的第一个 action 阶段已经认过了」，一局一次性。
	# rematch 时**必须**跟着清：新局的第一个行动阶段还是靠服务器那条 phase 开的
	# （见 _on_net_phase），不清的话新局双方都是灰按钮，谁也动不了
	_net_phase_seen = false
	# 同上，一局一次性：不清的话 _on_net_phase 里那道「桌子没摆就不开阶段」的门
	# 在新局里读到的是上一局的 true，而 rematch 是自己调 _respawn_all 摆桌子的
	# （_on_rematch_started），两处对「摆过没有」的看法就分叉了
	_net_table_drawn = false
	# 认输按钮复位。放在 keep_net 那道返回**之前** —— rematch 也要它：
	# 上一局如果就是认输结束的，这个按钮此刻是禁用的、字还停在「真的认输？」，
	# 不复位的话新局开起来了却认不了输（而且按钮上写着一句上一局的话）
	if btn_resign:
		btn_resign.disabled = false
		btn_resign.text = TXT_RESIGN
		btn_resign.set_meta("danger_armed", false)
	_refresh_button_theme()
	_resign_armed = false
	_connection_mascot_state = "idle"
	_set_mascot_state("idle")
	if keep_net:
		return
	# 座位回到单机局那一对。**这一句是「再战一局」在联网局之后的必需项**：
	# 上一局如果是远端那位（my_seat = BOT），不改回来的话新的单机局里
	# 我坐 BOT 座、本地 BOT 驱动 PLAYER 座 —— 桌子左右不镜像（scenes/main.gd 的拖拽广播与租约处理），
	# 于是我的牌摆在远侧半区、对手的摆在近侧，而且**我能拖对手的牌**
	# （摆放层按 my_seat 判近侧，draggable 按 my_seat 给）
	set_seats(str(SOLO_SEATS[0]), str(SOLO_SEATS[1]))
	if _net != null:
		# 先摘信号再 close：close 会让对端/本端走 disconnected，而那条回调
		# （_on_net_down）现在除了收回租约还会**锁输入 + 灰掉结束回合**。
		# 不摘的话「重开 = 退出房间」这条路会把刚开的单机局一起锁死：
		# 新桌子摆好了，一张牌也拖不动、回合也结束不了，而且不报错
		_detach_net_signals(_net)
		_net.close()
		_net = null
	# 房是本机开的话，服务器也要跟着收 —— 退回单机局之后没人再需要它，
	# 而它占着端口：下次开房会顺延到另一个端口，
	# 而玩家可能还在照着上一次报出来的地址叫对手连（见 stop_local_host）
	stop_local_host()
	set_foe_remote(false)
	# 把联网入口放回来，并撤掉断线时那道锁。
	#
	# 这两件事是一对：上一局如果是**断线**结束的，_on_net_down 已经锁了输入、
	# 灰了结束回合按钮；新的单机局不撤的话是「桌子摆好了但一步也走不了」。
	# 而 btn_net 是开联网局时藏掉的（局中再点会开出第二条连接），
	# 回到单机局就该重新点得到 —— 不放回来的话「联网 → 重开 → 想再联网」
	# 这条路上没有入口，只能重启游戏
	if btn_net:
		btn_net.visible = true
	if board:
		board.input_locked = false
	if btn_pass:
		btn_pass.disabled = false

# ---------- HUD ----------

func _update_hud() -> void:
	_update_thinking_hint(true)
	# HUD 读的是资源总量（破百看这个）→ 计量名。
	#
	# 两个读数各带一个括号（scenes/main.gd 的 HUD 与面板实现）：资源不对称之后一个总数说明不了局面 ——
	# 「资金 34」里有 8 块是这回合就要付出去的，真实可用是 26；
	# 「用户 12」里有 5 个闲置，那是发不了电的资本。两个数都得看得见括号里那半截，
	# 玩家才会想「该买张核心卡开席位了」
	var piles: Array = _core_piles()
	var due: int = state.pending_pay(my_seat, piles)
	var dep: Dictionary = state.user_deployment(my_seat, piles)
	var cash_txt := "%s %d" % [
		CardDB.res_label(CardDB.RES_CASH), state.resource_count(my_seat, CardDB.RES_CASH)]
	# 待付 0 就不写括号：每回合都挂一个「（本回合待付 0）」是常态噪音，
	# 而这一条的价值全在「非零时被看见」
	if due > 0:
		cash_txt += "（本回合待付 %d）" % due
		# 付完会归零 → `Settle._pay_recipe` 当场拒付、整组作废（README.md §「2.6 组合与结算」 那条护栏）。
		# 光写「待付 10」不够：手上正好 10 的时候读起来像刚好付得起，
		# 而结算时它一分钱都产不出。归零差的就是最后这 1 块
		if state.resource_count(my_seat, CardDB.RES_CASH) \
				+ state.pending_cash_income(my_seat, piles) - due <= 0:
			cash_txt += "⚠ 付完归零，整组会作废"
	var user_txt := "%s %d" % [
		CardDB.res_label(CardDB.RES_USER), state.resource_count(my_seat, CardDB.RES_USER)]
	# 在岗/闲置反过来**一直写**：闲置为 0 是这条读数唯一的好消息，
	# 藏掉的话玩家分不清「全部在岗」和「这个读数没算」
	user_txt += "（在岗 %d / 闲置 %d）" % [int(dep["on_duty"]), int(dep["idle"])]
	lbl_player_res.text = "你的公司 · %s · %s" % [cash_txt, user_txt]
	# 对手侧同样拆开。他的摞不在 board.groups 里（那是玩家能拖能典当的东西），
	# 得从 state.combos 现搭 —— 于是行动阶段读不到（那时 combos 是空的，
	# 见 pending_pay 的注释），**攻击阶段起才有数**。
	#
	# 而攻击阶段正是这条读数最该出现的时刻：他这一摞要付 6，我打掉他两块现金
	# 就能让 Settle._pay_recipe 拒付、整组作废（README.md §「2.6 组合与结算」）。
	# 显示待付金额，玩家才能在收手前判断对手是否付得起配方。
	var foe_piles: Array = []
	for combo in state.combos:
		if str(combo.get("owner", "")) == foe_seat:
			foe_piles.append({ "uids": combo.get("uids", []) })
	var foe_due: int = state.pending_pay(foe_seat, foe_piles)
	var foe_dep: Dictionary = state.user_deployment(foe_seat, foe_piles)
	var foe_cash := "%s %d" % [
		CardDB.res_label(CardDB.RES_CASH), state.resource_count(foe_seat, CardDB.RES_CASH)]
	if foe_due > 0:
		foe_cash += "（本回合待付 %d）" % foe_due
		# 对手侧同一条预警，读法反过来：这是「已经打够了，不用再补刀」的信号
		if state.resource_count(foe_seat, CardDB.RES_CASH) \
				+ state.pending_cash_income(foe_seat, foe_piles) - foe_due <= 0:
			foe_cash += "⚠ 他付完归零，整组会作废"
	var foe_user := "%s %d" % [
		CardDB.res_label(CardDB.RES_USER), state.resource_count(foe_seat, CardDB.RES_USER)]
	# 对手的在岗/闲置只在**问得出来**的时候写：他的摞一张不在 combos 里时
	# 算出来的是「在岗 0 / 闲置 12」，那不是局面，那是没数据。
	# 玩家侧不会遇到这个（board.groups 一直在），所以只有这一侧要这道判断
	if not foe_piles.is_empty():
		foe_user += "（在岗 %d / 闲置 %d）" % [int(foe_dep["on_duty"]), int(foe_dep["idle"])]
	lbl_bot_res.text = "对手公司 · %s · %s" % [foe_cash, foe_user]
	if is_instance_valid(hud_player_card):
		hud_player_card.set_resources(state.resource_count(my_seat, CardDB.RES_CASH),
			state.resource_count(my_seat, CardDB.RES_USER), due,
			int(dep["on_duty"]), int(dep["idle"]), true,
			due > 0 and state.resource_count(my_seat, CardDB.RES_CASH)
				+ state.pending_cash_income(my_seat, piles) - due <= 0)
	if is_instance_valid(hud_bot_card):
		hud_bot_card.set_resources(state.resource_count(foe_seat, CardDB.RES_CASH),
			state.resource_count(foe_seat, CardDB.RES_USER), foe_due,
			int(foe_dep["on_duty"]), int(foe_dep["idle"]), not foe_piles.is_empty(),
			foe_due > 0 and state.resource_count(foe_seat, CardDB.RES_CASH)
				+ state.pending_cash_income(foe_seat, foe_piles) - foe_due <= 0)
	if drawer_presentation:
		drawer_presentation.compact_header_resources()
	else:
		# 等文字最小尺寸缓存更新后再收紧/居中，风险徽章消失时也能恢复原宽。
		_position_table_hud.call_deferred()
	# 防御 Buff 保护状态 → 卡牌盾牌标记（防御卡在组合中即永久保护组内对应资源卡）
	_refresh_shields()

## 每帧只核对轻量输入；保护与光环按摞计算一次，牌组不变就复用结果。
var _shield_signature: Array = []
var _shield_uids := {}
var _buff_active_uids := {}

func _refresh_shields() -> void:
	if state == null:
		return
	var records := {}
	var signature: Array = [state.get_instance_id(), CardDB.CARDS.hash(), CardDB.GAME.hash()]
	for owner in [my_seat, foe_seat]:
		var by_uid := {}
		var card_keys: Array = []
		for card in state.players.get(owner, {}).get("cards", []):
			by_uid[int(card["uid"])] = card
			card_keys.append([card["uid"], card["def_id"]])
		records[owner] = by_uid
		signature.append([owner, card_keys])
	var groups: Array = []
	var grouped := {}
	for group in board.groups:
		var uids: Array = []
		var owner := my_seat
		for card in group["cards"]:
			if is_instance_valid(card):
				owner = my_seat if card.draggable else foe_seat
				uids.append(card.uid)
				grouped[card.uid] = true
		groups.append({"owner": owner, "uids": uids})
		signature.append([owner, uids])
	for combo in state.combos:
		# 布局占位组不具备规则评估，不参与护盾；真实裁决组必须有 eval。
		if not combo.get("eval") is Dictionary:
			continue
		# 权威组合保留原始 eval：破组之后不能用幸存材料重新定义保护额度。
		groups.append(combo)
		signature.append([combo["owner"], combo["uids"].duplicate(), combo["eval"].duplicate(true)])
	if signature != _shield_signature:
		_shield_signature = signature
		_shield_uids.clear()
		_buff_active_uids.clear()
		for group in groups:
			_cache_group_shields(group, records[group["owner"]], grouped)
	for uid in entities:
		var card: CardEntity = entities[uid]
		if not is_instance_valid(card):
			continue
		card.set_shield(_shield_uids.has(card.uid))
		var buff_type := str(CardDB.get_def(card.def_id).get("buff_type", ""))
		if buff_type != "":
			var tint := Color(0.42, 0.66, 0.95) if buff_type.begins_with("protect_") else Color(1.0, 0.85, 0.35)
			card.set_buff_glow(_buff_active_uids.has(card.uid), tint)

func _cache_group_shields(group: Dictionary, records: Dictionary, grouped: Dictionary) -> void:
	var cards: Array = []
	var live_uids: Array = []
	for uid in group["uids"]:
		if records.has(int(uid)):
			cards.append(records[int(uid)])
			live_uids.append(int(uid))
	var effect := ComboRules.evaluate(cards)
	if not effect.get("valid", false):
		return
	var owner: String = group["owner"]
	var authoritative := group.has("eval")
	var combo := group if authoritative else {"owner": owner, "uids": live_uids, "eval": effect}
	var protected_cash := state.protected_uids(owner, combo, CardDB.RES_CASH)
	var protected_user := state.protected_uids(owner, combo, CardDB.RES_USER)
	for uid in protected_cash.keys() + protected_user.keys():
		if not authoritative or not grouped.has(uid):
			_shield_uids[uid] = true
	for card in cards:
		var uid := int(card["uid"])
		if authoritative and grouped.has(uid):
			continue
		var buff_type := str(CardDB.get_def(card["def_id"]).get("buff_type", ""))
		var active := false
		match buff_type:
			"output_x2": active = effect["type"] == "production" and CardDB.buff_mult(buff_type) > 1
			"attack_x2": active = effect["type"] == "attack" and CardDB.buff_mult(buff_type) > 1
			"user_fill": active = effect.get("filled_by_fission", false)
			"protect_user": active = not protected_user.is_empty()
			"protect_cash": active = not protected_cash.is_empty()
		if active:
			_buff_active_uids[uid] = true

func _buff_effect_active(buff: CardEntity, _buff_type: String) -> bool:
	_refresh_shields()
	return _buff_active_uids.has(buff.uid)

func _is_card_shielded(card: CardEntity) -> bool:
	_refresh_shields()
	return _shield_uids.has(card.uid)

## 说一句话。屏幕上一份（提示条，常驻到下一句顶掉它），
## 记录里一份（scenes/msg_log.gd，翻得回去）。
##
## **这里从前有一条补间**：亮 MSG_HOLD 秒然后 MSG_FADE 秒淡到 0。
## 用户原话「游戏开局左上角出现了一行字又消失了，杜绝这种突然出现又消失的提示，
## 既看不清楚，也无法复现」—— 那两个理由分别对应现在这两行：
##
##   - **看不清楚** → 去掉补间。这条提示留在屏幕上，直到下一条来换它。
##     没有「自己消失」这一步了，读多久是玩家的事
##   - **无法复现** → 光不淡出治不了这一半：两条提示前后脚来的话
##     （比如「买不起」紧跟着对手行动那句），第一条照旧是被顶掉、找不回来。
##     所以每一条都同时进 msg_log
##
## record_text 允许网络状态保留简短摘要，完整的重连资料只入可复制的提示记录。
## tooltip 使用屏幕摘要，不把 IP、端口或房间码重新漏回牌桌。
func _show_message(text: String, color: Color, record_text := "") -> void:
	lbl_msg.text = text
	lbl_msg.tooltip_text = text
	lbl_msg.add_theme_color_override("font_color", Palette.readable_ink(color, Palette.semantic("surface")))
	if drawer_presentation:
		drawer_presentation.present_message(text, color)
	# msg_log 可能还没搭起来：_setup_hud 之前就有话说的路是有的
	# （比如场景刚 ready 时的联网回调）。少记一条比崩一次好
	if msg_log:
		msg_log.append(record_text if record_text != "" else text, color, state.round_num if state else 0)

# ---------- 录像播放 ----------
func open_replay_picker() -> void:
	if web_mode:
		# 浏览器的文件选择必须直接来自用户点击，不能推迟到下一帧。
		var session := _session_generation
		web_files.request_json(func(result: Dictionary):
			if not _session_current(session) or result.get("cancelled", false):
				return
			if not result.get("ok", false):
				_show_message(str(result.get("reason", "读取文件失败")), Palette.semantic("danger"))
				return
			_load_replay(result["path"]))
		return
	# 菜单自己的关闭/焦点事件结束后再建立表单，避免同一输入回调内重入。
	_show_replay_picker.call_deferred()

func _show_replay_picker() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if not is_instance_valid(_replay_picker):
		_replay_picker = ReplayPicker.new()
		_replay_picker.bind(self)
		add_child(_replay_picker)
	else:
		_replay_picker.show()

func _load_replay(path: String) -> Dictionary:
	if _net != null or _network_join_pending():
		var failure := {"ok": false, "reason": "请先退出局域网对局再读入录像。"}
		_show_message(failure["reason"], Palette.semantic("danger"))
		return failure
	var loaded: Dictionary = ReplaySession.load_path(path)
	if not loaded.get("ok", false):
		_show_message(str(loaded.get("reason", "录像读取失败")), Palette.semantic("danger"))
		return loaded
	# 切换前保存当前已操作的对局，读取失败绝不替换牌桌。
	if replay_session == null and tape.recording() and tape.size() > 0:
		if tape.save() == "":
			var failure := {"ok": false, "reason": "当前对局保存失败，未切换录像。"}
			_show_message(failure["reason"], Palette.semantic("danger"))
			return failure
	_replace_scene_for_replay.call_deferred(loaded["session"])
	return loaded

func _replace_scene_for_replay(session: RefCounted) -> void:
	# 替换由独立静态回调完成；不能旧场景仍活着时创建会更改根窗口的新抽屉。
	ReplayTransition.replace.call_deferred(self, session)

func _render_replay_step(intent: Dictionary = {}, rebuild := true) -> void:
	state = replay_session.state
	pipe = LocalTransport.new(replay_session.applier)
	phase = replay_session.phase
	_actor = replay_session.actor
	board.attack_mode = false
	if rebuild:
		_respawn_all()
		TableSnapshot.restore(self, replay_session.view)
	board.input_locked = true
	if _replay_previous_button == null:
		_replay_previous_button = Button.new()
		_replay_previous_button.name = "ReplayPrevious"
		_replay_previous_button.text = "录像上一步"
		_replay_previous_button.pressed.connect(_replay_previous)
		var row: Node = btn_pass.get_parent()
		row.add_child(_replay_previous_button)
		row.move_child(_replay_previous_button, btn_pass.get_index())
		if drawer_presentation:
			drawer_presentation._apply_tree_theme(_replay_previous_button)
		else:
			_replay_previous_button.position = btn_pass.position - Vector2(200, 0)
	if _replay_step_input == null:
		_build_replay_seek_controls()
	_set_button("录像下一步", _replay_next)
	btn_pass.disabled = _replay_busy or replay_session.action_cursor >= replay_session.action_count() or replay_session.error != ""
	_replay_previous_button.disabled = _replay_busy or replay_session.action_cursor <= 0
	_replay_step_input.editable = not _replay_busy
	_replay_step_input.text = str(replay_session.action_cursor)
	_replay_jump_button.disabled = _replay_busy
	_replay_step_range.text = "行动步（0～%d）" % replay_session.action_count()
	btn_resign.text = "退出录像"
	btn_resign.accessibility_name = "退出录像，开始新对局"
	btn_resign.tooltip_text = "退出录像，开始新对局"
	btn_resign.disabled = _replay_busy
	var grouped_size := int(intent.get("_group_size", 1))
	_show_message(replay_session.caption(intent, grouped_size), Palette.semantic("info"))
	lbl_round.text = "录像 · 第 %d 回合 · 行动 %d / %d" % [state.round_num, replay_session.action_cursor, replay_session.action_count()]
	if drawer_presentation:
		drawer_presentation.compact_header_resources()

func _build_replay_seek_controls() -> void:
	var controls := VBoxContainer.new()
	controls.name = "ReplaySeekControls"
	controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	controls.add_theme_constant_override("separation", 2)
	var parent: Node = btn_pass.get_parent()
	parent.add_child(controls)
	parent.move_child(controls, _replay_previous_button.get_index())
	_replay_step_range = Label.new()
	_replay_step_range.add_theme_font_override("font", Fonts.zh())
	_replay_step_range.add_theme_font_size_override("font_size", 12)
	controls.add_child(_replay_step_range)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	controls.add_child(row)
	_replay_step_input = LineEdit.new()
	_replay_step_input.name = "ReplayStepInput"
	_replay_step_input.custom_minimum_size.x = 76
	_replay_step_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_replay_step_input.select_all_on_focus = true
	_replay_step_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_replay_step_input.accessibility_name = "录像行动步数"
	_replay_step_input.tooltip_text = "0 为初始状态；同一摞连续攻击算一步，与上一步、下一步一致。输入后回车或点击跳转。"
	_replay_step_input.text_submitted.connect(func(_text: String): _replay_jump())
	row.add_child(_replay_step_input)
	_replay_jump_button = Button.new()
	_replay_jump_button.name = "ReplayJump"
	_replay_jump_button.text = "跳转"
	_replay_jump_button.add_theme_font_override("font", Fonts.zh())
	_replay_jump_button.pressed.connect(_replay_jump)
	row.add_child(_replay_jump_button)
	if drawer_presentation:
		_replay_step_range.set_meta("drawer_font_base", 12)
		drawer_presentation._apply_tree_theme(controls)
	else:
		# 普通牌桌底部有独立消息栏；录像导航放到它上方并跟随窗口右下角。
		_replay_previous_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		_replay_previous_button.position = btn_pass.position - Vector2(200, 72)
		controls.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		controls.position = btn_pass.position - Vector2(370, 72)

func _replay_jump() -> Dictionary:
	if replay_session == null or _replay_busy:
		return {"ok": false, "reason": "请等待当前录像动画结束"}
	var text := _replay_step_input.text.strip_edges()
	var maximum := str(replay_session.action_count())
	# 先比较十进制位数，避免任意长输入经 to_int 溢出后误跳到另一个合法步骤。
	var digits := text.trim_prefix("+").lstrip("0")
	if not text.is_valid_int() or text.begins_with("-") or digits.length() > maximum.length() \
			or (digits.length() == maximum.length() and digits > maximum):
		var invalid := {"ok": false, "reason": "请输入 0～%s 范围内的整数行动步数" % maximum}
		_show_message(invalid["reason"], Palette.semantic("danger"))
		return invalid
	var result: Dictionary = replay_session.seek_action(text.to_int())
	if not result.get("ok", false):
		_show_message(str(result["reason"]), Palette.semantic("danger"))
		return result
	_hide_attack_label()
	_render_replay_step({}, result.get("changed", false))
	return result

func _replay_next() -> void:
	var session := _session_generation
	if replay_session == null or _replay_busy:
		return
	var advanced: Dictionary = replay_session.advance_action()
	if not advanced.get("ok", false):
		btn_pass.disabled = true
		_show_message(str(advanced["reason"]), Palette.semantic("danger"))
		return
	_replay_busy = true
	state = replay_session.state
	pipe = LocalTransport.new(replay_session.applier)
	phase = replay_session.phase
	_actor = replay_session.actor
	var display_intent: Dictionary = advanced["intent"].duplicate(true)
	display_intent["_group_size"] = int(advanced.get("group_size", 1))
	_render_replay_step(display_intent, false)
	await _replay_presenter.play_group(advanced["frames"])
	if not _session_current(session):
		return
	_replay_busy = false
	_render_replay_step(display_intent, false)

func _replay_previous() -> void:
	if replay_session == null or _replay_busy:
		return
	var result: Dictionary = replay_session.previous_action()
	if not result.get("ok", false):
		return
	_hide_attack_label()
	_render_replay_step()

func _exit_replay() -> void:
	if not _replay_busy:
		_replace_scene_for_replay.call_deferred(null)

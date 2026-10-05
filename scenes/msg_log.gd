# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

## 提示记录（右下角，默认收起）。屏幕上出现过的每一条提示都留在这儿。
##
## 为什么要有这一块 —— 用户原话：
##
## > 游戏开局左上角出现了一行字又消失了，杜绝这种突然出现又消失的提示，
## > 既看不清楚，也无法复现
##
## 那句话点的是两件事，而它们要两样东西才治得住：
##
##   1. **看不清楚** → 提示条不再淡出（`main._show_message` 去掉了那条补间）。
##      新的一条来了才换掉旧的，中间没有「自己消失」这一步
##   2. **无法复现** → 光不淡出还不够：两条提示隔 200 毫秒接连来的话，
##      第一条照旧是被顶掉、找不回来。所以要有一份**留着的记录**，
##      而且选得中、抄得走（同 scenes/save_notice.gd 那一块的理由）
##
## 引擎那边本来就有一份战报（`GameState.log`，按回合记、按视角念），
## 而在这条改动之前**屏幕上没有任何地方显示它** —— 唯一的读者是结算末尾
## 那句「取最后一条塞进提示条」，塞完 2.6 秒也就没了。
## 本面板让玩家能展开、滚动和复制完整战报。
##
## **默认收起**，理由不是省地方而是它盖住的东西：这一块在右下角，
## 底下是玩家自己的桌面区。而它有可点的东西（展开钮、滚动条、选文本），
## 所以 Frame 必须是 STOP —— 取牌是 board.gd 打射线做的，STOP 盖住的地方
## 点不到牌（同 scenes/palette_panel.gd 第 1 条、main._setup_res_panel）。
## 右上角那两块面板也是 STOP，但它们压的是对手牌区，不是玩家自己要拖的牌。
## 收起态只剩一条标题栏，挡住的是右下角那一小条；展开是玩家自己按的，
## 他按的时候就是想读记录，不是想拖牌
##
## 层号 12：在终局面板（10）之上 —— 一局打完最想翻的就是这份记录，
## 压在底下等于没有；在 SaveNotice（15）和 JoinPanel（20）之下 ——
## 那两块是有事要办的时候才立起来的
class_name MsgLog
extends CanvasLayer

## 记录条数上限。满了从最旧那头丢。
##
## 要有上限：一局长的话提示能攒到几百条，而 RichTextLabel 是全量重排的 ——
## 不封顶的话越往后按展开越卡，而卡的原因在屏幕上看不出来。
## 200 条按实测的提示密度够翻回上一两个回合，那也是「刚才发生了什么」
## 唯一有人会去问的范围
const MAX_LINES := 200

const MARGIN := 24.0
const BODY_W := 380.0
const BODY_H := 300.0
const UI_FONT_BODY := 17
const UI_RADIUS := 10

func _style(fill: Color, margin := 9, border := 2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = Palette.get_color("card", "frame")
	style.set_border_width_all(border)
	style.set_corner_radius_all(UI_RADIUS)
	style.set_content_margin_all(margin)
	return style

var _frame: PanelContainer
var _title: Label
var _toggle: Button
var _body: RichTextLabel
## 已经记下的条数（含被上限挤掉的）。标题栏报的是这个数 ——
## 报「现在存着几条」的话上限一到数字就不动了，而玩家读它是当计数器读的
var _total := 0

func _init() -> void:
	layer = 12

func _ready() -> void:
	_frame = PanelContainer.new()
	_frame.name = "Frame"
	# **STOP**：这一块有可点的东西（展开钮、滚动、选文本）。
	# 代价写在文件头 —— 收起态把它压到最小就是为了把代价压到最小
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), 12))
	add_child(_frame)

	var vb := VBoxContainer.new()
	vb.name = "VB"
	vb.add_theme_constant_override("separation", 6)
	_frame.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	_title = Label.new()
	_title.add_theme_font_override("font", Fonts.zh_bold())
	_title.add_theme_font_size_override("font_size", UI_FONT_BODY)
	_title.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	head.add_child(_title)
	_toggle = Button.new()
	_toggle.add_theme_font_override("font", Fonts.zh_bold())
	_toggle.add_theme_font_size_override("font_size", UI_FONT_BODY)
	_toggle.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	_toggle.add_theme_color_override("font_hover_color", Palette.get_color("card", "body"))
	_toggle.add_theme_stylebox_override("normal", _style(Palette.get_color("world", "table_frame"), 8))
	_toggle.add_theme_stylebox_override("hover", _style(Palette.plate_color("plate_cash", "face"), 8))
	_toggle.add_theme_stylebox_override("pressed", _style(Palette.plate_color("plate_cash", "band"), 8))
	_toggle.custom_minimum_size = Vector2(96, 38)
	_toggle.pressed.connect(_toggle_body)
	head.add_child(_toggle)

	_body = RichTextLabel.new()
	_body.name = "Body"
	_body.bbcode_enabled = true
	# 三样凑齐才叫「抄得走」：选得中、Ctrl-C 走得通、新的一条来了自己滚到底
	_body.selection_enabled = true
	_body.shortcut_keys_enabled = true
	_body.scroll_following = true
	_body.custom_minimum_size = Vector2(BODY_W, BODY_H)
	_body.add_theme_font_override("normal_font", Fonts.zh_bold())
	_body.add_theme_font_size_override("normal_font_size", UI_FONT_BODY)
	_body.add_theme_color_override("default_color", Palette.get_color("card", "body"))
	_body.visible = false
	vb.add_child(_body)

	_sync_head()
	_relayout()
	# 内容自己变尺寸时也要重算 —— 收起/展开那条路以外还有一条：
	# 标题里的条数从「9 条」长到「221 条」时框子跟着变宽，而 offset 是按
	# **当时**那个宽度算的负数（贴右下角），不重算的话多出来的那点直接捅出
	# 右边界（实测 17 像素，tools/_relayout_probe.gd）。
	# 这条路上玩家没点过任何东西，_toggle_body 里那句兜不住它
	# （bot_panel.gd 那条 54g 变异钉的是同一个漏法）
	_frame.minimum_size_changed.connect(_relayout)


## 记一条。`color` 沿用提示条那一条的颜色 —— 红是拒绝、绿是成交、
## 橙是对手动作，那套配色本身是信息，只留文本会把它丢掉
func append(text: String, color: Color, round_num: int) -> void:
	if text.strip_edges() == "":
		return
	_total += 1
	# **先转义再拼 bbcode**：卡名和 reason 都是外部文本，里头真出现一个
	# `[` 的话后面整段会被当标签吃掉（症状是记录里凭空少几行）
	var safe := text.replace("[", "[lb]")
	_body.append_text("[color=#%s]【第 %d 回合】%s[/color]\n"
		% [color.darkened(0.55).to_html(false), round_num, safe])
	_trim()
	_sync_head()


## 超过上限就从最旧那头丢。RichTextLabel 没有「删第一行」，
## 所以按行重建 —— 这一步只在满了之后每条跑一次
func _trim() -> void:
	if _body.get_line_count() <= MAX_LINES:
		return
	var keep: Array = []
	var lines := _body.get_parsed_text().split("\n")
	var start: int = maxi(0, lines.size() - MAX_LINES)
	for i in range(start, lines.size()):
		keep.append(lines[i])
	_body.text = "\n".join(keep)


func _sync_head() -> void:
	# 收起态要**说得出自己藏了什么**：光写「提示记录」的话，
	# 玩家没有理由相信那里头有他刚错过的那一行
	_title.text = "提示记录 · %d 条" % _total
	_toggle.text = "收起" if _body.visible else "展开"


func _toggle_body() -> void:
	_body.visible = not _body.visible
	# 文案当帧就得跟上，不然那一帧里「按钮写着展开、底下却压着一片空框子」。
	#
	# 下面这句 _relayout() 和 _ready 里那条 minimum_size_changed 连接**分工**,
	# 不是一个顶另一个（实测：tools/_relayout_probe.gd）——
	#   这一句管展开/收起：玩家去点的那一下。
	#   那条信号管「内容自己长大」：条数从「· 1 条」涨到「· 221 条」时标题变宽,
	#   而这条路上没人点过任何东西，指望不上这一句。
	# 尺寸两边其实都不用管（Control 自己不让 size 低于最小尺寸，会回弹）,
	# 真要重算的是**位置** —— offset 是按当时那个宽度算的负数，贴的是右下角
	_sync_head()
	_relayout()


## 框子贴右下角。宽高按内容算 —— 收起态只剩标题栏，
## 展开态是标题栏 + BODY_H。**每次重算，不缓存**：条数变长框子会变宽
func _relayout() -> void:
	if _frame == null:
		return
	var sz: Vector2 = _frame.get_combined_minimum_size()
	_frame.size = sz
	_frame.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_frame.position = Vector2(-sz.x - MARGIN, -sz.y - MARGIN)


## 这一块此刻展开着没有（测试和 main 都要问得到）
func expanded() -> bool:
	return _body != null and _body.visible

## 记录里此刻的全文（判据读它，别去拆 bbcode）
func plain_text() -> String:
	return _body.get_parsed_text() if _body != null else ""

## 一共记过几条
func total() -> int:
	return _total

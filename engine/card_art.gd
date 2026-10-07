# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name CardArt
extends RefCounted

## 卡牌插画与配色登记表。边框/标题带由共享 Shader 绘制，不读取底板 PNG。
## data/ui.json 的 art 段提供保留插画的元数据；缺少插画时卡面、文字和碰撞仍正常。

const ART_DIR := "res://assets/art/"
const UIConfig = preload("res://engine/ui_config.gd")
const Delta = preload("res://engine/hover_delta.gd")

## 卡牌配色槽位，对应 data/ui.json 的 palette.plates；卡框由 Shader 绘制。
const PLATE_CASH := "plate_cash"
const PLATE_USER := "plate_user"
const PLATE_T1_MONEY := "plate_t1_money"
const PLATE_T1_GROWTH := "plate_t1_growth"
const PLATE_T2 := "plate_t2" # 仅保留旧配色槽位名称，生产卡不再按等级取色。
const PLATE_T3 := "plate_t3"
const PLATE_ATTACK := "plate_attack"
const PLATE_BUFF_UP := "plate_buff_up"
const PLATE_BUFF_DEF := "plate_buff_def"

## 卡面元素定位：将 1200×1600 设计画布上的像素值换算为归一化比例。
## 换算成比例而不是写死像素，卡牌 mesh 尺寸变化时不用改这里
const ICON_CX := 0.5           # 图标框中心 x：(240+720/2)/1200
const ICON_CY := 0.488750      # 图标框中心 y：(422+720/2)/1600
const UNIT_ICON_CY := 0.58     # 资源牌没有配方和产出，主图下移以平衡留白
const ICON_FRAC := 0.6         # 图标框宽占卡宽：720/1200
const BAND_CY := 0.106875      # 标题带中心 y：(46+250/2)/1600
const BAND_FRAC := 0.15625     # 标题带高占卡高：250/1600
const BLOB_L_CX := 0.180833    # 左墨团中心 x：217/1200
const BLOB_R_CX := 0.819167    # 右墨团中心 x：983/1200
const BLOB_CY := 0.85          # 墨团中心 y：1360/1600
const BLOB_FRAC := 0.215       # 墨团直径占卡宽：258/1200
const UNIT_ICON_CX := 0.646667 # 单位类型图标中心 x：776/1200
const UNIT_ICON_FRAC := 0.093333  # 单位类型图标宽占卡宽：112/1200

## 卡面四色（face/band/accent/ink）的兜底值不在这里，见 Palette.DEFAULTS ——
## 颜色由配置说话，几何由程序控制，这里保留插画贴图与尺寸。

static var _art: Dictionary = {}
static var _tex_cache: Dictionary = {}
static var _loaded := false

static func hover_config(def_id: String) -> Dictionary:
	_ensure_loaded()
	return _art.get("hover", {}).get("cards", {}).get(def_id, {})

static var _hover_cache: Dictionary = {}
static var _hover_pending: Dictionary = {}
static var _hover_loading: Dictionary = {}
static var _hover_owners: Dictionary = {}
static var _hover_lru: Array[String] = []
static var _hover_poll_scheduled := false
static var _hover_shutdown_bound := false

static func hover_fps() -> float:
	_ensure_loaded()
	return maxf(float(_art.get("hover", {}).get("fps", 12)), 1.0)

static func hover_frames(def_id: String) -> Array:
	return _hover_cache.get(def_id, [])

## 卡面创建时只读原图，真正悬停才后台加载动作素材。
static func request_hover_frames(def_id: String, owner := 0) -> void:
	var config := hover_config(def_id)
	if config.is_empty():
		return
	if not _hover_owners.has(def_id):
		_hover_owners[def_id] = {}
	_hover_owners[def_id][owner] = true
	if _hover_cache.has(def_id):
		_touch_hover(def_id)
		return
	if _hover_pending.has(def_id):
		return
	if config.get("codec", "") == "hdelta-v1":
		_request_delta_frames(def_id, config)
		return
	var paths: Array[String] = []
	for file in config.get("files", [config.get("file", "")]):
		paths.append(ART_DIR + str(file))
	var textures: Dictionary = {}
	for path in paths:
		if textures.has(path):
			continue
		if _tex_cache.get(path) is Texture2D:
			textures[path] = _tex_cache[path]
		elif not _hover_loading.has(path):
			if ResourceLoader.load_threaded_request(path, "Texture2D", true) != OK:
				push_warning("悬停素材无法后台加载：%s" % path)
				_schedule_hover_poll()
				return
			_hover_loading[path] = true
	_hover_pending[def_id] = {"paths": paths, "textures": textures}
	_schedule_hover_poll()

static func _request_delta_frames(def_id: String, config: Dictionary) -> void:
	var original := illustration_texture(def_id)
	if original == null:
		original = icon_texture(def_id)
	if original == null:
		return
	_hover_pending[def_id] = {"codec": "hdelta-v1", "original": original,
		"textures": [original], "decoded": {}, "next": 1}
	var key := "delta:" + def_id
	# 快速移开再回来可以接续尚未结束的同一后台解码，不重复占用内存。
	if not _hover_loading.has(key):
		var path := ART_DIR + str(config.get("file", ""))
		var result: Dictionary = {}
		var task := WorkerThreadPool.add_task(func(): result["decoded"] = Delta.decode_file(path))
		_hover_loading[key] = {"id": def_id, "task": task, "result": result}
	if not _hover_shutdown_bound:
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			tree.root.tree_exiting.connect(_finish_hover_workers, CONNECT_ONE_SHOT)
			_hover_shutdown_bound = true
	_schedule_hover_poll()

static func _finish_hover_workers() -> void:
	for work in _hover_loading.values():
		if work is Dictionary:
			WorkerThreadPool.wait_for_task_completion(work.task)
	_hover_loading.clear()
	_hover_pending.clear()
	_hover_cache.clear()
	_hover_owners.clear()
	_hover_lru.clear()
	_hover_poll_scheduled = false
	_hover_shutdown_bound = false

static func _receive_delta(key: String) -> void:
	var work: Dictionary = _hover_loading[key]
	if not WorkerThreadPool.is_task_completed(work.task):
		return
	WorkerThreadPool.wait_for_task_completion(work.task)
	_hover_loading.erase(key)
	if not _hover_pending.has(work.id):
		return
	var decoded: Dictionary = work.result.decoded
	var config := hover_config(work.id)
	var pending: Dictionary = _hover_pending[work.id]
	var original: Texture2D = pending.original
	var error := str(decoded.error)
	var size: Array = config.get("frame_size", [])
	if error.is_empty() and (decoded.timeline.size() != int(config.get("frames", 0)) \
			or decoded.width != original.get_width() or decoded.height != original.get_height() \
			or size.size() != 2 or int(size[0]) != decoded.width or int(size[1]) != decoded.height):
		error = "差分动画与静止图或登记尺寸不一致"
	if error.is_empty():
		var raw_size := int(decoded.width) * int(decoded.height) * 4
		var static_image := original.get_image()
		static_image.convert(Image.FORMAT_RGBA8)
		if static_image.get_data().slice(0, raw_size) != decoded.images[0].get_data().slice(0, raw_size):
			error = "差分首帧与静止图像素不一致"
	if not error.is_empty():
		_hover_pending.erase(work.id)
		push_warning("悬停差分素材无法加载：%s（%s）" % [work.id, error])
		return
	decoded.images[0] = null
	pending.decoded = decoded

static func release_hover_frames(def_id: String, owner := 0) -> void:
	if not _hover_owners.has(def_id) or not _hover_owners[def_id].has(owner):
		return
	_hover_owners[def_id].erase(owner)
	if not _hover_owners[def_id].is_empty():
		return
	_hover_owners.erase(def_id)
	_hover_pending.erase(def_id)
	_schedule_hover_poll()

static func _schedule_hover_poll() -> void:
	if _hover_poll_scheduled or (_hover_loading.is_empty() and _hover_pending.is_empty()):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		_hover_poll_scheduled = true
		tree.create_timer(0.016).timeout.connect(_poll_hover_loads)

static func _poll_hover_loads() -> void:
	_hover_poll_scheduled = false
	var consumed := 0
	for path in _hover_loading.keys():
		if _hover_loading[path] is Dictionary:
			_receive_delta(path)
			continue
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_hover_loading.erase(path)
		var texture: Texture2D = null
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			texture = ResourceLoader.load_threaded_get(path) as Texture2D
		if texture == null:
			for id in _hover_pending.keys():
				if _hover_pending[id].has("paths") and _hover_pending[id].paths.has(path):
					_hover_pending.erase(id)
			push_warning("悬停素材加载失败：%s" % path)
		else:
			for pending in _hover_pending.values():
				if pending.has("paths") and pending.paths.has(path):
					pending.textures[path] = texture
		consumed += 1
		# 后台同时完成时分批领取，避免首次悬停集中上传全部高清帧。
		if consumed >= 4:
			break
	for id in _hover_pending.keys():
		var pending: Dictionary = _hover_pending[id]
		if pending.get("codec", "") == "hdelta-v1":
			if pending.decoded.is_empty():
				continue
			var images: Array = pending.decoded.images
			while pending.next < images.size() and consumed < 4:
				pending.textures.append(ImageTexture.create_from_image(images[pending.next]))
				images[pending.next] = null
				pending.next += 1
				consumed += 1
			if pending.next < images.size():
				continue
			var ordered: Array = []
			for index in pending.decoded.timeline:
				ordered.append(pending.textures[index])
			_hover_pending.erase(id)
			_hover_cache[id] = ordered
			_touch_hover(id)
			_trim_hover_cache(id)
			continue
		if not pending.paths.all(func(path): return pending.textures.has(path)):
			continue
		var config := hover_config(id)
		var frames: Array = []
		if config.has("files"):
			for path in pending.paths:
				frames.append(pending.textures[path])
		else:
			var cell: Array = config.get("cell_size", [320, 320])
			var columns := maxi(int(config.get("columns", 4)), 1)
			for index in int(config.get("frames", 16)):
				var frame := AtlasTexture.new()
				frame.atlas = pending.textures[pending.paths[0]]
				frame.region = Rect2((index % columns) * float(cell[0]),
					floori(float(index) / columns) * float(cell[1]), cell[0], cell[1])
				frame.filter_clip = true
				frames.append(frame)
		_hover_pending.erase(id)
		_hover_cache[id] = frames
		_touch_hover(id)
		_trim_hover_cache(id)
	_schedule_hover_poll()

static func _touch_hover(def_id: String) -> void:
	_hover_lru.erase(def_id)
	_hover_lru.append(def_id)

static func _hover_cache_bytes() -> int:
	var bytes := 0
	var seen: Dictionary = {}
	for frames in _hover_cache.values():
		for texture in frames:
			var base: Texture2D = texture.atlas if texture is AtlasTexture else texture
			if seen.has(base.get_instance_id()):
				continue
			seen[base.get_instance_id()] = true
			bytes += int(base.get_width() * base.get_height() * 4.0 * 4.0 / 3.0)
	return bytes

static func _trim_hover_cache(current: String) -> void:
	var settings: Dictionary = _art.get("hover", {})
	var max_cards := maxi(int(settings.get("cache_cards", 3)), 1)
	var max_bytes := maxi(int(settings.get("cache_bytes", 268435456)), 1)
	while _hover_lru.size() > 1 and (_hover_lru.size() > max_cards or _hover_cache_bytes() > max_bytes):
		var oldest: String = _hover_lru[0]
		if oldest == current:
			_hover_lru.pop_front()
			_hover_lru.append(oldest)
			continue
		_hover_lru.pop_front()
		_hover_cache.erase(oldest)

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	# 素材与其他展示配置共用入口，外置 ui.json 也遵循相同的合并规则。
	_art = UIConfig.read_section("art")

## def_id → 配色槽位。按 cards.json 的类别、资源、产出和 Buff 类型推导，
## 同类卡牌共用配色，无需为每张卡单独维护映射。
static func plate_slot(def_id: String) -> String:
	var def: Dictionary = CardDB.get_def(def_id)
	match def.get("kind", ""):
		CardDB.KIND_UNIT:
			return PLATE_CASH if def.get("res") == CardDB.RES_CASH else PLATE_USER
		CardDB.KIND_LEGEND:
			return PLATE_T3
		CardDB.KIND_ATTACK:
			return PLATE_ATTACK
		CardDB.KIND_BUFF:
			# 防御 Buff（protect_*）走低饱和底板，与增强 Buff 形成素/艳对比
			return PLATE_BUFF_DEF if str(def.get("buff_type", "")).begins_with("protect_") \
				else PLATE_BUFF_UP
		CardDB.KIND_PRODUCT:
			# 生产牌按实际资源方向分色：用户→现金是变现线，现金→用户是拉新线。
			# T1/T2 共用功能色；升级、换名或导入新卡表都不应改变同一方向的配色。
			return PLATE_T1_MONEY if def.get("output_res") == CardDB.RES_CASH \
				else PLATE_T1_GROWTH
	return PLATE_T1_MONEY

## 程序化卡框几何（世界单位）；标题带高度为卡高占比。
const FRAME_SIZE := Vector2(1.2, 1.6)
const FRAME_RADIUS := 0.10
const FRAME_BORDER := 0.025
const FRAME_WOBBLE := 0.0075
const FRAME_PRESSURE := 0.18
const FRAME_BAND_HEIGHT := 0.18
const FRAME_PARAMETERS := ["card_size", "corner_radius", "border_width", "band_height", "stroke_wobble", "stroke_pressure"]

static func configure_frame(material: ShaderMaterial, scale_factor := 1.0) -> void:
	material.set_shader_parameter("card_size", FRAME_SIZE * scale_factor)
	material.set_shader_parameter("corner_radius", FRAME_RADIUS * scale_factor)
	material.set_shader_parameter("border_width", FRAME_BORDER * scale_factor)
	material.set_shader_parameter("band_height", FRAME_BAND_HEIGHT)
	material.set_shader_parameter("stroke_wobble", FRAME_WOBBLE * scale_factor)
	material.set_shader_parameter("stroke_pressure", FRAME_PRESSURE)

## 功能图标通常是可着色白色线稿；资源图标自带手绘墨色与纸色，缺失返回 null
static func icon_texture(def_id: String) -> Texture2D:
	# 两种资源只维护一份简笔符号，资源牌和所有配方/产出标记共用。
	_ensure_loaded()
	var entry: Dictionary = _art.get("icons", {}).get(def_id, {})
	return _load_tex(ART_DIR + str(entry.get("file", "icon/icon_" + def_id + ".png")))

## 情景插画保留原色；仅登记过的卡使用插画，其他卡继续使用功能图标。
static func illustration_texture(def_id: String) -> Texture2D:
	_ensure_loaded()
	var entry: Dictionary = _art.get("illustrations", {}).get(def_id, {})
	var path := str(entry.get("file", ""))
	return _load_tex(ART_DIR + path) if path != "" else null

## 资源图标（cash / user）：卡面底部用它表示产出、攻击、配方需求的资源种类，
## 替掉「产7」「攻3」这类中文，便于多语言化。
## 同一资源的卡牌主图、配方和产出直接复用同一份符号贴图。
static func res_icon_texture(res: String) -> Texture2D:
	if res != CardDB.RES_CASH and res != CardDB.RES_USER:
		return null
	return icon_texture(res)

## 共享资源简笔画含纸色填充与表情，主图和小徽标都保留原色。
static func icon_preserves_color(texture: Texture2D) -> bool:
	if texture == null:
		return false
	if texture == res_icon_texture(CardDB.RES_CASH) or texture == res_icon_texture(CardDB.RES_USER):
		return true
	_ensure_loaded()
	for id in _art.get("illustrations", {}):
		if texture == icon_texture(str(id)):
			return true
	return false

static func icon_tint(texture: Texture2D, ink: Color) -> Color:
	return Color.WHITE if icon_preserves_color(texture) else Palette.icon_color(ink)

## 牌桌素材：table_felt / zone_tray / market_slot / pawnshop / card_back / log_panel / badge_base
## 先尝试支持透明度的 .png，再尝试用于不透明台面等素材的 .jpg。
static func table_texture(name: String) -> Texture2D:
	var tex := _load_tex(ART_DIR + "table/" + name + ".png")
	if tex == null:
		tex = _load_tex(ART_DIR + "table/" + name + ".jpg")
	return tex

## 覆盖标记：overlay_shield / overlay_void_stamp / overlay_buff_glow
static func overlay_texture(name: String) -> Texture2D:
	return _load_tex(ART_DIR + "overlay/" + name + ".png")

## 以下四色一律走 Palette（data/ui.json 的 palette 段 + 游戏内选色面板），不读 art：
## 卡面填充与轮廓都在 Shader 中绘制，插画不会改变配置色。

## 墨色：卡名/图标/数字的颜色
static func ink_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "ink")

## 卡面填充色
static func face_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "face")

## 标题带填充色
static func band_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "band")

## 强调色：用于配方凑满、效果翻倍时的墨团和产出反馈。
static func accent_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "accent")

## 程序边框与标题分隔线共用的墨色
static func frame_color() -> Color:
	return Palette.get_color("card", "frame")

## 标题文字按程序化标题带的内边界对齐，不依赖旧母版的测量文件。
static func band_cy(_def_id: String) -> float:
	var top := FRAME_BORDER / FRAME_SIZE.y
	var bottom := FRAME_BAND_HEIGHT - FRAME_BORDER * 0.5 / FRAME_SIZE.y
	return (top + bottom) * 0.5

static func band_frac(_def_id: String) -> float:
	return FRAME_BAND_HEIGHT - FRAME_BORDER * 1.5 / FRAME_SIZE.y

## 整卡素材（典当行等 misc 里的 1200×1600 图）的标题带位置
static func misc_band_cy(name: String) -> float:
	return _num(_misc_entry(name), "band_cy", BAND_CY)

static func misc_band_frac(name: String) -> float:
	return _num(_misc_entry(name), "band_frac", BAND_FRAC)

static func _misc_entry(name: String) -> Dictionary:
	_ensure_loaded()
	var misc: Dictionary = _art.get("misc", {})
	var entry: Variant = misc.get(name, {})
	return entry if typeof(entry) == TYPE_DICTIONARY else {}

static func _field(entry: Dictionary, key: String) -> Variant:
	return entry[key] if entry.has(key) else null

static func _num(entry: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = _field(entry, key)
	return float(v) if v != null else fallback

static func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			tex = res
	_tex_cache[path] = tex
	return tex

class_name SettingsUI
extends CanvasLayer
## Asset-driven CONFIG / VOLUME screens replicating the original
## engine. Bases (spconfig / spvolume) carry labels, panels and
## slider tracks; the sheets carry every interactive graphic:
## spconfigButton = word pills in 3 states x 3 word groups, wide
## buttons, font scroll arrows; spVolumeButton = channel pills,
## character faces / cards / card pills, knobs, wide buttons.
## Info-line texts are the spconfigMessage sprite strips, mapped by
## the order they appear in the sheet (transcribed from the asset).
##
## Slider defaults and toggle defaults are the original factory
## values (see GameSettings). Consumers wired in main: master /
## BGM / voice / BGV volumes (+ ducking), screen mode, message
## window opacity, auto-mode interval. Stored-only for now: text
## speed (no typewriter yet), skip / backlog / bar toggles, font
## choice (list is selectable, dialogue font stays the bundled one).

signal closed
signal changed
signal test_bgm_requested
signal test_voice_requested(char_id: String)

const BROWN := Color(0.42, 0.29, 0.17)
const FONTS := ["Noto Sans CJK SC", "Noto Serif CJK SC",
	"游ゴシック", "游明朝", "ＭＳ ゴシック", "ＭＳ 明朝"]
const GROUP_Y := [[4, 46, 87], [130, 172, 213], [256, 298, 339]]
# key, panel, wordA [group, col], wordB, info [header, valA, valB]
const CFG_ITEMS := [
	["screen_mode", Vector2(35, 78), [0, 0], [0, 1], [0, 0], [0, 1], [0, 2]],
	["screen_effect", Vector2(35, 157), [0, 2], [0, 3], [0, 3], [0, 4], [0, 5]],
	["skip_unread", Vector2(35, 242), [0, 4], [0, 5], [0, 6], [0, 7], [0, 8]],
	["skip_after_choice", Vector2(35, 327), [0, 6], [1, 0], [0, 9], [0, 10], [0, 11]],
	["h_anime", Vector2(35, 412), [1, 1], [1, 2], [0, 12], [0, 13], [0, 14]],
	["pubic", Vector2(35, 497), [0, 2], [0, 3], [1, 23], [1, 24], [1, 25]],
	["voice_cut", Vector2(365, 78), [1, 3], [1, 4], [0, 15], [0, 16], [0, 17]],
	["backlog_style", Vector2(365, 157), [1, 5], [1, 6], [0, 18], [0, 19], [0, 20]],
	["confirm_dialog", Vector2(365, 242), [2, 0], [2, 1], [0, 21], [0, 22], [0, 23]],
	["voice_bar", Vector2(365, 327), [2, 2], [2, 3], [0, 24], [0, 25], [0, 26]],
	["auto_bar", Vector2(365, 412), [2, 4], [2, 5], [0, 27], [0, 28], [0, 29]],
]
const CFG_SLIDERS := [
	["window_opacity", 296, [0, 33]],
	["text_speed", 386, [0, 34]],
	["auto_speed", 476, [0, 35]],
]
const VOL_CHANNELS := ["master", "bgm", "se", "bgv", "bgv_duck", "env", "env_h"]
const VOL_INFO := [2, 3, 4, 5, 6, 7, 8]  # right-column strips
const CHAR_IDS := ["chinatsu", "fumiko"]
const CHAR_FACE_X := [2, 84]
const CHAR_CARD_X := [2, 596]
const CHAR_INFO := [11, 12]

var settings: GameSettings

var _root: Control
var _mode := "config"
var _pkg: GamePackage
var _base: TextureRect
var _info: TextureRect
var _shortcuts: TextureRect
var _built := false
var _cfg_sheet: Texture2D
var _vol_sheet: Texture2D
var _msg_sheet: Texture2D
var _cfg_base_img: Image
var _dyn: Array[Node] = []
var _toggle_btns: Dictionary = {}
var _sliders: Dictionary = {}
var _drag_key := ""
var _char_tab := "chinatsu"
var _font_offset := 0
var _font_rows: Array[Button] = []
var _font_current: Label
var _sample_overlay: ColorRect
var _card_tex: TextureRect
var _card_play_btn: TextureButton


func _ready() -> void:
	layer = 70
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)


func is_open() -> bool:
	return _root.visible


func open_screen(pkg: GamePackage, mode: String) -> void:
	_pkg = pkg
	_mode = mode
	if pkg.is_web():
		for img in ["spconfig", "spconfigButton", "spvolume",
				"spVolumeButton", "spconfigMessage", "spshortcutkey"]:
			await pkg.ensure_image(img)
	if not _built:
		_build_static(pkg)
	_rebuild()
	_root.visible = true


func close() -> void:
	_root.visible = false
	_shortcuts.visible = false
	closed.emit()


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if _shortcuts.visible:
		if (event is InputEventMouseButton and event.pressed) \
				or (event is InputEventKey and event.pressed \
				and event.keycode == KEY_ESCAPE):
			_shortcuts.visible = false
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
		return
	if _drag_key != "":
		if event is InputEventMouseMotion:
			_slider_apply(_drag_key, event.position.x)
		elif event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_drag_key = ""
			settings.save_settings()
			changed.emit()


func _build_static(pkg: GamePackage) -> void:
	_built = true
	_base = TextureRect.new()
	_base.stretch_mode = TextureRect.STRETCH_KEEP
	_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_base)
	_info = TextureRect.new()
	_info.position = Vector2(200, 15)
	_info.stretch_mode = TextureRect.STRETCH_KEEP
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_info)
	_cfg_sheet = _load_raw(pkg, "spconfigButton")
	_vol_sheet = _load_raw(pkg, "spVolumeButton")
	_msg_sheet = _load_raw(pkg, "spconfigMessage")
	_cfg_base_img = _load_image(pkg, "spconfig")
	_shortcuts = TextureRect.new()
	_shortcuts.stretch_mode = TextureRect.STRETCH_KEEP
	_shortcuts.texture = _load_cropped(pkg, "spshortcutkey")
	_shortcuts.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shortcuts.visible = false
	add_child(_shortcuts)


func _clear_dyn() -> void:
	for n in _dyn:
		n.queue_free()
	_dyn.clear()
	_toggle_btns.clear()
	_sliders.clear()
	_font_rows.clear()
	_drag_key = ""


func _dyn_add(n: Node) -> Node:
	_root.add_child(n)
	_dyn.append(n)
	return n


func _atlas(sheet: Texture2D, cell: Rect2i) -> AtlasTexture:
	var t := AtlasTexture.new()
	t.atlas = sheet
	t.region = Rect2(cell)
	return t


func _set_info(col: int, idx: int) -> void:
	if _msg_sheet == null or idx < 0:
		_info.texture = null
		return
	_info.texture = _atlas(_msg_sheet,
			Rect2i(3, 3 + 26 * idx, 495, 21) if col == 0
			else Rect2i(508, 3 + 26 * idx, 500, 21))


func _hover(node: Control, col: int, idx: int) -> void:
	node.mouse_entered.connect(func() -> void: _set_info(col, idx))


## A 3-state texture button (normal / hover / selected-as-normal).
func _pill(sheet: Texture2D, cell: Rect2i, pos: Vector2,
		state_rows: Array) -> TextureButton:
	var b := TextureButton.new()
	var dy: Array = state_rows
	b.texture_normal = _atlas(sheet, Rect2i(cell.position.x,
			cell.position.y + int(dy[0]), cell.size.x, cell.size.y))
	b.texture_hover = _atlas(sheet, Rect2i(cell.position.x,
			cell.position.y + int(dy[1]), cell.size.x, cell.size.y))
	b.texture_pressed = _atlas(sheet, Rect2i(cell.position.x,
			cell.position.y + int(dy[2]), cell.size.x, cell.size.y))
	b.position = pos
	b.size = Vector2(cell.size)
	b.stretch_mode = TextureButton.STRETCH_KEEP
	return b


func _touch() -> void:
	settings.save_settings()
	changed.emit()


# ---- sliders ----

func _make_slider(key: String, x0: int, x1: int, cy: int,
		info: Array) -> void:
	var knob := TextureRect.new()
	knob.texture = _atlas(_vol_sheet, Rect2i(848, 95, 19, 32))
	knob.stretch_mode = TextureRect.STRETCH_KEEP
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dyn_add(knob)
	var hit := Control.new()
	hit.position = Vector2(x0 - 12, cy - 18)
	hit.size = Vector2(x1 - x0 + 24, 36)
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_dyn_add(hit)
	_sliders[key] = {"knob": knob, "x0": x0, "x1": x1, "cy": cy}
	hit.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_drag_key = key
			_slider_apply(key, event.position.x + hit.position.x))
	_hover(hit, info[0], info[1])
	_slider_sync(key)


func _slider_value(key: String) -> int:
	match key:
		"window_opacity", "text_speed", "auto_speed":
			return int(settings.config[key])
		"char_volume":
			return int(settings.chars[_char_tab]["volume"])
		_:
			return int(settings.volume[key])


func _slider_store(key: String, v: int) -> void:
	match key:
		"window_opacity", "text_speed", "auto_speed":
			settings.config[key] = v
		"char_volume":
			settings.chars[_char_tab]["volume"] = v
		_:
			settings.volume[key] = v


func _slider_apply(key: String, gx: float) -> void:
	var s: Dictionary = _sliders[key]
	var frac := clampf((gx - float(s["x0"])) / float(s["x1"] - s["x0"]),
			0.0, 1.0)
	_slider_store(key, int(round(frac * 100.0)))
	_slider_sync(key)
	if key == "window_opacity":
		_sync_sample()
	changed.emit()


func _slider_sync(key: String) -> void:
	var s: Dictionary = _sliders[key]
	var v := _slider_value(key)
	var x := float(s["x0"]) + float(s["x1"] - s["x0"]) * v / 100.0
	(s["knob"] as TextureRect).position = Vector2(x - 9, int(s["cy"]) - 16)


func _sync_sample() -> void:
	if _sample_overlay != null:
		var v := int(settings.config["window_opacity"])
		_sample_overlay.color.a = 0.85 - v / 100.0 * 0.7


# ---- CONFIG ----

func _word_cell(group: int, col: int, state: int) -> Rect2i:
	return Rect2i(3 + col * 146, GROUP_Y[group][state], 140, 36)


func _build_config() -> void:
	_base.texture = _load_cropped(_pkg, "spconfig")
	for item in CFG_ITEMS:
		var key: String = item[0]
		var panel: Vector2 = item[1]
		var btns: Array[TextureButton] = []
		for side in range(2):
			var word: Array = item[2 + side]
			var pos := Vector2(panel.x + 8 + side * 156, panel.y + 42)
			var b := TextureButton.new()
			b.position = pos
			b.size = Vector2(140, 36)
			b.stretch_mode = TextureButton.STRETCH_KEEP
			var s := side
			b.pressed.connect(func() -> void:
				settings.config[key] = s
				_refresh_config()
				_touch())
			_dyn_add(b)
			btns.append(b)
			_hover(b, item[5 + side][0], item[5 + side][1])
		_toggle_btns[key] = btns
		var head := Control.new()
		head.position = panel
		head.size = Vector2(315, 36)
		head.mouse_filter = Control.MOUSE_FILTER_STOP
		_dyn_add(head)
		_hover(head, item[4][0], item[4][1])
	for s in CFG_SLIDERS:
		_make_slider(s[0], 719, 1219, s[1], s[2])
	_build_font_block()
	_build_sample()
	# Wide buttons.
	var reset := _pill(_cfg_sheet, Rect2i(3, 381, 278, 38),
			Vector2(943, 10), [0, 42, 42])
	reset.pressed.connect(func() -> void:
		settings.reset_config()
		_refresh_config()
		changed.emit())
	_dyn_add(reset)
	_hover(reset, 0, 37)
	var back := _pill(_cfg_sheet, Rect2i(285, 381, 278, 38),
			Vector2(62, 676), [0, 42, 42])
	back.pressed.connect(func() -> void: close())
	_dyn_add(back)
	_hover(back, 0, 38)
	var cuts := _pill(_cfg_sheet, Rect2i(567, 381, 278, 38),
			Vector2(501, 676), [0, 42, 42])
	cuts.pressed.connect(func() -> void: _shortcuts.visible = true)
	_dyn_add(cuts)
	_hover(cuts, 1, 0)
	var vol := _pill(_cfg_sheet, Rect2i(3, 465, 278, 38),
			Vector2(940, 676), [0, 49, 49])
	vol.pressed.connect(func() -> void:
		_mode = "volume"
		_rebuild())
	_dyn_add(vol)
	_hover(vol, 1, 1)
	_refresh_config()


func _refresh_config() -> void:
	for item in CFG_ITEMS:
		var key: String = item[0]
		var value := int(settings.config[key])
		var btns: Array = _toggle_btns[key]
		for side in range(2):
			var word: Array = item[2 + side]
			var b: TextureButton = btns[side]
			var state := 2 if side == value else 0
			var hov := 2 if side == value else 1
			b.texture_normal = _atlas(_cfg_sheet,
					_word_cell(word[0], word[1], state))
			b.texture_hover = _atlas(_cfg_sheet,
					_word_cell(word[0], word[1], hov))
			b.texture_pressed = b.texture_hover
	for s in CFG_SLIDERS:
		_slider_sync(s[0])
	_sync_sample()
	_refresh_fonts()


func _build_font_block() -> void:
	_font_current = Label.new()
	_font_current.position = Vector2(712, 121)
	DialogueUI.apply_font(_font_current, 20)
	_font_current.add_theme_color_override("font_color", BROWN)
	_dyn_add(_font_current)
	_hover(_font_current, 0, 31)
	for i in range(4):
		var row := Button.new()
		row.position = Vector2(712, 158 + i * 26)
		row.size = Vector2(460, 24)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.flat = true
		DialogueUI.apply_font(row, 17)
		row.add_theme_color_override("font_color", BROWN)
		var idx := i
		row.pressed.connect(func() -> void:
			settings.config["font"] = _font_offset + idx
			_refresh_fonts()
			_touch())
		_dyn_add(row)
		_font_rows.append(row)
		_hover(row, 0, 32)
	var up := _pill(_cfg_sheet, Rect2i(880, 256, 36, 36),
			Vector2(1192, 165), [0, 42, 42])
	up.pressed.connect(func() -> void:
		_font_offset = maxi(0, _font_offset - 1)
		_refresh_fonts())
	_dyn_add(up)
	var down := _pill(_cfg_sheet, Rect2i(922, 256, 36, 36),
			Vector2(1192, 218), [0, 42, 42])
	down.pressed.connect(func() -> void:
		_font_offset = mini(FONTS.size() - 4, _font_offset + 1)
		_refresh_fonts())
	_dyn_add(down)
	var head := Control.new()
	head.position = Vector2(695, 85)
	head.size = Vector2(300, 30)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	_dyn_add(head)
	_hover(head, 0, 30)


func _refresh_fonts() -> void:
	if _font_current == null:
		return
	_font_current.text = FONTS[int(settings.config["font"])]
	for i in range(4):
		var idx := _font_offset + i
		_font_rows[i].text = FONTS[idx] if idx < FONTS.size() else ""


func _build_sample() -> void:
	if _cfg_base_img != null:
		var room := TextureRect.new()
		room.texture = ImageTexture.create_from_image(
				_cfg_base_img.get_region(Rect2i(375, 543, 860, 97)))
		room.position = Vector2(375, 543)
		room.stretch_mode = TextureRect.STRETCH_KEEP
		room.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(room)
	_sample_overlay = ColorRect.new()
	_sample_overlay.color = Color(0.05, 0.03, 0.02, 0.5)
	_sample_overlay.position = Vector2(375, 578)
	_sample_overlay.size = Vector2(860, 62)
	_sample_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dyn_add(_sample_overlay)
	var head := Control.new()
	head.position = Vector2(365, 497)
	head.size = Vector2(300, 30)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	_dyn_add(head)
	_hover(head, 0, 36)


# ---- VOLUME ----

func _build_volume() -> void:
	_base.texture = _load_cropped(_pkg, "spvolume")
	for i in range(VOL_CHANNELS.size()):
		var key: String = VOL_CHANNELS[i]
		var py := 85 + i * 80
		if key != "master":
			var test := _pill(_vol_sheet, Rect2i(3, 3, 102, 28),
					Vector2(348, py + 7), [0, 30, 61])
			test.pressed.connect(func() -> void:
				if key == "bgm":
					test_bgm_requested.emit())
			_dyn_add(test)
			_hover(test, 1, 18)
		var play := TextureButton.new()
		play.position = Vector2(472, py + 7)
		play.size = Vector2(102, 28)
		play.stretch_mode = TextureButton.STRETCH_KEEP
		play.pressed.connect(func() -> void:
			settings.volume["play_" + key] = \
					not bool(settings.volume["play_" + key])
			_refresh_volume()
			_touch())
		_dyn_add(play)
		_toggle_btns["play_" + key] = [play]
		_hover(play, 1, 19)
		_make_slider(key, 60, 560, py + 52, [1, VOL_INFO[i]])
	# Character tabs + card.
	for i in range(2):
		var face := TextureButton.new()
		face.position = Vector2(650 + i * 88, 126)
		face.size = Vector2(80, 80)
		face.stretch_mode = TextureButton.STRETCH_KEEP
		var cid: String = CHAR_IDS[i]
		face.pressed.connect(func() -> void:
			_char_tab = cid
			_refresh_volume())
		_dyn_add(face)
		_toggle_btns["face_" + CHAR_IDS[i]] = [face]
		_hover(face, 1, CHAR_INFO[i])
	_card_tex = TextureRect.new()
	_card_tex.position = Vector2(644, 180)
	_card_tex.stretch_mode = TextureRect.STRETCH_KEEP
	_card_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dyn_add(_card_tex)
	var ctest := _pill(_vol_sheet, Rect2i(248, 225, 160, 44),
			Vector2(672, 395), [0, 46, 46])
	ctest.pressed.connect(func() -> void:
		test_voice_requested.emit(_char_tab))
	_dyn_add(ctest)
	_hover(ctest, 1, 18)
	_card_play_btn = TextureButton.new()
	_card_play_btn.position = Vector2(672, 449)
	_card_play_btn.size = Vector2(160, 44)
	_card_play_btn.stretch_mode = TextureButton.STRETCH_KEEP
	_card_play_btn.pressed.connect(func() -> void:
		settings.chars[_char_tab]["play"] = \
				not bool(settings.chars[_char_tab]["play"])
		_refresh_volume()
		_touch())
	_dyn_add(_card_play_btn)
	_hover(_card_play_btn, 1, 19)
	_make_slider("char_volume", 672, 1210, 640, [1, 9])
	# Wide buttons.
	var reset := _pill(_vol_sheet, Rect2i(3, 95, 278, 38),
			Vector2(943, 10), [0, 44, 44])
	reset.pressed.connect(func() -> void:
		settings.reset_volume()
		_refresh_volume()
		changed.emit())
	_dyn_add(reset)
	_hover(reset, 1, 20)
	var back := _pill(_vol_sheet, Rect2i(567, 95, 278, 38),
			Vector2(62, 676), [0, 44, 44])
	back.pressed.connect(func() -> void: close())
	_dyn_add(back)
	_hover(back, 1, 21)
	var cfg := _pill(_vol_sheet, Rect2i(285, 95, 278, 38),
			Vector2(940, 676), [0, 44, 44])
	cfg.pressed.connect(func() -> void:
		_mode = "config"
		_rebuild())
	_dyn_add(cfg)
	_hover(cfg, 1, 22)
	_refresh_volume()


func _refresh_volume() -> void:
	for key in VOL_CHANNELS:
		var play: TextureButton = _toggle_btns["play_" + key][0]
		var on := bool(settings.volume["play_" + key])
		var n := Rect2i(109, 64, 102, 28) if on else Rect2i(109, 3, 102, 28)
		play.texture_normal = _atlas(_vol_sheet, n)
		play.texture_hover = _atlas(_vol_sheet, Rect2i(109, 33, 102, 28))
		play.texture_pressed = play.texture_hover
		_slider_sync(key)
	for i in range(2):
		var face: TextureButton = _toggle_btns["face_" + CHAR_IDS[i]][0]
		var sel: bool = CHAR_IDS[i] == _char_tab
		face.texture_normal = _atlas(_vol_sheet,
				Rect2i(CHAR_FACE_X[i], 344 if sel else 182, 80, 80))
		face.texture_hover = _atlas(_vol_sheet,
				Rect2i(CHAR_FACE_X[i], 262, 80, 80))
		face.texture_pressed = face.texture_normal
	var ci := CHAR_IDS.find(_char_tab)
	_card_tex.texture = _atlas(_vol_sheet,
			Rect2i(CHAR_CARD_X[ci], 425, 592, 464))
	var con := bool(settings.chars[_char_tab]["play"])
	_card_play_btn.texture_normal = _atlas(_vol_sheet,
			Rect2i(410, 271, 160, 44) if con else Rect2i(410, 225, 160, 44))
	_card_play_btn.texture_hover = _atlas(_vol_sheet,
			Rect2i(410, 271, 160, 44))
	_card_play_btn.texture_pressed = _card_play_btn.texture_hover
	_slider_sync("char_volume")


func _rebuild() -> void:
	_clear_dyn()
	_info.texture = null
	if _mode == "config":
		_build_config()
	else:
		_build_volume()


# ---- image loading (same pattern as TitleUI / SaveLoadUI) ----

func _load_image(pkg: GamePackage, image_name: String) -> Image:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		return null
	return img


func _load_cropped(pkg: GamePackage, image_name: String) -> Texture2D:
	var img := _load_image(pkg, image_name)
	if img == null:
		push_warning("SettingsUI: image not found: " + image_name)
		return null
	var used: Rect2i = img.get_used_rect()
	if used.size.x > 0 and used.size.y > 0 and used.size != img.get_size():
		img = img.get_region(used)
	return ImageTexture.create_from_image(img)


func _load_raw(pkg: GamePackage, image_name: String) -> Texture2D:
	var img := _load_image(pkg, image_name)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

class_name EmoteRoom
extends Node
## The original's 立ち絵鑑賞 (EmoteRoom / VIEWER): a dark-themed
## E-mote playground built from spEmoteRoomItem (frame) and
## spEmoteRoomButton (controls), rendering through a dedicated
## Stage instance.
##
## Data notes (all measured from the assets / original screen):
## - The pose variables are the define table's named vars; the
##   viewer's sliders map 1:1 (head_slant, face_eye_UD, ...). The
##   centered sliders display var+30 (default 30 = var 0); the eye
##   slider displays 10 - var (10 = fully open = var 0, matching
##   the blink driver's additive range); face_mouth's default 30
##   matches pose em101's value exactly.
## - Costume -> model mapping identified by rendering every
##   standing model: chinatsu 裸=Mchina100 / 下着=Mchina101 /
##   妊娠裸=Mchina119 are certain; the rest are strong inferences
##   from the rendered outfits (marked in the devlog). fumiko and
##   kosu tables likewise come from the model renders. The hide
##   (4th face) table is best-effort from the Mhide model names.

signal tab_selected(tab: String)
signal to_title

const TABS := ["cg", "anime", "memory", "viewer", "music"]
## Costume order follows define.dat's chara->models association
## table (the engine's own list); label indices are positions in
## COSTUME_LABELS under that order. Chinatsu/Fumiko are table-exact
## (several entries render-verified); Kosu's middle labels and
## Hide's list are positional inference.
const CHARS := [
	{"costumes": [[0, "Mchina100"], [1, "Mchina101"], [2, "Mchina103"],
			[3, "Mchina109"], [4, "Mchina104"], [5, "Mchina110"],
			[6, "Mchina105"], [7, "Mchina107"], [8, "Mchina106"],
			[9, "Mchina108"], [19, "Mchina119"]]},
	{"costumes": [[0, "Mfumi300"], [1, "Mfumi301"], [2, "Mfumi303"],
			[3, "Mfumi309"], [4, "Mfumi304"], [5, "Mfumi310"],
			[6, "Mfumi305"], [7, "Mfumi307"], [8, "Mfumi312"],
			[9, "Mfumi308"]]},
	{"costumes": [[15, "Mkosu300"], [17, "Mkosu302"], [2, "Mkosu303"],
			[3, "Mkosu309"], [4, "Mkosu304"], [5, "Mkosu310"],
			[13, "Mkosu307"], [14, "Mkosu308"], [18, "Mkosu312"]]},
	{"costumes": [[0, "Mhide200a"], [12, "Mhide200b"],
			[1, "Mhide201a"], [2, "Mhide202a"], [3, "Mhide203a"],
			[4, "Mhide204a"]]},
]
const PRESETS := [
	{"mouth": 45, "eye": 8, "brow": 5, "cheek": 25},
	{"mouth": 58, "eye": 5, "brow": 0, "cheek": 40},
	{"mouth": 12, "eye": 10, "brow": -12, "talk": 30},
	{"mouth": 12, "eye": 7, "brow": 25, "cheek": 15},
	{"mouth": 3, "eye": 8, "brow": 15, "cheek": 30},
	{"mouth": 35, "eye": 7, "brow": 10, "cheek": 60},
	{"mouth": 18, "eye": 5, "brow": 20, "cheek": 85},
	{"mouth": 28, "eye": 6, "brow": 5, "cheek": 55, "talk": 12},
]
# kind: scale | center (var = disp-30) | eye (var = 10-disp) | raw
const SLIDERS := [
	{"info": "表示倍率を変更できます", "kind": "scale",
		"min": 20.0, "max": 200.0, "def": 100.0},
	{"info": "頭の傾きを変更できます", "var": "head_slant",
		"kind": "center", "min": 0.0, "max": 60.0, "def": 30.0},
	{"info": "体の傾きを変更できます", "var": "body_slant",
		"kind": "center", "min": 0.0, "max": 60.0, "def": 30.0},
	{"info": "瞳を上下に移動できます", "var": "face_eye_UD",
		"kind": "center", "min": 0.0, "max": 60.0, "def": 30.0},
	{"info": "瞳を左右に移動できます", "var": "face_eye_LR",
		"kind": "center", "min": 0.0, "max": 60.0, "def": 30.0},
	{"info": "目の開きを変更できます", "var": "face_eye_open",
		"kind": "eye", "min": 0.0, "max": 10.0, "def": 10.0},
	{"info": "眉の形を変更できます", "var": "face_eyebrow",
		"kind": "raw", "min": -20.0, "max": 40.0, "def": 0.0},
	{"info": "口の形を変更できます", "var": "face_mouth",
		"kind": "raw", "min": 0.0, "max": 60.0, "def": 30.0},
	{"info": "口の開きを変更できます", "var": "face_talk",
		"kind": "raw", "min": 0.0, "max": 60.0, "def": 0.0},
	{"info": "頬染めを変更できます", "var": "face_cheek",
		"kind": "raw", "min": 0.0, "max": 100.0, "def": 0.0},
]
const BG_NAMES := ["spRoombg01", "spRoombg02", "BG010", "BG020",
		"BG021", "BG022", "BG023", "BG030", "BG031", "BG032",
		"BG040", "BG041", "BG042", "BG043", "BG050", "BG051",
		"BG052", "BG053", "BG060", "BG066"]
const TRACK_X := 925.0
const TRACK_W := 235.0

var _root: Control
var _stage: Stage
var _btn_sheet: Texture2D
var _btn_img: Image
var _pkg: GamePackage
var _built := false
var _dyn: Array[Node] = []
var _info: Label
var _char := 0
var _costume := 0
var _costume_page := 0
var _preset_page := 0
var _bg := 0
var _bg_page := 0
var _vals: Array = []  # slider display values
var _tears := false
var _pubic := true
var _lip := false
var _idle := true
var _hidden := false
var _drag := -1
var _knobs: Array = []
var _value_labels: Array = []
var _lip_t := 0.0


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)


func is_open() -> bool:
	return _root.visible


func open_room(pkg: GamePackage, define: DefineTable) -> void:
	_pkg = pkg
	if not _built:
		_build(pkg, define)
	_load_model()
	_rebuild()
	_root.visible = true


func close_room() -> void:
	_root.visible = false
	if _stage != null:
		_stage.set_voice_level(0.0)


func _process(delta: float) -> void:
	if not is_open():
		return
	if _lip and _stage != null:
		_lip_t += delta
		_stage.set_voice_level(
				0.45 + 0.4 * sin(_lip_t * 6.3) * sin(_lip_t * 2.1))


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if _hidden:
		if event is InputEventMouseButton and event.pressed:
			_set_hidden(false)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_room()
		to_title.emit()
		get_viewport().set_input_as_handled()
		return
	if _drag >= 0:
		if event is InputEventMouseMotion:
			_slider_apply(_drag, event.position.x)
		elif event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_drag = -1
		get_viewport().set_input_as_handled()


func _build(pkg: GamePackage, define: DefineTable) -> void:
	_built = true
	var bg := ColorRect.new()
	bg.color = Color(0.145, 0.118, 0.094)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	_stage = Stage.new()
	_root.add_child(_stage)
	_stage.setup(pkg, define)
	_stage.position = Vector2(-70, 0)
	_btn_img = _load_image(pkg, "spEmoteRoomButton")
	_btn_sheet = ImageTexture.create_from_image(_btn_img) \
			if _btn_img != null else null
	var item := _load_image(pkg, "spEmoteRoomItem")
	if item != null:
		var used: Rect2i = item.get_used_rect()
		var art := TextureRect.new()
		art.texture = ImageTexture.create_from_image(
				item.get_region(used))
		art.position = Vector2(used.position)
		art.stretch_mode = TextureRect.STRETCH_KEEP
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(art)
	_info = Label.new()
	_info.position = Vector2(92, 100)
	_info.size = Vector2(292, 24)
	DialogueUI.apply_font(_info, 14)
	_info.add_theme_color_override("font_color", Color(0.92, 0.9, 0.86))
	_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_root.add_child(_info)
	for s in SLIDERS:
		_vals.append(float(s["def"]))


func _dyn_add(n: Node) -> Node:
	_root.add_child(n)
	_dyn.append(n)
	return n


func _clear_dyn() -> void:
	for n in _dyn:
		n.queue_free()
	_dyn.clear()
	_knobs.clear()
	_value_labels.clear()


func _atlas(cell: Rect2i) -> AtlasTexture:
	var t := AtlasTexture.new()
	t.atlas = _btn_sheet
	t.region = Rect2(cell)
	return t


func _btn(cell: Rect2i, hover: Rect2i, pos: Vector2,
		fn: Callable) -> TextureButton:
	var b := TextureButton.new()
	b.position = pos
	b.size = Vector2(cell.size)
	b.stretch_mode = TextureButton.STRETCH_KEEP
	b.texture_normal = _atlas(cell)
	b.texture_hover = _atlas(hover)
	b.texture_pressed = b.texture_hover
	b.pressed.connect(fn)
	return b


func _set_info(text: String) -> void:
	_info.text = text


func _hover(b: BaseButton, text: String) -> void:
	b.mouse_entered.connect(func() -> void: _set_info(text))


# ---- state application ----

func _load_model() -> void:
	var costumes: Array = CHARS[_char]["costumes"]
	_costume = clampi(_costume, 0, costumes.size() - 1)
	_stage.emote_load(0, str(costumes[_costume][1]))
	_stage.pos_set("", 0, 570, 0)
	_apply_all_vars()


func _var_of(i: int) -> float:
	var s: Dictionary = SLIDERS[i]
	var disp := float(_vals[i])
	match str(s["kind"]):
		"center":
			return disp - 30.0
		"eye":
			return 10.0 - disp
		_:
			return disp


func _apply_slider(i: int) -> void:
	var s: Dictionary = SLIDERS[i]
	if str(s["kind"]) == "scale":
		var f := float(_vals[i]) / 100.0
		_stage.scale = Vector2(f, f)
		_stage.position = Vector2(570 - 640 * f, 716 - 716 * f)
		return
	_stage.emote_set_var(0, str(s["var"]), _var_of(i))


func _apply_all_vars() -> void:
	for i in range(SLIDERS.size()):
		_apply_slider(i)
	_stage.emote_set_var(0, "face_tears", 1.0 if _tears else 0.0)
	_stage.emote_set_idle(0, _idle)


func _apply_preset(i: int) -> void:
	var p: Dictionary = PRESETS[i]
	_set_slider_disp("face_mouth", float(p.get("mouth", 30)))
	_set_slider_disp("face_eye_open", float(p.get("eye", 10)))
	_set_slider_disp("face_eyebrow", float(p.get("brow", 0)))
	_set_slider_disp("face_cheek", float(p.get("cheek", 0)))
	_set_slider_disp("face_talk", float(p.get("talk", 0)))
	_rebuild()


func _set_slider_disp(var_name: String, disp: float) -> void:
	for i in range(SLIDERS.size()):
		if str(SLIDERS[i].get("var", "")) == var_name:
			_vals[i] = disp
			_apply_slider(i)
			return


# ---- layout ----

func _rebuild() -> void:
	_clear_dyn()
	_build_header()
	_build_left()
	_build_right()
	_sync_sliders()


func _build_header() -> void:
	for i in range(TABS.size()):
		var row := 170 if TABS[i] == "viewer" else 86
		var b := _btn(Rect2i(3 + i * 186, row, 182, 38),
				Rect2i(3 + i * 186, 128 if TABS[i] != "viewer" else 170,
				182, 38),
				Vector2(305 + i * 196, 12),
				func() -> void:
					if TABS[i] != "viewer":
						close_room()
						tab_selected.emit(TABS[i]))
		_hover(b, "タイトル画面に戻ります" if false else "")
		_dyn_add(b)
	var back := _btn(Rect2i(3, 2, 278, 38), Rect2i(3, 44, 278, 38),
			Vector2(62, 676),
			func() -> void:
				close_room()
				to_title.emit())
	_hover(back, "タイトル画面に戻ります")
	_dyn_add(back)


func _build_left() -> void:
	# character faces
	for i in range(CHARS.size()):
		var row := 670 if i == _char else 620
		var b := _btn(Rect2i(2 + i * 50, row, 48, 48),
				Rect2i(2 + i * 50, 620 if i != _char else 670, 48, 48),
				Vector2(46 + i * 48, 203),
				func() -> void:
					_char = i
					_costume = 0
					_costume_page = 0
					_load_model()
					_rebuild())
		_hover(b, "キャラクターを変更できます")
		_dyn_add(b)
	# expression presets (5 per page of the 8)
	var p_off := _preset_page * 5
	for k in range(5):
		var idx := p_off + k
		if idx >= PRESETS.size():
			break
		var b := _btn(Rect2i(2 + idx * 50, 770, 48, 48),
				Rect2i(2 + idx * 50, 820, 48, 48),
				Vector2(46 + k * 47, 293),
				func() -> void: _apply_preset(idx))
		_hover(b, "設定された表情の値を読み込みます")
		_dyn_add(b)
	var p_next := _btn(Rect2i(882, 246, 29, 30),
			Rect2i(882, 246, 29, 30), Vector2(285, 302),
			func() -> void:
				_preset_page = (_preset_page + 1) % 2
				_rebuild())
	_dyn_add(p_next)
	# costumes (5 per page)
	var costumes: Array = CHARS[_char]["costumes"]
	var c_off := _costume_page * 5
	for k in range(5):
		var idx := c_off + k
		if idx >= costumes.size():
			break
		var cell_i := int(costumes[idx][0])
		var row := 1020 if idx == _costume else 920
		var b := _btn(Rect2i(2 + cell_i * 50, row, 48, 48),
				Rect2i(2 + cell_i * 50,
				970 if idx != _costume else 1020, 48, 48),
				Vector2(46 + k * 47, 388),
				func() -> void:
					_costume = idx
					_load_model()
					_rebuild())
		_hover(b, "衣装を変更できます")
		_dyn_add(b)
	if costumes.size() > 5:
		var c_next := _btn(Rect2i(882, 246, 29, 30),
				Rect2i(882, 246, 29, 30), Vector2(285, 397),
				func() -> void:
					_costume_page = (_costume_page + 1) \
							% int(ceil(costumes.size() / 5.0))
					_rebuild())
		_dyn_add(c_next)
	# backgrounds (4 per page of the 20)
	var b_off := _bg_page * 4
	for k in range(4):
		var idx := b_off + k
		if idx >= BG_NAMES.size():
			break
		var row := 1170 if idx == _bg else 1070
		var b := _btn(Rect2i(2 + idx * 50, row, 48, 48),
				Rect2i(2 + idx * 50, 1120 if idx != _bg else 1170,
				48, 48),
				Vector2(46 + k * 47, 483),
				func() -> void:
					_bg = idx
					_stage.show_image(BG_NAMES[idx])
					_rebuild())
		_hover(b, "背景を変更できます")
		_dyn_add(b)
	var b_next := _btn(Rect2i(882, 246, 29, 30),
			Rect2i(882, 246, 29, 30), Vector2(285, 492),
			func() -> void:
				_bg_page = (_bg_page + 1) % 5
				_rebuild())
	_dyn_add(b_next)
	# lip / idle / save / load / hide. Mid-block pills are 28-30 px
	# tall at a 34 px pitch: state rows 214 / 248 / 282.
	var lip := _btn(Rect2i(5, 299 if _lip else 215, 138, 34),
			Rect2i(5, 257, 138, 34), Vector2(125, 542),
			func() -> void:
				_lip = not _lip
				if not _lip:
					_stage.set_voice_level(0.0)
				_rebuild())
	_hover(lip, "口パクのオン／オフを設定できます")
	_dyn_add(lip)
	var lip2 := _btn(Rect2i(151, 215 if _lip else 299, 138, 34),
			Rect2i(151, 257, 138, 34), Vector2(268, 542),
			func() -> void:
				_lip = not _lip
				if not _lip:
					_stage.set_voice_level(0.0)
				_rebuild())
	_dyn_add(lip2)
	var idle := _btn(Rect2i(1405, 282 if _idle else 214, 116, 28),
			Rect2i(1405, 248, 116, 28), Vector2(125, 592),
			func() -> void:
				_idle = not _idle
				_stage.emote_set_idle(0, _idle)
				_rebuild())
	_hover(idle, "待機モーションのオン／オフを設定できます")
	_dyn_add(idle)
	var idle2 := _btn(Rect2i(1527, 214 if _idle else 282, 116, 28),
			Rect2i(1527, 248, 116, 28), Vector2(247, 592),
			func() -> void:
				_idle = not _idle
				_stage.emote_set_idle(0, _idle)
				_rebuild())
	_dyn_add(idle2)
	var save := _btn(Rect2i(297, 215, 90, 47),
			Rect2i(297, 271, 90, 47), Vector2(40, 630),
			func() -> void: _save_state())
	_hover(save, "現在の表情・衣装を保存します")
	_dyn_add(save)
	var load := _btn(Rect2i(395, 215, 90, 47),
			Rect2i(395, 271, 90, 47), Vector2(138, 630),
			func() -> void: _load_state())
	_hover(load, "保存した設定を読み込みます")
	_dyn_add(load)
	var hide := _btn(Rect2i(493, 215, 90, 47),
			Rect2i(493, 271, 90, 47), Vector2(236, 630),
			func() -> void: _set_hidden(true))
	_hover(hide, "スイッチを隠す事ができます")
	_dyn_add(hide)


func _build_right() -> void:
	for i in range(SLIDERS.size()):
		var cy := 108 + i * 44
		var hit := Control.new()
		hit.position = Vector2(TRACK_X - 12, cy - 20)
		hit.size = Vector2(TRACK_W + 24, 40)
		hit.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		hit.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
				_drag = idx
				_set_info(str(SLIDERS[idx]["info"]))
				_slider_apply(idx, event.global_position.x))
		hit.mouse_entered.connect(
				func() -> void: _set_info(str(SLIDERS[idx]["info"])))
		_dyn_add(hit)
		var knob := TextureRect.new()
		knob.texture = _atlas(Rect2i(826, 212, 19, 32))
		knob.stretch_mode = TextureRect.STRETCH_KEEP
		knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(knob)
		_knobs.append(knob)
		var val := TextureRect.new()
		val.position = Vector2(1180, cy - 38)
		val.size = Vector2(76, 26)
		val.stretch_mode = TextureRect.STRETCH_SCALE
		val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(val)
		_value_labels.append(val)
	# tears / pubic toggles
	var tears := _btn(Rect2i(917, 282 if _tears else 214, 116, 28),
			Rect2i(917, 248, 116, 28), Vector2(953, 532),
			func() -> void:
				_tears = not _tears
				_stage.emote_set_var(0, "face_tears",
						1.0 if _tears else 0.0)
				_rebuild())
	_hover(tears, "涙の有無を変更できます")
	_dyn_add(tears)
	var tears2 := _btn(Rect2i(1039, 214 if _tears else 282, 116, 28),
			Rect2i(1039, 248, 116, 28), Vector2(1080, 532),
			func() -> void:
				_tears = not _tears
				_stage.emote_set_var(0, "face_tears",
						1.0 if _tears else 0.0)
				_rebuild())
	_dyn_add(tears2)
	var pub := _btn(Rect2i(917, 282 if _pubic else 214, 116, 28),
			Rect2i(917, 248, 116, 28), Vector2(953, 576),
			func() -> void:
				_pubic = not _pubic
				_rebuild())
	_hover(pub, "女性の陰毛の有無を変更できます")
	_dyn_add(pub)
	var pub2 := _btn(Rect2i(1039, 214 if _pubic else 282, 116, 28),
			Rect2i(1039, 248, 116, 28), Vector2(1080, 576),
			func() -> void:
				_pubic = not _pubic
				_rebuild())
	_dyn_add(pub2)
	# camera / folder / reset (two-state icons, ~60 tall)
	var cam := _btn(Rect2i(592, 215, 72, 60),
			Rect2i(592, 278, 72, 60), Vector2(1000, 615),
			func() -> void: _capture())
	_hover(cam, "現在の状況をPNGデータで保存します")
	_dyn_add(cam)
	var fold := _btn(Rect2i(673, 215, 75, 60),
			Rect2i(673, 278, 75, 60), Vector2(1085, 615),
			func() -> void:
				_set_info("画像を保存したフォルダを開きます")
				if not OS.has_feature("web"):
					OS.shell_open(ProjectSettings.globalize_path(
							"user://")))
	_hover(fold, "画像を保存したフォルダを開きます")
	_dyn_add(fold)
	var rst := _btn(Rect2i(757, 216, 63, 63),
			Rect2i(757, 287, 63, 63), Vector2(1178, 612),
			func() -> void: _reset())
	_hover(rst, "バーの設定を初期化します")
	_dyn_add(rst)


func _sync_sliders() -> void:
	for i in range(SLIDERS.size()):
		var s: Dictionary = SLIDERS[i]
		var frac := (float(_vals[i]) - float(s["min"])) \
				/ (float(s["max"]) - float(s["min"]))
		_knobs[i].position = Vector2(
				TRACK_X + frac * TRACK_W - 9, 108 + i * 44 - 16)
		_draw_value(i)


## Slider values: the sheet's digit strip composited into one
## image per value (deterministic pixels; Label metrics and
## per-digit sprites both proved unreliable in this layout).
func _draw_value(i: int) -> void:
	var box := _value_labels[i] as TextureRect
	var v := int(round(float(_vals[i])))
	var text := str(absi(v))
	var img := Image.create(64, 24, false, Image.FORMAT_RGBA8)
	var dx := (64 - text.length() * 12 - (12 if v < 0 else 0)) / 2 + 8
	if v < 0:
		img.fill_rect(Rect2i(dx, 11, 9, 2), Color(0.23, 0.16, 0.1))
		dx += 12
	for ch in text:
		img.blit_rect(_btn_img,
				Rect2i(818 + int(ch) * 9, 314, 9, 19),
				Vector2i(dx, 2))
		dx += 12
	box.texture = ImageTexture.create_from_image(img)


func _slider_apply(i: int, x: float) -> void:
	var s: Dictionary = SLIDERS[i]
	var frac := clampf((x - TRACK_X) / TRACK_W, 0.0, 1.0)
	_vals[i] = float(s["min"]) + frac * (float(s["max"]) - float(s["min"]))
	_apply_slider(i)
	_sync_sliders()


func _set_hidden(on: bool) -> void:
	_hidden = on
	for child in _root.get_children():
		if child != _stage and child is CanvasItem:
			(child as CanvasItem).visible = not on


func _reset() -> void:
	for i in range(SLIDERS.size()):
		_vals[i] = float(SLIDERS[i]["def"])
	_tears = false
	_apply_all_vars()
	_sync_sliders()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://viewer_capture.png")
	_set_info("現在の状況をPNGデータで保存します")


func _save_state() -> void:
	var data := {"char": _char, "costume": _costume, "bg": _bg,
			"vals": _vals, "tears": _tears, "pubic": _pubic,
			"lip": _lip, "idle": _idle}
	var f := FileAccess.open("user://viewer.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	_set_info("現在の表情・衣装・背景を保存します")


func _load_state() -> void:
	if not FileAccess.file_exists("user://viewer.json"):
		return
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("user://viewer.json"))
	if parsed is not Dictionary:
		return
	_char = int(parsed.get("char", 0))
	_costume = int(parsed.get("costume", 0))
	_bg = int(parsed.get("bg", 0))
	_vals = (parsed.get("vals", _vals) as Array).duplicate()
	_tears = bool(parsed.get("tears", false))
	_pubic = bool(parsed.get("pubic", true))
	_lip = bool(parsed.get("lip", false))
	_idle = bool(parsed.get("idle", true))
	_load_model()
	_stage.show_image(BG_NAMES[_bg])
	_rebuild()
	_set_info("保存した設定を読み込みます")


# ---- image loading ----

func _load_image(pkg: GamePackage, image_name: String) -> Image:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		return null
	return img


func _load_raw(pkg: GamePackage, image_name: String) -> Texture2D:
	var img := _load_image(pkg, image_name)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

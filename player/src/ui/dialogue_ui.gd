class_name DialogueUI
extends CanvasLayer
## ADV-style dialogue UI at the 1280x720 baseline: bottom panel with
## speaker name + text, a blinking advance hint, and a choice menu.
## Ruby markup in pool text (@[base:reading] / ＠[base:reading]) is
## rendered as its base text only in v1.

signal choice_picked(k: int)
signal save_requested
signal load_requested
signal quick_save_requested
signal quick_load_requested
signal flow_requested
signal config_requested
signal volume_requested
signal backlog_requested
signal title_requested
signal voice_replay_requested
signal auto_toggled(on: bool)
signal skip_toggled(on: bool)
signal voice_wait_toggled(on: bool)

static var _font: Font


## The bundled CJK font, applied as an explicit override on every
## control. Relying on the project theme default font is NOT enough:
## on the Web build the theme default silently loses the TTC's CJK
## glyphs in TextServer (labels render missing-glyph boxes) while an
## explicit override of the same FontFile renders correctly —
## verified in-browser 2026-10-28 (theme label boxed, direct label
## perfect, has_char/metrics identical in both cases).
static func ui_font() -> Font:
	if _font == null:
		_font = load("res://assets/fonts/NotoSansCJK-Regular.ttc")
	return _font


static func apply_font(c: Control, size: int) -> void:
	c.add_theme_font_override("font", ui_font())
	c.add_theme_font_size_override("font_size", size)


var _panel: PanelContainer
var _panel_style: StyleBoxFlat


## Message window opacity from the CONFIG setting (alpha of the
## window background; the text stays fully opaque).
func set_window_opacity(alpha: float) -> void:
	if _panel_style != null:
		_panel_style.bg_color.a = alpha
var _name_label: Label
var _text_label: Label
var _hint: Label
var _menu: CenterContainer
var _menu_box: VBoxContainer
var _status: Label
var _blink := 0.0

# --- Original-style message-window chrome (button bar, speaker
# replay icon, wait lamps, backlog viewer), asset-driven from the
# spMessageWindowButton sheet. Built by set_package() once the game
# package (and its UI images) is available.
var _bar: HBoxContainer
var _speaker_btn: TextureButton
var _buttons: Dictionary = {}
var _lamp_voice: Button
var _lamp_auto: Button
var _chrome_hidden := false
var auto_on := false
var skip_on := false
var voice_wait_on := true
var _log_panel: PanelContainer
var _log_box: VBoxContainer
var _log_scroll: ScrollContainer

# Sheet cells: name -> [x, y, w]; all cells are 24 px tall, the
# hover row sits 26 px below the normal row.
const _CELLS := {
	"save": [2, 2, 68], "load": [72, 2, 68], "qsave": [142, 2, 68],
	"qload": [212, 2, 68], "conf": [282, 2, 68], "vol": [352, 2, 68],
	"skip": [422, 2, 68],
	"auto": [2, 54, 68], "blog": [72, 54, 68], "title": [142, 54, 68],
	"close": [212, 54, 24], "speaker": [238, 54, 32],
	"flow": [266, 54, 68],
}
const _BAR_ORDER := ["save", "load", "qsave", "qload", "flow",
		"conf", "vol", "skip", "auto", "blog", "title", "close"]


static func display_text(raw: String) -> String:
	var out := ""
	var i := 0
	while i < raw.length():
		var c := raw.unicode_at(i)
		if (c == 0x40 or c == 0xFF20) and i + 1 < raw.length() and raw.unicode_at(i + 1) == 0x5B:
			var colon := raw.find(":", i + 2)
			var close := raw.find("]", i + 2)
			if colon != -1 and close != -1 and colon < close:
				out += raw.substr(i + 2, colon - (i + 2))
				i = close + 1
				continue
		out += raw.substr(i, 1)
		i += 1
	# Trailing ideographic/ASCII padding in pool strings is layout noise.
	while out.length() > 0 and out.unicode_at(out.length() - 1) in [0x3000, 0x20, 0x0A, 0x09]:
		out = out.left(out.length() - 1)
	return out


func _ready() -> void:
	layer = 50
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = 90
	_panel.offset_right = -90
	_panel.offset_top = -178
	_panel.offset_bottom = -18
	var style := StyleBoxFlat.new()
	_panel_style = style
	style.bg_color = Color(0.02, 0.03, 0.08, 0.78)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_speaker_btn = TextureButton.new()
	_speaker_btn.custom_minimum_size = Vector2(32, 24)
	_speaker_btn.visible = false
	_speaker_btn.pressed.connect(func() -> void: voice_replay_requested.emit())
	top.add_child(_speaker_btn)
	_name_label = Label.new()
	apply_font(_name_label, 21)
	_name_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	top.add_child(_name_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 2)
	top.add_child(_bar)
	vbox.add_child(top)
	_text_label = Label.new()
	apply_font(_text_label, 21)
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.custom_minimum_size = Vector2(0, 84)
	_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	vbox.add_child(_text_label)
	_hint = Label.new()
	_hint.text = "▼"
	apply_font(_hint, 15)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_hint)
	_panel.add_child(vbox)
	add_child(_panel)
	_menu = CenterContainer.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_box = VBoxContainer.new()
	_menu_box.add_theme_constant_override("separation", 10)
	_menu.add_child(_menu_box)
	_menu.visible = false
	add_child(_menu)
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	apply_font(_status, 24)
	_status.offset_top = 24
	add_child(_status)
	# Wait lamps, bottom-left of the screen like the original.
	_lamp_voice = _make_lamp("音声待ち", Vector2(14, -30))
	_lamp_voice.pressed.connect(func() -> void:
		set_voice_wait(not voice_wait_on)
		voice_wait_toggled.emit(voice_wait_on))
	_lamp_auto = _make_lamp("オート待ち", Vector2(96, -30))
	_lamp_auto.pressed.connect(func() -> void:
		set_auto(not auto_on)
		auto_toggled.emit(auto_on))
	set_voice_wait(true)
	# Backlog viewer (hidden until B-LOG).
	_log_panel = PanelContainer.new()
	_log_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_log_panel.offset_left = 130
	_log_panel.offset_right = -130
	_log_panel.offset_top = 56
	_log_panel.offset_bottom = -56
	var lstyle := StyleBoxFlat.new()
	lstyle.bg_color = Color(0.02, 0.03, 0.08, 0.92)
	lstyle.corner_radius_top_left = 10
	lstyle.corner_radius_top_right = 10
	lstyle.corner_radius_bottom_left = 10
	lstyle.corner_radius_bottom_right = 10
	lstyle.content_margin_left = 26
	lstyle.content_margin_right = 26
	lstyle.content_margin_top = 18
	lstyle.content_margin_bottom = 18
	_log_panel.add_theme_stylebox_override("panel", lstyle)
	_log_scroll = ScrollContainer.new()
	_log_box = VBoxContainer.new()
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_box.add_theme_constant_override("separation", 8)
	_log_scroll.add_child(_log_box)
	_log_panel.add_child(_log_scroll)
	_log_panel.visible = false
	add_child(_log_panel)
	hide_dialogue()


func _process(delta: float) -> void:
	_blink += delta
	_hint.modulate.a = 0.35 + 0.65 * abs(sin(_blink * 3.0))


func present_say(speaker: String, text: String) -> void:
	if not _chrome_hidden:
		_panel.visible = true
		_set_lamps_visible(true)
	_name_label.text = speaker
	_name_label.visible = speaker != ""
	_speaker_btn.visible = speaker != "" and _speaker_btn.texture_normal != null
	_text_label.text = display_text(text)


func present_narrate(text: String) -> void:
	present_say("", text)


func hide_dialogue() -> void:
	_panel.visible = false
	_set_lamps_visible(false)


func hide_choices() -> void:
	_menu.visible = false


func show_choices(options: Array) -> void:
	show_chrome()
	for ch in _menu_box.get_children():
		ch.queue_free()
	for k in options.size():
		var b := Button.new()
		b.text = display_text(options[k]["text"])
		b.custom_minimum_size = Vector2(520, 44)
		apply_font(b, 20)
		var idx := k
		b.pressed.connect(func() -> void:
			_menu.visible = false
			choice_picked.emit(idx))
		_menu_box.add_child(b)
	_menu.visible = true


func show_status(text: String) -> void:
	_status.text = text


# ------------------------------------------------------------------
# Message-window chrome (button bar / lamps / backlog)
# ------------------------------------------------------------------

func _make_lamp(text: String, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	apply_font(b, 13)
	b.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	b.offset_left = pos.x
	b.offset_top = pos.y
	b.offset_right = pos.x + 78
	b.offset_bottom = pos.y + 24
	b.visible = false
	add_child(b)
	return b


func _set_lamps_visible(v: bool) -> void:
	if _lamp_voice != null:
		_lamp_voice.visible = v and not _chrome_hidden
		_lamp_auto.visible = v and not _chrome_hidden


func _atlas(sheet: Texture2D, cell: Array, hover: bool) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = sheet
	at.region = Rect2(int(cell[0]), int(cell[1]) + (26 if hover else 0),
			int(cell[2]), 24)
	return at


## Build the button bar from the package's spMessageWindowButton
## sheet. Called once the game package is open.
func set_package(p_pkg: GamePackage) -> void:
	if not _buttons.is_empty():
		return
	var bytes := p_pkg.image_bytes("spMessageWindowButton")
	if bytes.is_empty():
		return
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return
	var sheet := ImageTexture.create_from_image(img)
	for key in _BAR_ORDER:
		var cell: Array = _CELLS[key]
		var b := TextureButton.new()
		b.texture_normal = _atlas(sheet, cell, false)
		b.texture_hover = _atlas(sheet, cell, true)
		b.texture_pressed = _atlas(sheet, cell, true)
		b.custom_minimum_size = Vector2(int(cell[2]), 24)
		b.stretch_mode = TextureButton.STRETCH_KEEP
		_bar.add_child(b)
		_buttons[key] = b
	# Speaker replay icon next to the name label.
	_speaker_btn.texture_normal = _atlas(sheet, _CELLS["speaker"], false)
	_speaker_btn.texture_hover = _atlas(sheet, _CELLS["speaker"], true)
	_speaker_btn.texture_pressed = _atlas(sheet, _CELLS["speaker"], true)
	_speaker_btn.stretch_mode = TextureButton.STRETCH_KEEP
	(_buttons["save"] as TextureButton).pressed.connect(
			func() -> void: save_requested.emit())
	(_buttons["load"] as TextureButton).pressed.connect(
			func() -> void: load_requested.emit())
	(_buttons["qsave"] as TextureButton).pressed.connect(
			func() -> void: quick_save_requested.emit())
	(_buttons["qload"] as TextureButton).pressed.connect(
			func() -> void: quick_load_requested.emit())
	(_buttons["flow"] as TextureButton).pressed.connect(
			func() -> void: flow_requested.emit())
	(_buttons["conf"] as TextureButton).pressed.connect(
			func() -> void: config_requested.emit())
	(_buttons["vol"] as TextureButton).pressed.connect(
			func() -> void: volume_requested.emit())
	(_buttons["blog"] as TextureButton).pressed.connect(
			func() -> void: backlog_requested.emit())
	(_buttons["title"] as TextureButton).pressed.connect(
			func() -> void: title_requested.emit())
	(_buttons["close"] as TextureButton).pressed.connect(hide_chrome)
	(_buttons["auto"] as TextureButton).pressed.connect(func() -> void:
		set_auto(not auto_on)
		auto_toggled.emit(auto_on))
	(_buttons["skip"] as TextureButton).pressed.connect(func() -> void:
		set_skip(not skip_on)
		skip_toggled.emit(skip_on))
	_refresh_toggles(sheet)


func _refresh_toggles(sheet: Texture2D = null) -> void:
	if sheet == null:
		var b0: TextureButton = _buttons.get("auto")
		if b0 == null or b0.texture_normal == null:
			return
		sheet = (b0.texture_normal as AtlasTexture).atlas
	for key in ["auto", "skip"]:
		var b: TextureButton = _buttons[key]
		var on: bool = auto_on if key == "auto" else skip_on
		b.texture_normal = _atlas(sheet, _CELLS[key], on)


func set_auto(on: bool) -> void:
	auto_on = on
	_refresh_toggles()
	_paint_lamp(_lamp_auto, on)


func set_skip(on: bool) -> void:
	skip_on = on
	_refresh_toggles()


func set_voice_wait(on: bool) -> void:
	voice_wait_on = on
	_paint_lamp(_lamp_voice, on)


func _paint_lamp(b: Button, on: bool) -> void:
	if b == null:
		return
	b.add_theme_color_override("font_color",
			Color(0.95, 0.65, 0.25) if on else Color(0.75, 0.75, 0.78))
	b.add_theme_color_override("font_hover_color",
			Color(0.95, 0.65, 0.25) if on else Color(0.9, 0.9, 0.92))


func hide_chrome() -> void:
	_chrome_hidden = true
	_panel.visible = false
	_set_lamps_visible(false)


func show_chrome() -> void:
	if not _chrome_hidden:
		return
	_chrome_hidden = false
	_panel.visible = true
	_set_lamps_visible(true)


func chrome_hidden() -> bool:
	return _chrome_hidden


## True when a click position lands on the button bar, the speaker
## icon or the lamps (so the story must not advance for it).
func chrome_hit(pos: Vector2) -> bool:
	if _chrome_hidden or not _panel.visible:
		return false
	if _bar != null and _bar.get_global_rect().has_point(pos):
		return true
	if _speaker_btn.visible and _speaker_btn.get_global_rect().has_point(pos):
		return true
	for lamp in [_lamp_voice, _lamp_auto]:
		if lamp != null and lamp.visible and lamp.get_global_rect().has_point(pos):
			return true
	return false


func open_backlog(entries: Array) -> void:
	for ch in _log_box.get_children():
		ch.queue_free()
	for e in entries:
		var l := Label.new()
		var sp: String = e["speaker"]
		l.text = (sp + "：" if sp != "" else "") + display_text(e["text"])
		apply_font(l, 17)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color",
				Color(1.0, 0.85, 0.45) if sp != "" else Color(0.92, 0.92, 0.95))
		_log_box.add_child(l)
	_log_panel.visible = true
	await get_tree().process_frame
	_log_scroll.scroll_vertical = 1 << 30


func close_backlog() -> void:
	_log_panel.visible = false


func is_backlog_open() -> bool:
	return _log_panel != null and _log_panel.visible

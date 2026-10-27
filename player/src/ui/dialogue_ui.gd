class_name DialogueUI
extends CanvasLayer
## ADV-style dialogue UI at the 1280x720 baseline: bottom panel with
## speaker name + text, a blinking advance hint, and a choice menu.
## Ruby markup in pool text (@[base:reading] / ＠[base:reading]) is
## rendered as its base text only in v1.

signal choice_picked(k: int)

var _panel: PanelContainer
var _name_label: Label
var _text_label: Label
var _hint: Label
var _menu: CenterContainer
var _menu_box: VBoxContainer
var _status: Label
var _blink := 0.0


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
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 21)
	_name_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	vbox.add_child(_name_label)
	_text_label = Label.new()
	_text_label.add_theme_font_size_override("font_size", 21)
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.custom_minimum_size = Vector2(0, 84)
	_text_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	vbox.add_child(_text_label)
	_hint = Label.new()
	_hint.text = "▼"
	_hint.add_theme_font_size_override("font_size", 15)
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
	_status.add_theme_font_size_override("font_size", 24)
	_status.offset_top = 24
	add_child(_status)
	hide_dialogue()


func _process(delta: float) -> void:
	_blink += delta
	_hint.modulate.a = 0.35 + 0.65 * abs(sin(_blink * 3.0))


func present_say(speaker: String, text: String) -> void:
	_panel.visible = true
	_name_label.text = speaker
	_name_label.visible = speaker != ""
	_text_label.text = display_text(text)


func present_narrate(text: String) -> void:
	present_say("", text)


func hide_dialogue() -> void:
	_panel.visible = false


func show_choices(options: Array) -> void:
	for ch in _menu_box.get_children():
		ch.queue_free()
	for k in options.size():
		var b := Button.new()
		b.text = display_text(options[k]["text"])
		b.custom_minimum_size = Vector2(520, 44)
		b.add_theme_font_size_override("font_size", 20)
		var idx := k
		b.pressed.connect(func() -> void:
			_menu.visible = false
			choice_picked.emit(idx))
		_menu_box.add_child(b)
	_menu.visible = true


func show_status(text: String) -> void:
	_status.text = text

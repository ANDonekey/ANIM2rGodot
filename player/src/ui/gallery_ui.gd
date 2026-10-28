class_name GalleryUI
extends CanvasLayer
## Title menu + movie gallery + scene recollection list, built in
## code like DialogueUI. Shown after a package loads; starting a
## story or a recollection is delegated to Main through signals.
##
## Recollection mirrors the original engine: the gallery does not
## replay a recording, it asks Main to boot the script VM with the
## scene-request register (op 0xA6) preset, and CheckMemory in the
## script itself dispatches into the scene. Movie entries come from
## the op 0x21 unlock registry; scene entries from the CheckMemory
## dispatch table, enabled once story play has reached them.

signal start_story
signal resume_game
signal load_save
signal start_recollection(value: int)
signal play_movie(name: String)
signal list_movies_requested
signal list_scenes_requested
signal back_to_title

var _root: PanelContainer
var _heading: Label
var _buttons: VBoxContainer
var _scroll: ScrollContainer
var _list: VBoxContainer
var _mode := ""  # "", "title", "movies", "scenes"


func _ready() -> void:
	layer = 60
	_root = PanelContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.01, 0.01, 0.03, 0.82)
	_root.add_theme_stylebox_override("panel", style)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.custom_minimum_size = Vector2(600, 0)
	center.add_child(vbox)
	_heading = Label.new()
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	DialogueUI.apply_font(_heading, 30)
	vbox.add_child(_heading)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 10)
	vbox.add_child(_buttons)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(600, 420)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	vbox.add_child(_scroll)
	add_child(_root)
	_root.visible = false


func is_open() -> bool:
	return _mode != ""


func mode() -> String:
	return _mode


func _clear(box: BoxContainer) -> void:
	for ch in box.get_children():
		ch.queue_free()


func _menu_button(text: String, width := 600) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, 46)
	DialogueUI.apply_font(b, 20)
	return b


func show_title(can_resume: bool, has_save: bool, movie_count: int,
		scene_total: int, scene_reached: int) -> void:
	_mode = "title"
	_heading.text = "ANIM2rGodot"
	_clear(_buttons)
	_clear(_list)
	_scroll.visible = false
	if can_resume:
		var resume := _menu_button("继续游戏")
		resume.pressed.connect(func() -> void: resume_game.emit())
		_buttons.add_child(resume)
	var start := _menu_button("从头开始")
	start.pressed.connect(func() -> void: start_story.emit())
	_buttons.add_child(start)
	var movies := _menu_button("电影画廊（%d）" % movie_count)
	movies.disabled = movie_count == 0
	movies.pressed.connect(func() -> void: list_movies_requested.emit())
	_buttons.add_child(movies)
	var scenes := _menu_button("场景回想（%d/%d）" % [scene_reached, scene_total])
	scenes.disabled = scene_total == 0
	scenes.pressed.connect(func() -> void: list_scenes_requested.emit())
	_buttons.add_child(scenes)
	if has_save:
		var loadb := _menu_button("读取存档")
		loadb.pressed.connect(func() -> void: load_save.emit())
		_buttons.add_child(loadb)
	_root.visible = true


# Main fills the lists in response to list_movies_requested /
# list_scenes_requested, because it owns the unlock store and the
# script's dispatch table.
func show_movies(names: Array) -> void:
	_mode = "movies"
	_heading.text = "电影画廊"
	_clear(_buttons)
	_clear(_list)
	_scroll.visible = true
	_root.visible = true
	for n in names:
		var name: String = n
		var b := _menu_button(name, 568)
		b.pressed.connect(func() -> void: play_movie.emit(name))
		_list.add_child(b)
	_add_back_button()


func show_scenes(entries: Array) -> void:
	_mode = "scenes"
	_heading.text = "场景回想"
	_clear(_buttons)
	_clear(_list)
	_scroll.visible = true
	_root.visible = true
	for e in entries:
		var value: int = e["value"]
		var b := _menu_button(e["caption"], 568)
		b.disabled = not e["enabled"]
		if e["enabled"]:
			b.pressed.connect(func() -> void: start_recollection.emit(value))
		_list.add_child(b)
	_add_back_button()


func _add_back_button() -> void:
	var back := _menu_button("返回")
	back.pressed.connect(func() -> void: back_to_title.emit())
	_buttons.add_child(back)


func hide_all() -> void:
	_mode = ""
	_root.visible = false

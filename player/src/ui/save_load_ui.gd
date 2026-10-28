class_name SaveLoadUI
extends CanvasLayer
## Asset-driven SAVE / LOAD screens replicating the original engine.
## Layout (measured against the original running under Wine, incl. a
## filled slot): spSave / spLoad base image (paper, title, SAVE No.
## field, preview frame), spSaveButton / spLoadButton cell sheets
## (page tabs in 3 states, slot boxes in 2 states, trash icons, NEW
## badge, buttons). 100 manual slots (10 pages x 10) plus an AUTO
## SAVE page on the LOAD screen only. Slot files live in
## user://slots/ (slot_%03d.json/.png, auto.json/.png) with a meta
## block (date / time / text) inside the JSON.
##
## Numbers and dates are text-rendered for now; the original draws
## them from digit strips in the sheets (refinement, see spec).

signal load_requested(slot: int)
signal save_requested(slot: int)
signal delete_requested(slot: int)
signal wipe_requested
signal to_title_requested
signal closed

const SLOT_DIR := "user://slots"
const BROWN := Color(0.42, 0.29, 0.17)
const GOLD := Color(0.78, 0.47, 0.20)

const TAB_X0 := 380
const TAB_PITCH := 79
const TAB_Y := 88
const SLOT_X := 58
const SLOT_Y0 := 84
const SLOT_PITCH := 57

var _root: Control
var _mode := "load"
var _from_title := false
var _page := 0
var _base_tex: TextureRect
var _sheet: Texture2D
var _tabs: Array[TextureButton] = []
var _slots: Array[TextureButton] = []
var _trashes: Array[TextureButton] = []
var _num_labels: Array[Label] = []
var _date_groups: Array = []
var _badges: Array[TextureRect] = []
var _no_label: Label
var _thumb: TextureRect
var _banner: TextureRect
var _built := false

## slot states cache: slot index -> meta Dictionary ({} = empty)
var _states: Dictionary = {}


func _ready() -> void:
	layer = 70
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)


func is_open() -> bool:
	return _root.visible


func slot_path(slot: int) -> String:
	if slot >= 100:
		return SLOT_DIR + "/auto.json"
	return SLOT_DIR + "/slot_%03d.json" % slot


func thumb_path(slot: int) -> String:
	if slot >= 100:
		return SLOT_DIR + "/auto.png"
	return SLOT_DIR + "/slot_%03d.png" % slot


func read_states() -> Dictionary:
	var out: Dictionary = {}
	DirAccess.make_dir_recursive_absolute(SLOT_DIR)
	for n in range(101):
		var p := slot_path(n)
		if FileAccess.file_exists(p):
			var data: Variant = JSON.parse_string(
					FileAccess.get_file_as_string(p))
			if data is Dictionary and data.has("meta"):
				out[n] = data["meta"]
	return out


func newest_slot() -> int:
	var best := -1
	var best_key := ""
	for n in _states.keys():
		var m: Dictionary = _states[n]
		var key := str(m.get("date", "")) + " " + str(m.get("time", ""))
		if key > best_key:
			best_key = key
			best = n
	return best


func open_screen(pkg: GamePackage, mode: String, from_title: bool) -> void:
	_mode = mode
	_from_title = from_title
	_page = 0
	if pkg.is_web():
		await pkg.ensure_image("spLoad" if mode == "load" else "spSave")
		await pkg.ensure_image("spLoadButton" if mode == "load" else "spSaveButton")
	_build(pkg)
	_apply_mode(pkg)
	_refresh()
	_root.visible = true


func close() -> void:
	_root.visible = false
	closed.emit()


func go_back() -> void:
	close()


func _atlas(cell: Rect2i) -> AtlasTexture:
	var t := AtlasTexture.new()
	t.atlas = _sheet
	t.region = Rect2(cell)
	return t


func _tex_btn(cell: Rect2i, hover_cell: Rect2i, pos: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = _atlas(cell)
	if hover_cell.size.x > 0:
		b.texture_hover = _atlas(hover_cell)
		b.texture_pressed = _atlas(hover_cell)
	b.position = pos
	b.size = Vector2(cell.size)
	b.stretch_mode = TextureButton.STRETCH_KEEP
	return b


func _build(pkg: GamePackage) -> void:
	if _built:
		return
	_built = true
	_base_tex = TextureRect.new()
	_base_tex.stretch_mode = TextureRect.STRETCH_KEEP
	_base_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_base_tex)
	# Page tabs (positions fixed; textures swapped per mode/page).
	for i in range(11):
		var b := TextureButton.new()
		b.position = Vector2(TAB_X0 + i * TAB_PITCH - 2 if i < 10
				else 1178, TAB_Y - 2)
		b.size = Vector2(66, 66)
		b.stretch_mode = TextureButton.STRETCH_KEEP
		var idx := i
		b.pressed.connect(func() -> void:
			_page = idx
			_refresh())
		_root.add_child(b)
		_tabs.append(b)
	# Slots.
	for i in range(10):
		var y := SLOT_Y0 + i * SLOT_PITCH
		var trash := TextureButton.new()
		trash.position = Vector2(14, y + 8)
		trash.size = Vector2(31, 43)
		trash.stretch_mode = TextureButton.STRETCH_KEEP
		var ti := i
		trash.pressed.connect(func() -> void: _on_trash(ti))
		_root.add_child(trash)
		_trashes.append(trash)
		var slot := TextureButton.new()
		slot.position = Vector2(SLOT_X, y)
		slot.size = Vector2(305, 58)
		slot.stretch_mode = TextureButton.STRETCH_KEEP
		slot.mouse_entered.connect(func() -> void: _on_slot_hover(ti))
		slot.pressed.connect(func() -> void: _on_slot_click(ti))
		_root.add_child(slot)
		_slots.append(slot)
		var num := Label.new()
		num.position = Vector2(SLOT_X + 16, y + 4)
		DialogueUI.apply_font(num, 38)
		num.add_theme_color_override("font_color", BROWN)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(num)
		_num_labels.append(num)
		# Date/time digits sit in groups around the separators baked
		# into the slot box art (measured from a filled original slot):
		# yyyy / MM / dd on the top line, hh / mm / ss below.
		var groups: Array[Label] = []
		var gx := [105, 158, 186, 105, 138, 171]
		for gi in range(6):
			var part := Label.new()
			part.position = Vector2(SLOT_X + gx[gi],
					y + (8 if gi < 3 else 29))
			DialogueUI.apply_font(part, 17)
			part.add_theme_color_override("font_color", BROWN)
			part.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_root.add_child(part)
			groups.append(part)
		_date_groups.append(groups)
		var badge := TextureRect.new()
		badge.position = Vector2(SLOT_X + 240, y + 13)
		badge.stretch_mode = TextureRect.STRETCH_KEEP
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.visible = false
		_root.add_child(badge)
		_badges.append(badge)
	# Preview thumbnail inside the base's frame.
	_thumb = TextureRect.new()
	_thumb.position = Vector2(377, 158)
	_thumb.size = Vector2(866, 488)
	_thumb.stretch_mode = TextureRect.STRETCH_SCALE
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_thumb)
	# SAVE No. value (hovered slot number).
	_no_label = Label.new()
	_no_label.position = Vector2(272, 10)
	DialogueUI.apply_font(_no_label, 26)
	_no_label.add_theme_color_override("font_color", BROWN)
	_root.add_child(_no_label)
	# Thumbnail-saving banner (flashed on save).
	_banner = TextureRect.new()
	_banner.position = Vector2(435, 337)
	_banner.stretch_mode = TextureRect.STRETCH_KEEP
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	_root.add_child(_banner)


## Swap base + sheet textures and the mode-specific buttons.
func _apply_mode(pkg: GamePackage) -> void:
	var base_name := "spLoad" if _mode == "load" else "spSave"
	var sheet_name := "spLoadButton" if _mode == "load" else "spSaveButton"
	_base_tex.texture = _load_cropped(pkg, base_name)
	_sheet = _load_raw(pkg, sheet_name)
	# Remove previous mode buttons (tagged in group).
	for child in get_tree().get_nodes_in_group("saveload_mode_btn"):
		child.queue_free()
	var wipe := _tex_btn(Rect2i(285, 201, 278, 38),
			Rect2i(285, 243, 278, 38), Vector2(940, 6))
	wipe.add_to_group("saveload_mode_btn")
	wipe.pressed.connect(func() -> void: wipe_requested.emit())
	_root.add_child(wipe)
	# Bottom row: back / title / switch (switch + title hidden from
	# title context on LOAD, where back alone returns to the title).
	var back := _tex_btn(Rect2i(567, 201, 278, 38),
			Rect2i(567, 243, 278, 38), Vector2(62, 676))
	back.add_to_group("saveload_mode_btn")
	back.pressed.connect(func() -> void: close())
	_root.add_child(back)
	if not (_mode == "load" and _from_title):
		var title_b := _tex_btn(Rect2i(2, 285, 278, 38),
				Rect2i(2, 327, 278, 38), Vector2(501, 676))
		title_b.add_to_group("saveload_mode_btn")
		title_b.pressed.connect(func() -> void:
			_root.visible = false
			to_title_requested.emit())
		_root.add_child(title_b)
		var switch_b := _tex_btn(Rect2i(2, 201, 278, 38),
				Rect2i(2, 243, 278, 38), Vector2(940, 676))
		switch_b.add_to_group("saveload_mode_btn")
		switch_b.pressed.connect(func() -> void:
			_mode = "save" if _mode == "load" else "load"
			_page = mini(_page, 9)
			_apply_mode(pkg)
			_refresh())
		_root.add_child(switch_b)
	_banner.texture = _atlas(Rect2i(5, 717, 405, 46))


func _refresh() -> void:
	_states = read_states()
	var newest := newest_slot()
	var tab_count := 11 if _mode == "load" else 10
	for i in range(11):
		var b := _tabs[i]
		b.visible = i < tab_count
		if not b.visible:
			continue
		var cell := Rect2i(2 + i * 66, 2, 66, 66)
		var hover := Rect2i(2 + i * 66, 68, 66, 66)
		var sel := Rect2i(2 + i * 66, 134, 66, 66)
		b.texture_normal = _atlas(sel if i == _page else cell)
		b.texture_hover = _atlas(sel if i == _page else hover)
		b.texture_pressed = _atlas(sel)
	for i in range(10):
		var slot := _slot_at(i)
		var active := slot >= 0
		_slots[i].visible = active
		_trashes[i].visible = active
		_num_labels[i].visible = active
		for part in _date_groups[i]:
			(part as Label).visible = active
		if not active:
			_badges[i].visible = false
			continue
		var filled: bool = _states.has(slot)
		_slots[i].texture_normal = _atlas(Rect2i(2, 368, 305, 58))
		_slots[i].texture_hover = _atlas(Rect2i(2, 428, 305, 58))
		_slots[i].texture_pressed = _atlas(Rect2i(2, 428, 305, 58))
		_trashes[i].texture_normal = _atlas(Rect2i(7, 773, 31, 43))
		_trashes[i].texture_hover = _atlas(Rect2i(7, 822, 31, 43))
		_trashes[i].texture_pressed = _atlas(Rect2i(7, 822, 31, 43))
		_num_labels[i].text = "%03d" % (slot + 1) if slot < 100 else "AUTO"
		var parts: Array = ["", "", "", "", "", ""]
		if filled:
			var m: Dictionary = _states[slot]
			var d := str(m.get("date", "")).split("/")
			var t := str(m.get("time", "")).split(":")
			if d.size() == 3:
				parts[0] = d[0]; parts[1] = d[1]; parts[2] = d[2]
			if t.size() == 3:
				parts[3] = t[0]; parts[4] = t[1]; parts[5] = t[2]
		for gi in range(6):
			(_date_groups[i][gi] as Label).text = parts[gi]
		_badges[i].texture = _atlas(Rect2i(54, 773, 68, 30))
		_badges[i].visible = filled and slot == newest
	_on_slot_hover(-1)


## Row -> slot index. The AUTO SAVE page exposes the single auto
## slot on its first row; other rows are inert (-1). (The original's
## AUTO page layout is unverified - only its tab was observed.)
func _slot_at(row: int) -> int:
	if _page < 10:
		return _page * 10 + row
	return 100 if row == 0 else -1


func _on_slot_hover(row: int) -> void:
	for i in range(10):
		_num_labels[i].add_theme_color_override("font_color",
				GOLD if i == row else BROWN)
	if row < 0:
		_no_label.text = ""
		_thumb.texture = null
		return
	var slot := _slot_at(row)
	if slot < 0:
		_no_label.text = ""
		_thumb.texture = null
		return
	_no_label.text = "%03d" % (slot + 1) if slot < 100 else "AUTO"
	if _states.has(slot) and FileAccess.file_exists(thumb_path(slot)):
		var img := Image.new()
		if img.load(thumb_path(slot)) == OK:
			_thumb.texture = ImageTexture.create_from_image(img)
	else:
		_thumb.texture = null


func _on_slot_click(row: int) -> void:
	var slot := _slot_at(row)
	if slot < 0:
		return
	if _mode == "save":
		if slot >= 100:
			return
		save_requested.emit(slot)
		flash_banner()
		_refresh()
	elif _states.has(slot):
		load_requested.emit(slot)


func _on_trash(row: int) -> void:
	var slot := _slot_at(row)
	if slot >= 0 and _states.has(slot):
		delete_requested.emit(slot)
		_refresh()


func flash_banner() -> void:
	_banner.visible = true
	var t := get_tree().create_timer(0.7)
	t.timeout.connect(func() -> void: _banner.visible = false)


func _load_cropped(pkg: GamePackage, image_name: String) -> Texture2D:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		push_warning("SaveLoadUI: image not found: " + image_name)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		return null
	var used: Rect2i = img.get_used_rect()
	if used.size.x > 0 and used.size.y > 0 and used.size != img.get_size():
		img = img.get_region(used)
	return ImageTexture.create_from_image(img)


func _load_raw(pkg: GamePackage, image_name: String) -> Texture2D:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		push_warning("SaveLoadUI: image not found: " + image_name)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)

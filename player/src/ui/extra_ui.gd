class_name ExtraUI
extends CanvasLayer
## Asset-driven EXTRA hub replicating the original: five tabs
## (CG鑑賞 / アニメ鑑賞 / シーン回想 / 立ち絵鑑賞 / 音楽鑑賞) over
## per-tab bases (pCg / pAnime / pMemory / pMusic) with sheet-driven
## tabs, page plates, frames and counters.
##
## Functional this round: MEMORIES (76 scenes — the CheckMemory
## dispatch values 1..76; value 0 is the story start, which is why
## the original counter denominator is 76, not 77) with reached
## thumbnails from the p_metn sheets and recollection start; MUSIC
## (11 tracks, titles baked into the pMusicButton tag cells; play /
## stop / repeat). CG and ANIMATION render their full grids in the
## locked state (their unlock accounting is unresolved data work:
## CG group->variant mapping is still unknown). The VIEWER tab is
## present in the header; its screen is built in the next round.

signal to_title
signal start_recollection(value: int)
signal music_play(track: int)
signal music_stop
signal music_repeat(on: bool)

const TABS := ["cg", "anime", "memory", "viewer", "music"]
const BASES := {"cg": "pCg", "anime": "pAnime", "memory": "pMemory",
		"music": "pMusic"}
const SHEETS := {"cg": "pCgButton", "anime": "pCgButton",
		"memory": "pMemoryButton", "music": "pMusicButton",
		"viewer": "pMemoryButton"}
const DIGIT_X := [40, 81, 113, 149, 183, 222, 257, 293, 328, 364]
const DIGIT_W := [30, 21, 28, 27, 32, 27, 29, 27, 30, 29]
## The small strip is "/0123456789": index 0 is the slash,
## indices 1..10 are digits 0..9.
const SMALL_DIGIT := [Rect2i(3, 467, 14, 24), Rect2i(20, 467, 16, 24),
		Rect2i(40, 467, 12, 24), Rect2i(57, 467, 15, 24),
		Rect2i(75, 467, 14, 24), Rect2i(92, 467, 16, 24),
		Rect2i(111, 467, 15, 24), Rect2i(128, 467, 15, 24),
		Rect2i(147, 467, 15, 24), Rect2i(165, 467, 15, 24),
		Rect2i(183, 467, 15, 24)]
const CG_PAGE1_TOTALS := [16, 14, 10, 8, 18, 29, 6, 9, 8, 12, 14, 10]
const MUSIC_TITLES := 11

var scenes: Array = []
var music_count := 11
## Set by Main before opening (the viewer renders through its own
## Stage, which needs the define table).
var define: DefineTable
var room: EmoteRoom

var _root: Control
var _tab := "cg"
var _pkg: GamePackage
var _base: TextureRect
var _built := false
var _sheets: Dictionary = {}
var _dyn: Array[Node] = []
var _page := 0
var _playing := 0  # music track (1-based), 0 = none
var _repeat := false


func _ready() -> void:
	layer = 70
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)


func is_open() -> bool:
	return _root.visible or (room != null and room.is_open())


func repeat_on() -> bool:
	return _repeat


func open_screen(pkg: GamePackage, tab: String) -> void:
	_pkg = pkg
	_tab = tab
	if pkg.is_web():
		for img in ["pCg", "pAnime", "pMemory", "pMusic",
				"pCgButton", "pMemoryButton", "pMusicButton",
				"p_metn01", "p_cgtn01"]:
			await pkg.ensure_image(img)
	if tab == "viewer":
		_root.visible = false
		if room == null:
			room = EmoteRoom.new()
			add_child(room)
			room.tab_selected.connect(func(t: String) -> void:
				open_screen(_pkg, t))
			room.to_title.connect(func() -> void: to_title.emit())
		room.open_room(pkg, define)
		return
	if room != null:
		room.close_room()
	if not _built:
		_build_static(pkg)
	_page = 0
	_rebuild()
	_root.visible = true


func close() -> void:
	_root.visible = false
	if room != null:
		room.close_room()


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if room != null and room.is_open():
		return  # the room handles its own input (incl. Esc)
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close()
		to_title.emit()
		get_viewport().set_input_as_handled()


func _build_static(pkg: GamePackage) -> void:
	_built = true
	_base = TextureRect.new()
	_base.stretch_mode = TextureRect.STRETCH_KEEP
	_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_base)
	for sheet_name in SHEETS.values():
		if not _sheets.has(sheet_name):
			_sheets[sheet_name] = _load_raw(pkg, sheet_name)


func _dyn_add(n: Node) -> Node:
	_root.add_child(n)
	_dyn.append(n)
	return n


func _clear_dyn() -> void:
	for n in _dyn:
		n.queue_free()
	_dyn.clear()


func _atlas(sheet: Texture2D, cell: Rect2i) -> AtlasTexture:
	var t := AtlasTexture.new()
	t.atlas = sheet
	t.region = Rect2(cell)
	return t


func _sheet() -> Texture2D:
	return _sheets[SHEETS[_tab]]


## Header: the five tab buttons + TITLE button, shared by all tabs.
func _build_header() -> void:
	var sheet := _sheet()
	var rows: Array = [87, 128, 170] if _tab == "music" \
			else [285, 326, 368]
	for i in range(TABS.size()):
		var b := TextureButton.new()
		b.position = Vector2(305 + i * 196, 12)
		b.size = Vector2(182, 38)
		b.stretch_mode = TextureButton.STRETCH_KEEP
		var cell := Rect2i(3 + i * 186, rows[0], 182, 38)
		if TABS[i] == _tab:
			cell.position.y = rows[2]
		b.texture_normal = _atlas(sheet, cell)
		var hov := Rect2i(3 + i * 186,
				rows[2] if TABS[i] == _tab else rows[1], 182, 38)
		b.texture_hover = _atlas(sheet, hov)
		b.texture_pressed = b.texture_hover
		var target: String = TABS[i]
		b.pressed.connect(func() -> void:
			if target != _tab:
				open_screen(_pkg, target))
		_dyn_add(b)
	var back := TextureButton.new()
	back.position = Vector2(62, 676)
	back.size = Vector2(278, 38)
	back.stretch_mode = TextureButton.STRETCH_KEEP
	var by := 3 if _tab == "music" else 201
	back.texture_normal = _atlas(sheet, Rect2i(3, by, 278, 38))
	back.texture_hover = _atlas(sheet, Rect2i(3, by + 42, 278, 38))
	back.texture_pressed = back.texture_hover
	back.pressed.connect(func() -> void:
		close()
		to_title.emit())
	_dyn_add(back)


## Page plates (62x62) for the paged tabs.
func _build_plates(count: int) -> void:
	var sheet := _sheet()
	for i in range(count):
		var b := TextureButton.new()
		b.position = Vector2(95 + i * 77, 105)
		b.size = Vector2(62, 62)
		b.stretch_mode = TextureButton.STRETCH_KEEP
		var row := 135 if i == _page else 3
		b.texture_normal = _atlas(sheet, Rect2i(3 + i * 66, row, 62, 62))
		b.texture_hover = _atlas(sheet,
				Rect2i(3 + i * 66, 135 if i == _page else 69, 62, 62))
		b.texture_pressed = b.texture_hover
		var p := i
		b.pressed.connect(func() -> void:
			_page = p
			_rebuild())
		_dyn_add(b)


## Big digit sprites (the sheets' 0-9 strip), right-aligned.
func _draw_number(sheet: Texture2D, value: int, right_x: int,
		y: int) -> void:
	var text := str(value)
	var total := 0
	for ch in text:
		total += DIGIT_W[int(ch)] + 3
	var x := right_x - total + 3
	for ch in text:
		var d := int(ch)
		var t := TextureRect.new()
		t.texture = _atlas(sheet, Rect2i(DIGIT_X[d], 413, DIGIT_W[d], 46))
		t.position = Vector2(x, y)
		t.stretch_mode = TextureRect.STRETCH_KEEP
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(t)
		x += DIGIT_W[d] + 3


func _rebuild() -> void:
	_clear_dyn()
	match _tab:
		"cg":
			_build_grid(false)
		"anime":
			_build_grid(true)
		"memory":
			_build_memory()
		"music":
			_build_music()
		"viewer":
			_build_header()


# ---- CG / ANIME grids (locked-state replica) ----

func _build_grid(anime: bool) -> void:
	_base.texture = _load_cropped(_pkg, BASES[_tab])
	_build_header()
	_build_plates(7)
	_draw_number(_sheet(), 0, 1152, 100)
	var sheet := _sheet()
	for i in range(12):
		var pos := Vector2(95 + (i % 4) * 285, 168 + (i / 4) * 156)
		var frame := TextureRect.new()
		frame.texture = _atlas(sheet, Rect2i(2, 493, 274, 162))
		frame.position = pos
		frame.stretch_mode = TextureRect.STRETCH_KEEP
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(frame)
		if not anime and _page == 0:
			_draw_small_counter(i, pos)


## "0/N" group counter at a CG frame's bottom-right (page 1 totals
## are the only ones measured from the original so far).
func _draw_small_counter(i: int, pos: Vector2) -> void:
	var sheet := _sheet()
	var text := "0/" + str(CG_PAGE1_TOTALS[i])
	var w := 0
	for ch in text:
		w += (SMALL_DIGIT[0].size.x if ch == "/" \
				else SMALL_DIGIT[int(ch) + 1].size.x) + 1
	var x := int(pos.x) + 274 - 10 - w
	for ch in text:
		var cell: Rect2i = SMALL_DIGIT[0] if ch == "/" \
				else SMALL_DIGIT[int(ch) + 1]
		var t := TextureRect.new()
		t.texture = _atlas(sheet, cell)
		t.position = Vector2(x, pos.y + 100)
		t.stretch_mode = TextureRect.STRETCH_KEEP
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dyn_add(t)
		x += cell.size.x + 1


# ---- MEMORIES ----

func _build_memory() -> void:
	_base.texture = _load_cropped(_pkg, "pMemory")
	_build_header()
	_build_plates(10)
	var reached := 0
	for s in scenes:
		if s["reached"]:
			reached += 1
	_draw_number(_sheet(), reached, 1098, 100)
	_draw_number(_sheet(), scenes.size(), 1180, 100)
	var info := Label.new()
	info.position = Vector2(240, 578)
	info.size = Vector2(810, 62)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	DialogueUI.apply_font(info, 19)
	info.add_theme_color_override("font_color", Color(0.5, 0.2, 0.15))
	_dyn_add(info)
	var sheet := _sheet()
	var thumbs: Texture2D = null
	for i in range(8):
		var idx := _page * 8 + i
		var pos := Vector2(95 + (i % 4) * 285, 175 + (i / 4) * 190)
		var frame := TextureButton.new()
		frame.position = pos
		frame.size = Vector2(274, 162)
		frame.stretch_mode = TextureButton.STRETCH_KEEP
		frame.texture_normal = _atlas(sheet, Rect2i(2, 493, 274, 162))
		frame.texture_hover = _atlas(sheet, Rect2i(278, 493, 274, 162))
		frame.texture_pressed = frame.texture_hover
		frame.disabled = idx >= scenes.size()
		_dyn_add(frame)
		if idx >= scenes.size():
			continue
		var entry: Dictionary = scenes[idx]
		if entry["reached"]:
			if thumbs == null:
				thumbs = _load_raw(_pkg,
						"p_metn%02d" % (_page + 1))
			var thumb := TextureRect.new()
			var s := idx % 8
			var cell := Rect2i(2 + (s % 4) * 258,
					2 + (1 + (s / 4) * 2) * 146, 258, 146)
			thumb.texture = _atlas(thumbs, cell)
			thumb.position = pos + Vector2(8, 8)
			thumb.stretch_mode = TextureRect.STRETCH_KEEP
			thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_dyn_add(thumb)
			frame.pressed.connect(func() -> void:
				close()
				start_recollection.emit(int(entry["value"])))
		frame.mouse_entered.connect(func() -> void:
			info.text = str(entry["caption"]) if entry["reached"] else "")
		frame.mouse_exited.connect(func() -> void: info.text = "")


# ---- MUSIC ----

func _build_music() -> void:
	_base.texture = _load_cropped(_pkg, "pMusic")
	_build_header()
	var sheet := _sheet()
	var stop := TextureButton.new()
	stop.position = Vector2(755, 93)
	stop.size = Vector2(238, 44)
	stop.stretch_mode = TextureButton.STRETCH_KEEP
	stop.texture_normal = _atlas(sheet, Rect2i(3, 213, 238, 44))
	stop.texture_hover = _atlas(sheet, Rect2i(3, 260, 238, 44))
	stop.texture_pressed = stop.texture_hover
	stop.pressed.connect(func() -> void:
		_playing = 0
		music_stop.emit()
		_rebuild())
	_dyn_add(stop)
	var rep := TextureButton.new()
	rep.position = Vector2(1005, 93)
	rep.size = Vector2(238, 44)
	rep.stretch_mode = TextureButton.STRETCH_KEEP
	var rep_row := 308 if _repeat else 213
	rep.texture_normal = _atlas(sheet, Rect2i(245, rep_row, 238, 44))
	rep.texture_hover = _atlas(sheet, Rect2i(245, 260, 238, 44))
	rep.texture_pressed = rep.texture_hover
	rep.pressed.connect(func() -> void:
		_repeat = not _repeat
		music_repeat.emit(_repeat)
		_rebuild())
	_dyn_add(rep)
	for n in range(1, music_count + 1):
		var group := (n - 1) / 4
		var idx := (n - 1) % 4
		var cell_x := 2 + idx * 490
		var cell_y := 356 + group * 216
		var tag := TextureButton.new()
		# Column-major like the original: 01-06 left, 07-11 right.
		tag.position = Vector2(105, 190 + (n - 1) * 82) if n <= 6 \
				else Vector2(700, 190 + (n - 7) * 82)
		tag.size = Vector2(488, 70)
		tag.stretch_mode = TextureButton.STRETCH_KEEP
		var state := 2 if _playing == n else 0
		tag.texture_normal = _atlas(sheet,
				Rect2i(cell_x, cell_y + state * 72, 488, 70))
		tag.texture_hover = _atlas(sheet,
				Rect2i(cell_x, cell_y + (2 if _playing == n else 1) * 72,
				488, 70))
		tag.texture_pressed = tag.texture_hover
		var track := n
		tag.pressed.connect(func() -> void:
			_playing = track
			music_play.emit(track)
			_rebuild())
		_dyn_add(tag)


# ---- image loading (same pattern as the other screens) ----

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
		push_warning("ExtraUI: image not found: " + image_name)
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

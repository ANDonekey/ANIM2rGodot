class_name FlowUI
extends CanvasLayer

## FLOW (story flowchart) screen, asset-driven from
## spFlowChartBase (the pre-rendered chart) and spFlowChartButton
## (buttons). The node table comes from define.dat: type-0x11
## records carry (kind, id, x, y) per node in chart coordinates,
## type-0x12 records carry each node's title + description text.
##
## Scope note: the package contains no node -> script-position
## table (searched exhaustively: define.dat is fully decoded, the
## sce label table / string pool / code hold no such mapping), so
## node jumping and passed/current colouring are NOT implemented;
## clicking a node focuses it (green marker, per the chart legend)
## and shows its title and description, exactly the data the
## package itself provides.

signal closed

const CHART := Rect2i(0, 0, 2048, 900)
const VIEW_POS := Vector2(8, 8)
const VIEW_SIZE := Vector2(1264, 556)
const ZOOMS: Array[float] = [0.6172, 0.85, 1.2, 1.7, 2.4]
const BTN_BACK := Rect2i(2, 2, 178, 39)
const BTN_BACK_H := Rect2i(2, 43, 178, 39)
const BTN_RESET := Rect2i(2, 84, 178, 39)
const BTN_RESET_H := Rect2i(2, 125, 178, 39)
const BTN_PLUS := Rect2i(2, 166, 58, 39)
const BTN_PLUS_H := Rect2i(2, 207, 58, 39)
const BTN_FIT := Rect2i(62, 166, 58, 39)
const BTN_FIT_H := Rect2i(62, 207, 58, 39)
const BTN_MINUS := Rect2i(122, 166, 58, 39)
const BTN_MINUS_H := Rect2i(122, 207, 58, 39)


class FocusMark:
	extends Control
	var kind := 0  # 0 square, 1 diamond, 2 circle

	func _draw() -> void:
		var c := Color(0.05, 0.8, 0.1, 0.9)
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		match kind:
			1:
				draw_colored_polygon(PackedVector2Array([
					Vector2(cx, 1), Vector2(size.x - 1, cy),
					Vector2(cx, size.y - 1), Vector2(1, cy)]), c)
			2:
				draw_circle(Vector2(cx, cy), cx - 1.0, c)
			_:
				draw_rect(Rect2(1, 1, size.x - 2, size.y - 2), c)


var _root: Control
var _view: Control
var _chart_tr: TextureRect
var _focus: FocusMark
var _panel: Label
var _btn_sheet: Texture2D
var _buttons: Array = []  # {rect, tr, cell, cell_h, action}
var _hover := -1
var _nodes: Array = []  # {id, kind, x, y}
var _descs: Dictionary = {}  # id -> String
var _zoom_i := 0
var _pan := Vector2.ZERO
var _focus_id := -1
var _dragging := false
var _drag_moved := false
var _drag_last := Vector2.ZERO
var _help: TextureRect
var _help_chip: PanelContainer
const HELP_RECT := Rect2(1176, 16, 88, 34)
var _built := false


func _ready() -> void:
	layer = 70
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.13, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)
	_view = Control.new()
	_view.position = VIEW_POS
	_view.size = VIEW_SIZE
	_view.clip_contents = true
	_root.add_child(_view)
	_chart_tr = TextureRect.new()
	_chart_tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_chart_tr.stretch_mode = TextureRect.STRETCH_SCALE
	_chart_tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.add_child(_chart_tr)
	_focus = FocusMark.new()
	_focus.size = Vector2(20, 20)
	_focus.visible = false
	_focus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.add_child(_focus)
	var panel_box := PanelContainer.new()
	panel_box.position = Vector2(24, 576)
	panel_box.size = Vector2(1040, 134)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.953, 0.918, 0.824)
	sb.border_color = Color(0.54, 0.43, 0.23)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(14)
	panel_box.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel_box)
	_panel = Label.new()
	_panel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	DialogueUI.apply_font(_panel, 17)
	_panel.add_theme_color_override("font_color", Color(0.16, 0.12, 0.07))
	panel_box.add_child(_panel)
	_help = TextureRect.new()
	_help.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_help.stretch_mode = TextureRect.STRETCH_SCALE
	_help.visible = false
	_root.add_child(_help)


func is_open() -> bool:
	return _root.visible


func open_screen(pkg: GamePackage) -> void:
	if not _built:
		_build(pkg)
	_root.visible = true
	_zoom_i = 0
	_pan = Vector2.ZERO
	_focus_id = -1
	_focus.visible = false
	_panel.text = ""
	_apply_transform()


func close() -> void:
	_root.visible = false
	_help.visible = false
	closed.emit()


func _build(pkg: GamePackage) -> void:
	_built = true
	var base_img := _load_image(pkg, "spFlowChartBase")
	if base_img != null:
		var at := AtlasTexture.new()
		at.atlas = ImageTexture.create_from_image(base_img)
		at.region = Rect2(CHART)
		_chart_tr.texture = at
	_btn_sheet = _load_raw(pkg, "spFlowChartButton")
	var help_img := _load_image(pkg, "spFlowhelp")
	if help_img != null:
		var used := help_img.get_used_rect()
		var hat := AtlasTexture.new()
		hat.atlas = ImageTexture.create_from_image(help_img)
		hat.region = Rect2(used)
		_help.texture = hat
		_help.size = Vector2(used.size) * 0.62
		_help.position = (Vector2(1280, 720) - _help.size) * 0.5
	var data := _parse_flow(pkg.define_bytes())
	_nodes = data["nodes"]
	_descs = data["descs"]
	_mk_button(Rect2(1094, 577, 58, 39), BTN_PLUS, BTN_PLUS_H, "plus")
	_mk_button(Rect2(1154, 577, 58, 39), BTN_FIT, BTN_FIT_H, "fit")
	_mk_button(Rect2(1214, 577, 58, 39), BTN_MINUS, BTN_MINUS_H, "minus")
	_mk_button(Rect2(1094, 624, 178, 39), BTN_RESET, BTN_RESET_H, "reset")
	_mk_button(Rect2(1094, 671, 178, 39), BTN_BACK, BTN_BACK_H, "back")
	_help_chip = PanelContainer.new()
	_help_chip.position = HELP_RECT.position
	_help_chip.size = HELP_RECT.size
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.953, 0.918, 0.824, 0.92)
	hsb.border_color = Color(0.54, 0.43, 0.23)
	hsb.set_border_width_all(2)
	hsb.set_corner_radius_all(8)
	_help_chip.add_theme_stylebox_override("panel", hsb)
	var hl := Label.new()
	hl.text = "ヘルプ"
	hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	DialogueUI.apply_font(hl, 16)
	hl.add_theme_color_override("font_color", Color(0.16, 0.12, 0.07))
	_help_chip.add_child(hl)
	_root.add_child(_help_chip)


func _mk_button(rect: Rect2, cell: Rect2i, cell_h: Rect2i,
		action: String) -> void:
	var tr := TextureRect.new()
	tr.position = rect.position
	tr.size = rect.size
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _btn_sheet != null:
		var at := AtlasTexture.new()
		at.atlas = _btn_sheet
		at.region = Rect2(cell)
		tr.texture = at
	_root.add_child(tr)
	_buttons.append({"rect": rect, "tr": tr, "cell": cell,
			"cell_h": cell_h, "action": action})


func _set_button_tex(b: Dictionary, hover: bool) -> void:
	if _btn_sheet == null:
		return
	var at := AtlasTexture.new()
	at.atlas = _btn_sheet
	at.region = Rect2(b["cell_h"] if hover else b["cell"])
	(b["tr"] as TextureRect).texture = at


## define.dat flow tables. Node block: the longest run of 20-byte
## records [u32 0x11][kind][id][x][y]; description block follows:
## [u32 0x12][id][cp932/gbk cstring] records to end of data.
func _parse_flow(d: PackedByteArray) -> Dictionary:
	var out := {"nodes": [], "descs": {}}
	var best_start := -1
	var best_len := 0
	var i := 0
	while i + 20 <= d.size():
		if _u32(d, i) == 0x11 and _u32(d, i + 8) >= 101 \
				and _u32(d, i + 8) <= 999:
			var n := 0
			var j := i
			while j + 20 <= d.size() and _u32(d, j) == 0x11:
				n += 1
				j += 20
			if n > best_len:
				best_len = n
				best_start = i
			i = j
		else:
			i += 1  # block start alignment varies by package
	if best_start < 0:
		return out
	var nodes: Array = []
	for k in best_len:
		var o := best_start + k * 20
		nodes.append({"id": int(_u32(d, o + 8)),
				"kind": int(_u32(d, o + 4)),
				"x": int(_u32(d, o + 12)), "y": int(_u32(d, o + 16))})
	out["nodes"] = nodes
	# Descriptions: raw byte strings first, charset picked by the
	# same bad-string probe the script loader uses.
	var raw: Dictionary = {}
	var p := best_start + best_len * 20
	while p + 8 <= d.size() and _u32(d, p) == 0x12:
		var id := int(_u32(d, p + 4))
		var e := p + 8
		while e < d.size() and d[e] != 0:
			e += 1
		raw[id] = d.slice(p + 8, e)
		p = e + 1
	var sample: Array = []
	for id in raw.keys().slice(0, 24):
		sample.append(raw[id])
	var cs932 := Charset.load_mode("cp932")
	var cs_gbk := Charset.load_mode("gbk")
	var cs: Charset = cs_gbk if cs_gbk.bad_string_count(sample) \
			< cs932.bad_string_count(sample) else cs932
	var descs: Dictionary = {}
	for id in raw:
		descs[id] = cs.decode(raw[id])
	out["descs"] = descs
	return out


func _u32(d: PackedByteArray, o: int) -> int:
	return int(d[o]) | (int(d[o + 1]) << 8) | (int(d[o + 2]) << 16) \
			| (int(d[o + 3]) << 24)


func _zoom() -> float:
	return ZOOMS[_zoom_i]


func _apply_transform() -> void:
	var z := _zoom()
	# Clamp pan so the chart never leaves a void on the right/bottom
	# beyond one viewport of slack.
	var cw := CHART.size.x * z
	var ch := CHART.size.y * z
	_pan.x = clampf(_pan.x, VIEW_SIZE.x - cw, 0.0)
	_pan.y = clampf(_pan.y, VIEW_SIZE.y - ch, 0.0)
	if cw <= VIEW_SIZE.x:
		_pan.x = (VIEW_SIZE.x - cw) * 0.5
	if ch <= VIEW_SIZE.y:
		_pan.y = (VIEW_SIZE.y - ch) * 0.5
	_chart_tr.position = _pan
	_chart_tr.size = Vector2(CHART.size) * z
	_update_focus_marker()


func _node_center(n: Dictionary) -> Vector2:
	return Vector2(float(n["x"]) + 6.0, float(n["y"]) + 6.0)


func _update_focus_marker() -> void:
	if _focus_id < 0:
		_focus.visible = false
		return
	for n in _nodes:
		if int(n["id"]) == _focus_id:
			var c := _node_center(n)
			_focus.kind = 1 if int(n["kind"]) == 1 else \
					(2 if int(n["kind"]) == 2 else 0)
			_focus.position = _pan + c * _zoom() - _focus.size * 0.5
			_focus.visible = true
			return
	_focus.visible = false


func _focus_node(id: int) -> void:
	_focus_id = id
	_update_focus_marker()
	var text: String = _descs.get(id, "")
	_panel.text = text.replace("@n", "\n")


func _to_chart(screen: Vector2) -> Vector2:
	return (screen - VIEW_POS - _pan) / _zoom()


func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		if _help.visible:
			_help.visible = false
		else:
			close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = event.position
		if _help.visible:
			_help.visible = false
			get_viewport().set_input_as_handled()
			return
		if HELP_RECT.has_point(pos):
			_help.visible = true
			get_viewport().set_input_as_handled()
			return
		for bi in _buttons.size():
			if (_buttons[bi]["rect"] as Rect2).has_point(pos):
				_do_button(String(_buttons[bi]["action"]))
				get_viewport().set_input_as_handled()
				return
		if Rect2(VIEW_POS, VIEW_SIZE).has_point(pos):
			_dragging = true
			_drag_moved = false
			_drag_last = pos
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and not event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and _dragging:
		_dragging = false
		if not _drag_moved:
			var c := _to_chart(event.position)
			var best := -1
			var best_d := 16.0
			for n in _nodes:
				var d := c.distance_to(_node_center(n))
				if d < best_d:
					best_d = d
					best = int(n["id"])
			if best >= 0:
				_focus_node(best)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if _dragging:
			var delta: Vector2 = event.position - _drag_last
			_drag_last = event.position
			if delta.length() > 0.0:
				if delta.length() > 2.0:
					_drag_moved = true
				_pan += delta
				_apply_transform()
			get_viewport().set_input_as_handled()
			return
		var hi := -1
		for bi in _buttons.size():
			if (_buttons[bi]["rect"] as Rect2).has_point(event.position):
				hi = bi
				break
		if hi != _hover:
			if _hover >= 0:
				_set_button_tex(_buttons[_hover], false)
			_hover = hi
			if _hover >= 0:
				_set_button_tex(_buttons[_hover], true)


func _do_button(action: String) -> void:
	match action:
		"plus":
			_zoom_i = mini(_zoom_i + 1, ZOOMS.size() - 1)
		"minus":
			_zoom_i = maxi(_zoom_i - 1, 0)
		"fit":
			_zoom_i = 0
			_pan = Vector2.ZERO
		"reset":
			_zoom_i = 0
			_pan = Vector2.ZERO
			_focus_id = -1
			_focus.visible = false
			_panel.text = ""
		"back":
			close()
			return
	_apply_transform()


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
	return ImageTexture.create_from_image(img) if img != null else null
